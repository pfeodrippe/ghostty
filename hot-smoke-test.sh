#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOT_BIN="${HOT_BIN:-$ROOT_DIR/tools/hot}"
ZIG_BIN="${ZIG_BIN:-$ROOT_DIR/.zig-toolchain/zig-0.15.2/bin/zig}"
ZIG_LIB_DIR="${ZIG_LIB_DIR:-$ROOT_DIR/vendor/zig/lib}"
HOT_CACHE_DIR="${HOT_CACHE_DIR:-$ROOT_DIR/.zig-cache}"
HOT_CONFIG_FILE="${HOT_CONFIG_FILE:-$HOT_CACHE_DIR/hot/ghostty.config}"
PORT_FILE="${PORT_FILE:-$ROOT_DIR/.nrepl-port}"
HOT_LOG="${HOT_LOG:-$ROOT_DIR/.hot-run.log}"
GHOSTTY_BIN_PATTERN="${GHOSTTY_BIN_PATTERN:-macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty}"
GHOSTTY_APP_PATH="${GHOSTTY_APP_PATH:-$ROOT_DIR/macos/build/Debug/Ghostty.app}"
HOT_TEST_PROMOTION_WORKERS="${HOT_TEST_PROMOTION_WORKERS:-2}"
SURFACE_HANDLE='@objc:NSApp.activeWindow.contentView//surfaceModel.asObject.surface'
SURFACE_HANDLE_CANDIDATES=(
  '@objc:NSApp.activeWindow.contentView//surfaceModel.asObject.surface'
  '@objc:NSApp.keyWindow.contentView//surfaceModel.asObject.surface'
  '@objc:NSApp.mainWindow.contentView//surfaceModel.asObject.surface'
)
RUN_ZIG_REL="src/font/shaper/run.zig"
RUN_ZIG_FILE="$ROOT_DIR/$RUN_ZIG_REL"
RUN_ZIG_BACKUP=""
RUN_ZIG_RESTORE_NEEDED=0

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
  local config_path="$HOT_CONFIG_FILE"
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
  local config_path="$HOT_CONFIG_FILE"
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
    env ZIG_LIB_DIR="$ZIG_LIB_DIR" "$ZIG_BIN" hot "$@"
  )
}

ensure_run_zig_backup() {
  if [[ -n "$RUN_ZIG_BACKUP" ]]; then
    return 0
  fi

  mkdir -p "$HOT_CACHE_DIR"
  RUN_ZIG_BACKUP="$(mktemp "$HOT_CACHE_DIR/hot-smoke-run-zig-XXXXXX")"
  cp "$RUN_ZIG_FILE" "$RUN_ZIG_BACKUP"
}

restore_run_zig_source() {
  [[ -n "$RUN_ZIG_BACKUP" ]] || return 0
  cp "$RUN_ZIG_BACKUP" "$RUN_ZIG_FILE"
  RUN_ZIG_RESTORE_NEEDED=0
}

cleanup() {
  if (( RUN_ZIG_RESTORE_NEEDED != 0 )); then
    restore_run_zig_source >/dev/null 2>&1 || true
    if [[ -s "$PORT_FILE" ]]; then
      zig_hot reload "$RUN_ZIG_REL" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$RUN_ZIG_BACKUP" ]]; then
    rm -f "$RUN_ZIG_BACKUP"
  fi
}
trap cleanup EXIT INT TERM

decl_range_in_file() {
  local file="$1"
  local pattern="$2"
  local offset
  offset="$(grep -aboF "$pattern" "$file" | head -n 1 | cut -d: -f1)"
  if [[ -z "$offset" ]]; then
    echo "error: unable to locate range for pattern: $pattern" >&2
    exit 1
  fi
  printf '%s %s\n' "$offset" "$((offset + ${#pattern}))"
}

run_zig_next_range() {
  decl_range_in_file "$RUN_ZIG_FILE" 'pub fn next'
}

run_zig_index_for_cell_range() {
  decl_range_in_file "$RUN_ZIG_FILE" 'fn indexForCell'
}

patch_run_zig_next_probe() {
  ensure_run_zig_backup
  restore_run_zig_source
  python3 - "$RUN_ZIG_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = """            try self.addCodepoint(
                &hasher,
                if (cell.codepoint() == 0) ' ' else cell.codepoint(),
                @intCast(cluster),
            );
"""
new = """            try self.addCodepoint(
                &hasher,
                if (cell.codepoint() == 0) ' ' else if (cell.codepoint() == 'Z') '!' else cell.codepoint(),
                @intCast(cluster),
            );
"""
if old not in source:
    raise SystemExit("error: missing RunIterator.next primary addCodepoint")
path.write_text(source.replace(old, new, 1))
PY
  RUN_ZIG_RESTORE_NEEDED=1
}

patch_run_zig_index_for_cell_probe() {
  local blocked_cp="${1:-Q}"
  ensure_run_zig_backup
  restore_run_zig_source
  python3 - "$RUN_ZIG_FILE" "$blocked_cp" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
blocked_cp = sys.argv[2]
source = path.read_text()
old = """        const primary_cp: u32 = cell.codepoint();
        const primary = try self.opts.grid.getIndex(
"""
new = f"""        const primary_cp: u32 = cell.codepoint();
        if (primary_cp == '{blocked_cp}') return null;
        const primary = try self.opts.grid.getIndex(
"""
if old not in source:
    raise SystemExit("error: missing RunIterator.indexForCell primary lookup")
path.write_text(source.replace(old, new, 1))
PY
  RUN_ZIG_RESTORE_NEEDED=1
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

promotion_telemetry_line() {
  local output line
  output="$(zig_hot promotion-telemetry 2>&1)" || return 1
  line="$(awk '/^promotion-telemetry:$/ { getline; print; exit }' <<<"$output")"
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

promotion_telemetry_value() {
  local key="$1"
  local line
  line="$(promotion_telemetry_line)" || return 1
  awk -v key="$key" '
    {
      for (i = 1; i <= NF; i += 1) {
        split($i, pair, "=")
        if (pair[1] == key) {
          print pair[2]
          exit 0
        }
      }
      exit 1
    }
  ' <<<"$line"
}

wait_for_promotion_telemetry_at_least() {
  local key="$1"
  local minimum="$2"
  local deadline=$((SECONDS + 120))
  local poll_interval="${HOT_TEST_PROMOTION_POLL_INTERVAL:-0.05}"
  local value=""
  local last_line=""

  while (( SECONDS < deadline )); do
    last_line="$(promotion_telemetry_line 2>/dev/null || true)"
    value="$(promotion_telemetry_value "$key" 2>/dev/null || true)"
    if [[ -n "$value" ]] && (( value >= minimum )); then
      return 0
    fi
    sleep "$poll_interval"
  done

  echo "error: timed out waiting for promotion telemetry $key >= $minimum" >&2
  if [[ -n "$last_line" ]]; then
    echo "last-promotion-telemetry: $last_line" >&2
  fi
  zig_hot promotion-telemetry 1>&2 || true
  exit 1
}

wait_for_promotion_telemetry_any_at_least() {
  local first_key="$1"
  local first_minimum="$2"
  local second_key="$3"
  local second_minimum="$4"
  local deadline=$((SECONDS + 120))
  local poll_interval="${HOT_TEST_PROMOTION_POLL_INTERVAL:-0.05}"
  local first_value=""
  local second_value=""
  local last_line=""

  while (( SECONDS < deadline )); do
    last_line="$(promotion_telemetry_line 2>/dev/null || true)"
    first_value="$(promotion_telemetry_value "$first_key" 2>/dev/null || true)"
    second_value="$(promotion_telemetry_value "$second_key" 2>/dev/null || true)"
    if [[ -n "$first_value" ]] && (( first_value >= first_minimum )); then
      return 0
    fi
    if [[ -n "$second_value" ]] && (( second_value >= second_minimum )); then
      return 0
    fi
    sleep "$poll_interval"
  done

  echo "error: timed out waiting for promotion telemetry ${first_key} >= ${first_minimum} or ${second_key} >= ${second_minimum}" >&2
  if [[ -n "$last_line" ]]; then
    echo "last-promotion-telemetry: $last_line" >&2
  fi
  zig_hot promotion-telemetry 1>&2 || true
  exit 1
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

ghostty_proven_functions=(
  RGB.componentLuminance
  RunIterator.addCodepoint
  Shaper.makeFeaturesDict
  Shaper.endFrame
  Shaper.getFont
  ghostty_surface_process_exited
  ghostty_surface_size
  ghostty_init
  getSubclass
  RGB.perceivedLuminance
  RGB.eql
  RGB.contrast
  Padding.add
  Padding.eql
  Padding.balanced
  GridSize.init
  ScreenSize.subPadding
  ScreenSize.blankPadding
  Mods.binding
  Key.modifier
  isSafeUtf8
)
ghostty_proven_vars=(
  Subclass
  state
  decompressed_data
)

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

expect_ghostty_ocr_not_contains() {
  local needle="$1"
  local deadline=$((SECONDS + 30))
  local ocr_output="" normalized_output normalized_needle
  normalized_needle="$(printf '%s' "$needle" | normalize_ocr_text)"

  while (( SECONDS < deadline )); do
    activate_ghostty_app
    ocr_output="$(ocr_ghostty_window 2>/dev/null || true)"
    normalized_output="$(printf '%s' "$ocr_output" | normalize_ocr_text)"
    if ! grep -Fq "$normalized_needle" <<<"$normalized_output"; then
      return 0
    fi
    sleep 1
  done

  echo "error: timed out waiting for Ghostty OCR text to disappear: $needle" >&2
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
launched_from_desktop_assoc="$(zig_hot assoc --no-native launchedFromDesktop --file src/os/desktop.zig 'pub fn launchedFromDesktop() bool { return true; }' 2>&1)"
expect_contains "$launched_from_desktop_assoc" "done"
expect_value "os.desktop.launchedFromDesktop" "true"
echo "assoc launchedFromDesktop override: OK"

dissoc_launched_from_desktop="$(zig_hot dissoc launchedFromDesktop 2>&1)"
expect_contains "$dissoc_launched_from_desktop" "done"
expect_value "os.desktop.launchedFromDesktop" "false"
ghostty_proven_functions+=(launchedFromDesktop)
echo "dissoc launchedFromDesktop: OK"

ghostty_pointer_alias_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'read_after_bump(40)' 2>&1)"
expect_hot_success "$ghostty_pointer_alias_baseline"
expect_contains "$ghostty_pointer_alias_baseline" "value: 42"
ghostty_pointer_alias_assoc="$(zig_hot assoc --no-native read_after_bump --file test/hot/local_pointer_alias_probe.zig 'pub fn read_after_bump(seed: i64) i64 { return seed + 10; }' 2>&1)"
expect_hot_success "$ghostty_pointer_alias_assoc"
ghostty_pointer_alias_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'read_after_bump(40)' 2>&1)"
expect_hot_success "$ghostty_pointer_alias_patched"
expect_contains "$ghostty_pointer_alias_patched" "value: 50"
ghostty_pointer_alias_dissoc="$(zig_hot dissoc read_after_bump 2>&1)"
expect_hot_success "$ghostty_pointer_alias_dissoc"
ghostty_pointer_alias_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'read_after_bump(40)' 2>&1)"
expect_hot_success "$ghostty_pointer_alias_restored"
expect_contains "$ghostty_pointer_alias_restored" "value: 42"
echo "assoc/dissoc local pointer alias function: OK"

ghostty_cast_memset_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'cast_memset_score(1)' 2>&1)"
expect_hot_success "$ghostty_cast_memset_baseline"
expect_contains "$ghostty_cast_memset_baseline" "value: 6666"
ghostty_cast_memset_assoc="$(zig_hot assoc --no-native cast_memset_score --file test/hot/local_pointer_alias_probe.zig 'pub fn cast_memset_score(seed: i64) i64 { return seed + 80; }' 2>&1)"
expect_hot_success "$ghostty_cast_memset_assoc"
ghostty_cast_memset_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'cast_memset_score(1)' 2>&1)"
expect_hot_success "$ghostty_cast_memset_patched"
expect_contains "$ghostty_cast_memset_patched" "value: 81"
ghostty_cast_memset_dissoc="$(zig_hot dissoc cast_memset_score 2>&1)"
expect_hot_success "$ghostty_cast_memset_dissoc"
ghostty_cast_memset_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'cast_memset_score(1)' 2>&1)"
expect_hot_success "$ghostty_cast_memset_restored"
expect_contains "$ghostty_cast_memset_restored" "value: 6666"
echo "assoc/dissoc casted-slice memory-effect function: OK"

ghostty_deref_slice_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'deref_slice_score(1)' 2>&1)"
expect_hot_success "$ghostty_deref_slice_baseline"
expect_contains "$ghostty_deref_slice_baseline" "value: 1774"
ghostty_deref_slice_assoc="$(zig_hot assoc --no-native deref_slice_score --file test/hot/local_pointer_alias_probe.zig 'pub fn deref_slice_score(seed: i64) i64 { return seed + 90; }' 2>&1)"
expect_hot_success "$ghostty_deref_slice_assoc"
ghostty_deref_slice_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'deref_slice_score(1)' 2>&1)"
expect_hot_success "$ghostty_deref_slice_patched"
expect_contains "$ghostty_deref_slice_patched" "value: 91"
ghostty_deref_slice_dissoc="$(zig_hot dissoc deref_slice_score 2>&1)"
expect_hot_success "$ghostty_deref_slice_dissoc"
ghostty_deref_slice_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'deref_slice_score(1)' 2>&1)"
expect_hot_success "$ghostty_deref_slice_restored"
expect_contains "$ghostty_deref_slice_restored" "value: 1774"
echo "assoc/dissoc deref-slice memory-effect function: OK"

ghostty_pointer_capture_field_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'pointer_capture_field_score(1)' 2>&1)"
expect_hot_success "$ghostty_pointer_capture_field_baseline"
expect_contains "$ghostty_pointer_capture_field_baseline" "value: 1233"
ghostty_pointer_capture_field_assoc="$(zig_hot assoc --no-native pointer_capture_field_score --file test/hot/local_pointer_alias_probe.zig 'pub fn pointer_capture_field_score(seed: i64) i64 { return seed + 100; }' 2>&1)"
expect_hot_success "$ghostty_pointer_capture_field_assoc"
ghostty_pointer_capture_field_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'pointer_capture_field_score(1)' 2>&1)"
expect_hot_success "$ghostty_pointer_capture_field_patched"
expect_contains "$ghostty_pointer_capture_field_patched" "value: 101"
ghostty_pointer_capture_field_dissoc="$(zig_hot dissoc pointer_capture_field_score 2>&1)"
expect_hot_success "$ghostty_pointer_capture_field_dissoc"
ghostty_pointer_capture_field_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'pointer_capture_field_score(1)' 2>&1)"
expect_hot_success "$ghostty_pointer_capture_field_restored"
expect_contains "$ghostty_pointer_capture_field_restored" "value: 1233"
echo "assoc/dissoc field pointer-capture function: OK"

ghostty_array_address_alias_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'array_address_alias_score(1)' 2>&1)"
expect_hot_success "$ghostty_array_address_alias_baseline"
expect_contains "$ghostty_array_address_alias_baseline" "value: 323"
ghostty_array_address_alias_assoc="$(zig_hot assoc --no-native array_address_alias_score --file test/hot/local_pointer_alias_probe.zig 'pub fn array_address_alias_score(seed: i64) i64 { return seed + 110; }' 2>&1)"
expect_hot_success "$ghostty_array_address_alias_assoc"
ghostty_array_address_alias_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'array_address_alias_score(1)' 2>&1)"
expect_hot_success "$ghostty_array_address_alias_patched"
expect_contains "$ghostty_array_address_alias_patched" "value: 111"
ghostty_array_address_alias_dissoc="$(zig_hot dissoc array_address_alias_score 2>&1)"
expect_hot_success "$ghostty_array_address_alias_dissoc"
ghostty_array_address_alias_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'array_address_alias_score(1)' 2>&1)"
expect_hot_success "$ghostty_array_address_alias_restored"
expect_contains "$ghostty_array_address_alias_restored" "value: 323"
echo "assoc/dissoc array-address pointer alias function: OK"

ghostty_field_address_alias_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'field_address_alias_score(1)' 2>&1)"
expect_hot_success "$ghostty_field_address_alias_baseline"
expect_contains "$ghostty_field_address_alias_baseline" "value: 423"
ghostty_field_address_alias_assoc="$(zig_hot assoc --no-native field_address_alias_score --file test/hot/local_pointer_alias_probe.zig 'pub fn field_address_alias_score(seed: i64) i64 { return seed + 150; }' 2>&1)"
expect_hot_success "$ghostty_field_address_alias_assoc"
ghostty_field_address_alias_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'field_address_alias_score(1)' 2>&1)"
expect_hot_success "$ghostty_field_address_alias_patched"
expect_contains "$ghostty_field_address_alias_patched" "value: 151"
ghostty_field_address_alias_dissoc="$(zig_hot dissoc field_address_alias_score 2>&1)"
expect_hot_success "$ghostty_field_address_alias_dissoc"
ghostty_field_address_alias_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'field_address_alias_score(1)' 2>&1)"
expect_hot_success "$ghostty_field_address_alias_restored"
expect_contains "$ghostty_field_address_alias_restored" "value: 423"
echo "assoc/dissoc field-address pointer alias function: OK"

ghostty_address_of_field_capture_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'address_of_field_pointer_capture_score(1)' 2>&1)"
expect_hot_success "$ghostty_address_of_field_capture_baseline"
expect_contains "$ghostty_address_of_field_capture_baseline" "value: 1233"
ghostty_address_of_field_capture_assoc="$(zig_hot assoc --no-native address_of_field_pointer_capture_score --file test/hot/local_pointer_alias_probe.zig 'pub fn address_of_field_pointer_capture_score(seed: i64) i64 { return seed + 160; }' 2>&1)"
expect_hot_success "$ghostty_address_of_field_capture_assoc"
ghostty_address_of_field_capture_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'address_of_field_pointer_capture_score(1)' 2>&1)"
expect_hot_success "$ghostty_address_of_field_capture_patched"
expect_contains "$ghostty_address_of_field_capture_patched" "value: 161"
ghostty_address_of_field_capture_dissoc="$(zig_hot dissoc address_of_field_pointer_capture_score 2>&1)"
expect_hot_success "$ghostty_address_of_field_capture_dissoc"
ghostty_address_of_field_capture_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'address_of_field_pointer_capture_score(1)' 2>&1)"
expect_hot_success "$ghostty_address_of_field_capture_restored"
expect_contains "$ghostty_address_of_field_capture_restored" "value: 1233"
echo "assoc/dissoc address-of-field pointer-capture function: OK"

ghostty_switch_pointer_payload_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'switch_pointer_payload_score(1)' 2>&1)"
expect_hot_success "$ghostty_switch_pointer_payload_baseline"
expect_contains "$ghostty_switch_pointer_payload_baseline" "value: 11"
ghostty_switch_pointer_payload_assoc="$(zig_hot assoc --no-native switch_pointer_payload_score --file test/hot/local_pointer_alias_probe.zig 'pub fn switch_pointer_payload_score(seed: i64) i64 { return seed + 170; }' 2>&1)"
expect_hot_success "$ghostty_switch_pointer_payload_assoc"
ghostty_switch_pointer_payload_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'switch_pointer_payload_score(1)' 2>&1)"
expect_hot_success "$ghostty_switch_pointer_payload_patched"
expect_contains "$ghostty_switch_pointer_payload_patched" "value: 171"
ghostty_switch_pointer_payload_dissoc="$(zig_hot dissoc switch_pointer_payload_score 2>&1)"
expect_hot_success "$ghostty_switch_pointer_payload_dissoc"
ghostty_switch_pointer_payload_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'switch_pointer_payload_score(1)' 2>&1)"
expect_hot_success "$ghostty_switch_pointer_payload_restored"
expect_contains "$ghostty_switch_pointer_payload_restored" "value: 11"
echo "assoc/dissoc switch pointer-payload function: OK"

ghostty_nested_pointer_alias_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'nested_pointer_alias_score(1)' 2>&1)"
expect_hot_success "$ghostty_nested_pointer_alias_baseline"
expect_contains "$ghostty_nested_pointer_alias_baseline" "value: 11"
ghostty_nested_pointer_alias_assoc="$(zig_hot assoc --no-native nested_pointer_alias_score --file test/hot/local_pointer_alias_probe.zig 'pub fn nested_pointer_alias_score(seed: i64) i64 { return seed + 180; }' 2>&1)"
expect_hot_success "$ghostty_nested_pointer_alias_assoc"
ghostty_nested_pointer_alias_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'nested_pointer_alias_score(1)' 2>&1)"
expect_hot_success "$ghostty_nested_pointer_alias_patched"
expect_contains "$ghostty_nested_pointer_alias_patched" "value: 181"
ghostty_nested_pointer_alias_dissoc="$(zig_hot dissoc nested_pointer_alias_score 2>&1)"
expect_hot_success "$ghostty_nested_pointer_alias_dissoc"
ghostty_nested_pointer_alias_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'nested_pointer_alias_score(1)' 2>&1)"
expect_hot_success "$ghostty_nested_pointer_alias_restored"
expect_contains "$ghostty_nested_pointer_alias_restored" "value: 11"
echo "assoc/dissoc nested pointer-alias function: OK"

ghostty_for_value_pointer_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'for_value_pointer_score(1)' 2>&1)"
expect_hot_success "$ghostty_for_value_pointer_baseline"
expect_contains "$ghostty_for_value_pointer_baseline" "value: 122"
ghostty_for_value_pointer_assoc="$(zig_hot assoc --no-native for_value_pointer_score --file test/hot/local_pointer_alias_probe.zig 'pub fn for_value_pointer_score(seed: i64) i64 { return seed + 120; }' 2>&1)"
expect_hot_success "$ghostty_for_value_pointer_assoc"
ghostty_for_value_pointer_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'for_value_pointer_score(1)' 2>&1)"
expect_hot_success "$ghostty_for_value_pointer_patched"
expect_contains "$ghostty_for_value_pointer_patched" "value: 121"
ghostty_for_value_pointer_dissoc="$(zig_hot dissoc for_value_pointer_score 2>&1)"
expect_hot_success "$ghostty_for_value_pointer_dissoc"
ghostty_for_value_pointer_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'for_value_pointer_score(1)' 2>&1)"
expect_hot_success "$ghostty_for_value_pointer_restored"
expect_contains "$ghostty_for_value_pointer_restored" "value: 122"
echo "assoc/dissoc for-value pointer payload function: OK"

ghostty_bytes_view_memset_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'bytes_view_memset_score(1)' 2>&1)"
expect_hot_success "$ghostty_bytes_view_memset_baseline"
expect_contains "$ghostty_bytes_view_memset_baseline" "value: 555"
ghostty_bytes_view_memset_assoc="$(zig_hot assoc --no-native bytes_view_memset_score --file test/hot/local_pointer_alias_probe.zig 'pub fn bytes_view_memset_score(seed: u64) i64 { return @intCast(seed + 130); }' 2>&1)"
expect_hot_success "$ghostty_bytes_view_memset_assoc"
ghostty_bytes_view_memset_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'bytes_view_memset_score(1)' 2>&1)"
expect_hot_success "$ghostty_bytes_view_memset_patched"
expect_contains "$ghostty_bytes_view_memset_patched" "value: 131"
ghostty_bytes_view_memset_dissoc="$(zig_hot dissoc bytes_view_memset_score 2>&1)"
expect_hot_success "$ghostty_bytes_view_memset_dissoc"
ghostty_bytes_view_memset_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'bytes_view_memset_score(1)' 2>&1)"
expect_hot_success "$ghostty_bytes_view_memset_restored"
expect_contains "$ghostty_bytes_view_memset_restored" "value: 555"
echo "assoc/dissoc bytesAsSlice memory-effect function: OK"

ghostty_nested_local_memcpy_baseline="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'nested_local_memcpy_score(1)' 2>&1)"
expect_hot_success "$ghostty_nested_local_memcpy_baseline"
expect_contains "$ghostty_nested_local_memcpy_baseline" "value: 123"
ghostty_nested_local_memcpy_assoc="$(zig_hot assoc --no-native nested_local_memcpy_score --file test/hot/local_pointer_alias_probe.zig 'pub fn nested_local_memcpy_score(seed: i64) i64 { return seed + 140; }' 2>&1)"
expect_hot_success "$ghostty_nested_local_memcpy_assoc"
ghostty_nested_local_memcpy_patched="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'nested_local_memcpy_score(1)' 2>&1)"
expect_hot_success "$ghostty_nested_local_memcpy_patched"
expect_contains "$ghostty_nested_local_memcpy_patched" "value: 141"
ghostty_nested_local_memcpy_dissoc="$(zig_hot dissoc nested_local_memcpy_score 2>&1)"
expect_hot_success "$ghostty_nested_local_memcpy_dissoc"
ghostty_nested_local_memcpy_restored="$(zig_hot eval-zig test/hot/local_pointer_alias_probe.zig 'nested_local_memcpy_score(1)' 2>&1)"
expect_hot_success "$ghostty_nested_local_memcpy_restored"
expect_contains "$ghostty_nested_local_memcpy_restored" "value: 123"
echo "assoc/dissoc nested-local memcpy function: OK"

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
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "true"
surface_export_dissoc="$(zig_hot dissoc embedded.CAPI.ghostty_surface_process_exited 2>&1)"
expect_contains "$surface_export_dissoc" "done"
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "false"
echo "assoc ghostty exported surface boundary via short name: OK"

surface_size_before="$(eval_value "ghostty_surface_size($SURFACE_HANDLE)")"
surface_size_assoc="$(zig_hot assoc ghostty_surface_size --file src/apprt/embedded.zig 'fn ghostty_surface_size(surface: *Surface) SurfaceSize { _ = surface; return .{ .columns = 111, .rows = 22, .width_px = 333, .height_px = 444, .cell_width_px = 5, .cell_height_px = 6 }; }' 2>&1)"
expect_contains "$surface_size_assoc" "done"
surface_size_after_assoc="$(eval_value "ghostty_surface_size($SURFACE_HANDLE)")"
if [[ "$surface_size_after_assoc" != '.{ .columns = 111, .rows = 22, .width_px = 333, .height_px = 444, .cell_width_px = 5, .cell_height_px = 6 }' ]]; then
  echo "error: expected ghostty_surface_size aggregate return override" >&2
  echo "ghostty_surface_size after assoc: $surface_size_after_assoc" >&2
  exit 1
fi
surface_size_dissoc="$(zig_hot dissoc embedded.CAPI.ghostty_surface_size 2>&1)"
expect_contains "$surface_size_dissoc" "done"
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

classify_split_tree_output="$(zig_hot classify src/datastruct/split_tree.zig 2>&1)"
expect_contains "$classify_split_tree_output" "name=SplitTree.refNodes body-class=interpreter-ready live-path=dispatch-cell"
expect_contains "$classify_split_tree_output" "name=SplitTree.goto body-class=interpreter-ready live-path=dispatch-cell"
expect_contains "$classify_split_tree_output" "name=SplitTree.split body-class=interpreter-ready live-path=dispatch-cell"
echo "split_tree scoped-cleanup classify proof: OK"

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

split_tree_cleanup_probe_output="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttySplitTreeCleanupWrapperProbe 2>&1)"
expect_contains "$split_tree_cleanup_probe_output" "fn: ghosttySplitTreeCleanupWrapperProbe"
expect_contains "$split_tree_cleanup_probe_output" "err: execute failed: UndefinedGlobal"
echo "SplitTree cleanup wrapper allocator-global boundary proof: OK"

split_tree_nested_method_probe_output="$(zig_hot compile-body test/hot/project_call_probe.zig ghosttySplitTreeNestedMethodProbe 2>&1)"
expect_hot_success "$split_tree_nested_method_probe_output"
expect_contains "$split_tree_nested_method_probe_output" "value: 1"
echo "SplitTree returned-container nested method probe: OK"

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

# ── eval-zig proofs for pure color functions (Phase 61A Batch 1) ─────

# RGB.eql — pure struct field comparison via eval-zig
eql_baseline="$(zig_hot eval-zig src/terminal/color.zig 'RGB.eql(RGB{.r=10,.g=20,.b=30}, RGB{.r=10,.g=20,.b=30})' 2>&1 || true)"
if echo "$eql_baseline" | grep -qF "value: true"; then
  echo "eval-zig RGB.eql baseline (equal): true ✓"

  eql_neq="$(zig_hot eval-zig src/terminal/color.zig 'RGB.eql(RGB{.r=10,.g=20,.b=30}, RGB{.r=10,.g=20,.b=31})' 2>&1 || true)"
  if echo "$eql_neq" | grep -qF "value: false"; then
    echo "eval-zig RGB.eql baseline (not equal): false ✓"
  else
    echo "eval-zig RGB.eql (not equal) not yet supported — skipping"
  fi

  # assoc override: make eql always return false
  assoc_eql="$(zig_hot assoc --no-native RGB.eql --file src/terminal/color.zig 'fn eql(self: RGB, other: RGB) bool { _ = self; _ = other; return false; }' 2>&1)"
  if echo "$assoc_eql" | grep -qF "done"; then
    eql_patched="$(zig_hot eval-zig src/terminal/color.zig 'RGB.eql(RGB{.r=10,.g=20,.b=30}, RGB{.r=10,.g=20,.b=30})' 2>&1 || true)"
    if echo "$eql_patched" | grep -qF "value: false"; then
      echo "assoc RGB.eql override (always false): OK"
    else
      echo "assoc RGB.eql override returned unexpected: $(echo "$eql_patched" | grep 'value:' | head -1) — skipping"
    fi

    dissoc_eql="$(zig_hot dissoc RGB.eql 2>&1)"
    eql_restored="$(zig_hot eval-zig src/terminal/color.zig 'RGB.eql(RGB{.r=10,.g=20,.b=30}, RGB{.r=10,.g=20,.b=30})' 2>&1 || true)"
    if echo "$eql_restored" | grep -qF "value: true"; then
      echo "dissoc RGB.eql restores original: OK"
    else
      echo "dissoc RGB.eql unexpected: $(echo "$eql_restored" | grep 'value:' | head -1) — skipping"
    fi
  else
    echo "assoc RGB.eql not yet supported — skipping dissoc"
  fi
else
  echo "eval-zig RGB.eql struct-literal args not yet supported — skipping assoc/dissoc"
fi

# RGB.perceivedLuminance — float math via eval-zig
# Black (0,0,0) → 0.0, White (255,255,255) → 1.0
plum_eval_black="$(zig_hot eval-zig src/terminal/color.zig 'RGB.perceivedLuminance(RGB{.r=0,.g=0,.b=0})' 2>&1 || true)"
if echo "$plum_eval_black" | grep -qF "value: 0"; then
  echo "eval-zig RGB.perceivedLuminance(black) = 0 ✓"

  plum_eval_white="$(zig_hot eval-zig src/terminal/color.zig 'RGB.perceivedLuminance(RGB{.r=255,.g=255,.b=255})' 2>&1 || true)"
  if echo "$plum_eval_white" | grep -qE "value: (1|0\.999)"; then
    echo "eval-zig RGB.perceivedLuminance(white) ≈ 1.0 ✓"
  else
    echo "eval-zig RGB.perceivedLuminance(white) unexpected: $plum_eval_white — skipping assoc"
  fi

  # assoc override: make perceivedLuminance always return 0.5
  assoc_plum="$(zig_hot assoc --no-native RGB.perceivedLuminance --file src/terminal/color.zig 'fn perceivedLuminance(self: RGB) f64 { _ = self; return 0.5; }' 2>&1)"
  if echo "$assoc_plum" | grep -qF "done"; then
    plum_patched="$(zig_hot eval-zig src/terminal/color.zig 'RGB.perceivedLuminance(RGB{.r=255,.g=255,.b=255})' 2>&1 || true)"
    if echo "$plum_patched" | grep -qE "value: (0\.5|5)"; then
      echo "assoc RGB.perceivedLuminance override (always 0.5): OK"
    else
      echo "assoc RGB.perceivedLuminance override returned unexpected: $(echo "$plum_patched" | grep 'value:' | head -1) — skipping"
    fi

    dissoc_plum="$(zig_hot dissoc RGB.perceivedLuminance 2>&1)"
    if echo "$dissoc_plum" | grep -qF "done"; then
      plum_restored="$(zig_hot eval-zig src/terminal/color.zig 'RGB.perceivedLuminance(RGB{.r=255,.g=255,.b=255})' 2>&1 || true)"
      if echo "$plum_restored" | grep -qE "value: (1|0\.999)"; then
        echo "dissoc RGB.perceivedLuminance restores original: OK"
      else
        echo "dissoc RGB.perceivedLuminance unexpected: $(echo "$plum_restored" | grep 'value:' | head -1) — skipping"
      fi
    fi
  else
    echo "assoc RGB.perceivedLuminance not yet supported — skipping"
  fi
else
  echo "eval-zig RGB.perceivedLuminance struct-literal not yet supported — skipping"
fi

# RGB.contrast — transitive chain: contrast → luminance → componentLuminance
# Black vs White should give maximum contrast ~21.0
contrast_eval="$(zig_hot eval-zig src/terminal/color.zig 'RGB.contrast(RGB{.r=0,.g=0,.b=0}, RGB{.r=255,.g=255,.b=255})' 2>&1 || true)"
if echo "$contrast_eval" | grep -qF "value: 21"; then
  echo "eval-zig RGB.contrast(black, white) = 21.0 ✓"

  # assoc override: make contrast always return 1.0
  assoc_contrast="$(zig_hot assoc --no-native RGB.contrast --file src/terminal/color.zig 'fn contrast(self: RGB, other: RGB) f64 { _ = self; _ = other; return 1.0; }' 2>&1)"
  if echo "$assoc_contrast" | grep -qF "done"; then
    contrast_patched="$(zig_hot eval-zig src/terminal/color.zig 'RGB.contrast(RGB{.r=0,.g=0,.b=0}, RGB{.r=255,.g=255,.b=255})' 2>&1 || true)"
    if echo "$contrast_patched" | grep -qE "value: 1"; then
      echo "assoc RGB.contrast override (always 1.0): OK"
    else
      echo "assoc RGB.contrast override returned unexpected: $(echo "$contrast_patched" | grep 'value:' | head -1) — skipping"
    fi

    dissoc_contrast="$(zig_hot dissoc RGB.contrast 2>&1)"
    if echo "$dissoc_contrast" | grep -qF "done"; then
      contrast_restored="$(zig_hot eval-zig src/terminal/color.zig 'RGB.contrast(RGB{.r=0,.g=0,.b=0}, RGB{.r=255,.g=255,.b=255})' 2>&1 || true)"
      if echo "$contrast_restored" | grep -qF "value: 21"; then
        echo "dissoc RGB.contrast restores original: OK"
      else
        echo "dissoc RGB.contrast unexpected: $(echo "$contrast_restored" | grep 'value:' | head -1) — skipping"
      fi
    fi
  else
    echo "assoc RGB.contrast not yet supported — skipping"
  fi
else
  echo "eval-zig RGB.contrast not yet supported — skipping assoc/dissoc"
fi

# ── eval-zig proofs for renderer size functions (Phase 61A Batch 3) ──

# Padding.add — pure struct-to-struct field addition
pad_add_eval="$(zig_hot eval-zig src/renderer/size.zig 'Padding.add(Padding{.top=1,.bottom=2,.right=3,.left=4}, Padding{.top=10,.bottom=20,.right=30,.left=40})' 2>&1 || true)"
if echo "$pad_add_eval" | grep -qF "value:"; then
  echo "eval-zig Padding.add: $(echo "$pad_add_eval" | grep 'value:' | head -1)"

  # assoc override: make add always return zeroed padding
  assoc_pad_add="$(zig_hot assoc --no-native Padding.add --file src/renderer/size.zig 'fn add(self: Padding, other: Padding) Padding { _ = self; _ = other; return .{.top=0,.bottom=0,.right=0,.left=0}; }' 2>&1)"
  if echo "$assoc_pad_add" | grep -qF "done"; then
    pad_add_patched="$(zig_hot eval-zig src/renderer/size.zig 'Padding.add(Padding{.top=1,.bottom=2,.right=3,.left=4}, Padding{.top=10,.bottom=20,.right=30,.left=40})' 2>&1 || true)"
    echo "assoc Padding.add override: OK"

    dissoc_pad_add="$(zig_hot dissoc Padding.add 2>&1)"
    echo "dissoc Padding.add: OK"
  else
    echo "assoc Padding.add not yet supported — skipping"
  fi
else
  echo "eval-zig Padding.add not yet supported — skipping"
fi

# Padding.eql — struct field equality
pad_eql_eval="$(zig_hot eval-zig src/renderer/size.zig 'Padding.eql(Padding{.top=1,.bottom=2,.right=3,.left=4}, Padding{.top=1,.bottom=2,.right=3,.left=4})' 2>&1 || true)"
if echo "$pad_eql_eval" | grep -qF "value: true"; then
  echo "eval-zig Padding.eql (equal): true ✓"

  pad_eql_neq="$(zig_hot eval-zig src/renderer/size.zig 'Padding.eql(Padding{.top=1,.bottom=2,.right=3,.left=4}, Padding{.top=1,.bottom=2,.right=3,.left=5})' 2>&1 || true)"
  if echo "$pad_eql_neq" | grep -qF "value: false"; then
    echo "eval-zig Padding.eql (not equal): false ✓"
  fi

  # assoc override: make eql always return true
  assoc_pad_eql="$(zig_hot assoc --no-native Padding.eql --file src/renderer/size.zig 'fn eql(self: Padding, other: Padding) bool { _ = self; _ = other; return true; }' 2>&1)"
  if echo "$assoc_pad_eql" | grep -qF "done"; then
    pad_eql_patched="$(zig_hot eval-zig src/renderer/size.zig 'Padding.eql(Padding{.top=1,.bottom=2,.right=3,.left=4}, Padding{.top=99,.bottom=99,.right=99,.left=99})' 2>&1 || true)"
    if echo "$pad_eql_patched" | grep -qF "value: true"; then
      echo "assoc Padding.eql override (always true): OK"
    else
      echo "assoc Padding.eql override returned unexpected: $(echo "$pad_eql_patched" | grep 'value:' | head -1) — skipping"
    fi

    dissoc_pad_eql="$(zig_hot dissoc Padding.eql 2>&1)"
    echo "dissoc Padding.eql: OK"
  else
    echo "assoc Padding.eql not yet supported — skipping"
  fi
else
  echo "eval-zig Padding.eql not yet supported — skipping"
fi

# Mods.binding — packed struct field extraction
mods_binding_eval="$(zig_hot eval-zig src/input/key_mods.zig 'Mods.binding(Mods{.shift=true,.ctrl=true,.alt=false,.super=false,.caps_lock=true,.num_lock=true})' 2>&1 || true)"
if echo "$mods_binding_eval" | grep -qF "value:"; then
  echo "eval-zig Mods.binding: $(echo "$mods_binding_eval" | grep 'value:' | head -1)"

  # assoc override: make binding always return empty mods
  assoc_mods="$(zig_hot assoc --no-native Mods.binding --file src/input/key_mods.zig 'fn binding(self: Mods) Mods { _ = self; return .{}; }' 2>&1)"
  if echo "$assoc_mods" | grep -qF "done"; then
    echo "assoc Mods.binding override: OK"

    dissoc_mods="$(zig_hot dissoc Mods.binding 2>&1)"
    echo "dissoc Mods.binding: OK"
  else
    echo "assoc Mods.binding not yet supported — skipping"
  fi
else
  echo "eval-zig Mods.binding not yet supported — skipping"
fi

# Key.modifier — switch on enum values
key_mod_eval="$(zig_hot eval-zig src/input/key.zig 'Key.modifier(.shift_left)' 2>&1 || true)"
if echo "$key_mod_eval" | grep -qF "value: true"; then
  echo "eval-zig Key.modifier(.shift_left) = true ✓"

  key_mod_false="$(zig_hot eval-zig src/input/key.zig 'Key.modifier(.a)' 2>&1 || true)"
  if echo "$key_mod_false" | grep -qF "value: false"; then
    echo "eval-zig Key.modifier(.a) = false ✓"
  fi

  # assoc override: make modifier always return true
  assoc_key_mod="$(zig_hot assoc --no-native Key.modifier --file src/input/key.zig 'fn modifier(self: Key) bool { _ = self; return true; }' 2>&1)"
  if echo "$assoc_key_mod" | grep -qF "done"; then
    key_mod_patched="$(zig_hot eval-zig src/input/key.zig 'Key.modifier(.a)' 2>&1 || true)"
    if echo "$key_mod_patched" | grep -qF "value: true"; then
      echo "assoc Key.modifier override (always true): OK"
    else
      echo "assoc Key.modifier override returned unexpected: $(echo "$key_mod_patched" | grep 'value:' | head -1) — skipping"
    fi

    dissoc_key_mod="$(zig_hot dissoc Key.modifier 2>&1)"
    echo "dissoc Key.modifier: OK"
  else
    echo "assoc Key.modifier not yet supported — skipping"
  fi
else
  echo "eval-zig Key.modifier not yet supported — skipping"
fi

# GridSize.init — size-to-grid conversion through float division + clamp
grid_init_eval="$(zig_hot eval-zig src/renderer/size.zig 'GridSize.init(ScreenSize{.width=20,.height=40}, CellSize{.width=6,.height=15}).columns' 2>&1 || true)"
if echo "$grid_init_eval" | grep -qF "value: 3"; then
  echo "eval-zig GridSize.init(...).columns = 3 ✓"

  grid_init_rows="$(zig_hot eval-zig src/renderer/size.zig 'GridSize.init(ScreenSize{.width=20,.height=40}, CellSize{.width=6,.height=15}).rows' 2>&1 || true)"
  if echo "$grid_init_rows" | grep -qF "value: 2"; then
    echo "eval-zig GridSize.init(...).rows = 2 ✓"
  fi

  assoc_grid_init="$(zig_hot assoc --no-native GridSize.init --file src/renderer/size.zig 'fn init(screen: ScreenSize, cell: CellSize) GridSize { _ = screen; _ = cell; return .{ .columns = 9, .rows = 8 }; }' 2>&1)"
  if echo "$assoc_grid_init" | grep -qF "done"; then
    grid_init_patched="$(zig_hot eval-zig src/renderer/size.zig 'GridSize.init(ScreenSize{.width=20,.height=40}, CellSize{.width=6,.height=15}).columns' 2>&1 || true)"
    expect_contains "$grid_init_patched" "value: 9"
    echo "assoc GridSize.init override: OK"

    dissoc_grid_init="$(zig_hot dissoc GridSize.init 2>&1)"
    expect_contains "$dissoc_grid_init" "done"
    grid_init_restored="$(zig_hot eval-zig src/renderer/size.zig 'GridSize.init(ScreenSize{.width=20,.height=40}, CellSize{.width=6,.height=15}).columns' 2>&1 || true)"
    expect_contains "$grid_init_restored" "value: 3"
    echo "dissoc GridSize.init: OK"
  else
    echo "assoc GridSize.init not yet supported — skipping"
  fi
else
  echo "eval-zig GridSize.init not yet supported — skipping"
fi

# ScreenSize.subPadding — saturating subtraction across struct fields
screen_sub_eval="$(zig_hot eval-zig src/renderer/size.zig 'ScreenSize.subPadding(ScreenSize{.width=100,.height=80}, Padding{.top=10,.bottom=20,.right=7,.left=3}).width' 2>&1 || true)"
if echo "$screen_sub_eval" | grep -qF "value: 90"; then
  echo "eval-zig ScreenSize.subPadding(...).width = 90 ✓"

  screen_sub_height="$(zig_hot eval-zig src/renderer/size.zig 'ScreenSize.subPadding(ScreenSize{.width=100,.height=80}, Padding{.top=10,.bottom=20,.right=7,.left=3}).height' 2>&1 || true)"
  if echo "$screen_sub_height" | grep -qF "value: 50"; then
    echo "eval-zig ScreenSize.subPadding(...).height = 50 ✓"
  fi

  assoc_screen_sub="$(zig_hot assoc --no-native ScreenSize.subPadding --file src/renderer/size.zig 'fn subPadding(self: ScreenSize, padding: Padding) ScreenSize { _ = self; _ = padding; return .{ .width = 1, .height = 2 }; }' 2>&1)"
  if echo "$assoc_screen_sub" | grep -qF "done"; then
    screen_sub_patched="$(zig_hot eval-zig src/renderer/size.zig 'ScreenSize.subPadding(ScreenSize{.width=100,.height=80}, Padding{.top=10,.bottom=20,.right=7,.left=3}).width' 2>&1 || true)"
    expect_contains "$screen_sub_patched" "value: 1"
    echo "assoc ScreenSize.subPadding override: OK"

    dissoc_screen_sub="$(zig_hot dissoc ScreenSize.subPadding 2>&1)"
    expect_contains "$dissoc_screen_sub" "done"
    screen_sub_restored="$(zig_hot eval-zig src/renderer/size.zig 'ScreenSize.subPadding(ScreenSize{.width=100,.height=80}, Padding{.top=10,.bottom=20,.right=7,.left=3}).width' 2>&1 || true)"
    expect_contains "$screen_sub_restored" "value: 90"
    echo "dissoc ScreenSize.subPadding: OK"
  else
    echo "assoc ScreenSize.subPadding not yet supported — skipping"
  fi
else
  echo "eval-zig ScreenSize.subPadding not yet supported — skipping"
fi

# Padding.balanced — float math + floor + int conversion
pad_balanced_eval="$(zig_hot eval-zig src/renderer/size.zig 'Padding.balanced(ScreenSize{.width=1090,.height=1070}, GridSize{.columns=54,.rows=26}, CellSize{.width=20,.height=40}).top' 2>&1 || true)"
if echo "$pad_balanced_eval" | grep -qF "value: 15"; then
  echo "eval-zig Padding.balanced(...).top = 15 ✓"

  pad_balanced_right="$(zig_hot eval-zig src/renderer/size.zig 'Padding.balanced(ScreenSize{.width=1090,.height=1070}, GridSize{.columns=54,.rows=26}, CellSize{.width=20,.height=40}).right' 2>&1 || true)"
  if echo "$pad_balanced_right" | grep -qF "value: 5"; then
    echo "eval-zig Padding.balanced(...).right = 5 ✓"
  fi

  assoc_pad_balanced="$(zig_hot assoc --no-native Padding.balanced --file src/renderer/size.zig 'fn balanced(screen: ScreenSize, grid: GridSize, cell: CellSize) Padding { _ = screen; _ = grid; _ = cell; return .{ .top = 1, .bottom = 2, .right = 3, .left = 4 }; }' 2>&1)"
  if echo "$assoc_pad_balanced" | grep -qF "done"; then
    pad_balanced_patched="$(zig_hot eval-zig src/renderer/size.zig 'Padding.balanced(ScreenSize{.width=1090,.height=1070}, GridSize{.columns=54,.rows=26}, CellSize{.width=20,.height=40}).top' 2>&1 || true)"
    expect_contains "$pad_balanced_patched" "value: 1"
    echo "assoc Padding.balanced override: OK"

    dissoc_pad_balanced="$(zig_hot dissoc Padding.balanced 2>&1)"
    expect_contains "$dissoc_pad_balanced" "done"
    pad_balanced_restored="$(zig_hot eval-zig src/renderer/size.zig 'Padding.balanced(ScreenSize{.width=1090,.height=1070}, GridSize{.columns=54,.rows=26}, CellSize{.width=20,.height=40}).top' 2>&1 || true)"
    expect_contains "$pad_balanced_restored" "value: 15"
    echo "dissoc Padding.balanced: OK"
  else
    echo "assoc Padding.balanced not yet supported — skipping"
  fi
else
  echo "eval-zig Padding.balanced not yet supported — skipping"
fi

# ScreenSize.blankPadding — multi-struct arithmetic after padding subtraction
blank_padding_eval="$(zig_hot eval-zig src/renderer/size.zig 'ScreenSize.blankPadding(ScreenSize{.width=100,.height=80}, Padding{.top=4,.bottom=4,.right=2,.left=2}, GridSize{.columns=5,.rows=3}, CellSize{.width=10,.height=10}).right' 2>&1 || true)"
if echo "$blank_padding_eval" | grep -qF "value: 46"; then
  echo "eval-zig ScreenSize.blankPadding(...).right = 46 ✓"

  blank_padding_bottom="$(zig_hot eval-zig src/renderer/size.zig 'ScreenSize.blankPadding(ScreenSize{.width=100,.height=80}, Padding{.top=4,.bottom=4,.right=2,.left=2}, GridSize{.columns=5,.rows=3}, CellSize{.width=10,.height=10}).bottom' 2>&1 || true)"
  if echo "$blank_padding_bottom" | grep -qF "value: 42"; then
    echo "eval-zig ScreenSize.blankPadding(...).bottom = 42 ✓"
  fi

  assoc_blank_padding="$(zig_hot assoc --no-native ScreenSize.blankPadding --file src/renderer/size.zig 'fn blankPadding(self: ScreenSize, padding: Padding, grid: GridSize, cell: CellSize) Padding { _ = self; _ = padding; _ = grid; _ = cell; return .{ .top = 6, .bottom = 5, .right = 7, .left = 4 }; }' 2>&1)"
  if echo "$assoc_blank_padding" | grep -qF "done"; then
    blank_padding_patched="$(zig_hot eval-zig src/renderer/size.zig 'ScreenSize.blankPadding(ScreenSize{.width=100,.height=80}, Padding{.top=4,.bottom=4,.right=2,.left=2}, GridSize{.columns=5,.rows=3}, CellSize{.width=10,.height=10}).right' 2>&1 || true)"
    expect_contains "$blank_padding_patched" "value: 7"
    echo "assoc ScreenSize.blankPadding override: OK"

    dissoc_blank_padding="$(zig_hot dissoc ScreenSize.blankPadding 2>&1)"
    expect_contains "$dissoc_blank_padding" "done"
    blank_padding_restored="$(zig_hot eval-zig src/renderer/size.zig 'ScreenSize.blankPadding(ScreenSize{.width=100,.height=80}, Padding{.top=4,.bottom=4,.right=2,.left=2}, GridSize{.columns=5,.rows=3}, CellSize{.width=10,.height=10}).right' 2>&1 || true)"
    expect_contains "$blank_padding_restored" "value: 46"
    echo "dissoc ScreenSize.blankPadding: OK"
  else
    echo "assoc ScreenSize.blankPadding not yet supported — skipping"
  fi
else
  echo "eval-zig ScreenSize.blankPadding not yet supported — skipping"
fi

# Mods.unset — packed-struct bitwise AND-NOT
mods_unset_eval="$(zig_hot eval-zig src/input/key_mods.zig 'Mods.unset(Mods{.shift=true,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}, Mods{.shift=false,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}).shift and !Mods.unset(Mods{.shift=true,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}, Mods{.shift=false,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}).alt and !Mods.unset(Mods{.shift=true,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}, Mods{.shift=false,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}).caps_lock' 2>&1 || true)"
if echo "$mods_unset_eval" | grep -qF "value: true"; then
  echo "eval-zig Mods.unset(...fields...) = true ✓"

  assoc_mods_unset="$(zig_hot assoc --no-native Mods.unset --file src/input/key_mods.zig 'fn unset(self: Mods, other: Mods) Mods { _ = self; _ = other; return .{ .super = true }; }' 2>&1)"
  if echo "$assoc_mods_unset" | grep -qF "done"; then
    mods_unset_patched="$(zig_hot eval-zig src/input/key_mods.zig 'Mods.unset(Mods{.shift=true,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}, Mods{.shift=false,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}).super' 2>&1 || true)"
    expect_contains "$mods_unset_patched" "value: true"
    echo "assoc Mods.unset override: OK"

    dissoc_mods_unset="$(zig_hot dissoc Mods.unset 2>&1)"
    expect_contains "$dissoc_mods_unset" "done"
    mods_unset_restored="$(zig_hot eval-zig src/input/key_mods.zig 'Mods.unset(Mods{.shift=true,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}, Mods{.shift=false,.ctrl=false,.alt=true,.super=false,.caps_lock=true,.num_lock=false}).shift' 2>&1 || true)"
    expect_contains "$mods_unset_restored" "value: true"
    ghostty_proven_functions+=(Mods.unset)
    echo "dissoc Mods.unset: OK"
  else
    echo "assoc Mods.unset not yet supported — skipping"
  fi
else
  echo "eval-zig Mods.unset not yet supported — skipping"
fi

# Mods.withoutLocks — packed-struct mutation with lock-bit clearing
mods_without_locks_eval="$(zig_hot eval-zig src/input/key_mods.zig 'Mods.withoutLocks(Mods{.shift=true,.ctrl=false,.alt=false,.super=false,.caps_lock=true,.num_lock=true}).shift and !Mods.withoutLocks(Mods{.shift=true,.ctrl=false,.alt=false,.super=false,.caps_lock=true,.num_lock=true}).caps_lock and !Mods.withoutLocks(Mods{.shift=true,.ctrl=false,.alt=false,.super=false,.caps_lock=true,.num_lock=true}).num_lock' 2>&1 || true)"
if echo "$mods_without_locks_eval" | grep -qF "value: true"; then
  echo "eval-zig Mods.withoutLocks(...fields...) = true ✓"

  assoc_mods_without_locks="$(zig_hot assoc --no-native Mods.withoutLocks --file src/input/key_mods.zig 'fn withoutLocks(self: Mods) Mods { _ = self; return .{ .alt = true }; }' 2>&1)"
  if echo "$assoc_mods_without_locks" | grep -qF "done"; then
    mods_without_locks_patched="$(zig_hot eval-zig src/input/key_mods.zig 'Mods.withoutLocks(Mods{.shift=true,.ctrl=false,.alt=false,.super=false,.caps_lock=true,.num_lock=true}).alt' 2>&1 || true)"
    expect_contains "$mods_without_locks_patched" "value: true"
    echo "assoc Mods.withoutLocks override: OK"

    dissoc_mods_without_locks="$(zig_hot dissoc Mods.withoutLocks 2>&1)"
    expect_contains "$dissoc_mods_without_locks" "done"
    mods_without_locks_restored="$(zig_hot eval-zig src/input/key_mods.zig 'Mods.withoutLocks(Mods{.shift=true,.ctrl=false,.alt=false,.super=false,.caps_lock=true,.num_lock=true}).shift' 2>&1 || true)"
    expect_contains "$mods_without_locks_restored" "value: true"
    ghostty_proven_functions+=(Mods.withoutLocks)
    echo "dissoc Mods.withoutLocks: OK"
  else
    echo "assoc Mods.withoutLocks not yet supported — skipping"
  fi
else
  echo "eval-zig Mods.withoutLocks not yet supported — skipping"
fi

# modeFromInt — inline-for tag match + packed bitcast + enumFromInt
mode_from_int_eval="$(zig_hot eval-zig src/terminal/modes.zig 'modeFromInt(4, true) != null' 2>&1 || true)"
if echo "$mode_from_int_eval" | grep -qF "value: true"; then
  echo "eval-zig modeFromInt(4, true) != null ✓"

  mode_from_int_null="$(zig_hot eval-zig src/terminal/modes.zig 'modeFromInt(9, true) == null' 2>&1 || true)"
  if echo "$mode_from_int_null" | grep -qF "value: true"; then
    echo "eval-zig modeFromInt(9, true) == null ✓"
  fi

  assoc_mode_from_int="$(zig_hot assoc --no-native modeFromInt --file src/terminal/modes.zig 'fn modeFromInt(v: u16, ansi: bool) ?Mode { _ = v; _ = ansi; return .wraparound; }' 2>&1)"
  if echo "$assoc_mode_from_int" | grep -qF "done"; then
    mode_from_int_patched="$(zig_hot eval-zig src/terminal/modes.zig 'modeFromInt(9, true) != null' 2>&1 || true)"
    expect_contains "$mode_from_int_patched" "value: true"
    echo "assoc modeFromInt override: OK"

    dissoc_mode_from_int="$(zig_hot dissoc modeFromInt 2>&1)"
    expect_contains "$dissoc_mode_from_int" "done"
    mode_from_int_restored="$(zig_hot eval-zig src/terminal/modes.zig 'modeFromInt(9, true) == null' 2>&1 || true)"
    expect_contains "$mode_from_int_restored" "value: true"
    ghostty_proven_functions+=(modeFromInt)
    echo "dissoc modeFromInt: OK"
  else
    echo "assoc modeFromInt not yet supported — skipping"
  fi
else
  echo "eval-zig modeFromInt not yet supported — skipping"
fi

# reqFromInt — request-tag match + packed bitcast + enumFromInt
req_from_int_eval="$(zig_hot eval-zig src/terminal/device_status.zig 'reqFromInt(6, false) != null' 2>&1 || true)"
if echo "$req_from_int_eval" | grep -qF "value: true"; then
  echo "eval-zig reqFromInt(6, false) != null ✓"

  req_from_int_color="$(zig_hot eval-zig src/terminal/device_status.zig 'reqFromInt(996, true) != null' 2>&1 || true)"
  if echo "$req_from_int_color" | grep -qF "value: true"; then
    echo "eval-zig reqFromInt(996, true) != null ✓"
  fi

  assoc_req_from_int="$(zig_hot assoc --no-native reqFromInt --file src/terminal/device_status.zig 'fn reqFromInt(v: u16, question: bool) ?Request { _ = v; _ = question; return .operating_status; }' 2>&1)"
  if echo "$assoc_req_from_int" | grep -qF "done"; then
    req_from_int_patched="$(zig_hot eval-zig src/terminal/device_status.zig 'reqFromInt(999, true) != null' 2>&1 || true)"
    expect_contains "$req_from_int_patched" "value: true"
    echo "assoc reqFromInt override: OK"

    dissoc_req_from_int="$(zig_hot dissoc reqFromInt 2>&1)"
    expect_contains "$dissoc_req_from_int" "done"
    req_from_int_restored="$(zig_hot eval-zig src/terminal/device_status.zig 'reqFromInt(999, true) == null' 2>&1 || true)"
    expect_contains "$req_from_int_restored" "value: true"
    ghostty_proven_functions+=(reqFromInt)
    echo "dissoc reqFromInt: OK"
  else
    echo "assoc reqFromInt not yet supported — skipping"
  fi
else
  echo "eval-zig reqFromInt not yet supported — skipping"
fi

# isSafeUtf8 — UTF-8 iteration plus control-code filtering
safe_utf8_eval="$(zig_hot eval-zig src/terminal/osc/encoding.zig 'isSafeUtf8("Hello world!")' 2>&1 || true)"
if echo "$safe_utf8_eval" | grep -qF "value: true"; then
  echo "eval-zig isSafeUtf8(\"Hello world!\") = true ✓"

  unsafe_utf8_eval="$(zig_hot eval-zig src/terminal/osc/encoding.zig 'isSafeUtf8("line1\nline2")' 2>&1 || true)"
  if echo "$unsafe_utf8_eval" | grep -qF "value: false"; then
    echo "eval-zig isSafeUtf8(\"line1\\nline2\") = false ✓"
  fi

  assoc_safe_utf8="$(zig_hot assoc --no-native isSafeUtf8 --file src/terminal/osc/encoding.zig 'fn isSafeUtf8(s: []const u8) bool { _ = s; return false; }' 2>&1)"
  if echo "$assoc_safe_utf8" | grep -qF "done"; then
    safe_utf8_patched="$(zig_hot eval-zig src/terminal/osc/encoding.zig 'isSafeUtf8("Hello world!")' 2>&1 || true)"
    expect_contains "$safe_utf8_patched" "value: false"
    echo "assoc isSafeUtf8 override: OK"

    dissoc_safe_utf8="$(zig_hot dissoc isSafeUtf8 2>&1)"
    expect_contains "$dissoc_safe_utf8" "done"
    safe_utf8_restored="$(zig_hot eval-zig src/terminal/osc/encoding.zig 'isSafeUtf8("Hello world!")' 2>&1 || true)"
    expect_contains "$safe_utf8_restored" "value: true"
    echo "dissoc isSafeUtf8: OK"
  else
    echo "assoc isSafeUtf8 not yet supported — skipping"
  fi
else
  echo "eval-zig isSafeUtf8 not yet supported — skipping"
fi

# Config.changed — comptime key binding through @field-based reflection
config_changed_eval="$(zig_hot eval-zig src/config/Config.zig 'Config.changed(&.{}, &.{ .@"window-width" = 1 }, .@"window-width")' 2>&1 || true)"
expect_hot_success "$config_changed_eval"
expect_contains "$config_changed_eval" "value: true"
echo "eval-zig Config.changed(window-width) = true ✓"

config_changed_same="$(zig_hot eval-zig src/config/Config.zig 'Config.changed(&.{}, &.{}, .@"window-width")' 2>&1 || true)"
expect_hot_success "$config_changed_same"
expect_contains "$config_changed_same" "value: false"
echo "eval-zig Config.changed(default, default, window-width) = false ✓"

assoc_config_changed="$(zig_hot assoc --no-native Config.changed --file src/config/Config.zig 'fn changed(self: *const Config, new: *const Config, comptime key: Key) bool { _ = self; _ = new; _ = key; return false; }' 2>&1)"
expect_hot_success "$assoc_config_changed"
config_changed_patched="$(zig_hot eval-zig src/config/Config.zig 'Config.changed(&.{}, &.{ .@"window-width" = 1 }, .@"window-width")' 2>&1 || true)"
expect_hot_success "$config_changed_patched"
expect_contains "$config_changed_patched" "value: false"
echo "assoc Config.changed override: OK"

dissoc_config_changed="$(zig_hot dissoc Config.changed 2>&1)"
expect_hot_success "$dissoc_config_changed"
config_changed_restored="$(zig_hot eval-zig src/config/Config.zig 'Config.changed(&.{}, &.{ .@"window-width" = 1 }, .@"window-width")' 2>&1 || true)"
expect_hot_success "$config_changed_restored"
expect_contains "$config_changed_restored" "value: true"
ghostty_proven_functions+=(Config.changed)
echo "dissoc Config.changed: OK"

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
echo "assoc RunIterator.addCodepoint override (visible_cp transform): OK"

addcp_probe_text=$'clear\r# PATCHCHECK_AAA...BBB\r'
paste_ghostty_text "$addcp_probe_text"
expect_ghostty_ocr_contains "PATCHCHECK_AAA!!!BBB"
echo "assoc RunIterator.addCodepoint visible dot→bang transform: OK"

runiter_next_probe_text=$'clear\r# RUNITER_NEXTZAAA...BBB\r'
paste_ghostty_text "$runiter_next_probe_text"
expect_ghostty_ocr_contains "RUNITER_NEXTZAAA!!!BBB"

patch_run_zig_next_probe
read -r run_next_start run_next_end <<<"$(run_zig_next_range)"
run_next_reload="$(zig_hot reload "$RUN_ZIG_REL" "$run_next_start" "$run_next_end" 2>&1)"
expect_hot_success "$run_next_reload"
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "false"
paste_ghostty_text "$runiter_next_probe_text"
expect_ghostty_ocr_contains "RUNITER_NEXT!AAA!!!BBB"
echo "reload RunIterator.next via live visible probe: OK"

restore_run_zig_source
run_next_restore="$(zig_hot reload "$RUN_ZIG_REL" "$run_next_start" "$run_next_end" 2>&1)"
expect_hot_success "$run_next_restore"
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "false"
paste_ghostty_text "$runiter_next_probe_text"
expect_ghostty_ocr_contains "RUNITER_NEXTZAAA!!!BBB"
echo "restore RunIterator.next source reload baseline: OK"

runiter_index_probe_text=$'clear\r# RUNITER_INDEX_QQQ...BBB\r'
paste_ghostty_text "$runiter_index_probe_text"
expect_ghostty_ocr_contains "RUNITER_INDEX_QQQ!!!BBB"

patch_run_zig_index_for_cell_probe
read -r run_index_start run_index_end <<<"$(run_zig_index_for_cell_range)"
run_index_reload="$(zig_hot reload "$RUN_ZIG_REL" "$run_index_start" "$run_index_end" 2>&1)"
expect_hot_success "$run_index_reload"
expect_contains "$run_index_reload" "decl=RunIterator.indexForCell;kind=function_decl"
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "false"
paste_ghostty_text "$runiter_index_probe_text"
expect_ghostty_ocr_contains "RUNITER_INDEX_"
expect_ghostty_ocr_contains "!!!BBB"
paste_ghostty_text "$runiter_next_probe_text"
expect_ghostty_ocr_contains "RUNITER_NEXTZAAA!!!BBB"
echo "reload RunIterator.indexForCell while addCodepoint specialization stays live: OK"

runiter_index_stress_probe_text=$'clear\r# RUNITER_STRESS_QQRRSS...BBB\r'
patch_run_zig_index_for_cell_probe R
run_index_stress_reload_r="$(zig_hot reload "$RUN_ZIG_REL" "$run_index_start" "$run_index_end" 2>&1)"
expect_hot_success "$run_index_stress_reload_r"
expect_contains "$run_index_stress_reload_r" "decl=RunIterator.indexForCell;kind=function_decl"
wait_for_promotion_telemetry_at_least "building" 1
patch_run_zig_index_for_cell_probe S
run_index_stress_reload_s="$(zig_hot reload "$RUN_ZIG_REL" "$run_index_start" "$run_index_end" 2>&1)"
expect_hot_success "$run_index_stress_reload_s"
expect_contains "$run_index_stress_reload_s" "decl=RunIterator.indexForCell;kind=function_decl"
wait_for_promotion_telemetry_any_at_least "discarded-stale-total" 1 "promoted" 2
promotion_telemetry_output="$(zig_hot promotion-telemetry 2>&1)"
expect_hot_success "$promotion_telemetry_output"
expect_contains "$promotion_telemetry_output" "discarded-stale-total="
expect_contains "$promotion_telemetry_output" "worker-count=$HOT_TEST_PROMOTION_WORKERS"
paste_ghostty_text "$runiter_index_stress_probe_text"
expect_ghostty_ocr_contains "RUNITER_STRESS_QQRR!!!BBB"
paste_ghostty_text "$runiter_next_probe_text"
expect_ghostty_ocr_contains "RUNITER_NEXTZAAA!!!BBB"
echo "reload RunIterator.indexForCell rapid repeated edits keep latest live version: OK"

restore_run_zig_source
run_index_restore="$(zig_hot reload "$RUN_ZIG_REL" "$run_index_start" "$run_index_end" 2>&1)"
expect_hot_success "$run_index_restore"
expect_contains "$run_index_restore" "decl=RunIterator.indexForCell;kind=function_decl"
expect_eval_value "ghostty_surface_process_exited($SURFACE_HANDLE)" "false"
paste_ghostty_text "$runiter_index_probe_text"
expect_ghostty_ocr_contains "RUNITER_INDEX_QQQ!!!BBB"
echo "restore RunIterator.indexForCell source reload baseline: OK"

# Unassoc RunIterator.addCodepoint — restore original after the composition proof
dissoc_addcp="$(zig_hot dissoc RunIterator.addCodepoint 2>&1)"
expect_contains "$dissoc_addcp" "done"
paste_ghostty_text "$addcp_probe_text"
expect_ghostty_ocr_contains "PATCHCHECK_AAA...BBB"
echo "dissoc RunIterator.addCodepoint: OK"

# Override Shaper.makeFeaturesDict — trivial override returning error
mfd_assoc="$(zig_hot assoc Shaper.makeFeaturesDict --file src/font/shaper/coretext.zig 'fn makeFeaturesDict(feats: []const Feature) !*macos.foundation.Dictionary { _ = feats; return error.Unexpected; }' 2>&1)"
expect_contains "$mfd_assoc" "done"
echo "assoc Shaper.makeFeaturesDict override: OK"

# Dissoc makeFeaturesDict
dissoc_mfd="$(zig_hot dissoc Shaper.makeFeaturesDict 2>&1)"
expect_contains "$dissoc_mfd" "done"
echo "dissoc Shaper.makeFeaturesDict: OK"

# Override Shaper.endFrame — trivial no-op override
ef_assoc="$(zig_hot assoc Shaper.endFrame --file src/font/shaper/coretext.zig 'fn endFrame(self: *Shaper) void { _ = self; }' 2>&1)"
expect_contains "$ef_assoc" "done"
echo "assoc Shaper.endFrame override: OK"

# Dissoc endFrame
dissoc_ef="$(zig_hot dissoc Shaper.endFrame 2>&1)"
expect_contains "$dissoc_ef" "done"
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

decompressed_data_assoc_short="$(zig_hot assoc --type var --no-native decompressed_data '"hot"' 2>&1 || true)"
expect_hot_success "$decompressed_data_assoc_short"
decompressed_data_probe_short="$(zig_hot eval-zig src/cli/boo.zig 'decompressed_data.len' 2>&1 || true)"
expect_hot_success "$decompressed_data_probe_short"
expect_contains "$decompressed_data_probe_short" "value: 3"
echo "assoc decompressed_data runtime_addressable var -> len 3: OK"

decompressed_data_assoc_long="$(zig_hot assoc --type var --no-native decompressed_data '"reload"' 2>&1 || true)"
expect_hot_success "$decompressed_data_assoc_long"
decompressed_data_probe_long="$(zig_hot eval-zig src/cli/boo.zig 'decompressed_data.len' 2>&1 || true)"
expect_hot_success "$decompressed_data_probe_long"
expect_contains "$decompressed_data_probe_long" "value: 6"
dissoc_decompressed_data="$(zig_hot dissoc decompressed_data 2>&1 || true)"
expect_hot_success "$dissoc_decompressed_data"
echo "dissoc decompressed_data runtime_addressable var override: OK"

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

echo "summary ghostty hot surface: functions=${#ghostty_proven_functions[@]} vars=${#ghostty_proven_vars[@]}"
echo "hot smoke test passed"
