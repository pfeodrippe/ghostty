# Ghostty Hot Reload Testing

This document records the exact workflow we have been using to validate the live hot-reload lane on the real macOS Ghostty app.

## What this covers

- build or reuse the stockboot hot compiler
- launch the real Ghostty app with `make hot-run`
- verify the embedded nREPL
- perform path-aware `load-file`
- enter `in-file` eval context when needed
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
export HOT_ZIG_BIN="${HOT_ZIG_BIN:-$HOT_ZIG_REPO/stage3-debug-llvm20-stockboot/bin/zig}"
export HOT_NREPL_SEND="${HOT_NREPL_SEND:-$HOT_ZIG_REPO/tools/hot_nrepl_send.zig}"
export GHOSTTY_PORT_FILE="${GHOSTTY_PORT_FILE:-$GHOSTTY_REPO/.nrepl-port}"

port() {
  cat "$GHOSTTY_PORT_FILE"
}

hotreq() {
  "$HOT_ZIG_BIN" run "$HOT_NREPL_SEND" -- --addr "127.0.0.1:$(port)" "$@"
}
```

```sh
enter_file() {
  python3 - "$1" "$GHOSTTY_PORT_FILE" <<'PY'
import socket
import sys

path = sys.argv[1]
port = int(open(sys.argv[2]).read().strip())

def bstr(value: bytes) -> bytes:
    return str(len(value)).encode() + b":" + value

request = b"d" + b"".join([
    bstr(b"op"), bstr(b"in-file"),
    bstr(b"session"), bstr(b"root"),
    bstr(b"path"), bstr(path.encode()),
]) + b"e"

sock = socket.create_connection(("127.0.0.1", port), timeout=5)
sock.sendall(request)
sock.settimeout(0.5)
response = bytearray()
while True:
    try:
        chunk = sock.recv(65536)
        if not chunk:
            break
        response.extend(chunk)
    except socket.timeout:
        break
sock.close()
print(response.decode("utf-8", "replace"))
PY
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

`tools/hot_nrepl_send.zig` does not currently provide a convenience wrapper for `in-file`, so use the `enter_file` helper first and then plain `eval`.

Example:

```sh
enter_file "$GHOSTTY_REPO/src/termio/stream_handler.zig"
hotreq --op eval --code 'StreamHandler.tmux_enabled'
```

This is useful when you need file-context eval rather than the default root eval scope.

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
