# Hot Zig ABI Expansion Plan

## Goal

Expand the hot runtime so `zig hot` can call the broader set of real Zig functions we identified in Ghostty, without Ghostty-internal source changes.

## Constraints

- Only change:
  - `/Users/pfeodrippe/dev/ghostty/vendor/zig`
  - `/Users/pfeodrippe/dev/ghostty/Makefile`
  - repo-local tooling and tests
- No Ghostty core source changes under:
  - `/Users/pfeodrippe/dev/ghostty/src`
  - `/Users/pfeodrippe/dev/ghostty/pkg`
  - `/Users/pfeodrippe/dev/ghostty/macos`
- Keep the implementation compiler-owned and generic.

## Scope

The runtime currently handles:

- primitive scalars
- opaque pointers
- byte strings
- a small fixed arity

This plan expands support for the function shapes that are currently blocked:

- `4+` arguments
- enum parameters
- struct parameters
- allocator parameters
- optional/sentinel string parameters
- slice parameters beyond `[]const u8`
- error-union returns such as `!void`
- aggregate returns such as arrays/vectors/structs where possible from compiler metadata

## Execution Order

### 1. Value Layer

Add richer hot values and syntax so calls can express the missing shapes.

- Add bytecode/runtime values for:
  - enum tags
  - lists
  - objects
- Extend the expression parser to accept:
  - `.enum_tag`
  - `[a, b, c]`
  - `.{ .field = value, .other = value }`
- Add parser tests for each new literal form.

Status:
- Done.

### 2. Type Descriptor Layer

Replace the current narrow signature model with richer descriptors.

- Extend type descriptors to model:
  - general slices
  - optionals
  - enums
  - structs
  - arrays
  - vectors
  - allocators
  - error-union returns
- Keep simple fast paths for existing primitive/pointer/string cases.
- Parse named type definitions from DWARF when a raw type name is not directly primitive.
- Add unit tests for DWARF parsing of:
  - struct types
  - enum types
  - allocator-like structs

Status:
- In progress.
- Done so far:
  - enum metadata parsing from DWARF
  - source-informed parameter upgrades for:
    - `?[]const u8`
    - `[:0]const u8`
    - `?[:0]const u8`
    - `mem.Allocator`
  - source-informed return upgrades for:
    - `!void`
    - `!?[:0]const u8`

### 3. Invocation Layer

Remove the fixed-arity call path and replace it with recursive typed dispatch.

- Replace the `0/1/2/3`-argument specialization with a generic recursive dispatcher.
- Build typed tuples dynamically from the runtime signature descriptor.
- Marshal:
  - structs by value
  - enums by underlying tag
  - slices from list/string values
  - allocator values from compiler-owned built-ins
- Add direct invoke tests for:
  - `4` arguments
  - struct parameter mutation
  - enum parameter handling
  - slice-of-int parameter handling

Status:
- In progress.
- Done so far:
  - generic `4+` arity dispatch
  - enum argument coercion
  - optional/sentinel byte-slice argument coercion
  - allocator argument coercion via compiler-owned names:
    - `@allocator.c`
    - `@allocator.page`
    - `@allocator.smp`

### 4. Return Recovery

Handle the cases where DWARF collapses Zig returns to `void` or `anyerror`.

- Recover missing return-shape information when needed.
- First target:
  - `!void`
  - `!?[:0]const u8`
  - aggregate returns like `[4]@Vector(4, f32)` when their shape is recoverable
- Add tests for:
  - error-only returns
  - optional string returns
  - aggregate return rendering

Status:
- In progress.
- Done so far:
  - `!void`
  - `!?[:0]const u8`

### 5. Generic Marshal Layer

Add a compiler-owned generic value marshaller that can recursively decode and encode:

- enums
- optionals
- structs
- arrays
- vectors
- generic slices
- allocator values

This is the reusable layer needed before arbitrary user-defined struct and aggregate calls can be invoked safely.

Status:
- In progress.
- Initial implementation lives in:
  - `/Users/pfeodrippe/dev/ghostty/vendor/zig/lib/compiler/hot/marshal.zig`

### 6. Typed Thunk Layer

The remaining unsupported cases require compiler-generated typed thunks.

Why:
- the current runtime can only directly invoke function shapes whose concrete Zig types are already compiled into the hot runtime itself
- arbitrary project-defined structs, arrays, vectors, and aggregate returns are not available that way

Approach:
- generate a small Zig thunk per discovered signature
- let the thunk use the generic marshal layer with the concrete project type at comptime
- call the target function address through that thunk
- return results back as hot bytecode values

First targets:
- by-value struct parameters like `Surface.sizeCallback`
- aggregate returns like `ghostty_surface_size`
- nested slices / slice-of-slices
- allocator + aggregate return paths like `Surface.selectionString`

Status:
- In progress.
- Done so far:
  - compiler-owned typed thunk loader/compiler in:
    - `/Users/pfeodrippe/dev/ghostty/vendor/zig/lib/compiler/hot/typed_thunk.zig`
  - hot module root for generated thunks in:
    - `/Users/pfeodrippe/dev/ghostty/vendor/zig/lib/compiler/hot/hot_root.zig`
  - bundle fallback to typed thunks for unsupported signatures
  - passing typed-thunk test for by-value struct parameters
  - passing bundle parse fallback test for hidden aggregate returns

### 7. End-to-End Verification

Re-verify the live Ghostty flow after the compiler changes.

- Keep `make hot-run` working.
- Keep `/Users/pfeodrippe/dev/ghostty/hot-smoke-test.sh` passing.
- Add at least one new smoke assertion using one of the newly supported function classes.

## Immediate Work Items

1. Implement the richer bytecode values and parser.
2. Replace the fixed-arity invoke path.
3. Add type-descriptor support for enums, structs, slices, and allocator values.
4. Add regression tests before moving to the next unsupported class.
5. Re-run hot Ghostty and validate one real newly supported call per class.
