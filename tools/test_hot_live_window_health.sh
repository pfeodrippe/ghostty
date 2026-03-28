#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

window_contents() {
  osascript <<'OSA'
tell application "System Events"
  tell process "ghostty"
    if (count of windows) is 0 then error "ghostty has no windows"
    tell window 1
      set xs to entire contents
      set out to {}
      repeat with x in xs
        try
          set end of out to ((role description of x) as text) & ":" & ((name of x) as text)
        end try
      end repeat
      return out
    end tell
  end tell
end tell
OSA
}

ghostty_pid() {
  ps -axo pid=,command= | awk '/\/Ghostty\.app\/Contents\/MacOS\/ghostty$/ { pid = $1 } END { if (pid != "") print pid }'
}

pid="$(ghostty_pid)"
[[ -n "$pid" ]] || fail "no live Ghostty app process found"

ui_dump="$(window_contents)" || fail "unable to inspect Ghostty window contents"

case "$ui_dump" in
  *"text:Oh, no. 😭"*|*"text:The terminal failed to initialize. Please check the logs for more information. This is usually a bug."*)
    fail "Ghostty window is showing the terminal initialization error view"
    ;;
  *"The renderer has failed."*)
    fail "Ghostty window is showing the renderer failure view"
    ;;
esac

case "$ui_dump" in
  *"text entry area:"*)
    ;;
  *)
    fail "Ghostty window does not expose the normal terminal text entry area"
    ;;
esac

generation="$(hot_sample_current_generation)" || fail "unable to query hot runtime generation from live app"

printf 'PASS live Ghostty window healthy (pid=%s, generation=%s)\n' "$pid" "$generation"
