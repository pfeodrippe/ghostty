#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"
bash "$script_dir/test_hot_live_window_health.sh" >/dev/null

target="src/font/shaper/run.zig"
load_file_helper="$HOT_SAMPLE_REPO_ROOT/tools/hot_sample_output_dots_to_bangs.sh"

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

printf 'baseline_start_generation=%s\n' "$(hot_sample_current_generation)"

literal_output_file="$(mktemp)"
block_output_file="$(mktemp)"
decl_output_file="$(mktemp)"
load_on_output_file="$(mktemp)"
load_off_output_file="$(mktemp)"
trap 'rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$load_on_output_file" "$load_off_output_file"' EXIT

literal_ms="$(measure_ms_to_file "$literal_output_file" "$HOT_SAMPLE_HELPER" --timeout "$HOT_SAMPLE_TIMEOUT" --port-file "$HOT_SAMPLE_PORT_FILE" --op eval --code '"ping"')" || fail "root literal eval failed"
literal_value="$(decode_text_value "$(cat "$literal_output_file")")"
[[ "$literal_value" == "ping" ]] || fail "unexpected literal eval result: $literal_value"
printf 'eval_literal_ms=%s value=%s\n' "$literal_ms" "$literal_value"

block_session="$(hot_sample_new_session)"
trap 'hot_sample_close_session "$block_session" >/dev/null 2>&1 || true; rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$load_on_output_file" "$load_off_output_file"' EXIT
hot_sample_hotreq --session "$block_session" --op in-file --path "$HOT_SAMPLE_PROBE_FILE" >/dev/null || fail "in-file setup failed"
block_ms="$(measure_ms_to_file "$block_output_file" "$HOT_SAMPLE_HELPER" --timeout "$HOT_SAMPLE_TIMEOUT" --port-file "$HOT_SAMPLE_PORT_FILE" --session "$block_session" --op eval --code 'const x: i32 = 41; x + 1')" || fail "in-file block eval failed"
block_value="$(decode_raw_value "$(cat "$block_output_file")")"
[[ "$block_value" == "42" ]] || fail "unexpected block eval result: $block_value"
hot_sample_close_session "$block_session" >/dev/null || true
trap 'rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$load_on_output_file" "$load_off_output_file"' EXIT
printf 'eval_in_file_block_ms=%s value=%s\n' "$block_ms" "$block_value"

decl_session="$(hot_sample_new_session)"
trap 'hot_sample_close_session "$decl_session" >/dev/null 2>&1 || true; rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$load_on_output_file" "$load_off_output_file"' EXIT
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
trap 'rm -f "$literal_output_file" "$block_output_file" "$decl_output_file" "$load_on_output_file" "$load_off_output_file"' EXIT

initial_status="$("$load_file_helper" status)"
if [[ "$initial_status" == ACTIVE\ * ]]; then
  "$load_file_helper" off >/dev/null || fail "failed to normalize load-file helper to inactive"
fi

load_on_ms="$(measure_ms_to_file "$load_on_output_file" "$load_file_helper" on)" || fail "load-file activation failed"
if ! grep -q '^Activated output overlay' "$load_on_output_file"; then
  fail "unexpected load-file activation output"
fi
printf 'load_file_on_ms=%s target=%s\n' "$load_on_ms" "$target"

load_off_ms="$(measure_ms_to_file "$load_off_output_file" "$load_file_helper" off)" || fail "load-file deactivation failed"
if ! grep -q '^Deactivated output overlay' "$load_off_output_file"; then
  fail "unexpected load-file deactivation output"
fi
printf 'load_file_off_ms=%s target=%s\n' "$load_off_ms" "$target"

bash "$script_dir/test_hot_live_window_health.sh" >/dev/null || fail "window health check failed after measurement"
printf 'baseline_end_generation=%s\n' "$(hot_sample_current_generation)"
