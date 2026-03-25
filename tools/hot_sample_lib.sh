#!/usr/bin/env bash

set -euo pipefail

hot_sample_repo_root() {
  local script_dir
  script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd -- "$script_dir/.." && pwd
}

HOT_SAMPLE_REPO_ROOT="${GHOSTTY_REPO:-$(hot_sample_repo_root)}"
HOT_SAMPLE_HELPER="${GHOSTTY_HOT_TOOL:-$HOT_SAMPLE_REPO_ROOT/tools/hot_nrepl.py}"
HOT_SAMPLE_PORT_FILE="${GHOSTTY_PORT_FILE:-$HOT_SAMPLE_REPO_ROOT/.nrepl-port}"
HOT_SAMPLE_PROBE_FILE="${GHOSTTY_HOT_PROBE_FILE:-$HOT_SAMPLE_REPO_ROOT/src/input/mouse.zig}"

hot_sample_hotreq() {
  "$HOT_SAMPLE_HELPER" --port-file "$HOT_SAMPLE_PORT_FILE" "$@"
}

hot_sample_json_get() {
  local key="$1"
  python3 -c 'import json,sys; key=sys.argv[1]; value=json.load(sys.stdin)[key]; print(value if isinstance(value, str) else json.dumps(value))' "$key"
}

hot_sample_new_session() {
  hot_sample_hotreq --op clone | hot_sample_json_get new-session
}

hot_sample_close_session() {
  hot_sample_hotreq --session "$1" --op close >/dev/null
}

hot_sample_eval_in_file() {
  local path="$1"
  local code="$2"
  local session
  local response

  session="$(hot_sample_new_session)"
  if ! hot_sample_hotreq --session "$session" --op in-file --path "$path" >/dev/null; then
    hot_sample_close_session "$session" >/dev/null 2>&1 || true
    return 1
  fi

  if ! response="$(hot_sample_hotreq --session "$session" --op eval --code "$code")"; then
    hot_sample_close_session "$session" >/dev/null 2>&1 || true
    return 1
  fi

  hot_sample_close_session "$session" >/dev/null 2>&1 || true
  printf '%s\n' "$response"
}

hot_sample_load_file() {
  local path="$1"
  local file_path="$2"
  hot_sample_hotreq --op load-file --path "$path" --file-path "$file_path" >/dev/null
}

hot_sample_restore_file() {
  local path="$1"
  hot_sample_load_file "$path" "$path"
}

hot_sample_current_generation() {
  hot_sample_hotreq --op current-generation | hot_sample_json_get generation
}

hot_sample_probe_eval() {
  local code="$1"
  hot_sample_eval_in_file "$HOT_SAMPLE_PROBE_FILE" "$code"
}

hot_sample_probe_value() {
  local code="$1"
  hot_sample_probe_eval "$code" | hot_sample_json_get value
}

hot_sample_try_probe_value() {
  local code="$1"
  local response

  if ! response="$(hot_sample_probe_eval "$code" 2>/dev/null)"; then
    return 1
  fi

  printf '%s\n' "$response" | hot_sample_json_get value
}

hot_sample_decode_text_value() {
  python3 -c 'import sys; raw=sys.stdin.read().strip();
if raw.startswith("{") and raw.endswith("}"):
    inner=raw[1:-1].strip();
    if not inner:
        print("");
    else:
        print(bytes(int(part.strip()) for part in inner.split(",")).decode("utf-8"));
else:
    print(raw)'
}

hot_sample_probe_text() {
  local code="$1"
  hot_sample_probe_value "$code" | hot_sample_decode_text_value
}
