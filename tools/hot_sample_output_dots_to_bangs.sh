#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

target="src/font/shaper/run.zig"
state_file="${TMPDIR:-/tmp}/ghostty-hot-sample-output-dots-to-bangs.state"

load_generation_state() {
  cached_base_generation=""
  cached_overlay_generation=""
  [[ -f "$state_file" ]] || return 0

  while IFS='=' read -r key value; do
    case "$key" in
      target)
        if [[ "$value" != "$target" ]]; then
          cached_base_generation=""
          cached_overlay_generation=""
          return 0
        fi
        ;;
      base_generation) cached_base_generation="$value" ;;
      overlay_generation) cached_overlay_generation="$value" ;;
    esac
  done <"$state_file"
}

write_generation_state() {
  local base_generation="$1"
  local overlay_generation="$2"
  local tmp_state

  tmp_state="$(mktemp "${state_file}.XXXXXX")"
  printf 'target=%s\nbase_generation=%s\noverlay_generation=%s\n' \
    "$target" \
    "$base_generation" \
    "$overlay_generation" >"$tmp_state"
  mv "$tmp_state" "$state_file"
}

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
load_generation_state

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
  if [[ -n "${cached_base_generation:-}" && -n "${cached_overlay_generation:-}" && "$generation_before" == "$cached_overlay_generation" ]]; then
    if hot_sample_activate_generation "$cached_base_generation" >/dev/null 2>&1; then
      generation_after="$(hot_sample_current_generation_retry)"
      printf 'Deactivated output overlay on %s (generation %s -> %s).\n' \
        "$target" \
        "$generation_before" \
        "$generation_after"
      exit 0
    fi
  fi

  hot_sample_restore_file "$target"
  generation_after="$(hot_sample_current_generation_retry)"
  write_generation_state "$generation_after" "$generation_before"
  printf 'Deactivated output overlay on %s (generation %s -> %s).\n' \
    "$target" \
    "$generation_before" \
    "$generation_after"
  exit 0
fi

if [[ -n "${cached_base_generation:-}" && -n "${cached_overlay_generation:-}" && "$generation_before" == "$cached_base_generation" ]]; then
  if hot_sample_activate_generation "$cached_overlay_generation" >/dev/null 2>&1; then
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
    exit 0
  fi
fi

hot_sample_load_file "$target" "$overlay"
generation_after="$(hot_sample_current_generation_retry)"
write_generation_state "$generation_before" "$generation_after"

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
