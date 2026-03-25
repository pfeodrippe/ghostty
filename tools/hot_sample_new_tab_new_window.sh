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

active="false"
if active_value="$(hot_sample_try_probe_value "$active_expr")"; then
  active="$active_value"
fi

if [[ "$mode" == "toggle" ]]; then
  if [[ "$active" == "true" ]]; then
    mode="off"
  else
    mode="on"
  fi
fi

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

if [[ "$mode" == "off" ]]; then
  if [[ "$active" != "true" ]]; then
    printf 'Already inactive %s\n' "$target"
    exit 0
  fi

  base_generation="$(hot_sample_current_generation)"
  hot_sample_restore_file "$target"
  hot_sample_restore_file "$marker_target"
  revert_generation="$(hot_sample_current_generation)"
  printf 'Deactivated New Tab overlay on %s (generation %s -> %s).\n' \
    "$target" \
    "$base_generation" \
    "$revert_generation"
  exit 0
fi

if [[ "$active" == "true" ]]; then
  printf 'Already active %s behavior=new-tab-opens-new-window generation=%s\n' \
    "$target" \
    "$(hot_sample_current_generation)"
  exit 0
fi

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

base_generation="$(hot_sample_current_generation)"
hot_sample_load_file "$target" "$overlay"
if ! hot_sample_load_file "$marker_target" "$marker_overlay"; then
  hot_sample_restore_file "$target"
  exit 1
fi
overlay_generation="$(hot_sample_current_generation)"

printf 'Activated New Tab overlay on %s (generation %s -> %s).\n' \
  "$target" \
  "$base_generation" \
  "$overlay_generation"
printf '%s\n' \
  'Now trigger New Tab once in the Ghostty UI.' \
  'Expected result:' \
  '  - a new Ghostty window opens instead of a tab' \
  '  - the terminal where hot-run is running prints: [hot_sample] new_tab -> newWindow' \
  '' \
  'Run this script again, or use `off`, to restore the real file.'
