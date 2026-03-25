# Ghostty: Deep Project Guide

> This is an AI-authored, human-facing overview of the Ghostty repository.
> It is meant to complement `README.md` and `HACKING.md` by focusing on the
> shape of the codebase itself: what Ghostty builds, how the Zig core is
> organized, where the native frontends fit, how the public library surfaces
> are split, and which parts of the repository carry the most architectural
> weight.

## 1. What Ghostty is

Ghostty is a terminal emulator built primarily in Zig, but the repository is
larger than “just a terminal app.”

This tree contains:

- a native graphical terminal application
- a helper CLI
- the core terminal-emulation and input-encoding libraries
- the public C header for embedding
- platform-native application wrappers and resources
- examples, tests, docs tooling, packaging files, translations, and build glue

The public `README.md` describes Ghostty in user-facing terms: fast,
feature-rich, native, standards-aware, and embeddable. The source tree shows
how that is achieved: a shared Zig core, compile-time-selected runtimes and
renderers, and a build graph that can emit apps, libraries, docs, resources,
examples, tarballs, and platform-specific bundles.

## 2. The project in one mental model

The shortest accurate mental model is:

1. Ghostty has a shared Zig core under `src/`.
2. That core models terminal state, PTY/process I/O, rendering, input,
   configuration, and application-level window/surface behavior.
3. Platform frontends sit around that core:
   - GTK on Linux and related Unix-like targets
   - an embedded/macOS-oriented runtime used by the Xcode app wrapper
   - a browser/WASM runtime
4. The build system decides, at compile time, which runtime and renderer exist
   in a given artifact.
5. The same repository also exposes an embeddable library story, especially
   through `libghostty-vt` and the Zig module in `src/lib_vt.zig`.

If you are trying to understand “where Ghostty really lives,” the answer is:
mostly in `src/`, with the macOS app wrapper in `macos/` and the public
embedding surface split between `include/ghostty.h` and `src/lib_vt.zig`.

## 3. What the repository produces

The build graph in `build.zig` and `src/build/` makes it clear that Ghostty is
not a single binary project.

Key outputs include:

- the main executable and/or app launch path
- the macOS app bundle and related XCFramework artifacts
- `libghostty-vt` shared and static libraries
- the larger historical `libghostty` embedding layer used by the macOS app
- documentation and manpages
- web data
- benchmark tools
- resources such as themes, shell integration, and terminfo data
- translations
- distribution tarballs

`build.zig` creates explicit steps for:

- `run`
- `run-valgrind`
- `test`
- `test-lib-vt`
- `test-valgrind`
- `update-translations`
- `dist`
- `distcheck`

The repository therefore operates simultaneously as:

- an application repo
- a library repo
- a docs/resources repo
- a platform-integration repo
- a packaging repo

## 4. Top-level repository layout

The root layout matters because Ghostty intentionally separates core logic,
native wrappers, build orchestration, examples, and packaging.

### Core directories

- `src/`
  - the main Zig codebase
  - terminal logic, rendering, runtime abstraction, config, input, font,
    library exports, CLI helpers, crash tooling, inspector, and build modules

- `macos/`
  - the macOS app wrapper
  - Xcode project, Swift sources, assets, entitlements, tests, and build files
  - this is where the “real app” side of the macOS experience lives

- `include/`
  - public C headers
  - `include/ghostty.h` is the key header to inspect for the embedding API

- `example/`
  - small standalone consumers of the library APIs
  - both C and Zig examples live here

- `test/`
  - testing utilities and external test-oriented material that does not fit as
    ordinary Zig `test` blocks next to source

- `pkg/`
  - vendored or pinned dependency packages used by the build
  - graphics, shaping, regex, crash reporting, Wayland, macOS SDK glue, etc.

- `vendor/`
  - extra vendored assets or submodules such as GLAD and fonts

### Build, packaging, and tooling

- `build.zig`
  - the main build entrypoint

- `build.zig.zon`
  - dependency manifest and minimum Zig version

- `src/build/`
  - the real build system internals once `build.zig` delegates into modules

- `Makefile`
  - convenience workflows, especially this worktree’s stock-vs-hot build and
    run loops

- `nix/`, `flake.nix`, `shell.nix`, `default.nix`
  - Nix integration

- `flatpak/`, `snap/`, `dist/`
  - packaging and distribution support

- `po/`
  - translations

- `tools/`
  - repo utilities, developer scripts, and in this worktree, hot-reload helper
    scripts

### Project documentation

- `README.md`
  - user-facing/project-facing summary

- `HACKING.md`
  - developer workflow and tooling guide

- `CONTRIBUTING.md`
  - contribution policy

- `PACKAGING.md`
  - packaging guidance

- `Doxyfile`, `DoxygenLayout.xml`
  - API documentation generation

## 5. The Zig core: the important packages

The important work of understanding Ghostty is understanding `src/`.

The top level of `src/` is a map of the project’s major concerns:

- `App.zig`
- `Surface.zig`
- `Command.zig`
- `apprt/`
- `terminal/`
- `termio/`
- `renderer/`
- `font/`
- `input/`
- `config/`
- `os/`
- `inspector/`
- `cli/`
- `crash/`
- `lib_vt.zig`

Below is the practical architecture.

## 6. Startup and runtime selection

The best entrypoint to read first is `src/main_ghostty.zig`.

This file makes several important things explicit:

- Ghostty initializes process-global state first.
- CLI actions can short-circuit normal app startup.
- GUI startup only happens when the build/runtime configuration supports it.
- the application object (`App`) and the runtime object (`apprt.App`) are
  separate concerns

The runtime abstraction is defined in `src/apprt.zig`.

That file shows that Ghostty chooses its application runtime at compile time:

- executable builds use either:
  - `apprt.none`
  - or `apprt.gtk`
- library builds use:
  - `apprt.embedded`
- WASM builds use:
  - `apprt.browser`

This is a crucial architectural point: Ghostty is not a single runtime with
`if` statements all over the place. It is a shared core with a compile-time
runtime selection model.

## 7. App and Surface: the main integration layer

If you want to know where subsystems meet, read `src/App.zig` and
`src/Surface.zig`.

### `src/App.zig`

`App` is the primary GUI application object.

At a high level it owns:

- the active surface list
- the focused application/surface state
- a mailbox for app-thread messages
- shared font grid/cache state
- app-level conditional configuration state

Responsibilities include:

- creating and tracking surfaces
- coordinating shutdown behavior when no surfaces remain
- applying config changes across surfaces
- maintaining shared font cache structures
- acting as the app-level coordination point for the runtime

`App` is relatively small compared to `Surface`, but it sits at the center of
application-level lifecycle management.

### `src/Surface.zig`

`Surface` is the single most important file in the repository if your question
is “where does a real terminal instance come together?”

The opening comments say exactly what the type is: a single terminal “surface,”
minimal enough to be embedded in a window, tab, split, or preview pane,
depending on the higher-level runtime.

`Surface` owns or coordinates:

- a pointer back to `App`
- runtime-facing app and surface handles
- font state and font metrics
- the chosen renderer and render state
- the renderer thread and OS thread handle
- keyboard and mouse state
- the terminal I/O object (`termio.Termio`)
- the I/O thread
- the terminal inspector
- size and configuration state
- child-process lifecycle state
- search state
- command timing and notification-related state

In other words, `Surface` is where Ghostty becomes “a terminal you can see and
interact with.”

Why it matters:

- it is the primary integration hub
- it is large because it coordinates many subsystems rather than implementing a
  single narrow algorithm
- behavior changes here often ripple into rendering, input handling, PTY I/O,
  windowing, and config

If you are making small, safe changes, `Surface.zig` is usually not the first
place to start. If you are making behavior changes that affect real user
interaction, it is often the place you eventually end up.

## 8. Terminal emulation core

The `src/terminal/` package is the heart of Ghostty’s terminal behavior.

`src/terminal/main.zig` acts as the public face of the package and reexports:

- the parser
- screen/page/grid types
- stream processing
- CSI/OSC/APC/DCS handling
- color, style, modes, search, formatting, size-reporting, and mouse support

Important files include:

- `src/terminal/Terminal.zig`
  - the main terminal state machine and grid update logic

- `src/terminal/Parser.zig`
  - escape-sequence parsing

- `src/terminal/Screen.zig`
  - active screen state

- `src/terminal/Page.zig`, `src/terminal/PageList.zig`
  - screen/scrollback data structures

- `src/terminal/render.zig`
  - render-state derivation

- `src/terminal/csi.zig`, `osc.zig`, `apc.zig`, `dcs.zig`
  - protocol families

- `src/terminal/kitty/`
  - Kitty protocol support

- `src/terminal/tmux/`
  - tmux control-mode support

This package is where Ghostty’s standards work actually lives: control
sequences, screen mutations, scrollback behavior, styling, state queries, and
terminal-facing semantics.

This is also the part of the codebase that most naturally feeds the embeddable
library surface.

## 9. Termio: PTY, subprocesses, and stream handling

`src/termio/` is the bridge between the outside process and the terminal model.

`src/termio/Termio.zig` makes the purpose clear in its first lines:

- it owns the PTY/subprocess/backend side
- it owns the terminal state object used by the I/O layer
- it manages renderer and surface mailboxes
- it hosts the terminal stream parser

Key responsibilities:

- starting and coordinating the child process
- configuring terminal defaults from Ghostty config
- feeding bytes into the terminal stream parser
- turning stream actions into terminal mutations and UI notifications
- coordinating renderer wakeups and message passing

`src/termio/stream_handler.zig` is especially important because it translates
parsed terminal actions into:

- terminal state updates
- renderer wakeups
- surface/app actions
- clipboard, title, bell, and related side effects

If `terminal/` is “what terminal behavior means,” `termio/` is “how process
output/input becomes terminal behavior in the running app.”

## 10. Rendering architecture

The renderer abstraction lives in `src/renderer.zig`.

That file shows another important compile-time decision:

- `Metal`
- `OpenGL`
- `WebGL`

are all concrete backend implementations, and `Renderer` is selected from
`build_config.renderer`.

The renderer subsystem includes:

- `src/renderer/Metal.zig`
- `src/renderer/OpenGL.zig`
- `src/renderer/WebGL.zig`
- `src/renderer/generic.zig`
- `src/renderer/Thread.zig`
- `src/renderer/State.zig`
- `src/renderer/Overlay.zig`
- `src/renderer/cursor.zig`
- `src/renderer/image.zig`
- shader-related source and tooling

Notable design points:

- rendering is threaded
- the render backend is chosen at build time
- renderer state is shared with other subsystems through explicit coordination
- overlays, cursor style, cell rendering, links, and shader support live here

Ghostty’s performance story is not just “the parser is fast”; it is also that
rendering and state propagation are organized as first-class subsystems instead
of bolted-on output code.

## 11. Fonts and shaping

The font subsystem lives under `src/font/`.

This is a substantial system, not a thin wrapper.

Important concerns in the font tree include:

- font discovery
- font loading
- shaping
- atlas and glyph handling
- shared grid/font cache coordination across surfaces
- OpenType parsing helpers
- platform-specific font backends

Important areas:

- `src/font/main.zig`
- `src/font/face/`
- `src/font/shaper/`
- `src/font/opentype/`
- `src/font/SharedGrid*`

This subsystem is one reason Ghostty is more than “a parser plus a grid.” The
renderer and font layers are deeply integrated with terminal presentation.

## 12. Input, bindings, and terminal-side encoding

The input subsystem lives under `src/input/`.

This includes:

- key and mouse data types
- key modifier modeling
- keyboard layout handling
- keybinding/action mapping
- link detection/input helpers
- encoding of keyboard and mouse events back into terminal protocols

Important files:

- `src/input/Binding.zig`
- `src/input/command.zig`
- `src/input/key.zig`
- `src/input/key_encode.zig`
- `src/input/key_mods.zig`
- `src/input/mouse.zig`
- `src/input/mouse_encode.zig`

This package matters for both the app and the library surfaces because a
terminal emulator has to work in both directions:

- decode terminal output from the child process
- encode user input back into the terminal protocol

## 13. Configuration, OS integration, inspector, CLI, and crash tooling

Several secondary packages are important because they connect the terminal core
to a usable product.

### Configuration

- `src/config.zig`
- `src/config/`

This is where the large configuration surface lives: parsing, editing,
formatting, conditionals, and config-facing helpers.

### OS abstraction

- `src/os/`

This package contains platform helpers for paths, environment handling, shell
integration, DBus/systemd support, desktop integration, and more.

### Inspector

- `src/inspector/`

Ghostty includes internal inspection/debugging-oriented tooling. This is part
of the repo’s story that is easy to miss if you only read the public README.

### CLI

- `src/cli/`

Ghostty is not only a GUI app. `main_ghostty.zig` explicitly supports CLI
actions, and the CLI package contains the implementation details for those
action-oriented flows.

### Crash reporting

- `src/crash/`

The public README discusses crash report generation. The crash subsystem in
source is where that behavior lives.

## 14. Public library surfaces: `libghostty-vt`, `ghostty.h`, and the split library story

One of the most interesting parts of the repo is that the public library story
is intentionally split.

### `src/lib_vt.zig`

This is the public Zig API for the VT-oriented library surface.

It reexports terminal-facing pieces such as:

- parser and stream types
- screen/page/grid types
- SGR, OSC, mode, and formatting helpers
- render-state access
- input encoding helpers for focus, paste, keyboard, and mouse

The top comment is important:

- the functionality is considered stable because it is extracted from the real
  Ghostty core
- the API shape is still explicitly not guaranteed stable

### `include/ghostty.h`

This is the public C header.

A careful read shows that the public C surface includes:

- opaque app/config/surface/inspector handles
- platform, clipboard, input, and key enums
- terminal and rendering-related C APIs

The header comments also reveal an important nuance:

- the embedding API exists and is real
- but some of it is still historically shaped around the needs of the macOS app

### Build-system nuance

`build.zig` and `src/build/` make a subtle but important distinction:

- `libghostty-vt` is the clearly separated VT-oriented public library artifact
- the larger `GhosttyLib` / `libghostty` layer is historically the glue between
  the macOS UI and the full Ghostty core

That means the repository’s “embedding story” is real, but not all parts of it
are equally mature or equally generic yet.

## 15. Native frontends and platform wrappers

Ghostty is cross-platform, but the repository does not chase a lowest-common
denominator UI.

### macOS

The macOS wrapper lives in `macos/`.

Important pieces include:

- `macos/Ghostty.xcodeproj`
- `macos/Sources/App`
- `macos/Sources/Features`
- `macos/Sources/Ghostty`
- `macos/Sources/Helpers`
- assets, entitlements, tests, and bundle metadata

The Zig side of the macOS integration uses the embedded runtime path and the
Xcode build artifacts wired from `src/build/GhosttyXcodebuild.zig` and
`src/build/GhosttyXCFramework.zig`.

### GTK / Linux / Unix-like desktop

GTK lives under:

- `src/apprt/gtk/`

This is where Ghostty’s Linux desktop runtime exists, including windowing,
Wayland/X11-adjacent support, portals, and runtime-specific surface/app logic.

### Browser / WASM

The browser path is selected through:

- `src/apprt/browser.zig`
- `src/main_wasm.zig`
- `src/renderer/WebGL.zig`

This is another example of Ghostty’s shared-core design: the same tree can
target a browser runtime without pretending that browser integration is just a
different command-line flag on a monolithic desktop app.

## 16. Build system architecture

`build.zig` is intentionally thin and delegates real work into `src/build/`.

That subtree contains focused modules for:

- config parsing for build options
- shared dependency setup
- executable creation
- library creation
- XCFramework generation
- Xcode integration
- docs generation
- resources installation
- translations
- benchmarks
- dist tarballs
- web data
- Zig module export setup

Important files:

- `src/build/main.zig`
- `src/build/Config.zig`
- `src/build/SharedDeps.zig`
- `src/build/GhosttyExe.zig`
- `src/build/GhosttyLib.zig`
- `src/build/GhosttyLibVt.zig`
- `src/build/GhosttyDocs.zig`
- `src/build/GhosttyResources.zig`
- `src/build/GhosttyI18n.zig`
- `src/build/GhosttyXcodebuild.zig`
- `src/build/GhosttyXCFramework.zig`

This modular build layout is worth understanding because many “what does Ghostty
even build?” questions are answered more cleanly here than in product docs.

## 17. External integrations and dependencies

`build.zig.zon` and `pkg/` reveal the project’s native integration surface.

Notable Zig dependencies include:

- `libxev`
- `z2d`
- `zig_objc`
- `zig_js`
- `zig_wayland`
- `zf`
- generated `gobject` bindings

Notable packaged native dependencies include:

- `freetype`
- `harfbuzz`
- `fontconfig`
- `oniguruma`
- `opengl`
- `libpng`
- `zlib`
- `simdutf`
- `utfcpp`
- `wuffs`
- `sentry`
- `dcimgui`
- `glslang`
- `spirv-cross`
- `gtk4-layer-shell`
- Apple SDK and Android NDK packages

What that says about the project:

- text shaping and font discovery are real first-class concerns
- regex and hyperlink/text analysis matter
- crash reporting is integrated
- shader and graphics translation tooling matter to the renderer stack
- Ghostty spans native windowing and graphics ecosystems rather than hiding
  behind a single cross-platform GUI toolkit

## 18. Tests, examples, docs, and contributor tooling

Ghostty combines several kinds of developer support:

### Zig tests

The source tree itself contains many `test` blocks, and `main_ghostty.zig`
imports a very broad swath of the repo during testing to keep declarations and
internal packages exercised.

### External testing utilities

- `test/`
- `test/fuzz-libghostty/`

These cover utilities and fuzzing-oriented workflows that do not fit cleanly as
ordinary inline Zig tests.

### Examples

The `example/` tree contains small standalone consumers of the library APIs.

Examples exist for:

- C consumers
- Zig consumers
- VT parsing/stream handling
- formatter and size-report APIs
- input encoding flows

This is one of the best ways to understand the public library surfaces without
reading the entire app.

### Docs and contributor tooling

`HACKING.md` documents the primary workflows:

- `zig build`
- `zig build run`
- `zig build test`
- filtered tests with `-Dtest-filter=...`
- `zig build update-translations`
- `zig build dist`
- `zig build distcheck`

It also calls out linting and formatting tools used in CI:

- Prettier
- Alejandra
- ShellCheck
- SwiftLint

## 19. This worktree’s hot-reload and live-eval workflow

This repository copy currently includes a hot-reload workflow that is layered
on top of Ghostty via the hot Zig toolchain.

Relevant files include:

- `Makefile`
- `HOT_RELOAD_TESTING.md`
- `tools/hot_nrepl.py`
- `.zig-hot/`
- `.nrepl-port`

The `Makefile` provides convenience targets such as:

- `stock-build`
- `stock-run`
- `hot-build`
- `hot-run`
- `hot-test`

These are not the only way to build Ghostty, but they are a practical wrapper
for this worktree’s stock-vs-hot development loop.

This hot workflow is useful for experimentation and live overlays, but it is
not a substitute for understanding the ordinary build graph in `build.zig` and
`src/build/`.

## 20. A practical reading roadmap

If you are new to the repo and want the fastest path to real understanding,
read in roughly this order:

1. `README.md`
2. `HACKING.md`
3. `build.zig`
4. `src/build/main.zig`
5. `src/main_ghostty.zig`
6. `src/apprt.zig`
7. `src/App.zig`
8. `src/Surface.zig`
9. `src/terminal/main.zig`
10. `src/terminal/Terminal.zig`
11. `src/termio/Termio.zig`
12. `src/termio/stream_handler.zig`
13. `src/renderer.zig`
14. one concrete renderer backend (`Metal.zig`, `OpenGL.zig`, or `WebGL.zig`)
15. `src/input/Binding.zig` and `src/input/key_encode.zig`
16. `src/config.zig`
17. `src/lib_vt.zig`
18. `include/ghostty.h`
19. `example/README.md` plus one or two examples

That reading order moves from:

- what the project claims to be
- to how it is built
- to how it starts
- to how the app and surface coordinate
- to how terminal state and process I/O work
- to how rendering and input are layered on top
- to how the library surface is exposed to external users

## 21. Where the complexity really lives

Some hotspots deserve explicit mention.

### `src/Surface.zig`

This is the main integration hub and one of the highest-risk edit surfaces in
the repo.

### `src/apprt/`

Runtime abstractions are elegant, but they hide real platform complexity:

- GTK app/runtime behavior
- embedded/macOS behavior
- browser/WASM behavior

### `src/termio/` + `src/terminal/` + `src/renderer/`

This is the high-value pipeline of the whole app:

- process bytes
- parse terminal actions
- mutate terminal state
- derive render state
- wake and feed the renderer

These packages are individually understandable, but the behavior that users
care about usually spans all three.

### Library surface evolution

The project’s public API story is real, but split:

- the VT-oriented library surface is the cleanest public entry today
- the full embedding story still reflects historical coupling to the app

That is not a flaw so much as an important architectural fact.

## 22. Final takeaway

Ghostty is best understood as a shared Zig terminal core surrounded by
specialized runtimes, renderers, and packaging surfaces.

It is simultaneously:

- a native terminal application
- a terminal-emulation library
- a platform integration project
- a graphics/text-rendering project
- a build/distribution system

If you keep one idea in mind while reading the code, keep this one:

Ghostty is not organized around “a big main file that does terminal things.”
It is organized around a reusable terminal core, a strong `Surface`-level
integration layer, compile-time runtime/backend selection, and a build graph
that can emit multiple products from the same codebase.
