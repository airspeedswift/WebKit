# SafeJSC: a stack-rooted, memory-safe Swift API for JavaScriptCore

Status: **rough import**. The code is here so it can be worked on in the WebKit tree. It is not yet part
of the JavaScriptCore build.

## The model

- A JS value is a `~Escapable` `JSRef`. It is valid only while the library frame that roots it is on the
  stack, so JavaScriptCore's conservative stack scan keeps the cell alive.
- Values reach client code through yielding accessors and yield-once functions (`let v = obj["key"]`,
  `let r = try f.call(this: o, args)`). The coroutine frame that yields the value stays suspended on the
  caller's stack while the value is in use, and lifetime dependence stops the value from escaping it.
- Leaves (strings, numbers, booleans, nested `JSDecodable` values) are read and written as Swift values.
- Values the VM roots itself are plain borrowing getters (`vm.global`).
- A value that has to outlive its access is rooted explicitly into a `JSHandle` (`JSValueProtect`).
- Client code needs no `unsafe`. The library is the only code that says it, and strict memory safety is an
  error here.
- Stack-rooting APIs are `noasync`. This is a property of the collector rather than of this API: an async
  function's values may live in its task-allocated async context whenever the compiler chooses, a task
  resumes on any thread in the cooperative pool, and the conservative scan covers only the stacks of
  threads that took the API lock. JS access from async code is therefore unsound whatever API is used,
  including the C API, which gives no diagnostic for it. Async code crosses into JS through a JS-thread
  executor and two-phase promise settlement (`Async.swift`).

## Layout

| Path | What |
|---|---|
| `SafeJSC/` | The library: `Core`, `JSRef`, `Typed` (typed references `JSObject`, `JSCallable`, `JSArray`, `JSPromise`), `Roots+VM` (`JSVM`, `JSHandle`), `Convertible` (Swift ↔ JS), `HostFunctions`, `Async`, `ObjCBridge` (sharing a context with ObjC-API code), `Raw` |
| `CJSCKeepAlive/` | A one-instruction keep-alive the library uses to pin a root, and the header of the internals backend |
| `Internals/` | An optional backend on JavaScriptCore internals (lock and identifier fast paths), built against one WebKit build and found at run time; `build-internals.sh` |
| `Package.swift` | A stand-alone SwiftPM package, for now |

## Building (for now)

The library needs throwing yielding accessors and yield-once functions, which today means a
coroutine-enhanced Swift 6.5-dev toolchain:

    SWIFT_EXEC=<toolchain>/bin/swiftc swift build -c release --disable-sandbox --build-system native

It links the system JavaScriptCore, or a WebKit-built one via `DYLD_FRAMEWORK_PATH`.

## Integration plan (next)

1. **Into the JavaScriptCore Swift overlay.** `Source/JavaScriptCore/JavaScriptCore.swift` already makes
   the Swift module shadow the Clang module under `JSC_SUPPORTS_SWIFT`. SafeJSC's files become part of
   that module, presumably as a separate `JavaScriptCore.Safe` namespace or a submodule, with the
   experimental features enabled in `Configurations/JavaScriptCore.xcconfig` only for these files.
2. **Library evolution.** The framework builds with `BUILD_LIBRARY_FOR_DISTRIBUTION = YES`. Resilient
   clients call yielding accessors through the legacy `_read` ABI until the `CoroutineAccessors` feature
   has a real availability, which puts the frame on the heap where the stack scan cannot see it. Until
   then, the types that yield values need `@frozen` and their accessors `@inlinable`. The non-escaping
   copy-out of an address-only yield is dependence-checked (a separate Swift fix).
3. **The internals backend becomes in-framework code.** Inside JavaScriptCore it can call
   `JSLockHolder` and the identifier table directly, instead of being loaded with `dlsym`. `CJSCKeepAlive`
   becomes a private header.
4. **Tests and benchmarks.** Add API tests next to `API/tests`, and a stand-alone benchmark against the C
   API floor.
5. **License headers** on every file.
