# Next session: run layout tests against the five Swift conversions

Written 2026-09-21 at the end of the conversion session. Everything below is committed;
the worktree is clean apart from build logs. Nothing has been pushed and no PR exists.

## State

| | |
|---|---|
| worktree | `/Users/ben/src/wk-coalesce` |
| branch | `keyed-coder-swift` |
| base | `b46287a4f505` (tip of `webgpu-island-coalescence`) |
| tracked changes | none — clean |
| disk | 150 GiB free (92% used). A full rebuild plus layout-test results fits, but do not start a second build tree. |

Five commits, oldest first:

```
e9f9477d70fc  Implement WKKeyedCoder in Swift behind ENABLE(KEYED_CODER_SWIFT)
7c8132cf2ee5  Turn on ENABLE(KEYED_CODER_SWIFT) for macOS, and stop trusting the header's key type
5cfb2dd2817f  Implement WebActionDisablingCALayerDelegate in Swift, and let WebCore's Swift see its gates
f525b1588fd5  Implement the CoreVideo pixel-format tables in Swift
bc492506b0ef  Implement the key-event character tables in Swift
```

**All four gates default to ON for macOS** (`PLATFORM(MAC) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 260500`),
declared in `Source/WTF/wtf/PlatformEnableCocoa.h`:
`ENABLE_KEYED_CODER_SWIFT`, `ENABLE_ACTION_DISABLING_DELEGATE_SWIFT`,
`ENABLE_SHAREABLE_CV_PIXEL_FORMAT_SWIFT`, `ENABLE_KEY_EVENT_TABLES_SWIFT`.
So a default build of this branch **is** the Swift arm. That is the point of the exercise.

## Why this session exists

Every conversion is verified against the code it replaced — symbol tables, full-domain
differentials, `dlopen` harnesses. **None of it has run in a browser.** Five commits touch
IPC serialisation for PassKit and `NSURLCredential`, the keyboard event path, compositing
layer actions, and GPU-process pixel-format marshalling, with the gates on by default.

A unit differential cannot catch a wiring mistake. This branch already produced one: the
gate reached C++ but not swiftc, so the C++ arm compiled out, the Swift arm compiled away,
and the class left the framework entirely — caught only because an unrelated translation
unit referenced it and the *link* failed. A class with no external caller would have linked
clean and been absent at runtime. That is the class of bug layout tests exist to find.

## First: rebuild the tools stage

`WebKitBuild/Release/WebKitTestRunner` is dated **Sep 20 07:12** and every commit above is
from **Sep 21**. It is stale and will test the wrong binary.

```
swarmly_call pi.unsandboxed/build_wk_coalesce {"gate":"on","stage":"all","log":"build-for-layout-tests.log"}
```

### Three traps with that binding, all hit this session

1. **`gate` is not your gate.** That argument controls `ENABLE_WEBGPU_SWIFT` for an
   unrelated experiment. `gate:"off"` passes `ENABLE_WEBGPU_SWIFT=` and does nothing to the
   four gates above. Always pass `gate:"on"` here. To flip a conversion's gate you edit
   `PlatformEnableCocoa.h` — insert `#define ENABLE_X 0` above its `#if !defined(...)` block,
   build, then remove it. That is how both arms were verified for each commit.
2. **The call can return empty while `xcodebuild` is still running.** Happened once. If the
   result is empty or the log tail shows a mid-build compile line, poll the log until
   `BUILD SUCCEEDED` or `BUILD FAILED` appears; do not read an empty return as success.
3. `stage:"all"` builds frameworks then the three tool projects. `TestWebKitAPI` is
   deliberately excluded — its `Testing.framework` embed phase fails under confinement and
   nothing here needs it.

## Then: run the suites

`pi.unsandboxed/run_webgpu_layout_tests` takes a `tests` argument, so it works for any path
despite the name. It needs unsandboxed exec: confined, every test reports CRASH because the
web content process cannot be granted its sandbox extensions, which says nothing about the
tree. Re-grant with `swarmly unsandbox` if it has lapsed.

```
swarmly_call pi.unsandboxed/run_webgpu_layout_tests {"label":"keyevents","tests":"fast/events"}
```

| suite | tests | exercises | why |
|---|---|---|---|
| `fast/events` | 1212 (81 named `*key*`) | `bc492506b0ef` | the DOM `key` and `keyIdentifier` values now come from Swift tables through an `@_cdecl` returning static storage |
| `http/tests/ssl/applepay` | 21 | `e9f9477d70fc`, `7c8132cf2ee5` | PassKit types serialise through `WKKeyedCoder`, whose fifteen members are now Swift |
| `compositing` | 1243 | `5cfb2dd2817f` | `WebActionDisablingCALayerDelegate` suppresses implicit animations; if its `NSNull` contract broke, layers animate when they should not |
| `media` | 1467 | `f525b1588fd5` | `ShareableCVPixelFormat` marshals pixel formats to the GPU process |

Start with `fast/events` and `http/tests/ssl/applepay` — smallest blast radius per minute and
they cover the two conversions with real logic. `compositing` and `media` are large and
slower; run them if the first two are clean.

**Get a baseline.** These suites have pre-existing failures unrelated to this branch. Either
run each suite on `b46287a4f505` first and diff, or judge only `report`-flagged regressions —
the binding already filters to those, and its docstring explains why comparing `actual`
against `expected` as strings gives a wrong answer (TEXT/IMAGE/AUDIO are all kinds of FAIL,
which once turned 1 real regression into 31 apparent ones).

## What would invalidate what is committed

- Any `fast/events` key regression → the key tables. The differential covered all 65,536
  code points for both functions with zero disagreement, so a failure here is about the
  *boundary*, not the tables: the `@_cdecl` static-storage return, `String::fromLatin1`, or
  the surrogate fallback that deliberately stayed in C++.
- Any `compositing` regression involving unexpected animation → the `NSNull` contract in
  `WebActionDisablingCALayerDelegate`. `NSNull` means "suppress"; `nil` means "no opinion".
  Returning the wrong one re-enables every implicit animation the class exists to suppress.
- An applepay failure → `WKKeyedCoder`. Note `-initWithDictionary:` now filters non-string
  keys rather than trapping; if something depended on a non-string key surviving, this is
  where it shows.

## Known, already-decided, do not re-investigate

- **`String::fromLatin1` vs `"ArrowUp"_s`.** Both allocate a `StringImpl`; the original
  referenced the literal's characters, the port copies ≤16 bytes inline. Real but minor and
  on a human-speed path. `createWithoutCopying(unsafeSpan(name))` restores exact parity but
  trades a `memcpy` for a `strlen` — a wash. Fold it in only if the file is touched anyway.
- **`WebCoreCALayerExtras` was considered and rejected**, on evidence, not omission. See
  `wk.swift/calayer_extras_rejected`.

## After the tests

`wk.swift/survey_remainder` holds what is left of the survey, why each item is ranked where
it is, and what was rejected. Read that rather than re-deriving from the HTML.
