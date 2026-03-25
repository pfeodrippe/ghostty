#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

right="${1:-800}"
top="${2:-600}"

if [[ ! "$right" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ ! "$top" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "usage: $(basename "$0") [right>0] [top>0]" >&2
  exit 2
fi

code="$(python3 -c 'import sys; right=sys.argv[1]; top=sys.argv[2]; print(f"const m = ortho2d(0, {right}, 0, {top}); m[0][0]")' "$right" "$top")"
response="$(hot_sample_eval_in_file "src/math.zig" "$code")"
value="$(printf '%s\n' "$response" | hot_sample_json_get value)"

printf 'ortho2d(0, %s, 0, %s)[0][0] = %s\n' "$right" "$top" "$value"
