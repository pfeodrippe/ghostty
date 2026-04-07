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
  local timeout="${PORT_FILE_TIMEOUT:-600}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if [[ -s "$PORT_FILE" ]]; then
      return 0
    fi
    # Fail fast if the build/app already exited
    if [[ -f "$HOT_LOG" ]] && grep -Fq "run Ghostty app failure" "$HOT_LOG"; then
      echo "error: Ghostty app exited before nREPL started" >&2
      tail -n 80 "$HOT_LOG" >&2
      exit 1
    fi
    sleep 1
  done

  echo "error: timed out after ${timeout}s waiting for $PORT_FILE" >&2
  if [[ -f "$HOT_LOG" ]]; then
    tail -n 80 "$HOT_LOG" >&2
  fi
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

wait_for_surface_handle() {
  local deadline=$((SECONDS + 60))
  local probe_expr="ghostty_surface_process_exited($SURFACE_HANDLE)"
  local output=""

  while (( SECONDS < deadline )); do
    output="$(zig_hot --eval "$probe_expr" 2>&1 || true)"
    if grep -Fq "status:" <<<"$output" &&
      grep -Fq "  done" <<<"$output" &&
      ! grep -Fq "err:" <<<"$output" &&
      ! grep -Fq "  eval-error" <<<"$output"; then
      return 0
    fi
    sleep 1
  done

  echo "error: timed out waiting for hot surface handle: $SURFACE_HANDLE" >&2
  echo "$output" >&2
  if [[ -f "$HOT_LOG" ]]; then
    tail -n 120 "$HOT_LOG" >&2
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

validate_decl_graph_semantic_edges() {
  local config_path="$ROOT_DIR/.zig-cache/hot/ghostty.config"
  local run_file="$ROOT_DIR/src/font/shaper/run.zig"
  local shape_file="$ROOT_DIR/src/font/shape.zig"
  local coretext_file="$ROOT_DIR/src/font/shaper/coretext.zig"
  local shared_grid_file="$ROOT_DIR/src/font/SharedGrid.zig"
  local termio_file="$ROOT_DIR/src/termio/Termio.zig"
  local apprt_surface_file="$ROOT_DIR/src/apprt/surface.zig"
  local iosurface_layer_file="$ROOT_DIR/src/renderer/metal/IOSurfaceLayer.zig"
  local shaders_file="$ROOT_DIR/src/renderer/metal/shaders.zig"
  local pipeline_file="$ROOT_DIR/src/renderer/metal/Pipeline.zig"

  if ! awk -F '\t' \
    -v run_file="$run_file" \
    -v shape_file="$shape_file" \
    -v coretext_file="$coretext_file" \
    -v shared_grid_file="$shared_grid_file" \
    -v termio_file="$termio_file" \
    -v apprt_surface_file="$apprt_surface_file" \
    -v iosurface_layer_file="$iosurface_layer_file" \
    -v shaders_file="$shaders_file" \
    -v pipeline_file="$pipeline_file" '
    $1 == "decl-node" && $3 == "function_decl" && $4 == run_file && $5 == "RunIterator.next" {
      next_key = $2
    }
    $1 == "decl-node" && $4 == run_file && $5 == "RunIterator.addCodepoint" {
      add_codepoint_key = $2
    }
    $1 == "decl-node" && $4 == run_file && $5 == "RunIterator.indexForCell" {
      index_for_cell_key = $2
    }
    $1 == "decl-node" && $3 == "function_decl" && $4 == run_file && $5 == "comparableStyle" {
      comparable_style_key = $2
    }
    $1 == "decl-node" && $3 == "container_decl" && $4 == run_file && $5 == "RunIterator" {
      iterator_key = $2
    }
    $1 == "decl-node" && $3 == "container_decl" && $4 == run_file && $5 == "TextRun" {
      text_run_key = $2
    }
    $1 == "decl-node" && $3 == "file_root" && $4 == shared_grid_file && $5 == "" {
      shared_grid_root_key = $2
    }
    $1 == "decl-node" && $3 == "const_decl" && $4 == shape_file && $5 == "Shaper" {
      shape_shaper_key = $2
    }
    $1 == "decl-node" && $3 == "container_decl" && $4 == coretext_file && $5 == "Shaper" {
      coretext_shaper_key = $2
    }
    $1 == "decl-node" && $3 == "container_decl" && $4 == coretext_file && $5 == "Shaper.RunIteratorHook" {
      coretext_run_iterator_hook_key = $2
    }
    $1 == "decl-node" && $3 == "container_decl" && $4 == shape_file && $5 == "RunOptions" {
      run_options_key = $2
    }
    $1 == "decl-node" && $3 == "file_root" && $4 == termio_file && $5 == "" {
      termio_root_key = $2
    }
    $1 == "decl-node" && $3 == "container_decl" && $4 == termio_file && $5 == "DerivedConfig" {
      derived_config_key = $2
    }
    $1 == "decl-node" && $3 == "container_decl" && $4 == termio_file && $5 == "ThreadEnterState" {
      thread_enter_state_key = $2
    }
    $1 == "decl-node" && $3 == "container_decl" && $4 == apprt_surface_file && $5 == "Mailbox" {
      surface_mailbox_key = $2
    }
    $1 == "decl-node" && $3 == "function_decl" && $4 == iosurface_layer_file && $5 == "init" {
      iosurface_init_key = $2
    }
    $1 == "decl-node" && $4 == iosurface_layer_file && $5 == "getSubclass" {
      get_subclass_key = $2
    }
    $1 == "decl-node" && $3 == "var_decl" && $4 == iosurface_layer_file && $5 == "Subclass" {
      subclass_key = $2
    }
    $1 == "decl-node" && $3 == "const_decl" && $4 == shaders_file && $5 == "PipelineCollection" {
      pipeline_collection_key = $2
    }
    $1 == "decl-node" && $3 == "file_root" && $4 == pipeline_file && $5 == "" {
      pipeline_root_key = $2
    }
    $1 == "decl-edge" && $2 == "type_dep" {
      type_dep[$3 SUBSEP $4] = 1
      next
    }
    $1 == "decl-edge" && $2 == "layout_dep" {
      layout_dep[$3 SUBSEP $4] = 1
      next
    }
    $1 == "decl-edge" && $2 == "calls" {
      calls[$3 SUBSEP $4] = 1
      next
    }
    $1 == "decl-edge" && $2 == "reads" {
      reads[$3 SUBSEP $4] = 1
      next
    }
    $1 == "decl-edge" && $2 == "writes" {
      writes[$3 SUBSEP $4] = 1
      next
    }
    $1 == "decl-edge" && $2 == "comptime_dep" {
      comptime_dep[$3 SUBSEP $4] = 1
    }
    $1 == "decl-edge" && $2 == "specializes" {
      specializes[$3 SUBSEP $4] = 1
    }
    END {
      if (next_key == "") {
        print "error: missing declaration graph node for RunIterator.next" > "/dev/stderr"
        exit 1
      }
      if (add_codepoint_key == "") {
        print "error: missing declaration graph node for RunIterator.addCodepoint" > "/dev/stderr"
        exit 1
      }
      if (index_for_cell_key == "") {
        print "error: missing declaration graph node for RunIterator.indexForCell" > "/dev/stderr"
        exit 1
      }
      if (comparable_style_key == "") {
        print "error: missing declaration graph node for comparableStyle" > "/dev/stderr"
        exit 1
      }
      if (iterator_key == "") {
        print "error: missing declaration graph node for RunIterator" > "/dev/stderr"
        exit 1
      }
      if (text_run_key == "") {
        print "error: missing declaration graph node for TextRun" > "/dev/stderr"
        exit 1
      }
      if (shared_grid_root_key == "") {
        print "error: missing declaration graph file-root node for SharedGrid.zig" > "/dev/stderr"
        exit 1
      }
      if (shape_shaper_key == "") {
        print "error: missing declaration graph node for shape.Shaper" > "/dev/stderr"
        exit 1
      }
      if (coretext_shaper_key == "") {
        print "error: missing declaration graph node for coretext.Shaper" > "/dev/stderr"
        exit 1
      }
      if (coretext_run_iterator_hook_key == "") {
        print "error: missing declaration graph node for coretext.Shaper.RunIteratorHook" > "/dev/stderr"
        exit 1
      }
      if (run_options_key == "") {
        print "error: missing declaration graph node for RunOptions" > "/dev/stderr"
        exit 1
      }
      if (termio_root_key == "") {
        print "error: missing declaration graph file-root node for Termio.zig" > "/dev/stderr"
        exit 1
      }
      if (derived_config_key == "") {
        print "error: missing declaration graph node for DerivedConfig" > "/dev/stderr"
        exit 1
      }
      if (thread_enter_state_key == "") {
        print "error: missing declaration graph node for ThreadEnterState" > "/dev/stderr"
        exit 1
      }
      if (surface_mailbox_key == "") {
        print "error: missing declaration graph node for apprt.surface.Mailbox" > "/dev/stderr"
        exit 1
      }
      if (iosurface_init_key == "") {
        print "error: missing declaration graph node for IOSurfaceLayer.init" > "/dev/stderr"
        exit 1
      }
      if (get_subclass_key == "") {
        print "error: missing declaration graph node for getSubclass" > "/dev/stderr"
        exit 1
      }
      if (subclass_key == "") {
        print "error: missing declaration graph node for Subclass" > "/dev/stderr"
        exit 1
      }
      if (pipeline_collection_key == "") {
        print "error: missing declaration graph node for PipelineCollection" > "/dev/stderr"
        exit 1
      }
      if (pipeline_root_key == "") {
        print "error: missing declaration graph file-root node for metal/Pipeline.zig" > "/dev/stderr"
        exit 1
      }
      if (!((next_key SUBSEP iterator_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: RunIterator.next -> RunIterator" > "/dev/stderr"
        exit 1
      }
      if (!((next_key SUBSEP text_run_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: RunIterator.next -> TextRun" > "/dev/stderr"
        exit 1
      }
      if (!((text_run_key SUBSEP shared_grid_root_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: TextRun -> SharedGrid.zig <file-root>" > "/dev/stderr"
        exit 1
      }
      if (!((iterator_key SUBSEP run_options_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: RunIterator -> RunOptions" > "/dev/stderr"
        exit 1
      }
      if (!((iterator_key SUBSEP coretext_run_iterator_hook_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: RunIterator -> coretext.Shaper.RunIteratorHook" > "/dev/stderr"
        exit 1
      }
      if (!((shape_shaper_key SUBSEP coretext_shaper_key) in comptime_dep)) {
        print "error: missing declaration graph comptime_dep edge: shape.Shaper -> coretext.Shaper" > "/dev/stderr"
        exit 1
      }
      if (!((termio_root_key SUBSEP surface_mailbox_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: <file-root> -> apprt.surface.Mailbox" > "/dev/stderr"
        exit 1
      }
      if (!((termio_root_key SUBSEP derived_config_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: <file-root> -> DerivedConfig" > "/dev/stderr"
        exit 1
      }
      if (!((termio_root_key SUBSEP thread_enter_state_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: <file-root> -> ThreadEnterState" > "/dev/stderr"
        exit 1
      }
      if (!((pipeline_collection_key SUBSEP pipeline_root_key) in layout_dep)) {
        print "error: missing declaration graph layout_dep edge: PipelineCollection -> metal/Pipeline.zig <file-root>" > "/dev/stderr"
        exit 1
      }
      if (!((next_key SUBSEP add_codepoint_key) in calls)) {
        print "error: missing declaration graph calls edge: RunIterator.next -> RunIterator.addCodepoint" > "/dev/stderr"
        exit 1
      }
      if (!((next_key SUBSEP index_for_cell_key) in calls)) {
        print "error: missing declaration graph calls edge: RunIterator.next -> RunIterator.indexForCell" > "/dev/stderr"
        exit 1
      }
      if (!((next_key SUBSEP comparable_style_key) in calls)) {
        print "error: missing declaration graph calls edge: RunIterator.next -> comparableStyle" > "/dev/stderr"
        exit 1
      }
      if (!((iosurface_init_key SUBSEP get_subclass_key) in calls)) {
        print "error: missing declaration graph calls edge: init -> getSubclass" > "/dev/stderr"
        exit 1
      }
      if (!((get_subclass_key SUBSEP subclass_key) in reads)) {
        print "error: missing declaration graph reads edge: getSubclass -> Subclass" > "/dev/stderr"
        exit 1
      }
      if (!((get_subclass_key SUBSEP subclass_key) in writes)) {
        print "error: missing declaration graph writes edge: getSubclass -> Subclass" > "/dev/stderr"
        exit 1
      }
      if (!((next_key SUBSEP add_codepoint_key) in specializes)) {
        print "error: missing declaration graph specializes edge: RunIterator.next -> RunIterator.addCodepoint" > "/dev/stderr"
        exit 1
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
validate_decl_graph_semantic_edges

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
wait_for_surface_handle
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

# Classify a known source file via nREPL
classify_output="$(zig_hot classify src/os/desktop.zig 2>&1)"
expect_contains "$classify_output" "body-class="
expect_contains "$classify_output" "launchedFromDesktop"

# Compile and execute a simple function body via nREPL
compile_output="$(zig_hot compile-body test/hot/body_fixture.zig answer 2>&1)"
expect_contains "$compile_output" "value: 42"
expect_contains "$compile_output" "instructions:"

# Compile and execute a function with a while loop
loop_output="$(zig_hot compile-body test/hot/body_fixture.zig sumToTen 2>&1)"
expect_contains "$loop_output" "value: 55"

# Compile and execute a function with cross-function calls
cross_output="$(zig_hot compile-body test/hot/body_fixture.zig doubleAnswer 2>&1)"
expect_contains "$cross_output" "value: 84"

# ── Real Ghostty function compile-body tests ───────────────────────────

# perceivedLuminance — float arithmetic with @floatFromInt and field access
plum_output="$(zig_hot compile-body src/terminal/color.zig perceivedLuminance 2>&1)"
expect_contains "$plum_output" "instructions:"

# componentLuminance — cross-module import resolution (std.math.pow) — Phase 8
clum_output="$(zig_hot compile-body src/terminal/color.zig componentLuminance 2>&1 || true)"
expect_contains "$clum_output" "instructions:"
echo "componentLuminance compiles: ${clum_output:0:80}"

# componentLuminance with arg 0 — should return 0 (0/255=0, ≤0.03928, 0/12.92=0)
clum0_output="$(zig_hot compile-body src/terminal/color.zig componentLuminance 0 2>&1 || true)"
expect_contains "$clum0_output" "value: 0"
echo "componentLuminance(0) = 0 ✓"

# eql — field comparison + boolean AND chain
eql_output="$(zig_hot compile-body src/terminal/color.zig eql 2>&1)"
expect_contains "$eql_output" "instructions:"

# addCodepoint — re-exported import binding (autoHash), char literals, anytype params
addcp_output="$(zig_hot compile-body src/font/shaper/run.zig addCodepoint 2>&1 || true)"
expect_contains "$addcp_output" "instructions:"
echo "addCodepoint compiles: ${addcp_output:0:80}"

# ── Assoc override end-to-end tests ─────────────────────────────────

# Override answer() to return 99 — then doubleAnswer() should return double(99) = 198
assoc_output="$(zig_hot assoc answer 'fn answer() i64 { return 99; }' 2>&1)"
expect_contains "$assoc_output" "done"
echo "assoc answer override: OK"

da_override="$(zig_hot compile-body test/hot/body_fixture.zig doubleAnswer 2>&1)"
expect_contains "$da_override" "value: 198"
echo "assoc override doubleAnswer() = 198 (answer→99, double(99)=198) ✓"

# Override RGB.componentLuminance — qualified with struct name and file
clum_assoc="$(zig_hot assoc RGB.componentLuminance --file src/terminal/color.zig 'fn componentLuminance(c: u8) f64 { return 1; }' 2>&1)"
expect_contains "$clum_assoc" "done"
echo "assoc RGB.componentLuminance override: OK"

# luminance() calls RGB.componentLuminance 3 times → 0.2126*1 + 0.7152*1 + 0.0722*1 = 1.0
lum_override="$(zig_hot compile-body src/terminal/color.zig luminance 2>&1)"
expect_contains "$lum_override" "value: 1"
echo "assoc override luminance() = 1.0 (RGB.componentLuminance→1.0) ✓"

echo "hot smoke test passed"
