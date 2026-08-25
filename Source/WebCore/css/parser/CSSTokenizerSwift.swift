public import WebCore_Private

// Swift island for the CSS tokenizer.
//
// A zero-`unsafe` port of WebCore's CSSTokenizer (Source/WebCore/css/parser/
// CSSTokenizer.cpp + CSSTokenizerInputStream.h), following the island pattern
// established for the HTML tokenizer (notes §8, §10).
//
// Boundary design, and why this needs no new interop feature:
//
//  * Input is a `Span<UInt8>` over the *preprocessed* string. C++ already owns
//    that string (CSSTokenizer::preprocessString) and already hands out
//    contiguous spans.
//  * Output is a POD `CSSTokenSwift` returned by value, one per call. The C++
//    `CSSParserToken` already stores its value as a view into the input
//    (m_valueDataCharRaw + m_valueLength), and the tokenizer already builds it
//    from `m_input.rangeAt(start, length)`, so a token carrying *offsets*
//    loses nothing.
//  * Numbers are NOT converted here. The token carries the number's offsets and
//    C++ calls charactersToDouble as it does today, so double rounding is
//    bit-identical for free, and the island needs no C++ call in its interior
//    (which is where an `unsafe` std::span construction would otherwise land).
//  * Values containing escapes are unescaped *here*, into a buffer the caller
//    provides alongside the token buffer, and the token's range then indexes that
//    buffer rather than the input. The caller only has to turn code units into
//    whatever string type it wants — it never has to re-tokenize, so no part of
//    this component's logic is left in C++.
//
//
// Runtime-check scrub (notes §10 discipline). Enumerated from the emitted arm64,
// not from reading the code. Zero retain/release, zero CoW uniqueness checks,
// zero `swift_once`, zero exclusivity checks, zero allocations (after the one
// block-stack malloc) and zero outlined value-witness calls. What remains is 9
// conditional branches into trap blocks, all in stdlib code inlined here, and
// `-Ounchecked` measures *no* throughput difference from removing them:
//
//   6   `Span._checkIndex` in the two whitespace scans and the digit scan
//       (`advanceUntilNonWhitespace`, `advanceUntilNewlineOrNonWhitespace`,
//       `skipDigits`). Emitted as `b.hs` range checks, four of them sharing one
//       trap block after threading duplicated the loop. `byteAt` below would
//       discharge them, but only pays where the EOF-marker select it performs is
//       wanted anyway — forcing it into these loops, whose own condition already
//       bounds the index, cost 28% on whitespace-heavy input. So they index
//       directly and keep the check, which measures zero.
//       Why the optimizer keeps them is NOT established. Two candidate fixes
//       were tried and refuted: `precondition(offset >= 0)` before the loop, and
//       the same with the index bound to a local first, both of which produce
//       instruction-for-instruction identical code. That is worth knowing because
//       it *does* work when the index is an SSA value rather than one held in
//       memory — see SITE-F.md in ~/Documents/swift-runtime-check-scrub/decoupled/,
//       which also shows the equivalent C is no better, so the miss is in LLVM.
//   1   `Span._checkIndex` in `nextCharsAreIdentifier`, reached from three call
//       sites: jump threading duplicates the guard, canonicalises the copies to
//       different signedness and tail-merges them, leaving a block no copy's
//       fact discharges. Same shape as the HTML island's SITE C. Forcing the
//       function to inline makes it *worse* (three checks, not one).
//   1   `_RigidArray.append(_:)` — `_precondition(!isFull)`, already
//       established by `UniqueArray.append(_:)` on both arms. HTML island
//       SITE A; filed.
//   1   `_RigidArray._items` — bounds-checks a slice formed only to
//       `deinitialize()`, a no-op for `UInt8`. HTML island SITE B; filed.
//
// Measured, standalone A/B against a same-work C++ control on identical input
// (~/src/webkit-swift-ports/cssprobe), medians of interleaved runs:
//
//   whitespace 1.02x   idents 1.04x   strings 1.18x   comments 0.94x
//   punctuation 0.91x  numbers 0.88x  declarations 0.80x
//   yui.css 0.96x      mixed real stylesheets 1.00x
//
// So Swift is at or ahead of C++ wherever a token involves scanning, and behind
// on token-dense input, i.e. the residual is per-token overhead rather than
// per-character. Ruled out as causes, each by measurement: runtime checks (zero
// under `-Ounchecked`), dispatch shape (C++'s member-function-pointer table and
// a switch measure identically), indirect vs register struct return (forcing
// sret is 15% worse), storing the span in the tokenizer instead of passing it
// (3% worse), and iterating a `Span` slice instead of indexing (no better).
//
// In-tree, the island scans at ~700 MB/s where the whole real CSSTokenizer runs
// at ~310 MB/s on the same stylesheet, so scanning is not where that tokenizer
// spends its time and there is headroom for the token materialisation the island
// deliberately leaves in C++.
//
// Validated token-by-token against the real CSSTokenizer, not just against the
// C++ control — see CSSTokenizerSwiftBridge.cpp and CSSTokenizerSwiftTest.cpp.
//
// This file names no C++ type and imports nothing but the standard library:
// the entire interior is Swift-owned, per the §4b' diagnostic. The C++ span
// conversion lives in a separate entry-point file.

/// Mirrors CSSParserTokenType. Raw values match so C++ can cast directly.
public enum CSSTokenTypeSwift: UInt8 {
    case ident = 0, function, atKeyword, hash, url, badUrl, delimiter
    case number, percentage, dimension
    case includeMatch, dashMatch, prefixMatch, suffixMatch, substringMatch, column
    case nonNewlineWhitespace, newline, cdo, cdc
    case colon, semicolon, comma
    case leftParenthesis, rightParenthesis, leftBracket, rightBracket, leftBrace, rightBrace
    case string, badString, endOfFile, comment
}

/// Mirrors CSSParserToken::BlockType.
public enum CSSBlockTypeSwift: UInt8 {
    case notBlock = 0, blockStart, blockEnd
}

/// A tokenizer result. POD by construction: no references, no allocation, no
/// lifetime dependence on the input, so it crosses to C++ as a plain struct.
public struct CSSTokenSwift {
    /// Input offset of the token's first character.
    public var start: UInt32 = 0
    /// Input offset just past the token.
    public var end: UInt32 = 0
    /// The token's value text (ident/at-keyword/hash/string/url name, or the
    /// unit of a dimension), as a range of the input.
    public var valueStart: UInt32 = 0
    public var valueLength: UInt32 = 0
    /// For numeric tokens, the number's text — CSSParserToken's `originalText`,
    /// and the range C++ converts to a double.
    public var numberStart: UInt32 = 0
    public var numberLength: UInt32 = 0
    /// Delimiter code point for `.delimiter`; whitespace run length for
    /// `.nonNewlineWhitespace` (CSSParserToken's nonNewlineWhitespaceCount).
    public var extra: UInt32 = 0

    public var type: UInt8 = CSSTokenTypeSwift.endOfFile.rawValue
    public var blockType: UInt8 = CSSBlockTypeSwift.notBlock.rawValue
    public var flags: UInt8 = 0

    public init() {}
}

/// `CSSTokenSwift.flags` bits. Kept out of the struct so it stays a plain
/// aggregate for `@_expose(Cxx)`; CSSTokenizerSwiftBridge.cpp declares the same
/// values.
enum CSSTokenFlag {
    static let nonInteger: UInt8 = 1 << 0 // NumberValueType, else IntegerValueType
    static let plusSign: UInt8 = 1 << 1 // NumericSign
    static let minusSign: UInt8 = 1 << 2
    static let hashTokenId: UInt8 = 1 << 3 // HashTokenId, else HashTokenUnrestricted
    /// The value's range indexes the unescape buffer handed back alongside the
    /// tokens, rather than the input. Set when the value contained escapes, which
    /// this tokenizer resolves itself; the caller only has to turn the code units
    /// into whatever string type it wants.
    static let unescaped: UInt8 = 1 << 4
}

/// The tokenizer is generic over the code unit so one implementation serves both
/// of `StringImpl`'s representations, as the C++ does by reading everything
/// through `StringImpl::operator[]` as `char16_t`. The difference is that the C++
/// pays an `is8Bit()` branch on every character read, while these specialize.
///
/// Nothing in the tokenizer looks above U+007F except to ask *whether* a unit is
/// ASCII, which is exactly what the CSS syntax spec's name-code-point rule needs,
/// so a per-code-unit port is faithful for 16-bit input too: surrogates are name
/// code points, and preprocessing has already replaced unpaired ones.
protocol CSSCodeUnit: FixedWidthInteger & UnsignedInteger { }
extension UInt8: CSSCodeUnit { }
extension UInt16: CSSCodeUnit { }

// MARK: - Character predicates
//
// Direct ports of CSSParserIdioms.h and the ASCIICType.h helpers the tokenizer
// uses. `@inline(always)`: each is a handful of compares and every one is on
// the per-character path.

@inline(always) private func isASCIIByte(_ c: some CSSCodeUnit) -> Bool { c <= 0x7F }
@inline(always) private func isASCIIDigitByte(_ c: some CSSCodeUnit) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(always) private func isASCIIAlphaByte(_ c: some CSSCodeUnit) -> Bool {
    ((c | 0x20) >= 0x61) && ((c | 0x20) <= 0x7A)
}
@inline(always) private func isASCIIHexDigitByte(_ c: some CSSCodeUnit) -> Bool {
    isASCIIDigitByte(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66)
}
@inline(always) private func hexValue(_ c: some CSSCodeUnit) -> UInt32 {
    // Callers guard with isASCIIHexDigitByte, so both subtractions are in range.
    isASCIIDigitByte(c) ? UInt32(c &- 0x30) : UInt32((c | 0x20) &- 0x61) &+ 10
}
/// isASCIIWhitespace: space, \n, \t, \r, \f — note \v is not included.
@inline(always) private func isASCIIWhitespaceByte(_ c: some CSSCodeUnit) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D || c == 0x0C
}
/// isCSSNewline: \n, \r, \f.
@inline(always) private func isCSSNewlineByte(_ c: some CSSCodeUnit) -> Bool {
    c == 0x0A || c == 0x0D || c == 0x0C
}
/// isNameStartCodePoint: ASCII alpha, '_', or any non-ASCII.
@inline(always) private func isNameStartByte(_ c: some CSSCodeUnit) -> Bool {
    isASCIIAlphaByte(c) || c == 0x5F || !isASCIIByte(c)
}
/// isNameCodePoint: name-start, digit, or '-'.
@inline(always) private func isNameByte(_ c: some CSSCodeUnit) -> Bool {
    isNameStartByte(c) || isASCIIDigitByte(c) || c == 0x2D
}
/// isNonPrintableCodePoint.
@inline(always) private func isNonPrintableByte(_ c: some CSSCodeUnit) -> Bool {
    c <= 0x08 || c == 0x0B || (c >= 0x0E && c <= 0x1F) || c == 0x7F
}

/// A bounds-checked read of the input that costs one unsigned compare.
///
/// `Span`'s subscript checks `0 <= index && index < count`. Every offset in this
/// file is non-negative by construction, but nothing establishes that for the
/// optimizer — the index arrives as a parameter or is loaded from a stored
/// property — so a check survives. Comparing bit patterns as unsigned discharges
/// both halves at once and is not `unsafe`: `UInt(bitPattern:)` is a
/// reinterpretation, and a negative index would fail the compare and read as the
/// EOF marker rather than going out of bounds. Using this on the name scan, the
/// hottest loop here, was worth 26% (994 -> 1279 MB/s, matching `-Ounchecked`).
///
/// NOT caused by the wrapping arithmetic. `&+` versus `+` makes no difference:
/// the two forms compile to the same body, which the minimal reproducer in
/// ~/Documents/swift-runtime-check-scrub/decoupled/ (site-f.swift, site-f.c,
/// SITE-F.md) shows, along with the fact that clang emits an identical loop from
/// equivalent C. So the underlying miss is in LLVM, not in Swift.
///
/// This is the shape C++ gets for free by indexing with `size_t`.
///
/// Use this ONLY where the EOF-marker semantics are wanted anyway. In a loop
/// whose own condition already bounds the index (`while i < count`), the select
/// this performs is pure overhead — measured at 28% on an all-whitespace input —
/// so those loops index directly.
@inline(always) private func byteAt<Unit: CSSCodeUnit>(_ data: Span<Unit>, _ index: Int) -> Unit {
    UInt(bitPattern: index) < UInt(bitPattern: data.count) ? data[index] : 0
}

/// The 128-entry dispatch class. The C++ holds a `std::array<CodePoint, 128>`
/// of *member function pointers* and calls through it once per token
/// (CSSTokenizer::nextToken). Here it is a `switch` on the byte, so the
/// dispatch is a jump table with no indirect call — see the notes for the
/// measured difference.
private enum Dispatch {
    case endOfFile, whitespace, newline, stringStart, hash, dollarSign
    case leftParenthesis, rightParenthesis, asterisk, plusOrFullStop, comma
    case hyphenMinus, solidus, asciiDigit, colon, semiColon, lessThan
    case commercialAt, nameStart, leftBracket, reverseSolidus, rightBracket
    case circumflexAccent, leftBrace, verticalLine, rightBrace, tilde
    case delimiter
}

@inline(always) private func dispatchClass(_ c: some CSSCodeUnit) -> Dispatch {
    // Mirrors CSSTokenizer::codePoints exactly, including that a null entry
    // means DelimiterToken, and that every non-ASCII byte is a name start.
    switch c {
    case 0x00: return .endOfFile
    case 0x09, 0x20: return .whitespace
    case 0x0A, 0x0C, 0x0D: return .newline
    case 0x22, 0x27: return .stringStart // " '
    case 0x23: return .hash
    case 0x24: return .dollarSign
    case 0x28: return .leftParenthesis
    case 0x29: return .rightParenthesis
    case 0x2A: return .asterisk
    case 0x2B, 0x2E: return .plusOrFullStop // + .
    case 0x2C: return .comma
    case 0x2D: return .hyphenMinus
    case 0x2F: return .solidus
    case 0x30...0x39: return .asciiDigit
    case 0x3A: return .colon
    case 0x3B: return .semiColon
    case 0x3C: return .lessThan
    case 0x40: return .commercialAt
    case 0x41...0x5A: return .nameStart
    case 0x5B: return .leftBracket
    case 0x5C: return .reverseSolidus
    case 0x5D: return .rightBracket
    case 0x5E: return .circumflexAccent
    case 0x5F: return .nameStart
    case 0x61...0x7A: return .nameStart
    case 0x7B: return .leftBrace
    case 0x7C: return .verticalLine
    case 0x7D: return .rightBrace
    case 0x7E: return .tilde
    default: return isASCIIByte(c) ? .delimiter : .nameStart
    }
}

/// The result of scanning a name or a quoted value: a range of the input plus
/// whether it contained escapes (in which case C++ unescapes the range).
/// The result of scanning a name or a quoted value.
///
/// Normally a range of the *input*. When the value contained escapes it is instead
/// a range of the tokenizer's unescape buffer, which the caller receives alongside
/// the tokens; `unescaped` says which.
private struct ScannedValue {
    var start: UInt32 = 0
    var length: UInt32 = 0
    var unescaped = false
}

struct CSSTokenizerSwift<Unit: CSSCodeUnit>: ~Copyable {
    /// The input cursor. As in C++ this may advance past the end — `consume()`
    /// on an exhausted input returns the EOF marker and still advances — so
    /// every read clamps and every report goes through `clampedOffset`.
    private var offset = 0
    /// Mirrors m_blockStack. Owned here and growable, so nesting is unbounded and no
    /// buffer has to cross the boundary for it.
    ///
    /// C++ uses `Vector<CSSParserTokenType, 8>`, whose inline capacity keeps shallow
    /// nesting out of the heap, and Swift has no growable container with inline
    /// capacity (§0a item 14). A two-tier `InlineArray` + spill version of this was
    /// tried, on the theory that the block-heavy corpora were paying for the heap
    /// indirection. It showed **no resolvable improvement** — punctuation moved from
    /// 194.3 to 196.1 MB/s while the C++ side drifted 5% the other way, so the
    /// apparent ratio gain was drift — and the extra tier was reverted. See the notes
    /// for what the gap actually tracks.
    private var blockStack = UniqueArray<UInt8>()

    /// Code units of values that contained escapes, in the order the tokens
    /// referring to them were produced. Handed to the caller a chunk at a time as a
    /// `Span`, which is the safe direction across the boundary.
    ///
    /// UTF-16 rather than the input's code unit, because an escape can name any
    /// code point: `\1F3A8` unescapes to a surrogate pair even in 8-bit input.
    private var unescaped = UniqueArray<UInt16>()
    /// Appends one code point, UTF-16 encoded. The buffer is this type's own and
    /// grows, so there is no capacity to overflow and no rewind protocol.
    @inline(always) private mutating func appendUnescaped(_ codePoint: UInt32) {
        if codePoint > 0xFFFF {
            let value = codePoint &- 0x10000
            unescaped.append(UInt16(truncatingIfNeeded: 0xD800 &+ (value >> 10)))
            unescaped.append(UInt16(truncatingIfNeeded: 0xDC00 &+ (value & 0x3FF)))
            return
        }
        unescaped.append(UInt16(truncatingIfNeeded: codePoint))
    }

    @inline(always) private mutating func appendUnescaped(unit: Unit) {
        appendUnescaped(UInt32(truncatingIfNeeded: unit))
    }

    /// Range of the unescape buffer filled since `mark`, for a value that has just
    /// been unescaped into it.
    @inline(always) private func unescapedValue(since mark: Int) -> ScannedValue {
        ScannedValue(
            start: UInt32(truncatingIfNeeded: mark),
            length: UInt32(truncatingIfNeeded: unescaped.count &- mark),
            unescaped: true)
    }

    public init() {}

    public var consumedOffset: Int { offset }

    /// Restores the cursor and block stack saved by `saveState`, so C++ can drive
    /// tokenization in cache-sized chunks without holding a Swift value across
    /// calls (it cannot: this type is `~Copyable`).
    /// The unescaped code units produced since the last `startChunk()`.
    var unescapedUnits: Span<UInt16> { unescaped.span }

    /// Drops the previous chunk's unescaped units, so token value ranges are always
    /// offsets into the chunk currently being handed over.
    mutating func startChunk() { unescaped.removeAll() }

    // MARK: Input stream — CSSTokenizerInputStream
    //
    // Note what is NOT here: the C++ reads every character through
    // `StringImpl::operator[]`, which branches on is8Bit() per access. This
    // island is monomorphic on the element type, so that branch does not exist.
    // The C++ control in the benchmark is monomorphic too, so the comparison
    // does not credit Swift for it; it is recorded separately as a C++ finding.

    @inline(always) private func peek(_ data: Span<Unit>, _ lookahead: Int) -> Unit {
        // Wrapping add: `offset` is at most `data.count + 1` and `lookahead` is a
        // small literal, so the sum cannot overflow for any span that exists.
        // This is the single most executed line in the island, so the check is
        // worth discharging by construction rather than leaving to the optimizer.
        // Mirrors CSSTokenizerInputStream::peek: past the end reads as the EOF
        // marker (NUL). Preprocessing has already removed real NULs.
        return byteAt(data, offset &+ lookahead)
    }

    @inline(always) private mutating func consume(_ data: Span<Unit>) -> Unit {
        let c = peek(data, 0)
        offset &+= 1
        return c
    }

    @inline(always) private mutating func advance(_ n: Int = 1) { offset &+= n }
    @inline(always) private mutating func reconsume() { offset &-= 1 }

    /// CSSTokenizerInputStream::offset() clamps: the cursor may be one past the
    /// end after consuming the EOF marker.
    @inline(always) private func clampedOffset(_ data: Span<Unit>) -> Int {
        offset < data.count ? offset : data.count
    }

    private mutating func advanceUntilNonWhitespace(_ data: Span<Unit>) {
        var i = offset
        let count = data.count
        while i < count, isASCIIWhitespaceByte(data[i]) { i &+= 1 }
        offset = i
    }

    private mutating func advanceUntilNewlineOrNonWhitespace(_ data: Span<Unit>) {
        var i = offset
        let count = data.count
        while i < count, isASCIIWhitespaceByte(data[i]) {
            if isCSSNewlineByte(data[i]) { break }
            i &+= 1
        }
        offset = i
    }

    @inline(always) private mutating func consumeIfNext(_ data: Span<Unit>, _ c: Unit) -> Bool {
        if peek(data, 0) == c {
            advance()
            return true
        }
        return false
    }

    @inline(always) private func twoCharsAreValidEscape(_ first: Unit, _ second: Unit) -> Bool {
        first == 0x5C && !isCSSNewlineByte(second)
    }

    private func nextTwoCharsAreValidEscape(_ data: Span<Unit>) -> Bool {
        twoCharsAreValidEscape(peek(data, 0), peek(data, 1))
    }

    // MARK: Token construction helpers

    @inline(always) private func token(
        _ type: CSSTokenTypeSwift, _ start: Int, _ data: Span<Unit>,
        block: CSSBlockTypeSwift = .notBlock
    ) -> CSSTokenSwift {
        var t = CSSTokenSwift()
        t.type = type.rawValue
        t.blockType = block.rawValue
        t.start = UInt32(truncatingIfNeeded: start)
        t.end = UInt32(truncatingIfNeeded: clampedOffset(data))
        return t
    }

    @inline(always) private func delimiter(_ c: Unit, _ start: Int, _ data: Span<Unit>) -> CSSTokenSwift {
        var t = token(.delimiter, start, data)
        t.extra = UInt32(truncatingIfNeeded: c)
        return t
    }

    @inline(always) private func valueToken(
        _ type: CSSTokenTypeSwift, _ value: ScannedValue, _ start: Int, _ data: Span<Unit>,
        block: CSSBlockTypeSwift = .notBlock
    ) -> CSSTokenSwift {
        var t = token(type, start, data, block: block)
        t.valueStart = value.start
        t.valueLength = value.length
        if value.unescaped { t.flags |= CSSTokenFlag.unescaped }
        return t
    }

    @inline(always) private mutating func pushBlock(_ type: CSSTokenTypeSwift) {
        blockStack.append(type.rawValue)
    }

    private mutating func blockStart(
        _ type: CSSTokenTypeSwift, _ start: Int, _ data: Span<Unit>
    ) -> CSSTokenSwift {
        pushBlock(type)
        return token(type, start, data, block: .blockStart)
    }

    private mutating func blockEnd(
        _ type: CSSTokenTypeSwift, _ startType: CSSTokenTypeSwift, _ start: Int, _ data: Span<Unit>
    ) -> CSSTokenSwift {
        // The unsigned compare both bounds-checks and tests for an empty stack.
        let top = blockStack.count &- 1
        if UInt(bitPattern: top) < UInt(bitPattern: blockStack.count),
           blockStack[top] == startType.rawValue {
            _ = blockStack.removeLast()
            return token(type, start, data, block: .blockEnd)
        }
        return token(type, start, data)
    }

    // MARK: - The tokenizer

    /// Returns the next token; `.endOfFile` when the input is exhausted.
    /// Mirrors CSSTokenizer::nextToken.
    mutating func nextToken(_ data: Span<Unit>) -> CSSTokenSwift {
        let start = clampedOffset(data)
        let cc = consume(data)

        switch dispatchClass(cc) {
        case .endOfFile:
            return token(.endOfFile, start, data)

        case .whitespace:
            // CSSTokenizer::whitespace: the count includes the character just
            // consumed, and stops at a newline so newlines tokenize separately.
            let runStart = clampedOffset(data)
            advanceUntilNewlineOrNonWhitespace(data)
            var t = token(.nonNewlineWhitespace, start, data)
            t.extra = UInt32(truncatingIfNeeded: 1 &+ (clampedOffset(data) &- runStart))
            return t

        case .newline:
            return token(.newline, start, data)

        case .stringStart:
            return consumeStringTokenUntil(data, cc, start)

        case .hash:
            let next = peek(data, 0)
            if isNameByte(next) || twoCharsAreValidEscape(next, peek(data, 1)) {
                let isId = nextCharsAreIdentifier(data)
                let name = consumeName(data)
                var t = valueToken(.hash, name, start, data)
                if isId { t.flags |= CSSTokenFlag.hashTokenId }
                return t
            }
            return delimiter(cc, start, data)

        case .dollarSign:
            if consumeIfNext(data, 0x3D) { return token(.suffixMatch, start, data) }
            return delimiter(cc, start, data)

        case .leftParenthesis:
            return blockStart(.leftParenthesis, start, data)

        case .rightParenthesis:
            return blockEnd(.rightParenthesis, .leftParenthesis, start, data)

        case .asterisk:
            if consumeIfNext(data, 0x3D) { return token(.substringMatch, start, data) }
            return delimiter(cc, start, data)

        case .plusOrFullStop:
            if nextCharsAreNumber(data, cc) {
                reconsume()
                return consumeNumericToken(data, start)
            }
            return delimiter(cc, start, data)

        case .comma:
            return token(.comma, start, data)

        case .hyphenMinus:
            if nextCharsAreNumber(data, cc) {
                reconsume()
                return consumeNumericToken(data, start)
            }
            if peek(data, 0) == 0x2D, peek(data, 1) == 0x3E { // -->
                advance(2)
                return token(.cdc, start, data)
            }
            if nextCharsAreIdentifier(data, cc) {
                reconsume()
                return consumeIdentLikeToken(data, start)
            }
            return delimiter(cc, start, data)

        case .solidus:
            if consumeIfNext(data, 0x2A) { // /*
                consumeUntilCommentEndFound(data)
                return token(.comment, start, data)
            }
            return delimiter(cc, start, data)

        case .asciiDigit:
            reconsume()
            return consumeNumericToken(data, start)

        case .colon:
            return token(.colon, start, data)

        case .semiColon:
            return token(.semicolon, start, data)

        case .lessThan:
            if peek(data, 0) == 0x21, peek(data, 1) == 0x2D, peek(data, 2) == 0x2D { // <!--
                advance(3)
                return token(.cdo, start, data)
            }
            return delimiter(cc, start, data)

        case .commercialAt:
            if nextCharsAreIdentifier(data) {
                let name = consumeName(data)
                return valueToken(.atKeyword, name, start, data)
            }
            return delimiter(cc, start, data)

        case .nameStart:
            reconsume()
            return consumeIdentLikeToken(data, start)

        case .leftBracket:
            return blockStart(.leftBracket, start, data)

        case .reverseSolidus:
            if twoCharsAreValidEscape(cc, peek(data, 0)) {
                reconsume()
                return consumeIdentLikeToken(data, start)
            }
            return delimiter(cc, start, data)

        case .rightBracket:
            return blockEnd(.rightBracket, .leftBracket, start, data)

        case .circumflexAccent:
            if consumeIfNext(data, 0x3D) { return token(.prefixMatch, start, data) }
            return delimiter(cc, start, data)

        case .leftBrace:
            return blockStart(.leftBrace, start, data)

        case .verticalLine:
            if consumeIfNext(data, 0x3D) { return token(.dashMatch, start, data) }
            if consumeIfNext(data, 0x7C) { return token(.column, start, data) }
            return delimiter(cc, start, data)

        case .rightBrace:
            return blockEnd(.rightBrace, .leftBrace, start, data)

        case .tilde:
            if consumeIfNext(data, 0x3D) { return token(.includeMatch, start, data) }
            return delimiter(cc, start, data)

        case .delimiter:
            return delimiter(cc, start, data)
        }
    }

    // MARK: Numbers

    /// Mirrors CSSTokenizer::consumeNumber, which merges the spec's
    /// consume-a-number with convert-a-string-to-a-number. The conversion
    /// itself is deliberately left to C++ (see the file comment).
    private mutating func consumeNumber(_ data: Span<Unit>, _ start: Int) -> CSSTokenSwift {
        let startOffset = clampedOffset(data)

        var nonInteger = false
        var signFlag: UInt8 = 0
        var length = 0

        var next = peek(data, 0)
        if next == 0x2B {
            length &+= 1
            signFlag = CSSTokenFlag.plusSign
        } else if next == 0x2D {
            length &+= 1
            signFlag = CSSTokenFlag.minusSign
        }

        // Wrapping throughout: `length` counts characters of a number that has
        // already been found to start at the cursor, so it is bounded by the
        // input length.
        length = skipDigits(data, from: length)
        next = peek(data, length)
        if next == 0x2E, isASCIIDigitByte(peek(data, length &+ 1)) {
            nonInteger = true
            length = skipDigits(data, from: length &+ 2)
            next = peek(data, length)
        }

        if next == 0x45 || next == 0x65 { // E e
            next = peek(data, length &+ 1)
            if isASCIIDigitByte(next) {
                nonInteger = true
                length = skipDigits(data, from: length &+ 1)
            } else if next == 0x2B || next == 0x2D, isASCIIDigitByte(peek(data, length &+ 2)) {
                nonInteger = true
                length = skipDigits(data, from: length &+ 3)
            }
        }

        advance(length)

        var t = token(.number, start, data)
        // CSSParserToken's originalText for a number is the whole consumed run,
        // which is also exactly the range C++ hands to charactersToDouble.
        t.numberStart = UInt32(truncatingIfNeeded: startOffset)
        t.numberLength = UInt32(truncatingIfNeeded: clampedOffset(data) &- startOffset)
        if nonInteger { t.flags |= CSSTokenFlag.nonInteger }
        t.flags |= signFlag
        return t
    }

    /// CSSTokenizerInputStream::skipWhilePredicate<isASCIIDigit>: `from` and the
    /// result are offsets relative to the cursor, not absolute.
    @inline(always) private func skipDigits(_ data: Span<Unit>, from: Int) -> Int {
        var relative = from
        let count = data.count
        // Per-digit, so wrapping: `offset &+ relative` is bounded by the input.
        while offset &+ relative < count, isASCIIDigitByte(data[offset &+ relative]) {
            relative &+= 1
        }
        return relative
    }

    /// Mirrors CSSTokenizer::consumeNumericToken.
    private mutating func consumeNumericToken(_ data: Span<Unit>, _ start: Int) -> CSSTokenSwift {
        var t = consumeNumber(data, start)
        if nextCharsAreIdentifier(data) {
            let unit = consumeName(data)
            t.type = CSSTokenTypeSwift.dimension.rawValue
            t.valueStart = unit.start
            t.valueLength = unit.length
            if unit.unescaped { t.flags |= CSSTokenFlag.unescaped }
        } else if consumeIfNext(data, 0x25) {
            t.type = CSSTokenTypeSwift.percentage.rawValue
        }
        t.end = UInt32(truncatingIfNeeded: clampedOffset(data))
        return t
    }

    // MARK: Identifiers

    /// Mirrors CSSTokenizer::consumeIdentLikeToken.
    private mutating func consumeIdentLikeToken(_ data: Span<Unit>, _ start: Int) -> CSSTokenSwift {
        let name = consumeName(data)
        if consumeIfNext(data, 0x28) { // (
            if nameIsURL(data, name) {
                // Matches the C++: whitespace is skipped here rather than
                // emitted, and a quoted argument makes this a function token so
                // the string tokenizes normally.
                advanceUntilNonWhitespace(data)
                let next = peek(data, 0)
                if next != 0x22, next != 0x27 {
                    return consumeURLToken(data, start)
                }
            }
            pushBlock(.leftParenthesis)
            return valueToken(.function, name, start, data, block: .blockStart)
        }
        return valueToken(.ident, name, start, data)
    }

    /// equalLettersIgnoringASCIICase(name, "url"), against either the input or the
    /// unescaped units, so `\75 rl(` is still recognised as a url token.
    private func nameIsURL(_ data: Span<Unit>, _ name: ScannedValue) -> Bool {
        guard name.length == 3 else { return false }
        if name.unescaped {
            let base = Int(name.start)
            guard base &+ 3 <= unescaped.count else { return false }
            return (unescaped[base] | 0x20) == 0x75 // u
                && (unescaped[base &+ 1] | 0x20) == 0x72 // r
                && (unescaped[base &+ 2] | 0x20) == 0x6C // l
        }
        let base = Int(name.start)
        guard base &+ 3 <= data.count else { return false }
        return (byteAt(data, base) | 0x20) == 0x75 // u
            && (byteAt(data, base &+ 1) | 0x20) == 0x72 // r
            && (byteAt(data, base &+ 2) | 0x20) == 0x6C // l
    }

    /// Mirrors CSSTokenizer::consumeName. The fast path returns a range of the
    /// input; the slow path unescapes into the unescape buffer and returns a range
    /// of that.
    private mutating func consumeName(_ data: Span<Unit>) -> ScannedValue {
        let count = data.count
        var i = offset
        while true {
            let cc = byteAt(data, i)
            if isNameByte(cc) {
                i &+= 1
                continue
            }
            // A genuine NUL inside the input is not the EOF marker: the C++
            // sends that case to the slow path, where it terminates the name.
            if cc == 0, i < count { break }
            if cc == 0x5C { break }
            let start = clampedOffset(data)
            offset = i
            return ScannedValue(
                start: UInt32(truncatingIfNeeded: start),
                length: UInt32(truncatingIfNeeded: i &- start),
                unescaped: false)
        }

        // Slow path: the name contains an escape or an embedded NUL. Mirrors the
        // C++ StringBuilder loop, appending to the unescape buffer instead.
        let mark = unescaped.count
        while true {
            let cc = consume(data)
            if isNameByte(cc) {
                appendUnescaped(unit: cc)
                continue
            }
            if twoCharsAreValidEscape(cc, peek(data, 0)) {
                appendUnescaped(consumeEscape(data))
                continue
            }
            reconsume()
            return unescapedValue(since: mark)
        }
    }

    // MARK: Strings

    /// Mirrors CSSTokenizer::consumeStringTokenUntil.
    private mutating func consumeStringTokenUntil(
        _ data: Span<Unit>, _ endingCodePoint: Unit, _ start: Int
    ) -> CSSTokenSwift {
        // Fast path: no escapes, so the value is a range of the input.
        var size = 0
        while true {
            let cc = peek(data, size)
            if cc == endingCodePoint {
                let startOffset = clampedOffset(data)
                advance(size &+ 1)
                var value = ScannedValue()
                value.start = UInt32(truncatingIfNeeded: startOffset)
                value.length = UInt32(truncatingIfNeeded: size)
                return valueToken(.string, value, start, data)
            }
            if isCSSNewlineByte(cc) {
                advance(size)
                return token(.badString, start, data)
            }
            if cc == 0 || cc == 0x5C { break }
            size &+= 1
        }

        // Slow path: unescape into the buffer, exactly as the C++ builds its
        // StringBuilder. A backslash before a newline is a line continuation and
        // contributes nothing; a backslash at EOF likewise.
        let mark = unescaped.count
        while true {
            let cc = consume(data)
            if cc == endingCodePoint || cc == 0 {
                return valueToken(.string, unescapedValue(since: mark), start, data)
            }
            if isCSSNewlineByte(cc) {
                reconsume()
                return token(.badString, start, data)
            }
            if cc == 0x5C {
                if peek(data, 0) == 0 { continue }
                if isCSSNewlineByte(peek(data, 0)) {
                    consumeSingleWhitespaceIfNext(data) // handles \r\n
                } else {
                    appendUnescaped(consumeEscape(data))
                }
            } else {
                appendUnescaped(unit: cc)
            }
        }
    }

    // MARK: URLs

    /// Mirrors CSSTokenizer::consumeURLToken.
    private mutating func consumeURLToken(_ data: Span<Unit>, _ start: Int) -> CSSTokenSwift {
        advanceUntilNonWhitespace(data)

        var size = 0
        while true {
            let cc = peek(data, size)
            if cc == 0x29 { // )
                let startOffset = clampedOffset(data)
                advance(size &+ 1)
                var value = ScannedValue()
                value.start = UInt32(truncatingIfNeeded: startOffset)
                value.length = UInt32(truncatingIfNeeded: size)
                return valueToken(.url, value, start, data)
            }
            if cc <= 0x20 || cc == 0x5C || cc == 0x22 || cc == 0x27 || cc == 0x28 || cc == 0x7F {
                break
            }
            size &+= 1
        }

        // Slow path: unescape into the buffer. Nothing is appended for the
        // terminating character, so a trailing whitespace run before the closing
        // paren does not end up in the value — matching the C++, which simply
        // stops appending to its StringBuilder.
        let mark = unescaped.count
        while true {
            let cc = consume(data)
            if cc == 0x29 || cc == 0 {
                return valueToken(.url, unescapedValue(since: mark), start, data)
            }
            if isASCIIWhitespaceByte(cc) {
                advanceUntilNonWhitespace(data)
                if consumeIfNext(data, 0x29) || peek(data, 0) == 0 {
                    return valueToken(.url, unescapedValue(since: mark), start, data)
                }
                break
            }
            if cc == 0x22 || cc == 0x27 || cc == 0x28 || isNonPrintableByte(cc) { break }
            if cc == 0x5C {
                if twoCharsAreValidEscape(cc, peek(data, 0)) {
                    appendUnescaped(consumeEscape(data))
                    continue
                }
                break
            }
            appendUnescaped(unit: cc)
        }

        consumeBadUrlRemnants(data)
        return token(.badUrl, start, data)
    }

    /// Mirrors CSSTokenizer::consumeBadUrlRemnants.
    private mutating func consumeBadUrlRemnants(_ data: Span<Unit>) {
        while true {
            let cc = consume(data)
            if cc == 0x29 || cc == 0 { return }
            if twoCharsAreValidEscape(cc, peek(data, 0)) { consumeEscape(data) }
        }
    }

    // MARK: Escapes and comments

    /// Mirrors CSSTokenizer::consumeSingleWhitespaceIfNext.
    private mutating func consumeSingleWhitespaceIfNext(_ data: Span<Unit>) {
        let next = peek(data, 0)
        if next == 0x0D, peek(data, 1) == 0x0A {
            advance(2)
        } else if isASCIIWhitespaceByte(next) {
            advance()
        }
    }

    /// Mirrors CSSTokenizer::consumeEscape. The code point itself is only needed
    /// by `nameIsURL`; here the cursor movement is what matters, so the value is
    /// discarded and the compiler drops the arithmetic.
    @discardableResult
    private mutating func consumeEscape(_ data: Span<Unit>) -> UInt32 {
        let cc = consume(data)
        if isASCIIHexDigitByte(cc) {
            var codePoint = hexValue(cc)
            var digits = 1
            while digits < 6, isASCIIHexDigitByte(peek(data, 0)) {
                codePoint = codePoint &* 16 &+ hexValue(consume(data))
                digits &+= 1
            }
            consumeSingleWhitespaceIfNext(data)
            if codePoint == 0 || (codePoint >= 0xD800 && codePoint <= 0xDFFF) || codePoint > 0x10FFFF {
                return 0xFFFD
            }
            return codePoint
        }
        if cc == 0 { return 0xFFFD }
        return UInt32(truncatingIfNeeded: cc)
    }

    /// Mirrors CSSTokenizer::consumeUntilCommentEndFound.
    private mutating func consumeUntilCommentEndFound(_ data: Span<Unit>) {
        var c = consume(data)
        while true {
            if c == 0 { return }
            if c != 0x2A { // *
                c = consume(data)
                continue
            }
            c = consume(data)
            if c == 0x2F { return } // /
        }
    }

    // MARK: Lookahead predicates

    /// Mirrors CSSTokenizer::nextCharsAreNumber(char16_t).
    private func nextCharsAreNumber(_ data: Span<Unit>, _ first: Unit) -> Bool {
        let second = peek(data, 0)
        if isASCIIDigitByte(first) { return true }
        if first == 0x2B || first == 0x2D {
            return isASCIIDigitByte(second) || (second == 0x2E && isASCIIDigitByte(peek(data, 1)))
        }
        if first == 0x2E { return isASCIIDigitByte(second) }
        return false
    }

    /// Mirrors the zero-argument overload: consume, test, reconsume. Written
    /// without moving the cursor, which is the same thing and keeps `self`
    /// immutable here.
    private func nextCharsAreNumber(_ data: Span<Unit>) -> Bool {
        let first = peek(data, 0)
        let second = peek(data, 1)
        if isASCIIDigitByte(first) { return true }
        if first == 0x2B || first == 0x2D {
            return isASCIIDigitByte(second) || (second == 0x2E && isASCIIDigitByte(peek(data, 2)))
        }
        if first == 0x2E { return isASCIIDigitByte(second) }
        return false
    }

    /// Mirrors CSSTokenizer::nextCharsAreIdentifier(char16_t).
    private func nextCharsAreIdentifier(_ data: Span<Unit>, _ first: Unit) -> Bool {
        let second = peek(data, 0)
        if isNameStartByte(first) || twoCharsAreValidEscape(first, second) { return true }
        if first == 0x2D {
            return isNameStartByte(second) || second == 0x2D || nextTwoCharsAreValidEscape(data)
        }
        return false
    }

    private func nextCharsAreIdentifier(_ data: Span<Unit>) -> Bool {
        let first = peek(data, 0)
        let second = peek(data, 1)
        if isNameStartByte(first) || twoCharsAreValidEscape(first, second) { return true }
        if first == 0x2D {
            return isNameStartByte(second) || second == 0x2D
                || twoCharsAreValidEscape(second, peek(data, 2))
        }
        return false
    }
}

// MARK: - C++ entry points
//
// POD in, POD out, so the C++ side needs no Swift type beyond the token struct
// itself. Nothing in the shipping parser calls these yet: the island is
// additive, reached only from the benchmark and the validation test.

/// Result of tokenizing a whole stylesheet.
/// `@frozen` matters here, not just as documentation. WebCore compiles Swift with
/// -enable-library-evolution, and without `@frozen` an exposed struct is resilient:
/// the generated C++ class wraps a heap-allocated opaque box, so every value
/// returned to C++ costs a malloc/free pair and its C++ sizeof() is meaningless.
@frozen
@_expose(Cxx)
public struct CSSTokenizeResultSwift {
    public var tokenCount: Int = 0
    public var fold: UInt64 = 0
    public init() {}
}

/// Folds only the token type, matching what webCoreCSSTokenizerBenchReal can
/// fold from a CSSParserToken.
///
/// Do not "improve" this by folding every field. Measured on the standalone
/// probe, folding all ten fields costs 90–164% on top of tokenization — it is
/// the single largest term in the benchmark. Because it is identical work on
/// both sides it does not bias the ratio in either direction, but it compresses
/// every real difference toward 1.0 and made an earlier round of numbers look
/// far better than the tokenizers actually are.
@inline(always) private func foldToken(_ sum: UInt64, _ t: CSSTokenSwift) -> UInt64 {
    sum &* 1000003 &+ UInt64(t.type)
}

/// TODO(unsafe): `Span(_unsafeCxxSpan:)` is the only `unsafe` in this island,
/// and it is at the boundary rather than in the interior — see the §4b'
/// diagnostic. It exists because there is no safe way to receive a `std::span`
/// from C++: `WTF::BorrowedBytes` is the safe pattern for *bytes* but has no
/// span-shaped equivalent. Per the project rule that a needed `unsafe` is a bug
/// to file, this is a to-file item, not an accepted cost. Shared with
/// HTMLTokenizerSwift.swift, which has the identical line.
@_expose(Cxx)
public func cssTokenizeSwiftSpan(_ data: WebCore.CSSTokenizerSpan8) -> CSSTokenizeResultSwift {
    let span = unsafe Span<UInt8>(_unsafeCxxSpan: data)
    var tokenizer = CSSTokenizerSwift<UInt8>()
    var result = CSSTokenizeResultSwift()
    while true {
        let t = tokenizer.nextToken(span)
        if t.type == CSSTokenTypeSwift.endOfFile.rawValue { break }
        result.tokenCount &+= 1
        result.fold = foldToken(result.fold, t)
    }
    return result
}

/// Copies one of the island's tokens into the C++ boundary struct.
///
/// The boundary type is defined in C++ (CSSTokenizerInputStream.h) rather than
/// here, because WebCore compiles Swift with -enable-library-evolution: a Swift
/// struct exposed with @_expose(Cxx) is resilient, so the generated C++ class is
/// a heap-allocated opaque box with no default constructor and a sizeof() that is
/// not the struct's size. Usable for a single returned value, unusable as the
/// element type of a shared buffer.
@inline(always) private func exported(_ token: CSSTokenSwift) -> WebCore.CSSSwiftToken {
    var out = WebCore.CSSSwiftToken()
    out.start = token.start
    out.end = token.end
    out.valueStart = token.valueStart
    out.valueLength = token.valueLength
    out.numberStart = token.numberStart
    out.numberLength = token.numberLength
    out.extra = token.extra
    out.type = token.type
    out.blockType = token.blockType
    out.flags = token.flags
    return out
}

/// Tokenizes a whole stylesheet, handing the tokens to `sink` a chunk at a time.
///
/// Every buffer here belongs to Swift, and each chunk crosses to C++ as a pair of
/// `Span`s. That is the direction a buffer handover can be made safe in
/// (SafeInteropWrappers transforms *parameters*), and the receiver is a refcounted
/// shared reference, which is how a directly-named callee reaches C++ state without a
/// pointer parameter. The result is that this function contains exactly one `unsafe`:
/// the input span, which has to arrive *from* C++ and so cannot be fixed by any
/// annotation. See swift-cpp-interop-notes.md §67.
///
/// The previous design was the mirror image — C++ owned the buffers and passed
/// pointers in, the cursor and block stack travelled in a state struct, and buffers
/// that filled up needed a rewind-and-grow protocol. Owning the buffers deletes all of
/// that, along with the fixed nesting cap.
///
/// Returns false if the sink could not take a chunk, which means allocation failure;
/// the caller then falls back to the C++ tokenizer.
@inline(always)
private func tokenizeAll<Unit: CSSCodeUnit>(
    _ span: Span<Unit>,
    _ sink: WebCore.CSSSwiftTokenSink
) -> Bool {
    // Chunked so the buffer stays cache-resident: one entry per token for a whole
    // document is tens of megabytes, and writing that and reading it back costs more
    // than the scan (notes §11i).
    let chunkCapacity = 1024

    var tokenizer = CSSTokenizerSwift<Unit>()
    var tokens = UniqueArray<WebCore.CSSSwiftToken>()
    tokens.reserveCapacity(chunkCapacity)

    while true {
        let token = tokenizer.nextToken(span)
        if token.type == CSSTokenTypeSwift.endOfFile.rawValue { break }
        tokens.append(exported(token))
        if tokens.count == chunkCapacity {
            guard sink.takeChunk(tokens.span, tokenizer.unescapedUnits) else { return false }
            tokens.removeAll()
            tokenizer.startChunk()
        }
    }

    if !tokens.isEmpty {
        guard sink.takeChunk(tokens.span, tokenizer.unescapedUnits) else { return false }
    }
    sink.finish()
    return true
}

/// 8-bit input: the common case, a stylesheet that survives preprocessing as Latin-1.
///
/// TODO(unsafe): `Span(_unsafeCxxSpan:)` is the only `unsafe` left in this island, and
/// unlike the ones it replaced it is not fixable by a WTF addition: this function's
/// parameters have to be C++-representable, and Swift's `Span` is not, so the source
/// text can only arrive as a C++ span. Filed as such rather than presented as a cost.
@_expose(Cxx)
public func cssTokenizeSwiftAll8(
    _ data: WebCore.CSSTokenizerSpan8,
    _ sink: WebCore.CSSSwiftTokenSink
) -> Bool {
    tokenizeAll(unsafe Span<UInt8>(_unsafeCxxSpan: data), sink)
}

/// 16-bit input. The C++ tokenizer reads every character through
/// `StringImpl::operator[]`, which branches on `is8Bit()` per read; here the two widths
/// are separate specializations of one implementation, so neither pays for the other.
@_expose(Cxx)
public func cssTokenizeSwiftAll16(
    _ data: WebCore.CSSTokenizerSpan16,
    _ sink: WebCore.CSSSwiftTokenSink
) -> Bool {
    tokenizeAll(unsafe Span<UInt16>(_unsafeCxxSpan: data), sink)
}

/// The `index`-th token, for the validation test to walk the stream alongside
/// the real `CSSTokenizer`.
///
/// O(index): the island's state is a `~Copyable` Swift struct, which C++ cannot
/// hold, so there is no way to expose a resumable cursor without either an
/// opaque class handle (refcounting) or a caller-provided output buffer (which
/// needs the `MutableBorrowedBytes` that does not exist). Quadratic is fine for
/// a test over a few thousand tokens, and the shape of the workaround is itself
/// worth recording.
@_expose(Cxx)
public func cssTokenizeSwiftNth(_ data: WebCore.CSSTokenizerSpan8, _ index: Int) -> WebCore.CSSSwiftToken {
    let span = unsafe Span<UInt8>(_unsafeCxxSpan: data)
    var tokenizer = CSSTokenizerSwift<UInt8>()
    var i = 0
    while true {
        let t = tokenizer.nextToken(span)
        if i == index || t.type == CSSTokenTypeSwift.endOfFile.rawValue { return exported(t) }
        i &+= 1
    }
}
