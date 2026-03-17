Problem

We need a cleaner Ghostty validation lane that uses the self-hosted stage4 AArch64 compiler without `-Dhot=true` and without LLVM/LLD. The latest `make hot-run` was not a deadlock: it compiled through and launched, then crashed at runtime in `global.GlobalState.init`. A plain non-hot stage4 lane will tell us whether that crash is hot-specific or reproducible in the ordinary app build with the same backend.

Planned changes

1. Add two new `Makefile` targets in the Ghostty repo root:
   - `stage4-build`
   - `stage4-run`
2. Point those targets at the current self-hosted compiler:
   - `../zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix-current/bin/zig`
   - with fallback to `stage4-debug-cmake-implfix/bin/zig`
3. Use the normal non-hot Ghostty flags:
   - `-Demit-macos-app=false`
   - `-Demit-xcframework=false`
4. Force the self-hosted backend and linker path through Ghostty build options:
   - `-Duse-llvm=false`
   - `-Duse-lld=false`
5. Keep this lane isolated from hot-mode cache state:
   - `.zig-cache-stage4`
   - `.zig-global-cache-stage4`
6. Reuse the existing Ghostty helpers for orphan cleanup, cache recovery, and process-group handling during `run`.

Testing instructions

1. Verify the new targets exist:
   - `make stage4-build`
   - `make stage4-run`
2. Run `make stage4-build` first.
   - Expected good result: the build completes successfully under the self-hosted no-LLVM backend.
   - If it fails, capture the exact compiler error and treat that as the next backend frontier.
3. Run `make stage4-run` second.
   - Expected good result: Ghostty launches successfully.
   - If it launches and stays open, that still counts as startup success for this lane; stop it cleanly afterward instead of waiting forever on GUI exit behavior.
   - If it crashes, capture the crash report and compare the failing symbol against the hot-mode crash in `global.GlobalState.init`.
4. Compare outcomes:
   - If `stage4-run` also crashes in the same place, the bug is deeper than hot-mode runtime glue.
   - If `stage4-run` succeeds while `hot-run` crashes, the remaining bug is likely specific to hot-mode startup/runtime paths.

Immediate execution order

1. Add the new Make targets.
2. Run `make stage4-build`.
3. Run `make stage4-run`.
4. Record the result in `LOG.md`.

Current progress

- `make stage4-build`
  - passed
- `make stage4-run`
  - currently in flight
- Current practical read
  - this non-hot stage4 lane is hitting the same self-hosted AArch64 selector hotspot as the hot lane
  - the remaining backend pain is therefore not specific to hot reload alone
