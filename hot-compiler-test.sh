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

run_test() {
  local file="$1"
  echo "==> $file"
  ZIG_LIB_DIR="$ZIG_LIB_DIR" "$ZIG_BIN" test "$file"
}

run_test_filter() {
  local file="$1"
  local filter="$2"
  echo "==> $file :: $filter"
  ZIG_LIB_DIR="$ZIG_LIB_DIR" "$ZIG_BIN" test "$file" --test-filter "$filter"
}

run_test "$ROOT_DIR/vendor/zig/lib/compiler/hot/bytecode.zig"
run_test "$ROOT_DIR/vendor/zig/lib/compiler/hot/expr.zig"
run_test "$ROOT_DIR/vendor/zig/lib/compiler/hot/fast_c_runtime.zig"
run_test "$ROOT_DIR/vendor/zig/lib/compiler/hot/fast_zig_runtime.zig"
run_test "$ROOT_DIR/vendor/zig/lib/compiler/hot/marshal.zig"
run_test "$ROOT_DIR/vendor/zig/lib/compiler/hot/typed_call.zig"
run_test_filter "$ROOT_DIR/vendor/zig/lib/compiler/hot/typed_thunk_test.zig" "struct parameter thunks"
run_test_filter "$ROOT_DIR/vendor/zig/lib/compiler/hot/typed_thunk_test.zig" "nested slice parameters"
run_test_filter "$ROOT_DIR/vendor/zig/lib/compiler/hot/typed_thunk_test.zig" "enum and optional slice parameters"
run_test_filter "$ROOT_DIR/vendor/zig/lib/compiler/hot/typed_thunk_test.zig" "allocator error-return thunks"
run_test_filter "$ROOT_DIR/vendor/zig/lib/compiler/hot/bundle.zig" "loadDeclarationGraph"
run_test_filter "$ROOT_DIR/vendor/zig/lib/compiler/hot/bundle.zig" "source-informed"
run_test_filter "$ROOT_DIR/vendor/zig/lib/compiler/hot/bundle.zig" "specializes symbol runtime arguments"
run_test_filter "$ROOT_DIR/vendor/zig/lib/compiler/hot/bundle.zig" "falls back to typed thunk for hidden aggregate returns"
run_test_filter "$ROOT_DIR/vendor/zig/lib/compiler/hot/bundle.zig" "falls back to typed thunk for nested slice parameters"
