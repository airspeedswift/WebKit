public import WebCore_Private

// Swift island for the HTML tokenizer's state machine.
//
// Design notes (see ~/Documents/webkit-swift-adoption-notes.md §8):
//  * §8a  loop+switch is at parity with C++ goto threading, because the optimizer
//         threads `state = .x; continue` when it sits adjacent to the switch.
//         Therefore the advance idiom is repeated at each transition site rather
//         than centralised — centralising it is 3x slower (§8b).
//  * §8c  the token is owned by the tokenizer and reused via clear(); callers read
//         it through an SE-0507 `borrow` accessor, so there is no copy per token.
//         UniqueArray, not Array: no CoW uniqueness check, and removeAll() keeps
//         capacity so refilling is allocation-free.
//  * §8g  the island does NOT take a SegmentedString: that type deletes both its
//         copy and move constructors so Swift cannot represent it. C++ hands over
//         a contiguous span (SegmentedString::currentSubstringSpan8() already
//         returns exactly that) and drives this.
//
// The state machine and token are zero-`unsafe`. The single `unsafe` is the
// C++ span conversion at the entry point — see the TODO there.
//
// Runtime-check scrub (§10). Enumerated from the emitted arm64, not from reading
// the code. This file has zero retain/release, zero CoW uniqueness checks, zero
// `swift_once`, zero exclusivity checks, zero allocations and zero outlined
// value-witness calls. What remains is 12 conditional branches into trap blocks,
// none of which is reachable, all of which are in stdlib code inlined into this
// file, and none of which can be removed from here without introducing `unsafe`:
//
//   5   `_RigidArray.append(_:)` — `_precondition(!isFull)`, already established
//       by `UniqueArray.append(_:)` on both of its arms.  [SITE A, stdlib bug]
//   3   `_RigidArray._items` — bounds-checks a slice formed only to
//       `deinitialize()` it, a no-op for `UInt8`.         [SITE B, stdlib bug]
//   2   `Span._checkIndex` — the source guard immediately above re-emitted; jump
//       threading duplicated the guard, canonicalised the copies to different
//       signedness, then tail-merged them.               [SITE C, optimizer bug]
//   2   `Span.extracting(Range)` — needs the induction fact that `runEnd` came
//       from a loop bounded by `count`.                   [SITE D, optimizer bug]
//
// A and B are stdlib layering, fixable in `UniqueArray`/`_RigidArray` without any
// optimizer change; C and D are missed optimizations. The C++ control discharges
// C's equivalent check at every site, so C is a Swift-vs-C++ gap on identical
// source logic, not an inherent cost of the check.
//
// Measured cost, standalone A/B on the same 8 MiB of markup, median of 17
// interleaved runs: removing all 12 is worth 6.3% (`-Ounchecked` control), of
// which 2.9% is SITE A + SITE B alone (matched control that changes nothing but
// those checks). SITE D measured at zero — it is once per text run, not per byte.
//
// Reproducers and the three bug reports: ~/Documents/swift-runtime-check-scrub/,
// summarised in the notes §10. Each site below is marked with its letter.

public enum HTMLTokenizerSwiftState {
    case data, tagOpen, endTagOpen, tagName
    case beforeAttributeName, attributeName, afterAttributeName
    case beforeAttributeValue, attributeValueDoubleQuoted
    case attributeValueSingleQuoted, attributeValueUnquoted
    case afterAttributeValueQuoted, selfClosingStartTag
}

@inline(__always) private func isTokenizerWhitespace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0C
}
@inline(__always) private func isASCIIAlphaByte(_ c: UInt8) -> Bool {
    ((c | 0x20) >= 0x61) && ((c | 0x20) <= 0x7A)
}

/// A token, owning its buffers so they can be cleared and refilled in place.
public struct HTMLTokenSwift: ~Copyable {
    public enum Kind: UInt8 { case uninitialized = 0, startTag, endTag, character }

    public var kind: Kind = .uninitialized
    public var name = UniqueArray<UInt8>()
    public var attributeCount = 0
    public var selfClosing = false

    public init() {}

    /// Mirrors HTMLToken::clear(): resets without releasing capacity.
    public mutating func clear() {
        kind = .uninitialized
        attributeCount = 0
        selfClosing = false
        // SITE B (§10): `removeAll()` traps on `count <= capacity`, a type
        // invariant. `_RigidArray.removeAll()` forms `_items` — a bounds-checked
        // slice — purely to `deinitialize()` it, which is a no-op for `UInt8`, so
        // only the check survives. The check exists because `_items` uses
        // `UnsafeMutableBufferPointer.extracting(_: Range)`, which is a deliberate
        // `@safe` overload carrying a release-enabled `_precondition`, rather than the
        // `extracting(unchecked:)` sibling. Must stay from here: this is the only API
        // that empties a `UniqueArray` while keeping its capacity, and the fact it
        // needs is not published to the optimizer. Paid once per token.
        name.removeAll()
    }
}

public struct HTMLTokenizerSwift: ~Copyable {
    private var token = HTMLTokenSwift()
    private var state = HTMLTokenizerSwiftState.data
    private var offset = 0

    public init() {}

    /// Borrowing view of the token the tokenizer owns. SE-0507 `borrow`, not a
    /// coroutine accessor: no `yielding` overhead is needed to expose a stored
    /// property.
    public var currentToken: HTMLTokenSwift { borrow { token } }

    public var consumedOffset: Int { offset }

    /// Advances until a token completes. Returns true when `currentToken` holds
    /// one, false when the input ran out first.
    public mutating func nextToken(_ data: Span<UInt8>) -> Bool {
        token.clear()
        let count = data.count
        // state and offset are copied into locals for the loop. As stored
        // properties of self they are re-read through memory on every access,
        // which defeats the jump threading that makes loop+switch match goto
        // (§8a) — that benchmark used locals. Written back on exit.
        var state = self.state
        var offset = self.offset
        defer { self.state = state; self.offset = offset }
        if offset >= count { return false }
        var character = data[offset]

        while true {
            switch state {
            case .data:
                if character == 0x3C {
                    offset &+= 1; if offset >= count { return false }
                    character = data[offset]; state = .tagOpen; continue
                }
                // Bulk-copy the plain-text run rather than appending per byte.
                // Mirrors findPlainTextInDataState() in HTMLTokenizer.cpp, and is
                // the §6e lesson: UniqueArray.append(copying: Span) hands the copy
                // to memcpy, where per-element append pays a bounds check each time.
                token.kind = .character
                var runEnd = offset
                while runEnd < count, data[runEnd] != 0x3C { runEnd &+= 1 }
                // SITE D (§10): `extracting` re-validates both bounds against
                // `count`. Both hold — `runEnd` starts at `offset` and the loop
                // above exits at `count` — but proving it needs the induction fact
                // across the loop exit. Must stay: `extracting(unchecked:)` is the
                // only formulation that drops it and it is `@unsafe`, and clamping
                // with `min`/`max` merely trades these two for a `Range`
                // lowerBound <= upperBound check. Measured cost: zero, because it
                // is once per text run rather than once per byte.
                // SITE A (§10) also applies to the append: one capacity check here
                // is redundant with `_ensureFreeCapacity` immediately above it.
                token.name.append(copying: data.extracting(offset ..< runEnd))
                offset = runEnd
                if offset >= count { return true }
                character = data[offset]; continue

            case .tagOpen:
                if character == 0x2F {
                    offset &+= 1; if offset >= count { return false }
                    character = data[offset]; state = .endTagOpen; continue
                }
                if isASCIIAlphaByte(character) {
                    token.kind = .startTag
                    // SITE A (§10), and likewise at the two other single-byte
                    // appends below. `UniqueArray.append(_:)` tests `!isFull` to
                    // pick its arm, then `_RigidArray.append(_:)` re-tests it —
                    // redundant on the fast arm by negation of the branch taken,
                    // and on the slow arm because the growth just guaranteed it.
                    // Must stay: no safe API appends a single element without it
                    // (`appendAssumingCapacity` carries the same precondition).
                    // This is the per-byte cost, and the bulk of the 2.9%.
                    token.name.append(character | 0x20)
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .tagName; continue
                }
                state = .data; continue

            case .endTagOpen:
                if isASCIIAlphaByte(character) {
                    token.kind = .endTag
                    token.name.append(character | 0x20)
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .tagName; continue
                }
                state = .data; continue

            case .tagName:
                if isTokenizerWhitespace(character) {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .beforeAttributeName; continue
                }
                if character == 0x3E {
                    offset &+= 1; state = .data
                    return true
                }
                if character == 0x2F {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .selfClosingStartTag; continue
                }
                token.name.append(character | 0x20)
                offset &+= 1; if offset >= count { return true }
                character = data[offset]; continue

            case .beforeAttributeName:
                if isTokenizerWhitespace(character) {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; continue
                }
                if character == 0x3E {
                    offset &+= 1; state = .data
                    return true
                }
                token.attributeCount &+= 1
                offset &+= 1; if offset >= count { return true }
                character = data[offset]; state = .attributeName; continue

            case .attributeName:
                if isTokenizerWhitespace(character) {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .afterAttributeName; continue
                }
                if character == 0x3D {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .beforeAttributeValue; continue
                }
                if character == 0x3E {
                    offset &+= 1; state = .data
                    return true
                }
                offset &+= 1; if offset >= count { return true }
                character = data[offset]; continue

            case .afterAttributeName:
                if isTokenizerWhitespace(character) {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; continue
                }
                if character == 0x3D {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .beforeAttributeValue; continue
                }
                if character == 0x3E {
                    offset &+= 1; state = .data
                    return true
                }
                state = .attributeName; continue

            case .beforeAttributeValue:
                if isTokenizerWhitespace(character) {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; continue
                }
                if character == 0x22 {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .attributeValueDoubleQuoted; continue
                }
                if character == 0x27 {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .attributeValueSingleQuoted; continue
                }
                state = .attributeValueUnquoted; continue

            case .attributeValueDoubleQuoted:
                if character == 0x22 {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .afterAttributeValueQuoted; continue
                }
                offset &+= 1; if offset >= count { return true }
                character = data[offset]; continue

            case .attributeValueSingleQuoted:
                if character == 0x27 {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .afterAttributeValueQuoted; continue
                }
                offset &+= 1; if offset >= count { return true }
                character = data[offset]; continue

            case .attributeValueUnquoted:
                if isTokenizerWhitespace(character) {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .beforeAttributeName; continue
                }
                if character == 0x3E {
                    offset &+= 1; state = .data
                    return true
                }
                offset &+= 1; if offset >= count { return true }
                character = data[offset]; continue

            case .afterAttributeValueQuoted:
                // SITE C (§10): the two `data[offset]` reads in this state are the
                // only two of ~25 in this function whose bounds check survives.
                // This is the one state entered from two others
                // (attributeValueDoubleQuoted and attributeValueSingleQuoted), so
                // jump threading makes two copies of the guard below, canonicalises
                // one to a signed and one to an unsigned compare, then tail-merges
                // them — leaving a block that neither copy's fact discharges. Must
                // stay: it is a consequence of the threading §8a depends on, and
                // nothing at this level chooses the canonical form. Reordering the
                // arms or hoisting `offset >= 0` out of the loop does not help.
                if isTokenizerWhitespace(character) {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .beforeAttributeName; continue
                }
                if character == 0x3E {
                    offset &+= 1; state = .data
                    return true
                }
                if character == 0x2F {
                    offset &+= 1; if offset >= count { return true }
                    character = data[offset]; state = .selfClosingStartTag; continue
                }
                state = .beforeAttributeName; continue

            case .selfClosingStartTag:
                if character == 0x3E {
                    token.selfClosing = true
                    offset &+= 1; state = .data
                    return true
                }
                state = .beforeAttributeName; continue
            }
        }
    }
}

// MARK: - C++ entry point
//
// A single POD-in/POD-out function so the C++ side needs no Swift types. Returns
// the token count and a checksum over token names, which is enough for a
// benchmark and for cross-checking against the C++ tokenizer.

@_expose(Cxx)
public struct HTMLTokenizeResult {
    public var tokenCount: Int = 0
    public var nameChecksum: UInt64 = 0
}

/// C++ entry point. Takes the C++ span type directly, because Swift's `Span` is
/// not representable in C++.
///
/// TODO(unsafe): `Span(_unsafeCxxSpan:)` is the one `unsafe` in this island, and
/// it is at the boundary, not the interior. It exists because there is no safe
/// way to receive a `std::span` from C++ — `WTF::BorrowedBytes` is the safe
/// pattern for *bytes* but has no span-shaped equivalent, and
/// `MutableBorrowedBytes` does not exist at all (notes §6d). Per the project
/// rule that a needed `unsafe` is a bug to file, this is a to-file item, not an
/// accepted cost. Come back to it.
@_expose(Cxx)
public func htmlTokenizeSwiftSpan(_ data: WebCore.SegmentedStringSpan8) -> HTMLTokenizeResult {
    var tokenizer = HTMLTokenizerSwift()
    var result = HTMLTokenizeResult()
    let span = unsafe Span<UInt8>(_unsafeCxxSpan: data)
    while tokenizer.nextToken(span) {
        result.tokenCount &+= 1
        let name = tokenizer.currentToken.name.span
        for b in name { result.nameChecksum &+= UInt64(b) }
    }
    return result
}
