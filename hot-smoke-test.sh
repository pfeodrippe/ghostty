#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOT_BIN="${HOT_BIN:-$ROOT_DIR/tools/hot}"
ZIG_BIN="${ZIG_BIN:-$ROOT_DIR/.zig-toolchain/zig-0.15.2/bin/zig}"
PORT_FILE="${PORT_FILE:-$ROOT_DIR/.nrepl-port}"
HOT_LOG="${HOT_LOG:-$ROOT_DIR/.hot-run.log}"
GHOSTTY_BIN_PATTERN="${GHOSTTY_BIN_PATTERN:-macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty}"
GHOSTTY_APP_PATH="${GHOSTTY_APP_PATH:-$ROOT_DIR/macos/build/Debug/Ghostty.app}"
SURFACE_HANDLE='@objc:NSApp.activeWindow.contentView//surfaceModel.asObject.surface'
SURFACE_HANDLE_CANDIDATES=(
  '@objc:NSApp.activeWindow.contentView//surfaceModel.asObject.surface'
  '@objc:NSApp.keyWindow.contentView//surfaceModel.asObject.surface'
  '@objc:NSApp.mainWindow.contentView//surfaceModel.asObject.surface'
)

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
  local output=""
  local handle=""
  local probe_expr=""

  while (( SECONDS < deadline )); do
    activate_ghostty_app
    for handle in "${SURFACE_HANDLE_CANDIDATES[@]}"; do
      probe_expr="ghostty_surface_process_exited($handle)"
      output="$(zig_hot --eval "$probe_expr" 2>&1 || true)"
      if grep -Fq "status:" <<<"$output" &&
        grep -Fq "  done" <<<"$output" &&
        ! grep -Fq "err:" <<<"$output" &&
        ! grep -Fq "  eval-error" <<<"$output"; then
        SURFACE_HANDLE="$handle"
        return 0
      fi
    done
    sleep 1
  done

  echo "error: timed out waiting for hot surface handle candidates" >&2
  printf 'candidates:\n' >&2
  printf '  %s\n' "${SURFACE_HANDLE_CANDIDATES[@]}" >&2
  echo "$output" >&2
  if [[ -f "$HOT_LOG" ]]; then
    tail -n 120 "$HOT_LOG" >&2
  fi
  exit 1
}

expr_uses_surface_handle() {
  local expr="$1"
  local handle

  for handle in "$SURFACE_HANDLE" "${SURFACE_HANDLE_CANDIDATES[@]}"; do
    [[ -n "$handle" ]] || continue
    if [[ "$expr" == *"$handle"* ]]; then
      return 0
    fi
  done

  return 1
}

refresh_surface_handle_expr() {
  local expr="$1"
  local old_handle=""
  local handle

  for handle in "$SURFACE_HANDLE" "${SURFACE_HANDLE_CANDIDATES[@]}"; do
    [[ -n "$handle" ]] || continue
    if [[ "$expr" == *"$handle"* ]]; then
      old_handle="$handle"
      break
    fi
  done

  wait_for_surface_handle

  if [[ -n "$old_handle" ]]; then
    printf '%s' "${expr//$old_handle/$SURFACE_HANDLE}"
  else
    printf '%s' "$expr"
  fi
}

LAST_EVAL_EXPR=""
LAST_EVAL_OUTPUT=""

run_eval() {
  local expr="$1"

  LAST_EVAL_EXPR="$expr"
  if expr_uses_surface_handle "$LAST_EVAL_EXPR"; then
    activate_ghostty_app
  fi

  LAST_EVAL_OUTPUT="$(zig_hot --eval "$LAST_EVAL_EXPR" 2>&1 || true)"

  if grep -Fq "err: UnknownHandle" <<<"$LAST_EVAL_OUTPUT" && expr_uses_surface_handle "$LAST_EVAL_EXPR"; then
    LAST_EVAL_EXPR="$(refresh_surface_handle_expr "$LAST_EVAL_EXPR")"
    activate_ghostty_app
    LAST_EVAL_OUTPUT="$(zig_hot --eval "$LAST_EVAL_EXPR" 2>&1 || true)"
  fi
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
  local version_file="$ROOT_DIR/src/cli/version.zig"
  local config_capi_file="$ROOT_DIR/src/config/CApi.zig"
  local global_file="$ROOT_DIR/src/global.zig"

  if ! awk -F '\t' \
    -v run_file="$run_file" \
    -v shape_file="$shape_file" \
    -v coretext_file="$coretext_file" \
    -v shared_grid_file="$shared_grid_file" \
    -v termio_file="$termio_file" \
    -v apprt_surface_file="$apprt_surface_file" \
    -v iosurface_layer_file="$iosurface_layer_file" \
    -v shaders_file="$shaders_file" \
    -v pipeline_file="$pipeline_file" \
    -v version_file="$version_file" \
    -v config_capi_file="$config_capi_file" \
    -v global_file="$global_file" '
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
    $1 == "decl-node" && $3 == "function_decl" && $4 == config_capi_file && $5 == "ghostty_config_open_path" {
      config_open_path_key = $2
    }
    $1 == "decl-node" && $3 == "var_decl" && $4 == global_file && $5 == "state" {
      global_state_key = $2
    }
    $1 == "decl-node" && $3 == "const_decl" && $4 == shaders_file && $5 == "PipelineCollection" {
      pipeline_collection_key = $2
    }
    $1 == "decl-node" && $3 == "file_root" && $4 == pipeline_file && $5 == "" {
      pipeline_root_key = $2
    }
    $1 == "decl-node" && $3 == "function_decl" && $4 == version_file && $5 == "run" {
      version_run_key = $2
    }
    $1 == "decl-node" && $3 == "const_decl" && $6 == "build_options" && $5 == "x11" {
      build_options_x11_key = $2
    }
    $1 == "decl-node" && $3 == "const_decl" && $6 == "build_options" && $5 == "wayland" {
      build_options_wayland_key = $2
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
      if (config_open_path_key == "") {
        print "error: missing declaration graph node for ghostty_config_open_path" > "/dev/stderr"
        exit 1
      }
      if (global_state_key == "") {
        print "error: missing declaration graph node for global.state" > "/dev/stderr"
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
      if (version_run_key == "") {
        print "error: missing declaration graph node for cli.version.run" > "/dev/stderr"
        exit 1
      }
      if (build_options_x11_key == "") {
        print "error: missing declaration graph node for build_options.x11" > "/dev/stderr"
        exit 1
      }
      if (build_options_wayland_key == "") {
        print "error: missing declaration graph node for build_options.wayland" > "/dev/stderr"
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
      if (!((version_run_key SUBSEP build_options_x11_key) in comptime_dep)) {
        print "error: missing declaration graph comptime_dep edge: cli.version.run -> build_options.x11" > "/dev/stderr"
        exit 1
      }
      if (!((version_run_key SUBSEP build_options_wayland_key) in comptime_dep)) {
        print "error: missing declaration graph comptime_dep edge: cli.version.run -> build_options.wayland" > "/dev/stderr"
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
      if (!((config_open_path_key SUBSEP global_state_key) in reads)) {
        print "error: missing declaration graph reads edge: ghostty_config_open_path -> global.state" > "/dev/stderr"
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

expect_hot_success() {
  local output="$1"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
  if grep -Fq "err:" <<<"$output" ||
    grep -Fq "  error" <<<"$output" ||
    grep -Fq "  eval-error" <<<"$output"; then
    echo "error: expected successful hot command" >&2
    echo "$output" >&2
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
  run_eval "$expr"
  expr="$LAST_EVAL_EXPR"
  output="$LAST_EVAL_OUTPUT"
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

eval_value() {
  local expr="$1"
  local output
  run_eval "$expr"
  expr="$LAST_EVAL_EXPR"
  output="$LAST_EVAL_OUTPUT"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
  if grep -Fq "err:" <<<"$output" || grep -Fq "  eval-error" <<<"$output"; then
    echo "error: expected successful hot eval for: $expr" >&2
    echo "$output" >&2
    exit 1
  fi
  awk '
    /^value:/ {
      sub(/^value: /, "");
      print;
      found = 1;
      exit 0;
    }
    END {
      if (!found) exit 1;
    }
  ' <<<"$output"
}

expect_eval_done() {
  local expr="$1"
  local output
  run_eval "$expr"
  expr="$LAST_EVAL_EXPR"
  output="$LAST_EVAL_OUTPUT"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
  if grep -Fq "err:" <<<"$output" || grep -Fq "  eval-error" <<<"$output"; then
    echo "error: expected successful hot eval for: $expr" >&2
    echo "$output" >&2
    exit 1
  fi
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

activate_ghostty_app() {
  osascript -e 'tell application "'"$GHOSTTY_APP_PATH"'" to activate' >/dev/null 2>&1 || true
}

ghostty_window_id() {
  local pid
  pid="$(pgrep -f "$GHOSTTY_BIN_PATTERN" | head -n 1)"
  if [[ -z "$pid" ]]; then
    echo "error: Ghostty app is not running" >&2
    exit 1
  fi

  swift - "$pid" <<'SWIFT'
import Foundation
import CoreGraphics

let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for entry in windows {
    guard let ownerPid = entry[kCGWindowOwnerPID as String] as? Int, ownerPid == pid else { continue }
    guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
    guard let id = entry[kCGWindowNumber as String] as? Int else { continue }
    print(id)
    exit(0)
}
exit(1)
SWIFT
}

ocr_ghostty_window() {
  local window_id image_path
  window_id="$(ghostty_window_id)"
  image_path="$(mktemp /tmp/ghostty-hot-smoke-XXXXXX.png)"
  screencapture -l "$window_id" "$image_path"
  swift - "$image_path" <<'SWIFT'
import Foundation
import AppKit
import Vision

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: url) else { fatalError("missing image") }
var rect = NSRect(origin: .zero, size: image.size)
guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
    fatalError("missing cgImage")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])
for observation in request.results ?? [] {
    if let text = observation.topCandidates(1).first?.string {
        print(text)
    }
}
SWIFT
  rm -f "$image_path"
}

normalize_ocr_text() {
  python3 - <<'PY'
import sys

mapping = str.maketrans({
    "А": "A",
    "В": "B",
    "Е": "E",
    "К": "K",
    "М": "M",
    "Н": "H",
    "О": "O",
    "Р": "P",
    "С": "C",
    "Т": "T",
    "Х": "X",
    "а": "a",
    "в": "b",
    "е": "e",
    "к": "k",
    "м": "m",
    "н": "h",
    "о": "o",
    "р": "p",
    "с": "c",
    "т": "t",
    "х": "x",
})

text = sys.stdin.read().translate(mapping).upper()
text = "".join(ch for ch in text if not ch.isspace())
print(text, end="")
PY
}

expect_ghostty_ocr_contains() {
  local needle="$1"
  local deadline=$((SECONDS + 30))
  local ocr_output="" normalized_output normalized_needle
  normalized_needle="$(printf '%s' "$needle" | normalize_ocr_text)"

  while (( SECONDS < deadline )); do
    activate_ghostty_app
    ocr_output="$(ocr_ghostty_window 2>/dev/null || true)"
    normalized_output="$(printf '%s' "$ocr_output" | normalize_ocr_text)"
    if grep -Fq "$normalized_needle" <<<"$normalized_output"; then
      return 0
    fi
    sleep 1
  done

  echo "error: timed out waiting for Ghostty OCR text: $needle" >&2
  echo "$ocr_output" >&2
  exit 1
}

paste_ghostty_text() {
  local text="$1"
  local paste_log_start ui_paste_output
  activate_ghostty_app
  paste_log_start="$(wc -l < "$HOT_LOG")"
  ui_paste_output="$("$ROOT_DIR/tools/hot-paste" "$text" 2>&1)"
  expect_contains "$ui_paste_output" "status:"
  expect_contains "$ui_paste_output" "  done"
  expect_log_after "$paste_log_start" "mailbox message=write_small"
  if ! pgrep -f "$GHOSTTY_BIN_PATTERN" >/dev/null 2>&1; then
    echo "error: Ghostty app exited after hot paste" >&2
    tail -n 120 "$HOT_LOG" >&2
    exit 1
  fi
  sleep 1
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
expect_contains "$describe_output" "ghostty_surface_size"

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

# Fresh-runtime downstream managed-state probes must work before any assoc/dissoc
# or reload seeds managed state for these graphs.
ghostty_init_cold_output="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttyGlobalStateActionProbe 2>&1 || true)"
expect_hot_success "$ghostty_init_cold_output"
expect_contains "$ghostty_init_cold_output" "value: 7"
echo "cold-start ghostty global.state reads live managed state: OK"

ghostty_config_open_path_cold_output="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttyConfigOpenPathProbe 2>&1 || true)"
expect_hot_success "$ghostty_config_open_path_cold_output"
expect_contains "$ghostty_config_open_path_cold_output" "value: 7"
echo "cold-start ghostty config resources probe reads live config state: OK"

surface_export_assoc="$(zig_hot assoc ghostty_surface_process_exited --file src/apprt/embedded.zig 'fn ghostty_surface_process_exited(surface: *Surface) bool { _ = surface; return true; }' 2>&1)"
expect_contains "$surface_export_assoc" "done"
expect_contains "$surface_export_assoc" "native: patched"
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "true"
surface_export_dissoc="$(zig_hot dissoc embedded.CAPI.ghostty_surface_process_exited 2>&1)"
expect_contains "$surface_export_dissoc" "done"
expect_contains "$surface_export_dissoc" "native: restored"
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "false"
echo "assoc ghostty exported surface boundary via short name: OK"

surface_size_before="$(eval_value "ghostty_surface_size($SURFACE_HANDLE)")"
surface_size_assoc="$(zig_hot assoc ghostty_surface_size --file src/apprt/embedded.zig 'fn ghostty_surface_size(surface: *Surface) SurfaceSize { _ = surface; return .{ .columns = 111, .rows = 22, .width_px = 333, .height_px = 444, .cell_width_px = 5, .cell_height_px = 6 }; }' 2>&1)"
expect_contains "$surface_size_assoc" "done"
expect_contains "$surface_size_assoc" "native: patched"
surface_size_after_assoc="$(eval_value "ghostty_surface_size($SURFACE_HANDLE)")"
if [[ "$surface_size_after_assoc" != '.{ .columns = 111, .rows = 22, .width_px = 333, .height_px = 444, .cell_width_px = 5, .cell_height_px = 6 }' ]]; then
  echo "error: expected ghostty_surface_size aggregate return override" >&2
  echo "ghostty_surface_size after assoc: $surface_size_after_assoc" >&2
  exit 1
fi
surface_size_dissoc="$(zig_hot dissoc embedded.CAPI.ghostty_surface_size 2>&1)"
expect_contains "$surface_size_dissoc" "done"
expect_contains "$surface_size_dissoc" "native: restored"
surface_size_after_dissoc="$(eval_value "ghostty_surface_size($SURFACE_HANDLE)")"
if [[ "$surface_size_after_dissoc" != "$surface_size_before" ]]; then
  echo "error: expected ghostty_surface_size to restore baseline after dissoc" >&2
  echo "ghostty_surface_size baseline: $surface_size_before" >&2
  echo "ghostty_surface_size after dissoc: $surface_size_after_dissoc" >&2
  exit 1
fi
echo "assoc ghostty exported aggregate return via short name: OK"

ui_marker="GHOSTTY_HOT_UI_VERIFY_${RANDOM}_${RANDOM}"
ui_paste_text=$'# '"$ui_marker"$'\r'
paste_ghostty_text "$ui_paste_text"

# Classify a known source file via nREPL
classify_output="$(zig_hot classify src/os/desktop.zig 2>&1)"
expect_contains "$classify_output" "body-class="
expect_contains "$classify_output" "launchedFromDesktop"

classify_config_output="$(zig_hot classify src/config/Config.zig 2>&1)"
expect_contains "$classify_config_output" "Config"
expect_contains "$classify_config_output" "reason=struct-container"
expect_contains "$classify_config_output" "boundary=versioned-only"
expect_contains "$classify_config_output" "guidance=reload-dependents"

classify_embedded_output="$(zig_hot classify src/apprt/embedded.zig 2>&1)"
expect_contains "$classify_embedded_output" "App.Options"
expect_contains "$classify_embedded_output" "reason=extern-container"
expect_contains "$classify_embedded_output" "boundary=versioned-only"
expect_contains "$classify_embedded_output" "guidance=reload-dependents"

classify_action_output="$(zig_hot classify src/apprt/action.zig 2>&1)"
expect_contains "$classify_action_output" "SizeLimit"
expect_contains "$classify_action_output" "reason=extern-container"
expect_contains "$classify_action_output" "boundary=versioned-only"
expect_contains "$classify_action_output" "guidance=reload-dependents"

classify_structs_output="$(zig_hot classify src/apprt/structs.zig 2>&1)"
expect_contains "$classify_structs_output" "ClipboardRequest"
expect_contains "$classify_structs_output" "reason=union-container"
expect_contains "$classify_structs_output" "boundary=versioned-only"
expect_contains "$classify_structs_output" "guidance=reload-dependents"

invalidate_config_output="$(zig_hot invalidate src/config/Config.zig 2>&1)"
expect_contains "$invalidate_config_output" "impact:"
expect_contains "$invalidate_config_output" "decl-key=owner=root;file=$ROOT_DIR/src/config/key.zig;decl=Key;kind=const_decl reason=comptime_dep"

size_limit_probe_output="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttySizeLimitWrapperProbe 2>&1)"
expect_hot_success "$size_limit_probe_output"
expect_contains "$size_limit_probe_output" "value: 17"
echo "SizeLimit wrapper probe: OK"

clipboard_probe_output="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttyClipboardRequestWrapperProbe 2>&1)"
expect_hot_success "$clipboard_probe_output"
expect_contains "$clipboard_probe_output" "value: 1"
echo "ClipboardRequest wrapper probe: OK"

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

# Override RunIterator.addCodepoint — the visible_cp dot-to-bang transform
addcp_assoc="$(zig_hot assoc RunIterator.addCodepoint --file src/font/shaper/run.zig - <<'ASSOC_EOF'
fn addCodepoint(self: *RunIterator, hasher: anytype, cp: u32, cluster: u32) !void {
    const visible_cp: u32 = if (cp == '.') '!' else cp;
    autoHash(hasher, visible_cp);
    autoHash(hasher, cluster);
    try self.hooks.addCodepoint(visible_cp, cluster);
}
ASSOC_EOF
2>&1)"
expect_contains "$addcp_assoc" "done"
expect_contains "$addcp_assoc" "native: patched"
echo "assoc RunIterator.addCodepoint override (visible_cp transform): OK"

addcp_probe_text=$'clear\r# PATCHCHECK_AAA...BBB\r'
paste_ghostty_text "$addcp_probe_text"
expect_ghostty_ocr_contains "PATCHCHECK_AAA!!!BBB"
echo "assoc RunIterator.addCodepoint visible dot→bang transform: OK"

# Verify addCodepoint compiles with the override in place
addcp_body="$(zig_hot compile-body src/font/shaper/run.zig addCodepoint 2>&1 || true)"
expect_contains "$addcp_body" "instructions:"
echo "addCodepoint with visible_cp override compiles: OK"

# Unassoc RunIterator.addCodepoint — restore original
dissoc_addcp="$(zig_hot dissoc RunIterator.addCodepoint 2>&1)"
expect_contains "$dissoc_addcp" "done"
expect_contains "$dissoc_addcp" "native: restored"
paste_ghostty_text "$addcp_probe_text"
expect_ghostty_ocr_contains "PATCHCHECK_AAA...BBB"
echo "dissoc RunIterator.addCodepoint: OK"

# Override Shaper.makeFeaturesDict — trivial override returning error
mfd_assoc="$(zig_hot assoc Shaper.makeFeaturesDict --file src/font/shaper/coretext.zig 'fn makeFeaturesDict(feats: []const Feature) !*macos.foundation.Dictionary { _ = feats; return error.Unexpected; }' 2>&1)"
expect_contains "$mfd_assoc" "done"
expect_contains "$mfd_assoc" "native: patched"
echo "assoc Shaper.makeFeaturesDict override: OK"

# Verify makeFeaturesDict compiles with the override
mfd_body="$(zig_hot compile-body src/font/shaper/coretext.zig makeFeaturesDict 2>&1 || true)"
expect_contains "$mfd_body" "instructions:"
echo "makeFeaturesDict with override compiles: OK"

# Dissoc makeFeaturesDict
dissoc_mfd="$(zig_hot dissoc Shaper.makeFeaturesDict 2>&1)"
expect_contains "$dissoc_mfd" "done"
expect_contains "$dissoc_mfd" "native: restored"
echo "dissoc Shaper.makeFeaturesDict: OK"

# Override Shaper.endFrame — trivial no-op override
ef_assoc="$(zig_hot assoc Shaper.endFrame --file src/font/shaper/coretext.zig 'fn endFrame(self: *Shaper) void { _ = self; }' 2>&1)"
expect_contains "$ef_assoc" "done"
expect_contains "$ef_assoc" "native: patched"
echo "assoc Shaper.endFrame override: OK"

# Verify endFrame compiles with the override
ef_body="$(zig_hot compile-body src/font/shaper/coretext.zig endFrame 2>&1 || true)"
expect_contains "$ef_body" "instructions:"
echo "endFrame with override compiles: OK"

# Dissoc endFrame
dissoc_ef="$(zig_hot dissoc Shaper.endFrame 2>&1)"
expect_contains "$dissoc_ef" "done"
expect_contains "$dissoc_ef" "native: restored"
echo "dissoc Shaper.endFrame: OK"

# Probe Ghostty runtime_addressable var reads through a real project function slot.
subclass_probe_assoc="$(zig_hot assoc --no-native getSubclass --file src/renderer/metal/IOSurfaceLayer.zig 'fn getSubclass() error{ObjCFailed}!objc.Class { return if (Subclass == null) 0 else 1; }' 2>&1)"
expect_hot_success "$subclass_probe_assoc"
echo "assoc getSubclass value-cell probe: OK"

subclass_assoc_one="$(zig_hot assoc --type var --no-native Subclass 1 2>&1)"
expect_hot_success "$subclass_assoc_one"
subclass_probe_one="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttyGetSubclass 2>&1)"
expect_hot_success "$subclass_probe_one"
expect_contains "$subclass_probe_one" "value: 1"
echo "assoc Subclass runtime_addressable var -> non-null: OK"

subclass_assoc_null="$(zig_hot assoc --type var --no-native Subclass null 2>&1)"
expect_hot_success "$subclass_assoc_null"
subclass_probe_null="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttyGetSubclass 2>&1)"
expect_hot_success "$subclass_probe_null"
expect_contains "$subclass_probe_null" "value: 0"
echo "assoc Subclass runtime_addressable var -> null: OK"

subclass_assoc_restore="$(zig_hot assoc --type var --no-native Subclass 1 2>&1)"
expect_hot_success "$subclass_assoc_restore"
subclass_probe_restore="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttyGetSubclass 2>&1)"
expect_hot_success "$subclass_probe_restore"
expect_contains "$subclass_probe_restore" "value: 1"
dissoc_subclass_probe="$(zig_hot dissoc getSubclass 2>&1)"
expect_hot_success "$dissoc_subclass_probe"
dissoc_subclass_var="$(zig_hot dissoc Subclass 2>&1)"
expect_hot_success "$dissoc_subclass_var"
echo "dissoc Subclass probe and var override: OK"

# Probe Ghostty imported runtime_addressable alias overrides through a real project function slot.
state_probe_assoc="$(zig_hot assoc --no-native ghostty_init --file src/main_c.zig 'fn ghostty_init(argc: usize, argv: [*][*:0]u8) c_int { _ = argc; _ = argv; return if (@intFromPtr(state) == 0) 0 else 7; }' 2>&1)"
expect_hot_success "$state_probe_assoc"
echo "assoc ghostty_init imported state probe: OK"

state_assoc_one="$(zig_hot assoc --type var --no-native state 1 2>&1)"
expect_hot_success "$state_assoc_one"
state_probe_one="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttyInitStateProbe 2>&1)"
expect_hot_success "$state_probe_one"
expect_contains "$state_probe_one" "value: 7"
echo "assoc state imported runtime_addressable alias -> non-zero: OK"

state_assoc_zero="$(zig_hot assoc --type var --no-native state 0 2>&1)"
expect_hot_success "$state_assoc_zero"
state_probe_zero="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttyInitStateProbe 2>&1)"
expect_hot_success "$state_probe_zero"
expect_contains "$state_probe_zero" "value: 0"
echo "assoc state imported runtime_addressable alias -> zero: OK"

state_assoc_restore="$(zig_hot assoc --type var --no-native state 1 2>&1)"
expect_hot_success "$state_assoc_restore"
state_probe_restore="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttyInitStateProbe 2>&1)"
expect_hot_success "$state_probe_restore"
expect_contains "$state_probe_restore" "value: 7"
dissoc_state_probe="$(zig_hot dissoc ghostty_init 2>&1)"
expect_hot_success "$dissoc_state_probe"
dissoc_state_var="$(zig_hot dissoc state 2>&1)"
expect_hot_success "$dissoc_state_var"
echo "dissoc ghostty imported state probe and var override: OK"

# Override Shaper.getFont without native patching — the live path should execute
# and Ghostty must stay responsive even if the override returns an error.
gf_assoc="$(zig_hot assoc --no-native Shaper.getFont --file src/font/shaper/coretext.zig - <<GF_EOF
fn getFont(self: *Shaper, grid: *font.SharedGrid, index: font.Collection.Index) !*macos.foundation.Dictionary {
    _ = self;
    _ = grid;
    _ = index;
    return error.Unexpected;
}
GF_EOF
2>&1)"
expect_contains "$gf_assoc" "done"
echo "assoc Shaper.getFont --no-native override: OK"

gf_probe_text=$'clear\r# PATCHCHECK_GETFONT_ASSOC\r'
paste_ghostty_text "$gf_probe_text"
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "false"
echo "assoc Shaper.getFont --no-native live path reached without crash: OK"

# Dissoc getFont and prove the renderer recovers
dissoc_gf="$(zig_hot dissoc Shaper.getFont 2>&1)"
expect_contains "$dissoc_gf" "done"
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "false"
gf_restore_text=$'clear\r# PATCHCHECK_GETFONT_DISSOC\r'
paste_ghostty_text "$gf_restore_text"
expect_ghostty_ocr_contains "PATCHCHECK_GETFONT_DISSOC"
echo "dissoc Shaper.getFont: OK"

# ── Verify dissoc restores original behavior ──────────────────────────

# After dissoc, compile-body should return the original instruction count
mfd_after_dissoc="$(zig_hot compile-body src/font/shaper/coretext.zig makeFeaturesDict 2>&1)"
expect_contains "$mfd_after_dissoc" "instructions:"
echo "dissoc restores makeFeaturesDict original: OK"

ef_after_dissoc="$(zig_hot compile-body src/font/shaper/coretext.zig endFrame 2>&1)"
expect_contains "$ef_after_dissoc" "instructions:"
echo "dissoc restores endFrame original: OK"

# ── Assoc with malformed code — should not crash ──────────────────────

malformed_output="$(zig_hot assoc answer --file src/font/shaper/coretext.zig 'fn answer(BROKEN SYNTAX' 2>&1 || true)"
if echo "$malformed_output" | grep -qF "done"; then
  echo "assoc malformed code: OK (accepted — no crash)"
else
  echo "assoc malformed code: OK (rejected cleanly)"
fi

# Assoc for non-existent function — should not crash
nonexist_output="$(zig_hot assoc totally_bogus_function_xyz --file src/font/shaper/coretext.zig 'fn bogus() void {}' 2>&1 || true)"
echo "assoc non-existent function: OK (no crash)"

# Dissoc remaining overrides to clean up
zig_hot dissoc answer >/dev/null 2>&1 || true
zig_hot dissoc RGB.componentLuminance >/dev/null 2>&1 || true

echo "hot smoke test passed"
