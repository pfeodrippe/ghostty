#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

status_of() {
  printf '%s\n' "$1" | hot_sample_json_get status
}

value_of() {
  printf '%s\n' "$1" | hot_sample_json_get value
}

bash "$script_dir/test_hot_live_window_health.sh" >/dev/null || fail "live Ghostty window is not healthy before declaration eval"

session="$(hot_sample_new_session)"
trap 'hot_sample_close_session "$session" >/dev/null 2>&1 || true' EXIT

generation_before="$(hot_sample_current_generation)"

root_before="$(
  hot_sample_hotreq \
    --op eval \
    --path "$HOT_SAMPLE_PROBE_FILE" \
    --code 'Button.max'
)" || fail "root Button.max probe failed before declaration eval"
[[ "$(status_of "$root_before")" == "[\"done\"]" ]] || fail "unexpected root pre-eval status"
[[ "$(value_of "$root_before")" == "11" ]] || fail "unexpected root Button.max before eval"

decl_response="$(
  hot_sample_hotreq \
    --session "$session" \
    --op eval \
    --scope session \
    --path "$HOT_SAMPLE_PROBE_FILE" \
    --code $'pub const Button = enum(c_int) {\n    const Self = @This();\n\n    pub const max = 99;\n\n    unknown = 0,\n    left = 1,\n    right = 2,\n    middle = 3,\n    four = 4,\n    five = 5,\n    six = 6,\n    seven = 7,\n    eight = 8,\n    nine = 9,\n    ten = 10,\n    eleven = 11,\n};\n'
)" || fail "declaration eval failed"

decl_status="$(status_of "$decl_response")"
[[ "$decl_status" == "[\"done\"]" ]] || fail "unexpected declaration-eval status: $decl_status"

session_call="$(
  hot_sample_hotreq \
    --session "$session" \
    --op eval \
    --path "$HOT_SAMPLE_PROBE_FILE" \
    --code 'Button.max'
)" || fail "session Button.max call failed after declaration eval"

[[ "$(status_of "$session_call")" == "[\"done\"]" ]] || fail "unexpected session declaration call status"
[[ "$(value_of "$session_call")" == "99" ]] || fail "unexpected session Button.max after declaration eval"

root_during="$(
  hot_sample_hotreq \
    --op eval \
    --path "$HOT_SAMPLE_PROBE_FILE" \
    --code 'Button.max'
)" || fail "root Button.max probe failed during session declaration eval"
[[ "$(status_of "$root_during")" == "[\"done\"]" ]] || fail "unexpected root during-eval status"
[[ "$(value_of "$root_during")" == "11" ]] || fail "unexpected root Button.max during session declaration eval"

generation_after="$(hot_sample_current_generation)"
[[ "$generation_before" == "$generation_after" ]] || fail \
  "declaration eval changed root generation unexpectedly: before=$generation_before after=$generation_after"

hot_sample_close_session "$session" >/dev/null 2>&1 || true
trap - EXIT

root_after="$(
  hot_sample_hotreq \
    --op eval \
    --path "$HOT_SAMPLE_PROBE_FILE" \
    --code 'Button.max'
)" || fail "root Button.max probe failed after session close"
[[ "$(status_of "$root_after")" == "[\"done\"]" ]] || fail "unexpected root after-close status"
[[ "$(value_of "$root_after")" == "11" ]] || fail "unexpected root Button.max after session close"

bash "$script_dir/test_hot_live_window_health.sh" >/dev/null || fail "live Ghostty window is not healthy after declaration eval"

printf 'PASS live declaration eval changes session behavior and cleans up against %s (session=%s root=%s session_value=%s generation=%s)\n' \
  "$HOT_SAMPLE_PROBE_FILE" \
  "$session" \
  "$(value_of "$root_after")" \
  "$(value_of "$session_call")" \
  "$generation_after"
