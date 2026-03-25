#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

target="src/file_type.zig"
active_expr='file_type.__hot_sample_file_type_overlay_active()'
extension_expr='file_type.__hot_sample_file_type_overlay_extension()'
mapped_tag_expr='file_type.__hot_sample_file_type_overlay_mapped_tag()'

mode="toggle"
if [[ $# -gt 0 ]]; then
  case "$1" in
    toggle|on|off|status)
      mode="$1"
      shift
      ;;
  esac
fi

extension="${1:-.hot}"
mapped_tag="${2:-png}"

if [[ ! "$mapped_tag" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "mapped enum tag must be a Zig identifier, got: $mapped_tag" >&2
  exit 2
fi

tmpdir="$(mktemp -d)"
overlay="$tmpdir/file_type_overlay.zig"
trap 'rm -rf "$tmpdir"' EXIT

if [[ "$mode" != "status" && "$mode" != "off" ]]; then
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
marker = f'''

pub fn __hot_sample_file_type_overlay_active() bool {{
    return true;
}}

pub fn __hot_sample_file_type_overlay_extension() []const u8 {{
    return {json.dumps(extension)};
}}

pub fn __hot_sample_file_type_overlay_mapped_tag() []const u8 {{
    return {json.dumps(mapped_tag)};
}}
'''
overlay.write_text(src.replace(needle, replacement, 1).rstrip() + marker)
PY
fi

toggle_response="$(hot_sample_toggle_request "$mode" "$active_expr" \
  --toggle-load "$target=$overlay" \
  --toggle-restore "$target=$target")"
action="$(printf '%s\n' "$toggle_response" | hot_sample_json_get action)"
active="$(printf '%s\n' "$toggle_response" | hot_sample_json_get active)"

if [[ "$mode" == "status" ]]; then
  if [[ "$active" == "true" ]]; then
    extension="$(hot_sample_probe_text "$extension_expr")"
    mapped_tag="$(hot_sample_probe_text "$mapped_tag_expr")"
    code="$(python3 -c 'import json,sys; ext=sys.argv[1]; tag=sys.argv[2]; print(f"FileType.guessFromExtension({json.dumps(ext)}) == .{tag}")' "$extension" "$mapped_tag")"
    value="$(hot_sample_eval_in_file "$target" "$code" | hot_sample_json_get value)"
    printf 'ACTIVE %s extension=%s mapped_tag=%s value=%s generation=%s\n' \
      "$target" \
      "$extension" \
      "$mapped_tag" \
      "$value" \
      "$(hot_sample_current_generation)"
  else
    printf 'INACTIVE %s\n' "$target"
  fi
  exit 0
fi

if [[ "$action" == "none" ]]; then
  if [[ "$active" == "true" ]]; then
    printf 'Already active %s extension=%s mapped_tag=%s generation=%s\n' \
      "$target" \
      "$(hot_sample_probe_text "$extension_expr")" \
      "$(hot_sample_probe_text "$mapped_tag_expr")" \
      "$(hot_sample_current_generation)"
  else
    printf 'Already inactive %s\n' "$target"
  fi
  exit 0
fi

generation_before="$(printf '%s\n' "$toggle_response" | hot_sample_json_get generation-before)"
generation_after="$(printf '%s\n' "$toggle_response" | hot_sample_json_get generation-after)"

if [[ "$action" == "off" ]]; then
  printf 'Deactivated file_type overlay on %s (generation %s -> %s).\n' \
    "$target" \
    "$generation_before" \
    "$generation_after"
  exit 0
fi

code="$(python3 -c 'import json,sys; ext=sys.argv[1]; tag=sys.argv[2]; print(f"FileType.guessFromExtension({json.dumps(ext)}) == .{tag}")' "$extension" "$mapped_tag")"
value="$(hot_sample_eval_in_file "$target" "$code" | hot_sample_json_get value)"

printf 'Activated file_type overlay on %s: mapped %s to .%s -> %s (generation %s -> %s).\n' \
  "$target" \
  "$extension" \
  "$mapped_tag" \
  "$value" \
  "$generation_before" \
  "$generation_after"
printf 'Run `%s status` to inspect or `%s off` to restore the real file.\n' \
  "$(basename "$0")" \
  "$(basename "$0")"
