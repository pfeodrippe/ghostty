#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <cache-dir> <max-gib> [label]" >&2
  exit 1
fi

CACHE_DIR="$1"
MAX_GIB="$2"
LABEL="${3:-$CACHE_DIR}"

if [[ ! "$MAX_GIB" =~ ^[0-9]+$ ]]; then
  echo "error: max-gib must be an integer, got: $MAX_GIB" >&2
  exit 1
fi

[[ -d "$CACHE_DIR" ]] || exit 0

size_kib() {
  du -sk "$1" 2>/dev/null | awk '{ print $1 }'
}

candidate_entries() {
  local path base
  while IFS= read -r path; do
    base="$(basename "$path")"
    if [[ -d "$path" && "$base" =~ ^[[:alnum:]_+-]{1,2}$ ]]; then
      find "$path" -mindepth 1 -maxdepth 1 -print
    else
      printf '%s\n' "$path"
    fi
  done < <(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -print | sort)
}

oldest_entry() {
  candidate_entries \
    | while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf '%s %s\n' "$(stat -f '%m' "$path")" "$path"
      done \
    | sort -n \
    | head -n 1 \
    | cut -d' ' -f2-
}

max_kib=$((MAX_GIB * 1024 * 1024))
current_kib="$(size_kib "$CACHE_DIR")"

if (( current_kib <= max_kib )); then
  exit 0
fi

printf 'trim\t%s\t%uGiB -> %uGiB\n' \
  "$LABEL" \
  $((current_kib / 1024 / 1024)) \
  "$MAX_GIB"

while (( current_kib > max_kib )); do
  path="$(oldest_entry)"
  [[ -n "$path" ]] || break
  printf 'clean\t%s\n' "$path"
  rm -rf "$path"
  current_kib="$(size_kib "$CACHE_DIR")"
done
