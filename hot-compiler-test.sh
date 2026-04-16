#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_BIN="${ZIG_BIN:-$ROOT_DIR/.zig-toolchain/zig-0.15.2/bin/zig}"
ZIG_LIB_DIR="${ZIG_LIB_DIR:-$ROOT_DIR/vendor/zig/lib}"
LLVM_PREFIX="${LLVM_PREFIX:-$(brew --prefix llvm@20 2>/dev/null || true)}"
LLD_PREFIX="${LLD_PREFIX:-$(brew --prefix lld@20 2>/dev/null || true)}"
ZSTD_PREFIX="${ZSTD_PREFIX:-$(brew --prefix zstd 2>/dev/null || true)}"
LIBXML2_PREFIX="${LIBXML2_PREFIX:-$(brew --prefix libxml2 2>/dev/null || true)}"
ZLIB_PREFIX="${ZLIB_PREFIX:-$(brew --prefix zlib 2>/dev/null || true)}"

if [[ ! -x "$ZIG_BIN" ]]; then
  echo "error: missing zig binary at $ZIG_BIN" >&2
  exit 1
fi

prepend_lib_dir() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  if [[ -z "${DYLD_LIBRARY_PATH:-}" ]]; then
    export DYLD_LIBRARY_PATH="$dir"
  else
    export DYLD_LIBRARY_PATH="$dir:$DYLD_LIBRARY_PATH"
  fi
}

prepend_lib_dir "$LLVM_PREFIX/lib"
prepend_lib_dir "$LLD_PREFIX/lib"
prepend_lib_dir "$ZSTD_PREFIX/lib"
prepend_lib_dir "$LIBXML2_PREFIX/lib"
prepend_lib_dir "$ZLIB_PREFIX/lib"
export ZIG_HOT_ZIG_BIN="$ZIG_BIN"
SUITE_START=$SECONDS
HOT_TEST_CLEAN="${HOT_TEST_CLEAN:-0}"
HOT_COMPILER_SUITE="${HOT_COMPILER_SUITE:-$ROOT_DIR/vendor/zig/lib/compiler/hot/test_suite.zig}"
HOT_COMPILER_BUILD_CACHE_DIR="${HOT_COMPILER_BUILD_CACHE_DIR:-$ROOT_DIR/.zig-hot-compiler-build-cache}"
HOT_COMPILER_GLOBAL_CACHE_DIR="${HOT_COMPILER_GLOBAL_CACHE_DIR:-$ROOT_DIR/.zig-hot-compiler-global-cache}"
HOT_COMPILER_TEST_FILTER="${HOT_COMPILER_TEST_FILTER:-}"
HOT_COMPILER_SKIP_SMOKES="${HOT_COMPILER_SKIP_SMOKES:-}"
if [[ -z "$HOT_COMPILER_SKIP_SMOKES" ]]; then
  if [[ -n "$HOT_COMPILER_TEST_FILTER" ]]; then
    HOT_COMPILER_SKIP_SMOKES=1
  else
    HOT_COMPILER_SKIP_SMOKES=0
  fi
fi
# These standalone hot smokes can be run in parallel, but cold hot-run builds
# can be memory-hungry. Keep the default serial unless the caller opts in.
HOT_SMOKE_JOBS="${HOT_SMOKE_JOBS:-1}"
PARALLEL_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hot-compiler-test.XXXXXX")"

cleanup_parallel_logs() {
  [[ -d "$PARALLEL_LOG_DIR" ]] || return 0
  rm -rf "$PARALLEL_LOG_DIR"
}
trap cleanup_parallel_logs EXIT

clean_dir() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  printf 'clean\t%s\n' "$path"
  rm -rf "$path"
}

prune_runtime_path() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  printf 'clean\t%s\n' "$path"
  rm -rf "$path"
}

if [[ "$HOT_TEST_CLEAN" == "1" ]]; then
  clean_dir "$HOT_COMPILER_BUILD_CACHE_DIR"
  clean_dir "$HOT_COMPILER_GLOBAL_CACHE_DIR"
  clean_dir "$ROOT_DIR/.zig-cache"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    clean_dir "$path"
  done < <(
    find "$ROOT_DIR/vendor/zig/test/standalone" -mindepth 2 -maxdepth 2 -type d \
      \( -name .zig-cache -o -name zig-out \) | sort
  )
else
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    prune_runtime_path "$path"
  done < <(
    {
      find "$ROOT_DIR/vendor/zig/test/standalone" \
        \( -name '.nrepl-port' -o -name '.hot-run.log' -o -name '.hot-run.pid' -o \
           -name '.hot-run.stdin' -o -name '.hot-run.stdin.pid' -o \
           -name '.build.log' -o -name '*.build.log' -o -name '.vscode-smoke-hot-run.log' \) -print
      find "$ROOT_DIR/vendor/zig/test/standalone" -path '*/zig-out/share/zig-hot/*.config' -print
    } | sort -u
  )
fi

mkdir -p "$HOT_COMPILER_BUILD_CACHE_DIR" "$HOT_COMPILER_GLOBAL_CACHE_DIR"

run_test() {
  local file="$1"
  local start=$SECONDS
  local -a zig_args=(
    test "$file"
    --cache-dir "$HOT_COMPILER_BUILD_CACHE_DIR"
    --global-cache-dir "$HOT_COMPILER_GLOBAL_CACHE_DIR"
  )
  if [[ -n "$HOT_COMPILER_TEST_FILTER" ]]; then
    zig_args+=(--test-filter "$HOT_COMPILER_TEST_FILTER")
  fi
  echo "==> $file"
  ZIG_LIB_DIR="$ZIG_LIB_DIR" "$ZIG_BIN" "${zig_args[@]}"
  printf 'time\t%s\t%ss\n' "$file" "$((SECONDS - start))"
}

run_smoke() {
  local script="$1"
  local start=$SECONDS
  echo "==> $script"
  ZIG_BIN="$ZIG_BIN" ZIG_LIB_DIR="$ZIG_LIB_DIR" "$script"
  printf 'time\t%s\t%ss\n' "$script" "$((SECONDS - start))"
}

run_smokes_parallel() {
  local jobs="$1"
  shift
  local scripts=("$@")
  local total="${#scripts[@]}"

  if (( total == 0 )); then
    return 0
  fi

  if (( jobs <= 1 || total == 1 )); then
    local script
    for script in "${scripts[@]}"; do
      run_smoke "$script"
    done
    return 0
  fi

  local -a pids=()
  local -a logs=()
  local next_index=0
  local failure=0

  launch_smoke() {
    local script="$1"
    local log="$PARALLEL_LOG_DIR/smoke.$next_index.log"
    (
      run_smoke "$script"
    ) >"$log" 2>&1 &
    pids+=("$!")
    logs+=("$log")
  }

  drain_one_smoke() {
    local done_index=-1
    local i pid rc

    while (( done_index < 0 )); do
      for (( i = 0; i < ${#pids[@]}; i += 1 )); do
        pid="${pids[$i]}"
        if ! kill -0 "$pid" 2>/dev/null; then
          wait "$pid"
          rc=$?
          done_index="$i"
          break
        fi
      done
      (( done_index >= 0 )) || sleep 1
    done

    cat "${logs[$done_index]}"
    rm -f "${logs[$done_index]}"

    if (( rc != 0 && failure == 0 )); then
      failure="$rc"
      for pid in "${pids[@]}"; do
        [[ "$pid" == "${pids[$done_index]}" ]] && continue
        kill -TERM "$pid" 2>/dev/null || true
      done
    fi

    unset 'pids[done_index]'
    unset 'logs[done_index]'
    pids=("${pids[@]}")
    logs=("${logs[@]}")
  }

  while (( next_index < total )); do
    launch_smoke "${scripts[$next_index]}"
    next_index=$((next_index + 1))
    if (( ${#pids[@]} >= jobs )); then
      drain_one_smoke
      (( failure == 0 )) || break
    fi
  done

  while (( ${#pids[@]} > 0 )); do
    drain_one_smoke
  done

  return "$failure"
}

run_test "$HOT_COMPILER_SUITE"

if [[ "$HOT_COMPILER_SKIP_SMOKES" == "1" ]]; then
  printf 'skip\t%s\n' "standalone hot smoke tests"
else
  smoke_scripts=()
  while IFS= read -r script; do
    [[ -n "$script" ]] || continue
    smoke_scripts+=("$script")
  done < <(
    # hot_specialization_reload only re-runs focused bundle/runtime/typed_thunk unit
    # tests that already ran above via the aggregated suite, so keep it out of the
    # full umbrella. The merged hot_specialization_suite replaces the legacy
    # per-shape hot_specialization_* standalones so they share one hot-run startup.
    {
      find "$ROOT_DIR/vendor/zig/test/standalone" -mindepth 2 -maxdepth 2 -name 'hot-smoke-test.sh' \
        ! -path "$ROOT_DIR/vendor/zig/test/standalone/hot_specialization_*/hot-smoke-test.sh"
      printf '%s\n' "$ROOT_DIR/vendor/zig/test/standalone/hot_specialization_suite/hot-smoke-test.sh"
    } | sort
  )
  run_smokes_parallel "$HOT_SMOKE_JOBS" "${smoke_scripts[@]}"
fi
printf 'time\t%s\t%ss\n' "hot-compiler-test-total" "$((SECONDS - SUITE_START))"
