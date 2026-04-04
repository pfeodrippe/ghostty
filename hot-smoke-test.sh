#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOT_BIN="${HOT_BIN:-$ROOT_DIR/tools/hot}"
PORT_FILE="${PORT_FILE:-$ROOT_DIR/.nrepl-port}"
HOT_LOG="${HOT_LOG:-$ROOT_DIR/.hot-run.log}"
GHOSTTY_BIN_PATTERN="${GHOSTTY_BIN_PATTERN:-macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty}"
SURFACE_HANDLE='@objc:NSApp.activeWindow.contentView//surfaceModel.asObject.surface'

if [[ ! -x "$HOT_BIN" ]]; then
  echo "error: missing hot wrapper at $HOT_BIN" >&2
  exit 1
fi

wait_for_port_file() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if [[ -s "$PORT_FILE" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "error: timed out waiting for $PORT_FILE" >&2
  exit 1
}

wait_for_app_ready() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if [[ -f "$HOT_LOG" ]]; then
      if grep -Fq "error initializing surface err=" "$HOT_LOG"; then
        echo "error: Ghostty surface initialization failed" >&2
        tail -n 80 "$HOT_LOG" >&2
        exit 1
      fi
      if grep -Fq "run Ghostty app failure" "$HOT_LOG"; then
        echo "error: Ghostty app exited during hot-run" >&2
        tail -n 80 "$HOT_LOG" >&2
        exit 1
      fi
      if grep -Fq "started subcommand path=" "$HOT_LOG" || grep -Fq "terminal pwd:" "$HOT_LOG"; then
        if pgrep -f "$GHOSTTY_BIN_PATTERN" >/dev/null 2>&1; then
          return 0
        fi
      fi
    fi
    sleep 1
  done

  echo "error: timed out waiting for a working Ghostty surface" >&2
  if [[ -f "$HOT_LOG" ]]; then
    tail -n 80 "$HOT_LOG" >&2
  fi
  exit 1
}

hot() {
  "$HOT_BIN" "$@"
}

expect_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "error: expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

expect_value() {
  local symbol="$1"
  local expected="$2"
  shift 2

  local output
  output="$(hot call "$symbol" "$@" 2>&1)"
  expect_contains "$output" "value: $expected"
}

expect_done() {
  local symbol="$1"
  shift

  local output
  output="$(hot call "$symbol" "$@" 2>&1)"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
}

expect_call_contains() {
  local symbol="$1"
  local needle="$2"
  shift 2

  local output
  output="$(hot call "$symbol" "$@" 2>&1)"
  expect_contains "$output" "$needle"
}

expect_log_after() {
  local start_line="$1"
  local needle="$2"
  local deadline=$((SECONDS + 30))

  while (( SECONDS < deadline )); do
    if [[ -f "$HOT_LOG" ]] && awk -v start="$start_line" 'NR > start { print }' "$HOT_LOG" | grep -Fq "$needle"; then
      return 0
    fi
    sleep 1
  done

  echo "error: timed out waiting for log marker: $needle" >&2
  tail -n 120 "$HOT_LOG" >&2
  exit 1
}

wait_for_port_file
wait_for_app_ready

describe_output="$(hot describe 2>&1)"
expect_contains "$describe_output" "os.flatpak.isFlatpak"
expect_contains "$describe_output" "os.desktop.launchedFromDesktop"
expect_contains "$describe_output" "os.env.setenv"
expect_contains "$describe_output" "os.env.unsetenv"
expect_contains "$describe_output" "simd.codepoint_width.codepointWidth"
expect_contains "$describe_output" "renderer.cell.isBlockElement"
expect_contains "$describe_output" "renderer.cell.isCovering"
expect_contains "$describe_output" "renderer.cell.noMinContrast"
expect_contains "$describe_output" "ghostty_surface_process_exited"

expect_value "os.flatpak.isFlatpak" "false"
expect_value "os.desktop.launchedFromDesktop" "false"
expect_value "os.env.setenv" "0" '"GHOSTTY_HOT_SMOKE"' '"1"'
expect_value "os.env.unsetenv" "0" '"GHOSTTY_HOT_SMOKE"'
expect_value "simd.codepoint_width.codepointWidth" "1" 65
expect_value "renderer.cell.isBlockElement" "true" 9608
expect_value "renderer.cell.isCovering" "true" 9608
expect_value "renderer.cell.noMinContrast" "true" 9608
expect_value "ghostty_surface_process_exited" "false" "$SURFACE_HANDLE"

ui_marker="GHOSTTY_HOT_UI_VERIFY_${RANDOM}_${RANDOM}"
ui_paste_text="$(printf 'printf %s\n' "$ui_marker")"
paste_log_start="$(wc -l < "$HOT_LOG")"
ui_paste_output="$("$ROOT_DIR/tools/hot-paste" "$ui_paste_text" 2>&1)"
expect_contains "$ui_paste_output" "status:"
expect_contains "$ui_paste_output" "  done"
expect_log_after "$paste_log_start" "mailbox message=write_small"
if ! pgrep -f "$GHOSTTY_BIN_PATTERN" >/dev/null 2>&1; then
  echo "error: Ghostty app exited after hot paste" >&2
  tail -n 120 "$HOT_LOG" >&2
  exit 1
fi

echo "hot smoke test passed"
