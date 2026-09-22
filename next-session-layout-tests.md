# Layout tests against the five Swift conversions — DONE, clean

Run 2026-09-21/22. **Verdict: no layout-test regression is attributable to any of the five
conversions.** Every unexpected result either reproduces with the gates forced off, or fails
to reproduce on a second run. The branch state is unchanged and the tree is back on the
committed gates, rebuilt and green.

Also in the store as `wk.swift/layout_test_verdict`, which is the copy to read if this file
has drifted.

## What was run

Frameworks and tools were rebuilt first: `WebKitTestRunner` was a day stale and would have
tested the wrong binary. Then four suites gate-on, then the three WebCore gates forced to 0
in `PlatformEnableCocoa.h`, rebuilt, and re-run. Only webkitpy `report`-flagged results were
judged.

| suite | gate-on | gate-off | reading |
|---|---|---|---|
| `http/tests/ssl/applepay` | 21/21 pass | — | `WKKeyedCoder`'s fifteen Swift members carry PassKit IPC unchanged |
| `fast/events` | 1 unexpected | same test, plus one unrelated CRASH | pre-existing |
| `compositing` | 1 unexpected | a *different* backing/animation test | load-sensitive flake |
| `media` | 9 unexpected | 8 of the same, byte-identical output | pre-existing |

### The three failures, individually

- **`fast/events/input-event-insert-link.html`** (TEXT). Expectation says
  `http://www.apple.com`, actual says `https://`. The test dispatches no key event at all —
  it is `execCommand("insertText")` plus automatic link detection. Fails identically with the
  key tables gated off.
- **`compositing/backing/backing-store-attachment-animating-outside-viewport.html`**
  (`backingStoreAttached 1` where `0` was expected). Passes in isolation. The gate-off run
  produced a different member of the same family, `animate-into-view-with-descendant.html`.
  Animation timing under load, not the `NSNull` contract.
- **`media`, 8 pixel tests** (`videorange`, `vp8/vp9` frames, `video-object-fit`,
  `media-source` rendering). `media-video-videorange.html` fails as
  `pixelData[0] >= 253, OBSERVED 252` — a one-off colour-range difference, which is exactly
  what a video-range/full-range mix-up in a pixel-format table would look like, so reasoning
  about the table could not settle it. What settles it: with
  `ENABLE_SHAREABLE_CV_PIXEL_FORMAT_SWIFT` forced to 0 and the Swift thunks confirmed absent
  from the framework, every `-actual.txt` and `-actual.png` is **byte-identical** to the
  gate-on output. The 9th failure (an `audio-session-not-activated` GPU-process CRASH) did
  not recur; the gate-off run threw its own unrelated TIMEOUT instead.

## Traps hit, for whoever flips a gate next

1. **Reverting `PlatformEnableCocoa.h` does not make the Swift files recompile.** The link
   then fails with undefined `_WebCoreKeyIdentifierNameForCharCode`, `_WebCoreKeyNameForCharCode`,
   `_WebCoreShareableCVPixelFormat{From,To}CVPixelFormat` and
   `_OBJC_CLASS_$_WebActionDisablingCALayerDelegate`: the C++ arm is back, the Swift compile was
   never considered dirty. `touch` the three `.swift` files and rebuild.
2. **`WebActionDisablingCALayerDelegate.swift` is in `platform/graphics/cocoa/`,** not in
   `platform/graphics/ca/cocoa/` beside the `.mm`. `touch` on the wrong path silently *creates*
   an empty `.swift` file that then shows as untracked.
3. **Editing a `pi.unsandboxed` binding revokes its unsandbox grant.** The grant is keyed to the
   binding's content: a one-line improvement to `run_webgpu_layout_tests` made the next run
   confined, and confined every test reports CRASH. That read as a 9-test catastrophe until a
   control run of a known-green suite came back 21/21 CRASH. Writing the byte-identical old
   source back restored it. See `wk.swift/unsandbox_grant_is_content_keyed`.
4. **That binding takes one test path.** Several paths joined with spaces is a single path that
   matches nothing, and surfaces as a missing `full_results.json`.

## Next

`wk.swift/survey_remainder` — what is left of the survey. The ranked items are the
`QuartzCoreSPI.h` `#if !__has_feature(modules)` cleanup (infrastructure, unblocks every future
WebCore island needing QuartzCore SPI), the five-adapter prep family (~34 lines of C++ change
unlocking 162), and `attributedStringByStrippingAttachmentCharacters` (28 lines against an
unproven `Unmanaged` object-return boundary).
