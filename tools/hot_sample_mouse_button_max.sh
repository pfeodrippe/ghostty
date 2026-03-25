#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

offset="${1:-0}"
if [[ ! "$offset" =~ ^[0-9]+$ ]]; then
  echo "usage: $(basename "$0") [non-negative-offset]" >&2
  exit 2
fi

response="$(hot_sample_eval_in_file "src/input/mouse.zig" "Button.max + @as(usize, $offset)")"
value="$(printf '%s\n' "$response" | hot_sample_json_get value)"

printf 'mouse.Button.max + %s = %s\n' "$offset" "$value"
