# Zig Build Stages

This repository now vendors Zig as a git submodule in `vendor/zig`, and the
`make stock-run` flow builds that Zig from source before using it to build
Ghostty.

This file explains what the different Zig build stages mean, using the actual
Zig 0.15.2 source tree that Ghostty currently targets.

## Short version

The important practical answer is:

- `zig2` is an intermediate bootstrap compiler.
- `stage3/bin/zig` is the final Zig CLI we should use for Ghostty.
- `stage4` is an optional verification/reproducibility step used by Zig's own
  CI; it is not the normal compiler we need in this project.

So for Ghostty:

- building through `zig2` is part of the bootstrap process,
- but the correct end state is still a real installed `zig` from stage3.

## Where the stage names come from

The stage names are not arbitrary. They come directly from Zig's source build
pipeline:

- `vendor/zig/CMakeLists.txt`
- `vendor/zig/README.md`
- `vendor/zig/ci/aarch64-macos-release.sh`

The most relevant parts are:

- `vendor/zig/README.md` explains that `bootstrap.c` can produce a `zig2`
  compiler, but that this compiler lacks some features.
- `vendor/zig/CMakeLists.txt` shows the actual source-build sequence:
  `zig1.wasm` -> `zig1` -> `zig2.c` and `compiler_rt.c` -> `zig2` ->
  `stage3/bin/zig`.
- `vendor/zig/ci/aarch64-macos-release.sh` shows that Zig's own macOS release
  pipeline uses `stage3-release/bin/zig` as the real compiler, and then
  optionally builds `stage4-release` only to verify determinism.

## Stage 0: External host toolchain

Zig's source build does not start from nothing. It starts from an external host
toolchain:

- a system C compiler,
- a system C++ compiler,
- LLVM,
- Clang,
- LLD,
- CMake,
- Ninja.

In our local Ghostty setup on macOS, that means:

- Apple Clang from Xcode for the host C/C++ compiler,
- Homebrew `llvm@20`,
- Homebrew `lld@20`,
- Homebrew `zstd`, `libxml2`, and `zlib`,
- CMake and Ninja from the host environment.

This is the "stage 0" environment in the practical sense: it is the outside
toolchain that lets Zig bootstrap itself.

## Stage 1: `zig1.wasm` turned into a native `zig1`

The Zig source tree ships a checked-in WebAssembly artifact:

- `vendor/zig/stage1/zig1.wasm`

Zig's CMake build first turns that wasm blob into C:

- `zig-wasm2c` converts `zig1.wasm` into `zig1.c`

Then it compiles that generated C into a native executable:

- `zig1`

This happens in `vendor/zig/CMakeLists.txt` in the block that defines:

- `ZIG1_WASM_MODULE`
- `ZIG1_C_SOURCE`
- `add_executable(zig1 ...)`

Conceptually:

- `zig1.wasm` is the seed compiler artifact,
- `zig1` is the first native executable produced from that seed.

## Stage 2: `zig1` generates `zig2.c`, then the host C toolchain links `zig2`

Once `zig1` exists, Zig uses it to generate more C source:

- `zig2.c`
- `compiler_rt.c`

This is visible in `vendor/zig/CMakeLists.txt`:

- `COMMAND zig1 ${BUILD_ZIG2_ARGS}`
- `COMMAND zig1 ${BUILD_COMPILER_RT_ARGS}`

Then the host C/C++ toolchain compiles and links those generated files into:

- `zig2`

This is the intermediate bootstrap compiler.

### What `zig2` is

`zig2` is:

- a real executable,
- produced during the bootstrap,
- good enough to build the final Zig,
- not the final installed Zig we should treat as the project toolchain.

### Why the name is confusing

The name `zig2` makes it sound like "Zig version 2" or "stage 2 is the final
CLI." That is not what it means. It is just the second compiler artifact in
Zig's historical bootstrap naming.

The next output after `zig2` is still just named:

- `zig`

but it lives under a stage3 install prefix.

## Stage 3: `zig2` builds the final installed `zig`

After `zig2` exists, Zig's CMake pipeline uses it to run Zig's own build system
and install a proper compiler layout under `stage3`:

- `stage3/bin/zig`
- `stage3/lib/...`

The key line in `vendor/zig/CMakeLists.txt` is:

```cmake
COMMAND zig2 build --prefix "${PROJECT_BINARY_DIR}/stage3" ${ZIG_BUILD_ARGS}
```

That is the transition from:

- intermediate bootstrap compiler (`zig2`)

to:

- proper installed Zig toolchain (`stage3/bin/zig` plus `stage3/lib`)

This stage3 compiler is the one we want for Ghostty.

### Why stage3 is the correct endpoint for Ghostty

The Zig README explicitly distinguishes between:

- the executable,
- the `lib/` directory.

A usable Zig installation is both together.

Stage3 gives us that normal layout. That matters because Ghostty uses Zig as a
real project toolchain, including package resolution and the normal build
entrypoints.

## Stage 4: Optional reproducibility verification

Zig's CI release scripts often do one more step after stage3:

- use `stage3/bin/zig` to build a second final compiler,
- install it under `stage4`,
- compare the stage3 and stage4 binaries byte-for-byte.

For example, `vendor/zig/ci/aarch64-macos-release.sh` does:

- build `stage3-release/bin/zig`
- use that to build `stage4-release`
- `diff stage3-release/bin/zig stage4-release/bin/zig`

That step is not required to use Zig. It is a release-quality and
determinism-check step.

So:

- stage3 is the final toolchain we need,
- stage4 is optional verification.

## The bootstrap path without LLVM

The Zig README also documents a different bootstrap path:

```sh
cc -o bootstrap bootstrap.c
./bootstrap
```

That path also produces a `zig2`, but the README is explicit that it lacks
important features, including:

- release-mode optimizations,
- `@cImport`,
- translating C,
- compiling C/C++/Objective-C/Objective-C++ inputs,
- several backend and linker capabilities.

That path is useful for some packaging scenarios, but it is not what we want
for Ghostty on macOS.

Ghostty needs the full LLVM/Clang/LLD-backed path, which is why our Makefile
builds Zig against:

- `llvm@20`
- `lld@20`
- `zstd`
- `libxml2`
- `zlib`

## What the current Ghostty Makefile is doing

At a high level, the Makefile is now doing this:

1. Use the vendored Zig source in `vendor/zig`.
2. Configure Zig's CMake build against the local LLVM 20 toolchain.
3. Build `zig2`.
4. Continue through Zig's own stage3 install.
5. Use the resulting stage3 `zig` to run `zig build run` for Ghostty.

That is the "right way until the end" for this repository.

## Practical mapping of names

If you just want a mental model:

- host compiler/toolchain: the external compiler and libraries Zig starts from
- `zig1.wasm`: the checked-in seed artifact
- `zig1`: native executable generated from the wasm seed
- `zig2`: intermediate bootstrap compiler
- `stage3/bin/zig`: the final installed Zig CLI we should use
- `stage4/bin/zig`: optional second final build used to verify determinism

## Why this matters for debugging Ghostty

When Ghostty fails during `make stock-run`, it is important to know which layer
is failing:

- host toolchain setup problem,
- Zig bootstrap problem,
- final Zig install problem,
- Ghostty build problem,
- Ghostty macOS/Xcode compatibility problem.

The stage names help separate those cases.

In our current setup:

- missing `zstd` and mismatched `lld` were host toolchain/bootstrap issues,
- getting to stage3 is still part of the Zig bootstrap,
- only after stage3 finishes do we get to the real Ghostty/macOS build issues.
