#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"
bash "$script_dir/test_hot_live_window_health.sh" >/dev/null

target="src/font/shaper/run.zig"
sample_script="$HOT_SAMPLE_REPO_ROOT/tools/hot_sample_output_dots_to_bangs.sh"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

json_get() {
  local key="$1"
  python3 -c 'import json,sys; value=json.load(sys.stdin)[sys.argv[1]]; print(value if isinstance(value, str) else json.dumps(value))' "$key"
}

make_overlay() {
  local overlay_path="$1"
  python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$overlay_path" <<'PY'
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
}

raw_active() {
  local overlay_path="$1"
  hot_sample_overlay_file_match "$target" "$overlay_path" | json_get matches
}

helper_state() {
  local status_output
  status_output="$("$sample_script" status)"
  case "$status_output" in
    ACTIVE\ *) printf 'active\n' ;;
    INACTIVE\ *) printf 'inactive\n' ;;
    *) fail "unexpected helper status output: $status_output" ;;
  esac
}

assert_consistent_state() {
  local overlay_path="$1"
  local expected="$2"
  local helper
  local raw

  helper="$(helper_state)"
  raw="$(raw_active "$overlay_path")"

  if [[ "$expected" == "active" ]]; then
    [[ "$helper" == "active" ]] || fail "helper reported $helper while expecting active"
    [[ "$raw" == "true" ]] || fail "raw overlay match reported $raw while expecting active"
  else
    [[ "$helper" == "inactive" ]] || fail "helper reported $helper while expecting inactive"
    [[ "$raw" == "false" ]] || fail "raw overlay match reported $raw while expecting inactive"
  fi
}

assert_generation_increased() {
  local before="$1"
  local after="$2"
  [[ "$after" =~ ^[0-9]+$ ]] || fail "non-numeric generation: $after"
  if (( after <= before )); then
    fail "generation did not increase: before=$before after=$after"
  fi
}

assert_generation_same() {
  local before="$1"
  local after="$2"
  if [[ "$after" != "$before" ]]; then
    fail "generation changed unexpectedly: before=$before after=$after"
  fi
}

run_and_capture() {
  "$@"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
overlay="$tmpdir/output_dots_to_bangs_overlay.zig"
make_overlay "$overlay"

initial_generation="$(hot_sample_current_generation)"
printf 'live generation=%s\n' "$initial_generation"

if [[ "$(raw_active "$overlay")" == "true" ]]; then
  before="$(hot_sample_current_generation)"
  run_and_capture "$sample_script" off >/dev/null
  after="$(hot_sample_current_generation_retry)"
  assert_generation_increased "$before" "$after"
fi
assert_consistent_state "$overlay" inactive

before="$(hot_sample_current_generation)"
run_and_capture "$sample_script" on >/dev/null
after="$(hot_sample_current_generation_retry)"
assert_generation_increased "$before" "$after"
assert_consistent_state "$overlay" active

before="$after"
run_and_capture "$sample_script" on >/dev/null
after="$(hot_sample_current_generation_retry)"
assert_generation_same "$before" "$after"
assert_consistent_state "$overlay" active

before="$after"
run_and_capture "$sample_script" off >/dev/null
after="$(hot_sample_current_generation_retry)"
assert_generation_increased "$before" "$after"
assert_consistent_state "$overlay" inactive

before="$after"
run_and_capture "$sample_script" off >/dev/null
after="$(hot_sample_current_generation_retry)"
assert_generation_same "$before" "$after"
assert_consistent_state "$overlay" inactive

before="$after"
run_and_capture "$sample_script" toggle >/dev/null
after="$(hot_sample_current_generation_retry)"
assert_generation_increased "$before" "$after"
assert_consistent_state "$overlay" active

before="$after"
run_and_capture "$sample_script" toggle >/dev/null
after="$(hot_sample_current_generation_retry)"
assert_generation_increased "$before" "$after"
assert_consistent_state "$overlay" inactive

printf 'PASS live output toggle helper remained consistent through on/off/toggle cycles (generation=%s)\n' "$after"
