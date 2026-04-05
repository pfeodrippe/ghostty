#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOT_BIN="${HOT_BIN:-$ROOT_DIR/tools/hot}"
ZIG_BIN="${ZIG_BIN:-$ROOT_DIR/.zig-toolchain/zig-0.15.2/bin/zig}"
PORT_FILE="${PORT_FILE:-$ROOT_DIR/.nrepl-port}"
HOT_LOG="${HOT_LOG:-$ROOT_DIR/.hot-run.log}"
GHOSTTY_BIN_PATTERN="${GHOSTTY_BIN_PATTERN:-macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty}"
SURFACE_HANDLE='@objc:NSApp.activeWindow.contentView//surfaceModel.asObject.surface'

if [[ ! -x "$HOT_BIN" ]]; then
  echo "error: missing hot wrapper at $HOT_BIN" >&2
  exit 1
fi

if [[ ! -x "$ZIG_BIN" ]]; then
  echo "error: missing zig binary at $ZIG_BIN" >&2
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

validate_decl_graph_config() {
  local config_path="$ROOT_DIR/.zig-cache/hot/ghostty.config"
  if [[ ! -f "$config_path" ]]; then
    echo "error: missing generated hot config at $config_path" >&2
    exit 1
  fi

  if ! awk -F '\t' '
    $1 == "decl-node" { nodes[$2] = 1; next }
    $1 == "decl-edge" {
      edge_kind[++edge_count] = $2
      edge_from[edge_count] = $3
      edge_to[edge_count] = $4
    }
    END {
      for (i = 1; i <= edge_count; i++) {
        if (!(edge_from[i] in nodes)) {
          printf "error: hot decl graph edge kind=%s references missing source node: %s\n", edge_kind[i], edge_from[i] > "/dev/stderr"
          exit 1
        }
        if (!(edge_to[i] in nodes)) {
          printf "error: hot decl graph edge kind=%s references missing destination node: %s\n", edge_kind[i], edge_to[i] > "/dev/stderr"
          exit 1
        }
      }
    }
  ' "$config_path"; then
    exit 1
  fi
}

hot() {
  "$HOT_BIN" "$@"
}

zig_hot() {
  (
    cd "$ROOT_DIR"
    "$ZIG_BIN" hot "$@"
  )
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
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
  if grep -Fq "err:" <<<"$output" || grep -Fq "  eval-error" <<<"$output"; then
    echo "error: expected successful hot value call for $symbol" >&2
    echo "$output" >&2
    exit 1
  fi
  expect_contains "$output" "value: $expected"
}

expect_done() {
  local symbol="$1"
  shift

  local output
  output="$(hot call "$symbol" "$@" 2>&1)"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
  if grep -Fq "err:" <<<"$output" || grep -Fq "  eval-error" <<<"$output"; then
    echo "error: expected successful hot done call for $symbol" >&2
    echo "$output" >&2
    exit 1
  fi
}

expect_call_contains() {
  local symbol="$1"
  local needle="$2"
  shift 2

  local output
  output="$(hot call "$symbol" "$@" 2>&1)"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
  if grep -Fq "err:" <<<"$output" || grep -Fq "  eval-error" <<<"$output"; then
    echo "error: expected successful hot call for $symbol" >&2
    echo "$output" >&2
    exit 1
  fi
  expect_contains "$output" "$needle"
}

expect_eval_contains() {
  local expr="$1"
  local needle="$2"

  local output
  output="$(zig_hot --eval "$expr" 2>&1)"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
  if grep -Fq "err:" <<<"$output" || grep -Fq "  eval-error" <<<"$output"; then
    echo "error: expected successful hot eval for: $expr" >&2
    echo "$output" >&2
    exit 1
  fi
  expect_contains "$output" "$needle"
}

expect_eval_value() {
  local expr="$1"
  local expected="$2"
  expect_eval_contains "$expr" "value: $expected"
}

expect_eval_done() {
  local expr="$1"
  expect_eval_contains "$expr" "status:"
  expect_eval_contains "$expr" "  done"
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
validate_decl_graph_config

describe_output="$(hot describe 2>&1)"
expect_contains "$describe_output" "os.flatpak.isFlatpak"
expect_contains "$describe_output" "os.desktop.launchedFromDesktop"
expect_contains "$describe_output" "os.env.setenv"
expect_contains "$describe_output" "os.env.unsetenv"
expect_contains "$describe_output" "config.string.parse"
expect_contains "$describe_output" "simd.codepoint_width.codepointWidth"
expect_contains "$describe_output" "math.ortho2d"
expect_contains "$describe_output" "apprt.embedded.Surface.preeditCallback"
expect_contains "$describe_output" "renderer.cell.isBlockElement"
expect_contains "$describe_output" "renderer.cell.isCovering"
expect_contains "$describe_output" "renderer.cell.noMinContrast"
expect_contains "$describe_output" "ghostty_surface_process_exited"

eval_output="$(zig_hot --eval 'renderer.cell.isBlockElement(9608)' 2>&1)"
expect_contains "$eval_output" "value: true"
expect_contains "$eval_output" "status:"
expect_contains "$eval_output" "  done"

expect_eval_contains 'config.string.parse("xxxxx", "a\\nb")' 'value: "a\nb"'

field_output="$(zig_hot --eval '.{ .columns = 80, .rows = 24 }.columns' 2>&1)"
expect_contains "$field_output" "value: 80"
expect_contains "$field_output" "status:"
expect_contains "$field_output" "  done"

expect_value "os.flatpak.isFlatpak" "false"
expect_value "os.desktop.launchedFromDesktop" "false"
expect_value "os.env.setenv" "0" '"GHOSTTY_HOT_SMOKE"' '"1"'
expect_value "os.env.unsetenv" "0" '"GHOSTTY_HOT_SMOKE"'
expect_value "simd.codepoint_width.codepointWidth" "1" 65
expect_call_contains "math.ortho2d" "value: [[2, 0, 0, 0], [0, 2, 0, 0], [0, 0, -1, 0], [-1, -1, 0, 1]]" 0.0 1.0 0.0 1.0
expect_eval_done "apprt.embedded.Surface.preeditCallback($SURFACE_HANDLE, null)"
expect_value "renderer.cell.isBlockElement" "true" 9608
expect_value "renderer.cell.isCovering" "true" 9608
expect_value "renderer.cell.noMinContrast" "true" 9608
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "false"
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
