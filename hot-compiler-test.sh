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

clean_dir() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  printf 'clean\t%s\n' "$path"
  rm -rf "$path"
}

clean_dir "$ROOT_DIR/.zig-cache"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  clean_dir "$path"
done < <(
  find "$ROOT_DIR/vendor/zig/test/standalone" -mindepth 2 -maxdepth 2 -type d \
    \( -name .zig-cache -o -name zig-out \) | sort
)

run_test() {
  local file="$1"
  local start=$SECONDS
  echo "==> $file"
  ZIG_LIB_DIR="$ZIG_LIB_DIR" "$ZIG_BIN" test "$file"
  printf 'time\t%s\t%ss\n' "$file" "$((SECONDS - start))"
}

run_smoke() {
  local script="$1"
  local start=$SECONDS
  echo "==> $script"
  ZIG_BIN="$ZIG_BIN" ZIG_LIB_DIR="$ZIG_LIB_DIR" "$script"
  printf 'time\t%s\t%ss\n' "$script" "$((SECONDS - start))"
}

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  run_test "$file"
done < <(
  grep -E -l '^test([[:space:]]+"|[[:space:]]*\{)' \
    "$ROOT_DIR"/vendor/zig/lib/compiler/hot/*.zig || true
)

run_test "$ROOT_DIR/vendor/zig/lib/std/std.zig"
while IFS= read -r script; do
  [[ -n "$script" ]] || continue
  run_smoke "$script"
done < <(
  find "$ROOT_DIR/vendor/zig/test/standalone" -mindepth 2 -maxdepth 2 -name 'hot-smoke-test.sh' | sort
)
printf 'time\t%s\t%ss\n' "hot-compiler-test-total" "$((SECONDS - SUITE_START))"
