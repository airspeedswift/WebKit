public import WebCore_Private

// Swift island for the HTML tokenizer's state machine, mirroring HTMLTokenizer.cpp.
//
// A loop and a switch, at parity with the C++'s goto threading because the optimizer
// threads `state = .x; continue` where it sits adjacent to the switch — which is why the
// advance idiom is repeated at each transition site rather than centralised, that being
// 3x slower. The token is owned here and reused via clear(), read through a `borrow`
// accessor so there is no copy per token, and held in UniqueArray rather than Array to
// avoid the CoW uniqueness check.
//
// The island does not take a SegmentedString: that type deletes its copy and move
// constructors, so Swift cannot represent it. C++ hands over a contiguous span, which
// `SegmentedString::currentSubstringSpan8()` already returns, and drives this.
//
// The state machine and token are zero-`unsafe`; the only `unsafe` is the C++ span
// conversion at the entry point. Twelve trap-guarding branches remain, none reachable,
// all in inlined stdlib code, and none removable from here without `unsafe`: eight are
// stdlib layering (SITE A and B below), four are missed optimizations (SITE C and D).
// Together worth 6.3%, of which A and B are 2.9%. Reproducers and the three filed
// reports: ~/Documents/swift-runtime-check-scrub/, summarised in adoption notes §8, §10.

public enum HTMLTokenizerSwiftState {
    case data, tagOpen, endTagOpen, tagName
    case beforeAttributeName, attributeName, afterAttributeName
    case beforeAttributeValue, attributeValueDoubleQuoted
    case attributeValueSingleQuoted, attributeValueUnquoted
    case afterAttributeValueQuoted, selfClosingStartTag
}

@inline(always) private func isTokenizerWhitespace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0C
}
@inline(always) private func isASCIIAlphaByte(_ c: UInt8) -> Bool {
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
        // SITE B: `removeAll()` traps on `count <= capacity`, a type invariant.
        // `_RigidArray.removeAll()` forms a bounds-checked slice purely to
        // `deinitialize()` it, a no-op for `UInt8`, so only the check survives. Must stay
        // from here — this is the only API that empties a `UniqueArray` while keeping its
        // capacity — and is paid once per token.
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
        // Locals, not stored properties: as properties they are re-read through memory
        // on every access, which defeats the jump threading that makes loop+switch match
        // goto. Written back on exit.
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
                // SITE D: `extracting` re-validates both bounds, which hold but need
                // an induction fact across the loop exit. The only formulation that
                // drops it is `@unsafe`, and clamping trades it for a Range check;
                // measured at zero, being once per text run. SITE A applies to the
                // append too, its capacity check being redundant with the
                // `_ensureFreeCapacity` above.
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
                    // SITE A, and likewise at the two other single-byte appends
                    // below. `UniqueArray.append(_:)` tests `!isFull` to pick its
                    // arm and `_RigidArray.append(_:)` re-tests it, redundantly on
                    // both. No safe API appends without it. The per-byte cost, and
                    // the bulk of the 2.9%.
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
                // SITE C: the only two `data[offset]` reads of ~25 in this function
                // whose bounds check survives. This state is entered from two others,
                // so jump threading makes two copies of the guard below, canonicalises
                // one signed and one unsigned, then tail-merges them into a block
                // neither copy's fact discharges — a consequence of the very threading
                // this shape depends on, and not chosen at this level.
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

/// `@frozen` for the same reason `CSSTokenizeResultSwift` carries it: WebCore
/// compiles Swift with -enable-library-evolution, and without it an exposed struct
/// is resilient, so the generated C++ class wraps a heap-allocated opaque box and
/// its `sizeof()` is meaningless.
@frozen
@_expose(Cxx)
public struct HTMLTokenizeResult {
    public var tokenCount: Int = 0
    public var nameChecksum: UInt64 = 0

    public init() {}
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
