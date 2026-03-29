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

grouped_response="$(hot_sample_eval_in_file "$HOT_SAMPLE_PROBE_FILE" 'const x: i32 = 40; (x + 2)')" || fail "grouped in-file block eval failed"
grouped_value="$(decode_raw_value "$grouped_response")"
[[ "$grouped_value" == "42" ]] || fail "unexpected grouped eval result: $grouped_value"

negated_response="$(hot_sample_hotreq --op eval --code '-40 + 42')" || fail "negated root eval failed"
negated_value="$(decode_raw_value "$negated_response")"
[[ "$negated_value" == "2" ]] || fail "unexpected negated eval result: $negated_value"

arithmetic_response="$(hot_sample_hotreq --op eval --code '6 * 7 - 40')" || fail "arithmetic root eval failed"
arithmetic_value="$(decode_raw_value "$arithmetic_response")"
[[ "$arithmetic_value" == "2" ]] || fail "unexpected arithmetic eval result: $arithmetic_value"

boolean_response="$(hot_sample_hotreq --op eval --code '!false')" || fail "boolean root eval failed"
boolean_value="$(decode_raw_value "$boolean_response")"
[[ "$boolean_value" == "true" ]] || fail "unexpected boolean eval result: $boolean_value"

conditional_response="$(hot_sample_hotreq --op eval --code 'if (6 * 7 == 42) "ok" else "bad"')" || fail "conditional root eval failed"
conditional_value="$(decode_text_value "$conditional_response")"
[[ "$conditional_value" == "ok" ]] || fail "unexpected conditional eval result: $conditional_value"

bound_conditional_response="$(hot_sample_hotreq --op eval --code 'const ok = 6 * 7 == 42; if (ok) "ok" else "bad"')" || fail "bound conditional root eval failed"
bound_conditional_value="$(decode_text_value "$bound_conditional_response")"
[[ "$bound_conditional_value" == "ok" ]] || fail "unexpected bound conditional eval result: $bound_conditional_value"

compiler_fallback_response="$(hot_sample_hotreq --op eval --code $'blk: {\n    if (6 * 7 == 42) {\n        break :blk \"ok\";\n    } else {\n        break :blk \"bad\";\n    }\n}')" || fail "compiler fallback root eval failed"
compiler_fallback_value="$(decode_text_value "$compiler_fallback_response")"
[[ "$compiler_fallback_value" == "ok" ]] || fail "unexpected compiler fallback eval result: $compiler_fallback_value"

compiler_switch_response="$(hot_sample_hotreq --op eval --code 'switch (6 * 7 == 42) { true => "ok", false => "bad" }')" || fail "compiler switch fallback root eval failed"
compiler_switch_value="$(decode_text_value "$compiler_switch_response")"
[[ "$compiler_switch_value" == "ok" ]] || fail "unexpected compiler switch eval result: $compiler_switch_value"

compiler_switch_integer_response="$(hot_sample_hotreq --op eval --code 'switch (6 * 7) { 41 => "bad", 42 => "ok", else => "bad" }')" || fail "compiler integer-switch fallback root eval failed"
compiler_switch_integer_value="$(decode_text_value "$compiler_switch_integer_response")"
[[ "$compiler_switch_integer_value" == "ok" ]] || fail "unexpected compiler integer-switch eval result: $compiler_switch_integer_value"

compiler_optional_payload_if_response="$(hot_sample_hotreq --op eval --code 'if (@as(?[]const u8, "ok")) |value| value else "bad"')" || fail "compiler optional-payload-if fallback root eval failed"
compiler_optional_payload_if_value="$(decode_text_value "$compiler_optional_payload_if_response")"
[[ "$compiler_optional_payload_if_value" == "ok" ]] || fail "unexpected compiler optional-payload-if eval result: $compiler_optional_payload_if_value"

compiler_error_union_catch_response="$(hot_sample_hotreq --op eval --code '(@as(anyerror![]const u8, "ok") catch "bad")')" || fail "compiler error-union-catch fallback root eval failed"
compiler_error_union_catch_value="$(decode_text_value "$compiler_error_union_catch_response")"
[[ "$compiler_error_union_catch_value" == "ok" ]] || fail "unexpected compiler error-union-catch eval result: $compiler_error_union_catch_value"

compiler_error_union_payload_if_response="$(hot_sample_hotreq --op eval --code 'if (@as(anyerror![]const u8, "ok")) |value| value else |_| "bad"')" || fail "compiler error-union-payload-if fallback root eval failed"
compiler_error_union_payload_if_value="$(decode_text_value "$compiler_error_union_payload_if_response")"
[[ "$compiler_error_union_payload_if_value" == "ok" ]] || fail "unexpected compiler error-union-payload-if eval result: $compiler_error_union_payload_if_value"

compiler_logical_and_response="$(hot_sample_hotreq --op eval --code 'if ((6 * 7 == 42) and (1 + 1 == 2)) "ok" else "bad"')" || fail "compiler logical-and fallback root eval failed"
compiler_logical_and_value="$(decode_text_value "$compiler_logical_and_response")"
[[ "$compiler_logical_and_value" == "ok" ]] || fail "unexpected compiler logical-and eval result: $compiler_logical_and_value"

compiler_logical_or_response="$(hot_sample_hotreq --op eval --code 'if ((6 * 7 != 42) or (1 + 1 == 2)) "ok" else "bad"')" || fail "compiler logical-or fallback root eval failed"
compiler_logical_or_value="$(decode_text_value "$compiler_logical_or_response")"
[[ "$compiler_logical_or_value" == "ok" ]] || fail "unexpected compiler logical-or eval result: $compiler_logical_or_value"

compiler_min_response="$(hot_sample_hotreq --op eval --code 'if (@min(42, 100) == 42) "ok" else "bad"')" || fail "compiler builtin-min fallback root eval failed"
compiler_min_value="$(decode_text_value "$compiler_min_response")"
[[ "$compiler_min_value" == "ok" ]] || fail "unexpected compiler builtin-min eval result: $compiler_min_value"

compiler_max_response="$(hot_sample_hotreq --op eval --code 'if (@max(40, 42) == 42) "ok" else "bad"')" || fail "compiler builtin-max fallback root eval failed"
compiler_max_value="$(decode_text_value "$compiler_max_response")"
[[ "$compiler_max_value" == "ok" ]] || fail "unexpected compiler builtin-max eval result: $compiler_max_value"

compiler_orelse_response="$(hot_sample_hotreq --op eval --code 'if ((@as(?i32, 42) orelse 0) == 42) "ok" else "bad"')" || fail "compiler orelse fallback root eval failed"
compiler_orelse_value="$(decode_text_value "$compiler_orelse_response")"
[[ "$compiler_orelse_value" == "ok" ]] || fail "unexpected compiler orelse eval result: $compiler_orelse_value"

second_literal_response="$(hot_sample_hotreq --op eval --code '"pong"')" || fail "second root literal eval failed"
second_literal_value="$(decode_text_value "$second_literal_response")"
[[ "$second_literal_value" == "pong" ]] || fail "unexpected second literal eval result: $second_literal_value"

generation_after="$(hot_sample_current_generation)"
[[ "$generation_before" == "$generation_after" ]] || fail \
  "eval changed generation unexpectedly: before=$generation_before after=$generation_after"

printf 'PASS live eval path works (generation=%s, literal=%s, block=%s, grouped=%s, negated=%s, arithmetic=%s, boolean=%s, conditional=%s, bound_conditional=%s, compiler_fallback=%s, compiler_switch=%s, compiler_switch_integer=%s, compiler_optional_payload_if=%s, compiler_error_union_catch=%s, compiler_error_union_payload_if=%s, compiler_logical_and=%s, compiler_logical_or=%s, compiler_min=%s, compiler_max=%s, compiler_orelse=%s, second=%s)\n' \
  "$generation_after" \
  "$literal_value" \
  "$block_value" \
  "$grouped_value" \
  "$negated_value" \
  "$arithmetic_value" \
  "$boolean_value" \
  "$conditional_value" \
  "$bound_conditional_value" \
  "$compiler_fallback_value" \
  "$compiler_switch_value" \
  "$compiler_switch_integer_value" \
  "$compiler_optional_payload_if_value" \
  "$compiler_error_union_catch_value" \
  "$compiler_error_union_payload_if_value" \
  "$compiler_logical_and_value" \
  "$compiler_logical_or_value" \
  "$compiler_min_value" \
  "$compiler_max_value" \
  "$compiler_orelse_value" \
  "$second_literal_value"
