#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

target="src/termio/stream_handler.zig"
active_expr='stream_handler.__hot_sample_output_overlay_active()'

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
overlay="$tmpdir/stream_handler_dots_to_bangs.zig"
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
    printf 'ACTIVE %s replacement=.->! generation=%s\n' \
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
  revert_generation="$(hot_sample_current_generation)"
  printf 'Deactivated output overlay on %s (generation %s -> %s).\n' \
    "$target" \
    "$base_generation" \
    "$revert_generation"
  exit 0
fi

if [[ "$active" == "true" ]]; then
  printf 'Already active %s replacement=.->! generation=%s\n' \
    "$target" \
    "$(hot_sample_current_generation)"
  exit 0
fi

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
                const cp = if (value.cp == '.') '!' else value.cp;
                try self.terminal.print(cp);
            },
'''
count = src.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 .print branch, found {count}")
marker = '''

pub fn __hot_sample_output_overlay_active() bool {
    return true;
}
'''
overlay.write_text(src.replace(needle, replacement, 1).rstrip() + marker)
PY

base_generation="$(hot_sample_current_generation)"
hot_sample_load_file "$target" "$overlay"
overlay_generation="$(hot_sample_current_generation)"

printf 'Activated output overlay on %s (generation %s -> %s).\n' \
  "$target" \
  "$base_generation" \
  "$overlay_generation"
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
