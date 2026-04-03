# Hot Zig nREPL Implementation Plan

## Goal

Build a Zig-owned hot runtime that:

- starts automatically when using the hot Zig configuration
- writes `.nrepl-port`
- accepts nREPL-like requests over TCP with bencode framing
- can evaluate calls to available Zig functions with sub-second latency after startup
- keeps the symbol graph, bytecode, and protocol inside the vendored Zig toolchain

Ghostty should only provide minimal build and entry wiring. It should not own
symbol discovery, function registration, protocol handling, or hot graph state.

## Hard Boundaries

The hot system must not:

- hand-parse Ghostty source files
- generate Ghostty-local symbol catalogs
- add Ghostty build config types just to model hot compiler state
- require the Ghostty entrypoint to list exported functions manually

The hot system must:

- derive symbol identity inside the vendored Zig toolchain
- use stable symbol ids instead of path strings as the execution identity
- expose bundle metadata that a client can inspect remotely
- lower textual eval through the toolchain, not through Ghostty-specific code

## Architecture

### 1. Hot Bundle

The hot runtime executes against a compiler-owned bundle abstraction.

The bundle contains:

- symbol table
  - `SymbolId`
  - symbol kind: `namespace`, `function`, `constant`
  - parent namespace relation
  - human-readable name metadata
  - callable/support metadata
- edge table
  - namespace membership edges now
  - later: call edges, constant dependencies, patch edges
- bytecode-facing symbol identity
  - bytecode references symbol ids, never string names

Current bootstrap implementation:

- `vendor/zig/lib/compiler/hot/bundle.zig`
- stable ids are derived inside vendored Zig from runtime/debug metadata
- symbol names come from the built app image
- call signatures come from DWARF for the built app
- synthetic namespace edges are derived from the discovered symbol graph

### 2. Shared Execution Representation

Phase 1 bytecode is intentionally small:

- `lookup` by `SymbolId`
- `constant`
- `call`
- `ret`

This bytecode is the common execution representation for:

- textual eval lowered by the server
- direct bytecode requests
- future background compilation handoff

Current file:

- `vendor/zig/lib/compiler/hot/bytecode.zig`

### 3. Eval Flow

`zig hot eval "foo(1, 2)"` should work like this:

1. client sends bencode request with textual code
2. server resolves symbol names against the hot bundle
3. server lowers the request into hot bytecode
4. interpreter executes the bytecode against bundle symbol ids
5. response returns value and type metadata

The important rule is that textual code is only a convenience syntax.
Execution identity is still the symbol id stored in bytecode.

### 4. Transport

Use an nREPL-like request/response transport:

- localhost TCP listener
- `.nrepl-port` file
- bencode payloads

Phase 1 operations:

- `clone`
- `close`
- `ls-sessions`
- `describe`
- `eval`

Current files:

- `vendor/zig/lib/compiler/hot/bencode.zig`
- `vendor/zig/lib/compiler/hot/runtime.zig`
- `vendor/zig/lib/compiler/hot/client.zig`
- `vendor/zig/lib/compiler/hot/main.zig`
- `vendor/zig/tools/hot-client/`

## Compiler Integration Plan

### Phase 0: Toolchain-Owned Foundation

Status: in progress, partly implemented.

Deliver:

- toolchain-owned bundle API
- stable symbol ids in bytecode
- server-side lowering for textual eval
- client and server transport
- symbol/edge inspection through `describe`

This is the foundation now living in `vendor/zig/lib/compiler/hot/`.

### Phase 1: Metadata-Backed Whole-App Discovery

Use the built program image and debug metadata as the source of truth.

Concrete direction:

- enumerate app functions from the built Mach-O symbol table
- resolve callable signatures lazily from DWARF in the generated dSYM
- derive namespace membership edges from discovered symbol paths
- use symbol ids as the execution identity for bytecode and transport

This removes any dependency on per-project symbol registration.

### Phase 2: Common IR / Interpreter Upgrade

Move from the phase-1 minimal bytecode toward an IR that can support:

- constant reads
- function calls
- patchable bodies
- explicit dependency edges
- hot replacement of function and constant nodes

Preferred path:

- reuse existing Zig IR where practical instead of inventing a second full
  compiler front-end
- keep one execution representation that can be interpreted now and compiled
  later

### Phase 3: Hot Mutation

Add graph mutation operations:

- replace function bodies
- replace constant values
- swap dependency edges
- invalidate and re-run dependent nodes

At that point the code graph becomes a live data structure rather than a
read-only catalog.

## Ghostty Integration

Ghostty should only do two things:

- select the vendored Zig toolchain
- launch normally while a vendored hot bootstrap dylib is injected at run time

Ghostty should not contain:

- per-app hot symbol registration
- hot protocol code
- source parsing helpers
- bundle generation

## Validation Plan

### Current Validation Targets

- `zig test vendor/zig/lib/compiler/hot/bytecode.zig`
- `zig test vendor/zig/lib/compiler/hot/expr.zig`
- `zig test vendor/zig/lib/compiler/hot/bundle.zig`
- `zig test vendor/zig/lib/compiler/hot/runtime.zig`
- `zig build` in `vendor/zig/tools/hot-client`

### First Acceptable End-to-End Deliverable

1. hot Zig build starts server automatically
2. `.nrepl-port` is written
3. `zig hot describe` returns symbol ids and edges from whole-app metadata
4. `zig hot eval` lowers through the toolchain and executes by symbol id
5. Ghostty needs only run/build wiring, not per-function export code

## Risks

### Stability Risk

If symbol ids are derived from ad hoc strings forever, the system will be
fragile. The reflective adapter is acceptable only as a bootstrap step inside
the toolchain. The real target is compiler-emitted ids from namespace/nav data.

### IR Duplication Risk

If we invent a separate hot-only IR unrelated to existing compiler IR, every
future feature becomes more expensive. The long-term implementation should
reuse existing compiler lowering products where possible.

### Performance Risk

Cold startup will always be more expensive than a hot eval. The target is:

- cold start pays for bundle/runtime startup once
- subsequent evals stay sub-second by avoiding full app rebuilds

## Immediate Next Steps

1. keep the bundle/bytecode/runtime work inside `vendor/zig`
2. inject a vendored hot bootstrap dylib at `make hot-run` time
3. discover symbols from the built app image and dSYM
4. verify end-to-end `zig hot describe` plus function calls against Ghostty
