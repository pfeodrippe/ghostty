#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

extension="${1:-.png}"
expected_tag="${2:-png}"

if [[ ! "$expected_tag" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "expected enum tag must be a Zig identifier, got: $expected_tag" >&2
  exit 2
fi

code="$(python3 -c 'import json,sys; ext=sys.argv[1]; tag=sys.argv[2]; print(f"FileType.guessFromExtension({json.dumps(ext)}) == .{tag}")' "$extension" "$expected_tag")"
response="$(hot_sample_eval_in_file "src/file_type.zig" "$code")"
value="$(printf '%s\n' "$response" | hot_sample_json_get value)"

printf 'FileType.guessFromExtension(%s) == .%s -> %s\n' "$extension" "$expected_tag" "$value"
