#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

extension="${1:-.hot}"
mapped_tag="${2:-png}"

if [[ ! "$mapped_tag" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "mapped enum tag must be a Zig identifier, got: $mapped_tag" >&2
  exit 2
fi

target="src/file_type.zig"
tmpdir="$(mktemp -d)"
overlay="$tmpdir/file_type_overlay.zig"
loaded=0

cleanup() {
  if [[ "$loaded" -eq 1 ]]; then
    hot_sample_hotreq --op load-file --path "$target" --file-path "$target" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$overlay" "$extension" "$mapped_tag" <<'PY'
from pathlib import Path
import json
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
extension = sys.argv[3]
mapped_tag = sys.argv[4]
needle = '    pub fn guessFromExtension(extension: []const u8) FileType {\n'
replacement = (
    '    pub fn guessFromExtension(extension: []const u8) FileType {\n'
    f'        if (std.ascii.eqlIgnoreCase(extension, {json.dumps(extension)})) return .{mapped_tag};\n'
)
count = src.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 guessFromExtension signature, found {count}")
overlay.write_text(src.replace(needle, replacement, 1))
PY

base_generation="$(hot_sample_current_generation)"
hot_sample_hotreq --op load-file --path "$target" --file-path "$overlay" >/dev/null
loaded=1
overlay_generation="$(hot_sample_current_generation)"

code="$(python3 -c 'import json,sys; ext=sys.argv[1]; tag=sys.argv[2]; print(f"FileType.guessFromExtension({json.dumps(ext)}) == .{tag}")' "$extension" "$mapped_tag")"
response="$(hot_sample_eval_in_file "$target" "$code")"
value="$(printf '%s\n' "$response" | hot_sample_json_get value)"

hot_sample_hotreq --op load-file --path "$target" --file-path "$target" >/dev/null
loaded=0
revert_generation="$(hot_sample_current_generation)"

printf 'overlay file_type mapped %s to .%s -> %s (generation %s -> %s -> %s)\n' \
  "$extension" \
  "$mapped_tag" \
  "$value" \
  "$base_generation" \
  "$overlay_generation" \
  "$revert_generation"
