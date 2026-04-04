# Handover

## Scope

This work is focused on the hot Zig runtime/compiler path under `vendor/zig`, plus repo-local build/tooling:

- `vendor/zig`
- `Makefile`
- `tools/`
- `hot-smoke-test.sh`
- `hot-compiler-test.sh`
- planning/docs files

Constraint being followed:

- no Ghostty-internal source changes under `src/`, `pkg/`, or `macos`

## Current Status

Current verified state:

- `make hot-run` works
- the hot runtime starts and writes `.nrepl-port`
- `hot-compiler-test.sh` passes
- `hot-smoke-test.sh` passes
- direct hot calls work for a broader set of real functions again, including:
  - `renderer.cell.isBlockElement`
  - `ghostty_surface_process_exited`
  - `math.ortho2d`

Not complete yet:

- the long-term goal "`zig hot` can call any non-`comptime` function shape fast" is not finished
- the system still uses a split strategy:
  - direct fast runtime for simple shapes
  - typed-thunk fallback for harder ABI shapes
- more real aggregate-heavy cases still need live verification and likely more support work

## What Was Done

### 1. Hot bootstrap and runtime wiring

- added/iterated on the hot bootstrap/runtime under `vendor/zig/lib/compiler/hot`
- ensured `make hot-run` builds and injects the hot dylib
- fixed stale-process handling in `Makefile`
- fixed `.nrepl-port` ownership so the main app process owns the live port file instead of child shell processes

Relevant files:

- `vendor/zig/lib/compiler/hot/bootstrap_entry.zig`
- `vendor/zig/lib/compiler/hot/runtime.zig`
- `Makefile`

### 2. Generic hot client path

- added repo-local wrapper:
  - `tools/hot`
- added helper tooling:
  - `tools/hot-paste`
  - `tools/hot-theme`
- live paste into Ghostty now works through hot calls

### 3. Compiler/runtime ABI expansion

- expanded value parsing and bytecode support:
  - enum tags
  - lists
  - objects
- added generic marshalling support
- added typed-call and typed-thunk fallback infrastructure
- kept the compiler/runtime implementation generic rather than Ghostty-specific

Relevant files:

- `vendor/zig/lib/compiler/hot/bytecode.zig`
- `vendor/zig/lib/compiler/hot/expr.zig`
- `vendor/zig/lib/compiler/hot/marshal.zig`
- `vendor/zig/lib/compiler/hot/typed_call.zig`
- `vendor/zig/lib/compiler/hot/typed_thunk.zig`
- `vendor/zig/lib/compiler/hot/hot_root.zig`

### 4. Fast-path split to control compile cost

- added a small generic direct C runtime:
  - `vendor/zig/lib/compiler/hot/fast_c_runtime.zig`
- added a small generic direct Zig runtime:
  - `vendor/zig/lib/compiler/hot/fast_zig_runtime.zig`
- this reduced the hot dylib build from the previous runaway multi-hour state to a short rebuild again

### 5. Signature parsing and dispatch fixes

- fixed a real bug in `bundle.zig` where primitive source returns were being treated as mismatches
- that bug incorrectly forced simple functions onto the typed-thunk path
- after the fix, simple calls such as `renderer.cell.isBlockElement` and `ghostty_surface_process_exited` work again

Relevant file:

- `vendor/zig/lib/compiler/hot/bundle.zig`

### 6. Typed-thunk module-map plumbing

- added generic `ZIG_HOT_MODULE_MAP` parsing in:
  - `vendor/zig/lib/compiler/hot/typed_thunk.zig`
- added repo-local module map discovery script:
  - `tools/hot-module-map`
- wired `make hot-run` to export that module map

This moved typed-thunk compilation further forward for project files with external module dependencies, but it is not complete yet.

## Latest Verified Fix

The latest concrete fix was in:

- `vendor/zig/lib/compiler/hot/bundle.zig`

What it fixed:

- primitive source return syntax such as `bool` now matches the already-resolved runtime type
- this avoids false `source-return-mismatch`
- simple signatures stay on the fast path instead of incorrectly falling back to typed thunks

New regression coverage added:

- `bundle.test.parseLookupSignature keeps matching primitive source returns on fast path`

## Current Verified Commands

These were run successfully during the latest round:

```bash
ZIG_LIB_DIR="$PWD/vendor/zig/lib" ./.zig-toolchain/zig-0.15.2/bin/zig test vendor/zig/lib/compiler/hot/bundle.zig --test-filter 'matching primitive source returns'

make hot-stop && make hot-run

./tools/hot call renderer.cell.isBlockElement 9608

./tools/hot call ghostty_surface_process_exited '@objc:NSApp.activeWindow.contentView//surfaceModel.asObject.surface'

./tools/hot call math.ortho2d 0.0 1.0 0.0 1.0

./hot-compiler-test.sh

./hot-smoke-test.sh
```

Observed results from the two direct live calls:

```text
value: true
status:
  done
```

for:

```bash
./tools/hot call renderer.cell.isBlockElement 9608
```

and:

```text
value: false
status:
  done
```

for:

```bash
./tools/hot call ghostty_surface_process_exited '@objc:NSApp.activeWindow.contentView//surfaceModel.asObject.surface'
```

and:

```text
value: [[2, 0, 0, 0], [0, 2, 0, 0], [0, 0, -1, 0], [-1, -1, 0, 1]]
status:
  done
```

for:

```bash
./tools/hot call math.ortho2d 0.0 1.0 0.0 1.0
```

## Test Entry Points

Compiler-side test runner:

```bash
./hot-compiler-test.sh
```

Live app smoke test:

```bash
./hot-smoke-test.sh
```

Hot app launch:

```bash
make hot-run
```

Stop hot app/processes:

```bash
make hot-stop
```

## What Still Needs To Be Done

### Immediate next work

1. Inventory remaining real unsupported live function shapes.
2. Finish typed-thunk support for project files that rely on additional build-graph modules and package compile settings.
3. Choose concrete Ghostty examples for each remaining class.
4. Expand support and tests in `vendor/zig` only.
5. Re-verify each newly supported class with:
   - `./hot-compiler-test.sh`
   - `make hot-run`
   - direct `./tools/hot call ...`
   - `./hot-smoke-test.sh`

### Remaining target classes

These are the main areas still not honestly “done for everything”:

- broader fast-path arity
- more aggregate returns
- more project-defined struct/value parameters
- more nested slice and slice-of-slice live cases
- more allocator + error-union real-world calls
- more vector/array return recovery

## Important Notes

- The hot compiler/runtime implementation under `vendor/zig/lib/compiler/hot` is intended to stay generic.
- Ghostty-specific logic must remain outside Ghostty core source.
- Do not claim "`zig hot` can call any function" yet. The truthful state is: coverage is substantially better, tests are broader, and several real previously failing calls now work, but the universal goal is not complete.
