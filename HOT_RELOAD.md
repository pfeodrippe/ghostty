# Ghostty Hot Reload Notes

This worktree is wired to the sibling Zig `0.15.2` hot backport at:

- `/Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2`

The stock validation compiler lives at:

- `/Users/pfeodrippe/dev/zig-stock-0.15.2`

Validate the stock path first:

```sh
make stock-build
make stock-run
make stock-open
make stock-test
```

For quick non-interactive run checks, pass CLI args through `RUN_ARGS`, for example:

```sh
make stock-run RUN_ARGS=--version
make hot-run RUN_ARGS=--version
```

Use the local helper targets here:

```sh
make hot-build
make hot-run
make hot-test
```

They default to:

- `HOT_ZIG=/Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig`
- `HOT_FLAGS=-Dhot=true -Demit-macos-app=false -Demit-xcframework=false`

## What `-Dhot=true` does

- enables Zig `hot_mode=.flecs` for Ghostty's Zig executable and macOS `GhosttyKit` library builds
- uses the self-hosted Mach-O path instead of LLVM/LLD for hot-enabled artifacts
- launches `zig build run` with:
  - `ZIG_HOT_COMPILER`
  - `ZIG_HOT_WORKSPACE`
  - `ZIG_HOT_ZIG_LIB_DIR`
  - `ZIG_HOT_MANIFEST`

On macOS, `zig build run -Dhot=true` still launches the Xcode-built app, but it points the app at the manifest emitted for the native `GhosttyKit` build so the linked Zig code can bootstrap `std.hot` inside the final app executable.

## Current Scope

- first-class target: local macOS `run`
- current defaults avoid universal `.xcframework` install builds in hot mode
- this is intended for local development on the matching Zig hot worktree, not release packaging

## Current Local Status

On this machine (`macOS 15.1`, `Xcode 16.1`), the stock sibling Zig `0.15.2` path is green with:

```sh
make stock-build
make stock-run RUN_ARGS=--version
make stock-open
make stock-test
```

Use `make stock-open` when you want the actual Ghostty window to be promoted to the foreground while keeping the standard `zig build run` launch path. `make stock-run` is still fine for log-oriented validation.

The hot path should only be resumed after keeping that stock baseline green.
