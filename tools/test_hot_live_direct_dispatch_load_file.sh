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

make_overlay() {
  local overlay_path="$1"
  python3 - "$HOT_SAMPLE_REPO_ROOT/$target" "$overlay_path" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
overlay = Path(sys.argv[2])
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
        return .{};
    }
'''
count = src.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 Dir.iterator body, found {count}")
overlay.write_text(src.replace(needle, replacement, 1))
PY
}

bash "$script_dir/test_hot_live_window_health.sh" >/dev/null || fail "live Ghostty window is not healthy before direct dispatch test"

target="src/crash/dir.zig"
symbol="crash.dir.Dir.iterator"
installed_manifest="$HOT_SAMPLE_REPO_ROOT/zig-out/share/ghostty/GhosttyKit.hot.json"

[[ -f "$installed_manifest" ]] || fail "installed hot manifest is missing: $installed_manifest"

manifest_compile_module_probe="$(
  python3 - "$installed_manifest" <<'PY'
import json
import os
from pathlib import Path, PurePosixPath
import sys

manifest_path = Path(sys.argv[1])
with manifest_path.open("r", encoding="utf-8") as fh:
    manifest = json.load(fh)

manifest_dir = manifest_path.parent
cache_backed_count = 0
escaping_relative_count = 0
missing_relative_count = 0
support_roots = set()
for module in manifest.get("compile_modules", ()):
    path = module.get("root_source_path", "")
    if any(marker in path for marker in (
        "/.zig-cache/",
        "/.zig-cache-hot/",
        "/.zig-global-cache/",
        "/.zig-global-cache-hot/",
    )):
        cache_backed_count += 1
    if not path or os.path.isabs(path):
        continue

    parts = PurePosixPath(path).parts
    if ".." in parts:
        escaping_relative_count += 1

    resolved = manifest_dir.joinpath(*parts)
    if not resolved.is_file():
        missing_relative_count += 1
    if parts:
        support_roots.add(str(manifest_dir / parts[0]))

print(
    cache_backed_count,
    escaping_relative_count,
    missing_relative_count,
    ";".join(sorted(support_roots)),
    sep="\t",
)
PY
)"
IFS=$'\t' read -r installed_manifest_cache_backed_count installed_manifest_escaping_relative_count installed_manifest_missing_relative_count installed_manifest_support_roots <<<"$manifest_compile_module_probe"
[[ "$installed_manifest_cache_backed_count" == "0" ]] || fail "installed hot manifest still contains cache-backed compile module roots"
[[ "$installed_manifest_escaping_relative_count" == "0" ]] || fail "installed hot manifest contains escaping relative compile module roots"
[[ "$installed_manifest_missing_relative_count" == "0" ]] || fail "installed hot manifest contains unresolved relative compile module roots"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
  hot_sample_hotreq --session root --op load-file --path "$target" --file-path "$HOT_SAMPLE_REPO_ROOT/$target" >/dev/null 2>&1 || true
}
trap cleanup EXIT

overlay="$tmpdir/renderer_size_dispatch_overlay.zig"
make_overlay "$overlay"

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
    --op load-file \
    --path "$target" \
    --file-path "$overlay" \
    --field activation=dispatch
)" || fail "direct dispatch load-file failed"

[[ "$(status_of "$dispatch_response")" == "[\"done\"]" ]] || fail "unexpected direct dispatch status"
[[ "$(string_field "$dispatch_response" activation-kind)" == "dispatch" ]] || fail "activation-kind was not dispatch"
[[ "$(int_field "$dispatch_response" generation)" == "$generation_before" ]] || fail "direct dispatch unexpectedly changed generation in response"
candidate_compile_skipped="$(string_field "$dispatch_response" candidate-compile-skipped)"
selection_kind="$(string_field "$dispatch_response" selection-kind)"
selection_changed_wrapper_fqns="$(int_field "$dispatch_response" selection-changed-wrapper-fqns)"
selection_changed_top_level_decls="$(int_field "$dispatch_response" selection-changed-top-level-decls)"
compile_root_deps_total="$(int_field "$dispatch_response" compile-root-deps-total)"
compile_root_deps_used="$(int_field "$dispatch_response" compile-root-deps-used)"
compile_modules_total="$(int_field "$dispatch_response" compile-modules-total)"
compile_modules_used="$(int_field "$dispatch_response" compile-modules-used)"
[[ "$candidate_compile_skipped" == "true" ]] || fail "candidate compile was not skipped"
[[ "$selection_kind" == "graph_manifest_body_hash" ]] || fail "direct dispatch selection fell back to $selection_kind"
[[ "$selection_changed_wrapper_fqns" -ge 1 ]] || fail "graph selection did not report any changed wrapper fqn"
[[ "$selection_changed_top_level_decls" -ge 1 ]] || fail "graph selection did not report any changed top-level decl"
[[ "$compile_root_deps_used" -le "$compile_root_deps_total" ]] || fail "root dep usage exceeded total"
[[ "$compile_modules_used" -le "$compile_modules_total" ]] || fail "module usage exceeded total"
[[ "$compile_root_deps_used" == "0" ]] || fail "direct dispatch still compiled root deps unexpectedly: $compile_root_deps_used/$compile_root_deps_total"
[[ "$compile_modules_used" == "0" ]] || fail "direct dispatch still compiled modules unexpectedly: $compile_modules_used/$compile_modules_total"

generation_after="$(hot_sample_current_generation)"
[[ "$generation_after" == "$generation_before" ]] || fail "direct dispatch changed current generation: before=$generation_before after=$generation_after"

after_info="$(dispatch_entry_info "$symbol")" || fail "dispatch-entry-info failed after activation"
[[ "$(status_of "$after_info")" == "[\"done\"]" ]] || fail "unexpected dispatch-entry-info status after activation"
after_impl_id="$(int_field "$after_info" active-impl-id)"
after_dispatch_index="$(int_field "$after_info" dispatch-index)"
after_abi_id="$(int_field "$after_info" abi-signature-id)"
after_type_version="$(int_field "$after_info" type-identity-version)"
after_generation="$(int_field "$after_info" generation)"
after_impl_kind="$(string_field "$after_info" impl-kind)"

[[ "$after_impl_kind" == "interpreted" ]] || fail "impl-kind after activation was $after_impl_kind"
[[ "$after_impl_id" != "$before_impl_id" ]] || fail "active impl id did not change under direct dispatch"
[[ "$after_dispatch_index" == "$before_dispatch_index" ]] || fail "dispatch index changed unexpectedly"
[[ "$after_abi_id" == "$before_abi_id" ]] || fail "abi signature id changed unexpectedly"
[[ "$after_type_version" == "$before_type_version" ]] || fail "type identity version changed unexpectedly"
[[ "$after_generation" == "$generation_before" ]] || fail "dispatch entry generation changed unexpectedly"

restore_before="$generation_after"
restore_response="$(
  hot_sample_hotreq \
    --session root \
    --op load-file \
    --path "$target" \
    --file-path "$HOT_SAMPLE_REPO_ROOT/$target" \
    --field activation=dispatch
)" || fail "failed to restore $target through direct dispatch"
[[ "$(status_of "$restore_response")" == "[\"done\"]" ]] || fail "unexpected direct dispatch restore status"
[[ "$(string_field "$restore_response" activation-kind)" == "dispatch" ]] || fail "restore activation-kind was not dispatch"
[[ "$(int_field "$restore_response" generation)" == "$restore_before" ]] || fail "direct dispatch restore unexpectedly changed generation in response"
restore_after="$(hot_sample_current_generation_retry)"
[[ "$restore_after" == "$restore_before" ]] || fail "direct dispatch restore changed generation: before=$restore_before after=$restore_after"

restored_info="$(dispatch_entry_info "$symbol")" || fail "dispatch-entry-info failed after restore"
[[ "$(status_of "$restored_info")" == "[\"done\"]" ]] || fail "unexpected dispatch-entry-info status after restore"
restored_impl_id="$(int_field "$restored_info" active-impl-id)"
restored_dispatch_index="$(int_field "$restored_info" dispatch-index)"
restored_abi_id="$(int_field "$restored_info" abi-signature-id)"
restored_type_version="$(int_field "$restored_info" type-identity-version)"
restored_generation="$(int_field "$restored_info" generation)"
restored_impl_kind="$(string_field "$restored_info" impl-kind)"
is_native_impl_kind "$restored_impl_kind" || fail "impl-kind after restore was $restored_impl_kind"
[[ "$restored_impl_id" == "$before_impl_id" ]] || fail "active impl id did not return to native under direct dispatch restore"
[[ "$restored_dispatch_index" == "$before_dispatch_index" ]] || fail "dispatch index changed unexpectedly after restore"
[[ "$restored_abi_id" == "$before_abi_id" ]] || fail "abi signature id changed unexpectedly after restore"
[[ "$restored_type_version" == "$before_type_version" ]] || fail "type identity version changed unexpectedly after restore"
[[ "$restored_generation" == "$generation_before" ]] || fail "dispatch entry generation changed unexpectedly after restore"

bash "$script_dir/test_hot_live_window_health.sh" >/dev/null || fail "live Ghostty window is not healthy after direct dispatch test"
trap - EXIT
rm -rf "$tmpdir"

printf 'PASS live direct-dispatch load-file swapped %s without generation churn (symbol=%s impl=%s->%s->%s generation=%s restored_generation=%s)\n' \
  "$target" \
  "$symbol" \
  "$before_impl_kind" \
  "$after_impl_kind" \
  "$restored_impl_kind" \
  "$generation_after" \
  "$restore_after"
printf 'PASS live direct-dispatch compile narrowing candidate_compile_skipped=%s root_deps=%s/%s modules=%s/%s\n' \
  "$candidate_compile_skipped" \
  "$compile_root_deps_used" \
  "$compile_root_deps_total" \
  "$compile_modules_used" \
  "$compile_modules_total"
printf 'PASS live direct-dispatch selection used %s wrappers=%s top_level_decls=%s\n' \
  "$selection_kind" \
  "$selection_changed_wrapper_fqns" \
  "$selection_changed_top_level_decls"
printf 'PASS installed hot manifest support roots resolve from %s (roots=%s cache_backed_compile_modules=%s)\n' \
  "$installed_manifest" \
  "${installed_manifest_support_roots:-<none>}" \
  "$installed_manifest_cache_backed_count"
printf 'PASS installed hot manifest compile module roots stay within manifest support tree and resolve cleanly (escaping_relative=%s missing_relative=%s)\n' \
  "$installed_manifest_escaping_relative_count" \
  "$installed_manifest_missing_relative_count"
