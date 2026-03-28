#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"
bash "$script_dir/test_hot_live_window_health.sh" >/dev/null

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

decode_text_value() {
  printf '%s\n' "$1" | hot_sample_json_get value | hot_sample_decode_text_value
}

decode_raw_value() {
  printf '%s\n' "$1" | hot_sample_json_get value
}

generation_before="$(hot_sample_current_generation)"

literal_response="$(hot_sample_hotreq --op eval --code '"ping"')" || fail "root literal eval failed"
literal_value="$(decode_text_value "$literal_response")"
[[ "$literal_value" == "ping" ]] || fail "unexpected literal eval result: $literal_value"

block_response="$(hot_sample_eval_in_file "$HOT_SAMPLE_PROBE_FILE" 'const x: i32 = 41; x + 1')" || fail "in-file block eval failed"
block_value="$(decode_raw_value "$block_response")"
[[ "$block_value" == "42" ]] || fail "unexpected block eval result: $block_value"

second_literal_response="$(hot_sample_hotreq --op eval --code '"pong"')" || fail "second root literal eval failed"
second_literal_value="$(decode_text_value "$second_literal_response")"
[[ "$second_literal_value" == "pong" ]] || fail "unexpected second literal eval result: $second_literal_value"

generation_after="$(hot_sample_current_generation)"
[[ "$generation_before" == "$generation_after" ]] || fail \
  "eval changed generation unexpectedly: before=$generation_before after=$generation_after"

printf 'PASS live eval path works (generation=%s, literal=%s, block=%s, second=%s)\n' \
  "$generation_after" \
  "$literal_value" \
  "$block_value" \
  "$second_literal_value"
