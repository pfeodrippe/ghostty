#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

target="src/Surface.zig"
marker_target="src/input/mouse.zig"
active_expr='mouse.__hot_sample_new_tab_overlay_active()'

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
overlay="$tmpdir/surface_new_tab_new_window.zig"
marker_overlay="$tmpdir/mouse_new_tab_marker.zig"
trap 'rm -rf "$tmpdir"' EXIT

if [[ "$mode" != "status" && "$mode" != "off" ]]; then
  python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$overlay" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
needle = '''        .new_tab => return try self.rt_app.performAction(
            .{ .surface = self },
            .new_tab,
            {},
        ),
'''
replacement = '''        .new_tab => {
            std.debug.print("[hot_sample] new_tab -> newWindow\\n", .{});
            try self.app.newWindow(self.rt_app, .{ .parent = self });
            return true;
        },
'''
count = src.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 .new_tab branch, found {count}")
overlay.write_text(src.replace(needle, replacement, 1))
PY

  python3 - "$HOT_SAMPLE_REPO_ROOT/$marker_target" "$marker_overlay" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
marker = '''

pub fn __hot_sample_new_tab_overlay_active() bool {
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
    printf 'ACTIVE %s behavior=new-tab-opens-new-window generation=%s\n' \
      "$target" \
      "$(hot_sample_current_generation)"
  else
    printf 'INACTIVE %s\n' "$target"
  fi
  exit 0
fi

if [[ "$action" == "none" ]]; then
  if [[ "$active" == "true" ]]; then
    printf 'Already active %s behavior=new-tab-opens-new-window generation=%s\n' \
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
  printf 'Deactivated New Tab overlay on %s (generation %s -> %s).\n' \
    "$target" \
    "$generation_before" \
    "$generation_after"
  exit 0
fi

printf 'Activated New Tab overlay on %s (generation %s -> %s).\n' \
  "$target" \
  "$generation_before" \
  "$generation_after"
printf '%s\n' \
  'Now trigger New Tab once in the Ghostty UI.' \
  'Expected result:' \
  '  - a new Ghostty window opens instead of a tab' \
  '  - the terminal where hot-run is running prints: [hot_sample] new_tab -> newWindow' \
  '' \
  'Run this script again, or use `off`, to restore the real file.'
