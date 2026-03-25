#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

target="src/math.zig"
active_expr='math.__hot_sample_math_overlay_active()'
factor_expr='math.__hot_sample_math_overlay_factor()'
right_expr='math.__hot_sample_math_overlay_right()'
top_expr='math.__hot_sample_math_overlay_top()'

mode="toggle"
if [[ $# -gt 0 ]]; then
  case "$1" in
    toggle|on|off|status)
      mode="$1"
      shift
      ;;
  esac
fi

factor="${1:-4}"
right="${2:-800}"
top="${3:-600}"

if [[ ! "$factor" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $(basename "$0") [positive-scale-numerator] [right>0] [top>0]" >&2
  exit 2
fi
if [[ ! "$right" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ ! "$top" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "usage: $(basename "$0") [positive-scale-numerator] [right>0] [top>0]" >&2
  exit 2
fi

tmpdir="$(mktemp -d)"
overlay="$tmpdir/math_overlay.zig"
trap 'rm -rf "$tmpdir"' EXIT

active="false"
if active_value="$(hot_sample_try_probe_value "$active_expr")"; then
  active="$active_value"
fi

if [[ "$mode" == "toggle" ]]; then
  if [[ "$active" == "true" ]]; then
    mode="off"
  else
    mode="on"
  fi
fi

if [[ "$mode" == "status" ]]; then
  if [[ "$active" == "true" ]]; then
    factor="$(hot_sample_probe_text "$factor_expr")"
    right="$(hot_sample_probe_text "$right_expr")"
    top="$(hot_sample_probe_text "$top_expr")"
    code="$(python3 -c 'import sys; right=sys.argv[1]; top=sys.argv[2]; print(f"const m = ortho2d(0, {right}, 0, {top}); m[0][0]")' "$right" "$top")"
    value="$(hot_sample_eval_in_file "$target" "$code" | hot_sample_json_get value)"
    printf 'ACTIVE %s factor=%s right=%s top=%s value=%s generation=%s\n' \
      "$target" \
      "$factor" \
      "$right" \
      "$top" \
      "$value" \
      "$(hot_sample_current_generation)"
  else
    printf 'INACTIVE %s\n' "$target"
  fi
  exit 0
fi

if [[ "$mode" == "off" ]]; then
  if [[ "$active" != "true" ]]; then
    printf 'Already inactive %s\n' "$target"
    exit 0
  fi

  base_generation="$(hot_sample_current_generation)"
  hot_sample_restore_file "$target"
  revert_generation="$(hot_sample_current_generation)"
  printf 'Deactivated math overlay on %s (generation %s -> %s).\n' \
    "$target" \
    "$base_generation" \
    "$revert_generation"
  exit 0
fi

if [[ "$active" == "true" ]]; then
  printf 'Already active %s factor=%s right=%s top=%s generation=%s\n' \
    "$target" \
    "$(hot_sample_probe_text "$factor_expr")" \
    "$(hot_sample_probe_text "$right_expr")" \
    "$(hot_sample_probe_text "$top_expr")" \
    "$(hot_sample_current_generation)"
  exit 0
fi

python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$overlay" "$factor" "$right" "$top" <<'PY'
from pathlib import Path
import json
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
factor = sys.argv[3]
right = sys.argv[4]
top = sys.argv[5]
needle = '.{ 2 / w, 0, 0, 0 },'
replacement = f'.{{ {factor} / w, 0, 0, 0 }},'
count = src.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 ortho2d x-scale row, found {count}")
marker = f'''

pub fn __hot_sample_math_overlay_active() bool {{
    return true;
}}

pub fn __hot_sample_math_overlay_factor() []const u8 {{
    return {json.dumps(factor)};
}}

pub fn __hot_sample_math_overlay_right() []const u8 {{
    return {json.dumps(right)};
}}

pub fn __hot_sample_math_overlay_top() []const u8 {{
    return {json.dumps(top)};
}}
'''
overlay.write_text(src.replace(needle, replacement, 1).rstrip() + marker)
PY

base_generation="$(hot_sample_current_generation)"
hot_sample_load_file "$target" "$overlay"
overlay_generation="$(hot_sample_current_generation)"

code="$(python3 -c 'import sys; right=sys.argv[1]; top=sys.argv[2]; print(f"const m = ortho2d(0, {right}, 0, {top}); m[0][0]")' "$right" "$top")"
value="$(hot_sample_eval_in_file "$target" "$code" | hot_sample_json_get value)"

printf 'Activated math overlay on %s: factor=%s changed ortho2d(0, %s, 0, %s)[0][0] to %s (generation %s -> %s).\n' \
  "$target" \
  "$factor" \
  "$right" \
  "$top" \
  "$value" \
  "$base_generation" \
  "$overlay_generation"
printf 'Run `%s status` to inspect or `%s off` to restore the real file.\n' \
  "$(basename "$0")" \
  "$(basename "$0")"
