#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"
bash "$script_dir/test_hot_live_window_health.sh" >/dev/null

target="src/font/shaper/run.zig"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

json_get() {
  local key="$1"
  python3 -c 'import json,sys; value=json.load(sys.stdin)[sys.argv[1]]; print(value if isinstance(value, str) else json.dumps(value))' "$key"
}

decode_text_value() {
  printf '%s\n' "$1" | hot_sample_json_get value | hot_sample_decode_text_value
}

decode_raw_value() {
  printf '%s\n' "$1" | hot_sample_json_get value
}

measure_ms_to_file() {
  local output_path="$1"
  shift
  python3 - "$output_path" "$@" <<'PY'
from pathlib import Path
import subprocess
import sys
import time

output_path = Path(sys.argv[1])
cmd = sys.argv[2:]
start = time.perf_counter_ns()
proc = subprocess.run(cmd, capture_output=True, text=True)
end = time.perf_counter_ns()
output_path.write_text(proc.stdout)
sys.stdout.write(f"{(end - start) / 1_000_000:.3f}\n")
sys.stderr.write(proc.stderr)
raise SystemExit(proc.returncode)
PY
}

measure_shell_ms_to_file() {
  local output_path="$1"
  shift
  local start_ns
  local end_ns
  local rc

  start_ns="$(python3 -c 'import time; print(time.perf_counter_ns())')"
  set +e
  "$@" >"$output_path"
  rc=$?
  set -e
  end_ns="$(python3 -c 'import time; print(time.perf_counter_ns())')"

  python3 - "$start_ns" "$end_ns" <<'PY'
import sys
start_ns = int(sys.argv[1])
end_ns = int(sys.argv[2])
print(f"{(end_ns - start_ns) / 1_000_000:.3f}")
PY
  return "$rc"
}

make_output_overlay() {
  local visible_char="$1"
  local overlay_path="$2"
  python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$visible_char" "$overlay_path" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
visible = sys.argv[2]
overlay = Path(sys.argv[3])
needle = '''    fn addCodepoint(self: *RunIterator, hasher: anytype, cp: u32, cluster: u32) !void {
        autoHash(hasher, cp);
        autoHash(hasher, cluster);
        try self.hooks.addCodepoint(cp, cluster);
    }
'''
replacement = f'''    fn addCodepoint(self: *RunIterator, hasher: anytype, cp: u32, cluster: u32) !void {{
        const visible_cp: u32 = if (cp == '.') '{visible}' else cp;
        autoHash(hasher, visible_cp);
        autoHash(hasher, cluster);
        try self.hooks.addCodepoint(visible_cp, cluster);
    }}
'''
count = src.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 print branch, found {count}")
overlay.write_text(src.replace(needle, replacement, 1))
PY
}

status_of() {
  local response="$1"
  printf '%s\n' "$response" | json_get status
}

string_field() {
  local response="$1"
  local key="$2"
  printf '%s\n' "$response" | json_get "$key"
}

assert_done_response() {
  local output_path="$1"
  local expected_activation="$2"
  local response

  response="$(cat "$output_path")"
  [[ "$(status_of "$response")" == "[\"done\"]" ]] || fail "unexpected load-file response: $response"
  if [[ -n "$expected_activation" ]]; then
    [[ "$(string_field "$response" activation-kind)" == "$expected_activation" ]] || fail "unexpected activation-kind in response: $response"
  fi
}

printf 'baseline_start_generation=%s\n' "$(hot_sample_current_generation)"

literal_output_file="$(mktemp)"
block_output_file="$(mktemp)"
decl_output_file="$(mktemp)"
dispatch_ab_output_file="$(mktemp)"
dispatch_bc_output_file="$(mktemp)"
publication_ab_output_file="$(mktemp)"
publication_bc_output_file="$(mktemp)"
overlay_b="$(mktemp)"
overlay_c="$(mktemp)"
trap 'rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$dispatch_ab_output_file" "$dispatch_bc_output_file" "$publication_ab_output_file" "$publication_bc_output_file" "$overlay_b" "$overlay_c"' EXIT

literal_ms="$(measure_ms_to_file "$literal_output_file" "$HOT_SAMPLE_HELPER" --timeout "$HOT_SAMPLE_TIMEOUT" --port-file "$HOT_SAMPLE_PORT_FILE" --op eval --code '"ping"')" || fail "root literal eval failed"
literal_value="$(decode_text_value "$(cat "$literal_output_file")")"
[[ "$literal_value" == "ping" ]] || fail "unexpected literal eval result: $literal_value"
printf 'eval_literal_ms=%s value=%s\n' "$literal_ms" "$literal_value"

block_session="$(hot_sample_new_session)"
trap 'hot_sample_close_session "$block_session" >/dev/null 2>&1 || true; rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$dispatch_ab_output_file" "$dispatch_bc_output_file" "$publication_ab_output_file" "$publication_bc_output_file" "$overlay_b" "$overlay_c"' EXIT
hot_sample_hotreq --session "$block_session" --op in-file --path "$HOT_SAMPLE_PROBE_FILE" >/dev/null || fail "in-file setup failed"
block_ms="$(measure_ms_to_file "$block_output_file" "$HOT_SAMPLE_HELPER" --timeout "$HOT_SAMPLE_TIMEOUT" --port-file "$HOT_SAMPLE_PORT_FILE" --session "$block_session" --op eval --code 'const x: i32 = 41; x + 1')" || fail "in-file block eval failed"
block_value="$(decode_raw_value "$(cat "$block_output_file")")"
[[ "$block_value" == "42" ]] || fail "unexpected block eval result: $block_value"
hot_sample_close_session "$block_session" >/dev/null || true
trap 'rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$dispatch_ab_output_file" "$dispatch_bc_output_file" "$publication_ab_output_file" "$publication_bc_output_file" "$overlay_b" "$overlay_c"' EXIT
printf 'eval_in_file_block_ms=%s value=%s\n' "$block_ms" "$block_value"

decl_session="$(hot_sample_new_session)"
trap 'hot_sample_close_session "$decl_session" >/dev/null 2>&1 || true; rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$dispatch_ab_output_file" "$dispatch_bc_output_file" "$publication_ab_output_file" "$publication_bc_output_file" "$overlay_b" "$overlay_c"' EXIT
decl_code=$'pub fn __hot_sample_decl_latency_probe() i32 {\n    return 101;\n}\n'
set +e
decl_ms="$(measure_ms_to_file "$decl_output_file" "$HOT_SAMPLE_HELPER" --timeout "$HOT_SAMPLE_TIMEOUT" --port-file "$HOT_SAMPLE_PORT_FILE" --session "$decl_session" --op eval --scope session --path "$HOT_SAMPLE_PROBE_FILE" --code "$decl_code")"
decl_rc=$?
set -e
if [[ $decl_rc -eq 0 ]]; then
  decl_value="$(decode_raw_value "$(
    hot_sample_hotreq --session "$decl_session" --op eval --path "$HOT_SAMPLE_PROBE_FILE" --code '__hot_sample_decl_latency_probe()'
  )")"
  [[ "$decl_value" == "101" ]] || fail "unexpected declaration eval probe result: $decl_value"
  decl_generation="$(cat "$decl_output_file" | json_get generation)"
  printf 'eval_declaration_session_ms=%s generation=%s value=%s status=done\n' "$decl_ms" "$decl_generation" "$decl_value"
else
  decl_err="$(python3 - "$decl_output_file" <<'PY'
import json
import sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    print(data.get("err", "unknown error"))
except Exception:
    print("unknown error")
PY
)"
  printf 'eval_declaration_session_ms=%s status=error err=%q\n' "$decl_ms" "$decl_err"
fi
hot_sample_close_session "$decl_session" >/dev/null || true
trap 'rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$dispatch_ab_output_file" "$dispatch_bc_output_file" "$publication_ab_output_file" "$publication_bc_output_file" "$overlay_b" "$overlay_c"' EXIT

make_output_overlay '!' "$overlay_b"
make_output_overlay '?' "$overlay_c"

if [[ "$(hot_sample_overlay_file_match "$target" "$overlay_b" | json_get matches)" == "true" ]] || \
   [[ "$(hot_sample_overlay_file_match "$target" "$overlay_c" | json_get matches)" == "true" ]]; then
  hot_sample_restore_file "$target" >/dev/null || fail "failed to normalize target file to baseline"
fi

dispatch_generation_before="$(hot_sample_current_generation)"
dispatch_ab_ms="$(
  measure_shell_ms_to_file \
    "$dispatch_ab_output_file" \
    hot_sample_hotreq \
    --op load-file \
    --path "$target" \
    --file-path "$overlay_b" \
    --field activation=dispatch
)" || fail "dispatch A->B load-file activation failed"
assert_done_response "$dispatch_ab_output_file" "dispatch"
dispatch_generation_after="$(hot_sample_current_generation_retry)"
[[ "$dispatch_generation_after" == "$dispatch_generation_before" ]] || fail "dispatch A->B changed generation unexpectedly: before=$dispatch_generation_before after=$dispatch_generation_after"
printf 'load_file_dispatch_a_to_b_ms=%s target=%s generation=%s\n' "$dispatch_ab_ms" "$target" "$dispatch_generation_after"

dispatch_generation_before="$dispatch_generation_after"
dispatch_bc_ms="$(
  measure_shell_ms_to_file \
    "$dispatch_bc_output_file" \
    hot_sample_hotreq \
    --op load-file \
    --path "$target" \
    --file-path "$overlay_c" \
    --field activation=dispatch
)" || fail "dispatch B->C load-file activation failed"
assert_done_response "$dispatch_bc_output_file" "dispatch"
dispatch_generation_after="$(hot_sample_current_generation_retry)"
[[ "$dispatch_generation_after" == "$dispatch_generation_before" ]] || fail "dispatch B->C changed generation unexpectedly: before=$dispatch_generation_before after=$dispatch_generation_after"
printf 'load_file_dispatch_b_to_c_ms=%s target=%s generation=%s\n' "$dispatch_bc_ms" "$target" "$dispatch_generation_after"

hot_sample_restore_file "$target" >/dev/null || fail "failed to restore target before publication measurement"

publication_generation_before="$(hot_sample_current_generation)"
publication_ab_ms="$(
  measure_shell_ms_to_file \
    "$publication_ab_output_file" \
    hot_sample_hotreq \
    --op load-file \
    --path "$target" \
    --file-path "$overlay_b"
)" || fail "publication A->B load-file activation failed"
assert_done_response "$publication_ab_output_file" ""
publication_generation_after="$(hot_sample_current_generation_retry)"
if [[ "$publication_generation_after" == "$publication_generation_before" ]]; then
  fail "publication A->B did not change generation"
fi
printf 'load_file_publication_a_to_b_ms=%s target=%s generation=%s\n' "$publication_ab_ms" "$target" "$publication_generation_after"

publication_generation_before="$publication_generation_after"
publication_bc_ms="$(
  measure_shell_ms_to_file \
    "$publication_bc_output_file" \
    hot_sample_hotreq \
    --op load-file \
    --path "$target" \
    --file-path "$overlay_c"
)" || fail "publication B->C load-file activation failed"
assert_done_response "$publication_bc_output_file" ""
publication_generation_after="$(hot_sample_current_generation_retry)"
if [[ "$publication_generation_after" == "$publication_generation_before" ]]; then
  fail "publication B->C did not change generation"
fi
printf 'load_file_publication_b_to_c_ms=%s target=%s generation=%s\n' "$publication_bc_ms" "$target" "$publication_generation_after"

hot_sample_restore_file "$target" >/dev/null || fail "failed to restore target after publication measurement"

bash "$script_dir/test_hot_live_window_health.sh" >/dev/null || fail "window health check failed after measurement"
printf 'baseline_end_generation=%s\n' "$(hot_sample_current_generation)"
