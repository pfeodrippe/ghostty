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

hot_sample_current_generation() {
  hot_sample_hotreq --op current-generation | hot_sample_json_get generation
}
