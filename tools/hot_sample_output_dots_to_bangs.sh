#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

target="src/font/shaper/run.zig"

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
trap 'rm -rf "$tmpdir"' EXIT

python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$overlay" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
needle = '''    fn addCodepoint(self: *RunIterator, hasher: anytype, cp: u32, cluster: u32) !void {
        autoHash(hasher, cp);
        autoHash(hasher, cluster);
        try self.hooks.addCodepoint(cp, cluster);
    }
'''
replacement = '''    fn addCodepoint(self: *RunIterator, hasher: anytype, cp: u32, cluster: u32) !void {
        const visible_cp: u32 = if (cp == '.') '!' else cp;
        autoHash(hasher, visible_cp);
        autoHash(hasher, cluster);
        try self.hooks.addCodepoint(visible_cp, cluster);
    }
'''
count = src.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 print branch, found {count}")
marker = '''

pub fn __hot_sample_output_overlay_active() bool {
    return true;
}
'''
overlay.write_text(src.replace(needle, replacement, 1).rstrip() + marker)
PY

match_response="$(hot_sample_overlay_file_match "$target" "$overlay")"
active="$(printf '%s\n' "$match_response" | hot_sample_json_get matches)"
effective_mode="$mode"

if [[ "$mode" == "toggle" ]]; then
  if [[ "$active" == "true" ]]; then
    effective_mode="off"
  else
    effective_mode="on"
  fi
fi

if [[ "$mode" == "status" ]]; then
  if [[ "$active" == "true" ]]; then
    printf 'ACTIVE %s replacement=.->! generation=%s\n' \
      "$target" \
      "$(hot_sample_current_generation_retry)"
  else
    printf 'INACTIVE %s\n' "$target"
  fi
  exit 0
fi

generation_before="$(hot_sample_current_generation)"

if [[ "$effective_mode" == "on" && "$active" == "true" ]]; then
  printf 'Already active %s replacement=.->! generation=%s\n' \
    "$target" \
    "$generation_before"
  exit 0
fi

if [[ "$effective_mode" == "off" && "$active" != "true" ]]; then
  printf 'Already inactive %s\n' "$target"
  exit 0
fi

if [[ "$effective_mode" == "off" ]]; then
  hot_sample_restore_file "$target"
  generation_after="$(hot_sample_current_generation_retry)"
  printf 'Deactivated output overlay on %s (generation %s -> %s).\n' \
    "$target" \
    "$generation_before" \
    "$generation_after"
  exit 0
fi

hot_sample_load_file "$target" "$overlay"
generation_after="$(hot_sample_current_generation_retry)"

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
