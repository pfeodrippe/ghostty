#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

factor="${1:-4}"
right="${2:-800}"
top="${3:-600}"

if [[ ! "$factor" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $(basename "$0") [positive-scale-numerator] [right>0] [top>0]" >&2
  exit 2
fi
if [[ ! "$right" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ ! "$top" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "usage: $(basename "$0") [positive-scale-numerator] [right>0] [top>0]" >&2
  exit 2
fi

target="src/math.zig"
tmpdir="$(mktemp -d)"
overlay="$tmpdir/math_overlay.zig"
loaded=0

cleanup() {
  if [[ "$loaded" -eq 1 ]]; then
    hot_sample_hotreq --op load-file --path "$target" --file-path "$target" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$overlay" "$factor" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
factor = sys.argv[3]
needle = '.{ 2 / w, 0, 0, 0 },'
replacement = f'.{{ {factor} / w, 0, 0, 0 }},'
count = src.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 ortho2d x-scale row, found {count}")
overlay.write_text(src.replace(needle, replacement, 1))
PY

base_generation="$(hot_sample_current_generation)"
hot_sample_hotreq --op load-file --path "$target" --file-path "$overlay" >/dev/null
loaded=1
overlay_generation="$(hot_sample_current_generation)"

code="$(python3 -c 'import sys; right=sys.argv[1]; top=sys.argv[2]; print(f"const m = ortho2d(0, {right}, 0, {top}); m[0][0]")' "$right" "$top")"
response="$(hot_sample_eval_in_file "$target" "$code")"
value="$(printf '%s\n' "$response" | hot_sample_json_get value)"

hot_sample_hotreq --op load-file --path "$target" --file-path "$target" >/dev/null
loaded=0
revert_generation="$(hot_sample_current_generation)"

printf 'overlay math scale factor=%s changed ortho2d(0, %s, 0, %s)[0][0] to %s (generation %s -> %s -> %s)\n' \
  "$factor" \
  "$right" \
  "$top" \
  "$value" \
  "$base_generation" \
  "$overlay_generation" \
  "$revert_generation"
