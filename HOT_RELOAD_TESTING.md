# Ghostty Hot Reload Testing

This document records the exact workflow we have been using to validate the live hot-reload lane on the real macOS Ghostty app.

## What this covers

- build or reuse the stockboot hot compiler
- launch the real Ghostty app with `make hot-run`
- verify the embedded nREPL
- perform path-aware `load-file`
- enter `in-file` eval context when needed
- use the repo-local hot nREPL helper for live requests
- run a machine-verifiable live proof by temporarily rerouting `New Tab` to `newWindow(...)`

## Required tools

- Ghostty checkout
- hot Zig checkout with the stockboot compiler build
- `make`
- `python3`
- `swift`

The commands below assume the usual sibling checkout layout:

- Ghostty repo: `$HOME/dev/ghostty-zig-worktree`
- hot Zig repo: `$HOME/dev/zig-hot-llvm-0.15.2`

## One-time shell setup

```sh
export GHOSTTY_REPO="${GHOSTTY_REPO:-$HOME/dev/ghostty-zig-worktree}"
export HOT_ZIG_REPO="${HOT_ZIG_REPO:-$HOME/dev/zig-hot-llvm-0.15.2}"
export GHOSTTY_HOT_TOOL="${GHOSTTY_HOT_TOOL:-$GHOSTTY_REPO/tools/hot_nrepl}"
export GHOSTTY_PORT_FILE="${GHOSTTY_PORT_FILE:-$GHOSTTY_REPO/.nrepl-port}"

hotreq() {
  "$GHOSTTY_HOT_TOOL" --port-file "$GHOSTTY_PORT_FILE" "$@"
}
```

`./tools/hot_nrepl` is a thin launcher that builds the standalone Zig client in
`tools/hot_nrepl_client/` on demand and then reuses the built binary.

```sh
clone_session() {
  hotreq --op clone | python3 -c 'import json,sys; print(json.load(sys.stdin)["new-session"])'
}
```

Use this helper to count Ghostty windows through Quartz:

```sh
ghostty_window_count() {
  swift - <<'SWIFT'
import Foundation
import CoreGraphics

let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var hits: [(Int, Int, Int, Int, Int)] = []

for win in list {
    let owner = (win[kCGWindowOwnerName as String] as? String ?? "").lowercased()
    guard owner.contains("ghostty") else { continue }

    let layer = win[kCGWindowLayer as String] as? Int ?? -999
    let number = win[kCGWindowNumber as String] as? Int ?? -1
    let bounds = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = bounds["X"] as? Int ?? -1
    let y = bounds["Y"] as? Int ?? -1
    let w = bounds["Width"] as? Int ?? -1
    let h = bounds["Height"] as? Int ?? -1

    if layer == 0 && w > 300 && h > 300 {
        hits.append((number, x, y, w, h))
    }
}

print("COUNT=\(hits.count)")
for hit in hits.sorted(by: { $0.0 < $1.0 }) {
    print(hit)
}
SWIFT
}
```

## Build or refresh the hot compiler

```sh
cd "$HOT_ZIG_REPO"
./tools/build_stage3_stockboot_debug_aarch64_macos.sh
```

Optional smoke checks from the hot Zig repo:

```sh
cd "$HOT_ZIG_REPO"
GHOSTTY_HOT_TARGET=hot-build ./tools/test_ghostty_hot.sh
GHOSTTY_HOT_TARGET=hot-run ./tools/test_ghostty_hot.sh
```

## Launch the real Ghostty app

If you need a clean relaunch, list and kill only explicit Ghostty PIDs first:

```sh
ps -axo pid,command | grep '/Ghostty.app/Contents/MacOS/ghostty' | grep -v grep
kill <pid>
```

Launch the real app, not the CLI-safe `--version` path:

```sh
cd "$GHOSTTY_REPO"
make hot-run RUN_ARGS=
```

Once the app is up, verify the embedded nREPL:

```sh
hotreq --op describe
hotreq --op current-generation
```

You can also invoke the helper directly:

```sh
./tools/hot_nrepl --op describe
./tools/hot_nrepl --op eval --code '1 + 2'
./tools/hot_nrepl --op eval --code - <<'EOF'
const x = 40;
x + 2
EOF
```

## Sample hot scripts

The repo also carries a few known-good sample scripts under `tools/`:

```sh
./tools/hot_sample_mouse_button_max.sh
./tools/hot_sample_file_type_guess.sh
./tools/hot_sample_math_ortho.sh
./tools/hot_sample_math_overlay_scale.sh
./tools/hot_sample_file_type_overlay_hot_ext.sh
./tools/hot_sample_new_tab_new_window.sh
./tools/hot_sample_output_dots_to_bangs.sh
```

What they show:

- `hot_sample_mouse_button_max.sh`
  - evaluates `src/input/mouse.zig`
  - prints `Button.max`, optionally plus a small shell-provided offset

- `hot_sample_file_type_guess.sh`
  - evaluates `src/file_type.zig`
  - checks whether `guessFromExtension(...)` matches the expected enum tag

- `hot_sample_math_ortho.sh`
  - evaluates `src/math.zig`
  - prints the x-scale entry from `ortho2d(...)`

- `hot_sample_math_overlay_scale.sh`
  - builds a temporary overlay for `src/math.zig`
  - changes the x-scale numerator in `ortho2d(...)`
  - reads the modified result back live
  - acts as a toggle by adding live marker decls to the overlaid file only

- `hot_sample_file_type_overlay_hot_ext.sh`
  - builds a temporary overlay for `src/file_type.zig`
  - teaches `guessFromExtension(...)` to map a custom extension
  - reads the modified result back live
  - acts as a toggle by adding live marker decls to the overlaid file only

- `hot_sample_new_tab_new_window.sh`
  - builds a temporary overlay for `src/Surface.zig`
  - rewires `New Tab` to open a new window instead
  - also prints a log line to the `hot-run` terminal when the action fires
  - uses a build-safe companion marker overlay so `status`/`off` still work even though direct eval of `Surface.zig` pulls in build-only imports
  - acts as a toggle and stays active until you rerun it or call it with `off`

- `hot_sample_output_dots_to_bangs.sh`
  - builds a temporary overlay for `src/terminal/stream.zig`
  - changes terminal output so printed `.` characters appear as `!`
  - gives you a simple command to run in Ghostty to verify the UI change
  - acts as a toggle and stays active until you rerun it or call it with `off`

The overlay scripts intentionally leave the on-disk source alone. They patch the running app generation, and each overlay uses live `pub` marker decls created through hot reload so the script can detect whether that one sample is active. Most samples put the marker directly on the overlaid file; the `Surface` sample uses a build-safe companion overlay for the marker because direct eval of `Surface.zig` itself is not nREPL-friendly. There is no hidden disk state and no tracked source module for toggles. Restarting the app returns all samples to a clean, off state automatically.

Overlay scripts accept `toggle` (default), `on`, `off`, and `status`.

Examples:

```sh
./tools/hot_sample_output_dots_to_bangs.sh
./tools/hot_sample_output_dots_to_bangs.sh status
./tools/hot_sample_output_dots_to_bangs.sh off
```

## Path-aware `load-file`

Reload an on-disk file directly:

```sh
hotreq --op load-file \
  --path "$GHOSTTY_REPO/src/termio/stream_handler.zig" \
  --file-path "$GHOSTTY_REPO/src/termio/stream_handler.zig"
```

Reload a temporary edited copy back onto the real module path:

```sh
hotreq --op load-file \
  --path "$GHOSTTY_REPO/src/Surface.zig" \
  --file-path /tmp/surface_overlay.zig
```

Always use `--path REAL_FILE --file-path OVERLAY_FILE` for scoped replacements. The old minimal Python client that omits `path` is not sufficient for this workflow.

## `in-file` eval

Use a cloned session when you want temporary file-context eval:

Example:

```sh
session="$(clone_session)"
hotreq --session "$session" --op in-file --path "$GHOSTTY_REPO/src/input/mouse.zig"
hotreq --session "$session" --op eval --code 'Action.press == .press'
hotreq --session "$session" --op close
```

This is useful when you need file-context eval rather than the default root eval scope.

## Generic extra request fields

For operations that need fields beyond the built-in flags, use `--field` and `--int-field`.

```sh
hotreq --op symbol-info --field symbol=telemetry.bannerChecksum
hotreq --op bind-generation --session s-2 --generation 4
```

## Machine-verifiable live proof: `New Tab` becomes `New Window`

This proof exercises a real user action and can be checked without guessing from the UI alone.

1. Count current Ghostty windows:

```sh
ghostty_window_count
```

2. Build a temporary overlay that rewires `.new_tab` in `src/Surface.zig`:

```sh
python3 - <<'PY'
from pathlib import Path
import os

ghostty_repo = Path(os.environ["GHOSTTY_REPO"])
orig = (ghostty_repo / "src/Surface.zig").read_text()
needle = '''        .new_tab => return try self.rt_app.performAction(
            .{ .surface = self },
            .new_tab,
            {},
        ),
'''
replacement = '''        .new_tab => {
            try self.app.newWindow(self.rt_app, .{ .parent = self });
            return true;
        },
'''

count = orig.count(needle)
if count != 1:
    raise SystemExit(f"expected 1 new_tab branch, found {count}")

Path("/tmp/surface_new_tab_to_new_window.zig").write_text(
    orig.replace(needle, replacement, 1)
)
print("/tmp/surface_new_tab_to_new_window.zig")
PY
```

3. Load the overlay onto the live app:

```sh
hotreq --op load-file \
  --path "$GHOSTTY_REPO/src/Surface.zig" \
  --file-path /tmp/surface_new_tab_to_new_window.zig

hotreq --op current-generation
```

4. In the running Ghostty app, trigger `New Tab` exactly once.

5. Count windows again:

```sh
ghostty_window_count
```

Expected result:

- the window count increases by `1`
- the new large Ghostty window proves that the live hot overlay changed the real binding path

This exact proof was validated live by watching the large-window count increase from `6` to `7` after a single `New Tab` action.

6. Revert the proof overlay immediately after the check:

```sh
hotreq --op load-file \
  --path "$GHOSTTY_REPO/src/Surface.zig" \
  --file-path "$GHOSTTY_REPO/src/Surface.zig"
```

## Troubleshooting

- If `.nrepl-port` is missing, the app either did not launch or the embedded runtime did not finish booting.
- If `load-file` returns `status=["error","done"]`, fix the overlay and retry, or revert by reloading the real on-disk file.
- If you only need to prove the runtime is alive, start with:

```sh
hotreq --op describe
hotreq --op current-generation
```

- Prefer validating reload behavior on a healthy already-running app instead of relaunching unnecessarily, because fresh launch can still intermittently fail during terminal surface initialization.
