#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

status_of() {
  printf '%s\n' "$1" | hot_sample_json_get status
}

string_field() {
  local response="$1"
  local key="$2"
  printf '%s\n' "$response" | hot_sample_json_get "$key"
}

int_field() {
  local response="$1"
  local key="$2"
  printf '%s\n' "$response" | hot_sample_json_get "$key"
}

is_native_impl_kind() {
  local kind="$1"
  [[ "$kind" == "baseline_native" || "$kind" == "promoted_native" ]]
}

dispatch_entry_info() {
  local symbol="$1"
  hot_sample_hotreq --session root --op dispatch-entry-info --field "symbol=$symbol"
}

eval_in_target_value() {
  local code="$1"
  hot_sample_eval_in_file "$target" "$code" | hot_sample_json_get value
}

make_declaration_overlay() {
  local overlay_path="$1"
  python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$overlay_path" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
start_needle = 'pub const Dir = struct {'
start = src.find(start_needle)
if start == -1:
    raise SystemExit("could not find Dir declaration")

brace_index = src.find('{', start)
if brace_index == -1:
    raise SystemExit("could not find Dir opening brace")

depth = 0
end = None
for i in range(brace_index, len(src)):
    c = src[i]
    if c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            if i + 1 >= len(src) or src[i + 1] != ';':
                raise SystemExit("Dir declaration did not end with '};'")
            end = i + 2
            break
if end is None:
    raise SystemExit("could not find Dir declaration end")

decl = src[start:end]
needle = '''    pub fn iterator(self: *const Dir) !ReportIterator {
        var dir = std.fs.openDirAbsolute(
            self.path,
            .{ .iterate = true },
        ) catch return .{};
        errdefer dir.close();

        return .{
            .dir = dir,
            .it = dir.iterate(),
        };
    }
'''
replacement = '''    pub fn iterator(self: *const Dir) !ReportIterator {
        _ = self;
        return error.Unexpected;
    }
'''
count = decl.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 Dir.iterator body in declaration, found {count}")
overlay.write_text(decl.replace(needle, replacement, 1))
PY
}

bash "$script_dir/test_hot_live_window_health.sh" >/dev/null || fail "live Ghostty window is not healthy before declaration direct-dispatch test"

target="src/crash/dir.zig"
symbol="crash.dir.Dir.iterator"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
  hot_sample_hotreq --session root --op load-file --path "$target" --file-path "$HOT_SAMPLE_REPO_ROOT/$target" >/dev/null 2>&1 || true
}
trap cleanup EXIT

overlay="$tmpdir/dir_iterator_decl_overlay.zig"
make_declaration_overlay "$overlay"

generation_before="$(hot_sample_current_generation)"
before_info="$(dispatch_entry_info "$symbol")" || fail "dispatch-entry-info failed before activation"
[[ "$(status_of "$before_info")" == "[\"done\"]" ]] || fail "unexpected dispatch-entry-info status before activation"
before_impl_id="$(int_field "$before_info" active-impl-id)"
before_dispatch_index="$(int_field "$before_info" dispatch-index)"
before_abi_id="$(int_field "$before_info" abi-signature-id)"
before_type_version="$(int_field "$before_info" type-identity-version)"
before_impl_kind="$(string_field "$before_info" impl-kind)"
is_native_impl_kind "$before_impl_kind" || fail "unexpected impl-kind before activation: $before_impl_kind"

dispatch_response="$(
  hot_sample_hotreq \
    --session root \
    --op eval \
    --scope global \
    --path "$target" \
    --field activation=dispatch \
    --code - < "$overlay"
)" || fail "direct-dispatch declaration eval failed"

[[ "$(status_of "$dispatch_response")" == "[\"done\"]" ]] || fail "unexpected declaration direct-dispatch status"
[[ "$(string_field "$dispatch_response" activation-kind)" == "dispatch" ]] || fail "activation-kind was not dispatch"
[[ "$(int_field "$dispatch_response" generation)" == "$generation_before" ]] || fail "direct-dispatch declaration eval unexpectedly changed generation in response"

generation_after="$(hot_sample_current_generation)"
[[ "$generation_after" == "$generation_before" ]] || fail "direct-dispatch declaration eval changed current generation: before=$generation_before after=$generation_after"

after_info="$(dispatch_entry_info "$symbol")" || fail "dispatch-entry-info failed after activation"
[[ "$(status_of "$after_info")" == "[\"done\"]" ]] || fail "unexpected dispatch-entry-info status after activation"
after_impl_id="$(int_field "$after_info" active-impl-id)"
after_dispatch_index="$(int_field "$after_info" dispatch-index)"
after_abi_id="$(int_field "$after_info" abi-signature-id)"
after_type_version="$(int_field "$after_info" type-identity-version)"
after_generation="$(int_field "$after_info" generation)"
after_impl_kind="$(string_field "$after_info" impl-kind)"

[[ "$after_impl_kind" == "interpreted" ]] || fail "impl-kind after activation was $after_impl_kind"
[[ "$after_impl_id" != "$before_impl_id" ]] || fail "active impl id did not change under declaration direct dispatch"
[[ "$after_dispatch_index" == "$before_dispatch_index" ]] || fail "dispatch index changed unexpectedly"
[[ "$after_abi_id" == "$before_abi_id" ]] || fail "abi signature id changed unexpectedly"
[[ "$after_type_version" == "$before_type_version" ]] || fail "type identity version changed unexpectedly"
[[ "$after_generation" == "$generation_before" ]] || fail "dispatch entry generation changed unexpectedly"

restore_before="$generation_after"
hot_sample_hotreq --session root --op load-file --path "$target" --file-path "$HOT_SAMPLE_REPO_ROOT/$target" >/dev/null || fail "failed to restore $target after declaration direct-dispatch activation"
restore_after="$(hot_sample_current_generation_retry)"
[[ "$restore_after" =~ ^[0-9]+$ ]] || fail "restore generation was not numeric"
if (( restore_after <= restore_before )); then
  fail "restoring original file did not publish a new generation: before=$restore_before after=$restore_after"
fi

restored_info="$(dispatch_entry_info "$symbol")" || fail "dispatch-entry-info failed after restore"
[[ "$(status_of "$restored_info")" == "[\"done\"]" ]] || fail "unexpected dispatch-entry-info status after restore"
restored_impl_kind="$(string_field "$restored_info" impl-kind)"
restored_dispatch_index="$(int_field "$restored_info" dispatch-index)"
restored_abi_id="$(int_field "$restored_info" abi-signature-id)"
restored_type_version="$(int_field "$restored_info" type-identity-version)"
is_native_impl_kind "$restored_impl_kind" || fail "impl-kind after restore was $restored_impl_kind"
[[ "$restored_dispatch_index" == "$before_dispatch_index" ]] || fail "dispatch index changed unexpectedly after restore"
[[ "$restored_abi_id" == "$before_abi_id" ]] || fail "abi signature id changed unexpectedly after restore"
[[ "$restored_type_version" == "$before_type_version" ]] || fail "type identity version changed unexpectedly after restore"

bash "$script_dir/test_hot_live_window_health.sh" >/dev/null || fail "live Ghostty window is not healthy after declaration direct-dispatch test"
trap - EXIT
rm -rf "$tmpdir"

printf 'PASS live direct-dispatch declaration eval swapped %s without generation churn (symbol=%s impl=%s->%s->%s generation=%s restored_generation=%s)\n' \
  "$target" \
  "$symbol" \
  "$before_impl_kind" \
  "$after_impl_kind" \
  "$restored_impl_kind" \
  "$generation_after" \
  "$restore_after"
