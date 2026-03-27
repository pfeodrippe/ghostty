#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

target="src/termio/stream_handler.zig"
marker_target="src/input/mouse.zig"
active_expr='mouse.__hot_sample_output_overlay_active()'

mode="toggle"
if [[ $# -gt 0 ]]; then
  case "$1" in
    toggle|on|off|status)
      mode="$1"
      shift
      ;;
  esac
fi

tmpdir="$(mktemp -d)"
overlay="$tmpdir/termio_output_dots_to_bangs.zig"
marker_overlay="$tmpdir/output_marker.zig"
trap 'rm -rf "$tmpdir"' EXIT

if [[ "$mode" != "status" && "$mode" != "off" ]]; then
  python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$overlay" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
needle = '''            .print => {
                @branchHint(.likely);
                try self.terminal.print(value.cp);
            },
'''
replacement = '''            .print => {
                @branchHint(.likely);
                const cp: u21 = if (value.cp == 46) 33 else value.cp;
                try self.terminal.print(cp);
            },
'''
count = src.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 print branch, found {count}")
overlay.write_text(src.replace(needle, replacement, 1))
PY

  python3 - "$HOT_SAMPLE_REPO_ROOT/$marker_target" "$marker_overlay" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
marker = '''

pub fn __hot_sample_output_overlay_active() bool {
    return true;
}
'''
overlay.write_text(src.rstrip() + marker)
PY
fi

toggle_response="$(hot_sample_toggle_request "$mode" "$active_expr" \
  --toggle-load "$target=$overlay" \
  --toggle-restore "$target=$target" \
  --toggle-load "$marker_target=$marker_overlay" \
  --toggle-restore "$marker_target=$marker_target")"
action="$(printf '%s\n' "$toggle_response" | hot_sample_json_get action)"
active="$(printf '%s\n' "$toggle_response" | hot_sample_json_get active)"

if [[ "$mode" == "status" ]]; then
  if [[ "$active" == "true" ]]; then
    printf 'ACTIVE %s replacement=.->! generation=%s\n' \
      "$target" \
      "$(hot_sample_current_generation)"
  else
    printf 'INACTIVE %s\n' "$target"
  fi
  exit 0
fi

if [[ "$action" == "none" ]]; then
  if [[ "$active" == "true" ]]; then
    printf 'Already active %s replacement=.->! generation=%s\n' \
      "$target" \
      "$(hot_sample_current_generation)"
  else
    printf 'Already inactive %s\n' "$target"
  fi
  exit 0
fi

generation_before="$(printf '%s\n' "$toggle_response" | hot_sample_json_get generation-before)"
generation_after="$(printf '%s\n' "$toggle_response" | hot_sample_json_get generation-after)"

if [[ "$action" == "off" ]]; then
  printf 'Deactivated output overlay on %s (generation %s -> %s).\n' \
    "$target" \
    "$generation_before" \
    "$generation_after"
  exit 0
fi

printf 'Activated output overlay on %s (generation %s -> %s).\n' \
  "$target" \
  "$generation_before" \
  "$generation_after"
printf '%s\n' \
  'Now run a command in Ghostty that prints periods, for example:' \
  "  printf 'a.b.c\\n'" \
  "  echo 'version 1.2.3'" \
  '' \
  'Expected result while the overlay is active:' \
  '  - every printed "." shows up as "!" in the Ghostty terminal UI' \
  '  - for example, a.b.c becomes a!b!c' \
  '' \
  'Run this script again, or use `off`, to restore the real file.'
