// Only this file's own boundary types, not the WebCore_Private umbrella: importing
// that walks ~3,500 headers into JavaScriptCore's, where two inner structs are
// defined in explicit submodules nothing imports, and the Swift step fails to
// compile on WTF::KeyValuePair instantiated over them. See CSSTokenizerSwiftTypes.h.
public import WebCore_Private.CSSTokenizerSwiftTypes

// Swift tokenizer for the CSS parser: a port of CSSTokenizer.cpp and
// CSSTokenizerInputStream.h, selected by USE_SWIFT_CSS_TOKENIZER (CSSTokenizer.h).
//
// Input is a `Span` over the preprocessed string, which C++ already owns and
// hands out as a contiguous span. Output is a *finished* token:
// `CSSParserTokenBits`, which is `CSSParserToken`'s own storage, written
// through the one factory per token kind in CSSParserTokenBits.h — each
// construction site knows its token kind statically, so no dispatch tag has
// to cross the boundary.
//
// What crosses in place of a pointer is an *offset*: `CSSParserToken`
// already stores a view into the input, so the pointer slot can carry the
// offset until `resolveValuePointer` runs on the C++ side, and Swift never
// forms or dereferences a pointer. The offset's top bit says whether it
// indexes the input or the chunk's unescape buffer.
//
// Numbers are not converted here, so C++ keeps calling charactersToDouble
// and double rounding stays bit-identical; until it runs, the union carries
// the number's own range, because once a dimension's number and unit have
// been merged the number is not recoverable from the value. Values
// containing escapes are unescaped into a buffer this file owns and hands
// to C++ alongside each chunk of tokens, so nothing has to be re-tokenized
// in C++.
//
// The interior contains no `unsafe` code. Two sites use
// `Span(_unsafeCxxSpan:)`: the production entry points that receive the
// source text from C++, `cssTokenizeSwiftAll8` and `cssTokenizeSwiftAll16`.
// There is no safe way yet to import a `std::span` where the callee is
// Swift (rdar://186723514).
//
// Validated token-by-token against the real CSSTokenizer —
// CSSTokenizerSwiftBridge.cpp and CSSTokenizerSwiftTest.cpp.

// `WebCore.CSSParserTokenType` is imported, not mirrored. `CSSParserToken.h` was not
// self-contained enough to join this file's own Swift-visible submodule, but
// `CSSParserTokenBits.h` already is, and `CSSParserToken.h` includes it; the enum lives
// there now, unscoped, so every `IdentToken` elsewhere in the CSS parser still resolves
// unqualified.
//
// Swift sees an unscoped C++ enum as a type with `rawValue` whose enumerators are global
// constants, so the spelling here is `WebCore.IdentToken` rather than a leading-dot case.
// That is the whole cost, and it removes a table that would otherwise be transcribed by hand.

/// Mirrors CSSParserToken::BlockType. `@c` for the same reason as above.
@c
enum CSSBlockTypeSwift: UInt8 {
    case notBlock = 0, blockStart, blockEnd
}

/// A finished token, on its way out to C++.
///
/// The two offsets are the observer's, not the token's: `CSSParserTokenBits` has no room for a
/// token's extent and must not grow, since it is the object the whole CSS parser stores.
struct EmittedToken {
    var bits: WebCore.CSSParserTokenBits
    var start: UInt32
    var end: UInt32
}

/// Generic over the code unit so one implementation serves both of `StringImpl`'s
/// representations, without the `is8Bit()` branch the C++ pays on every character read.
///
/// Nothing here looks above U+007F except to ask whether a unit is ASCII, which is what the CSS
/// syntax spec's name-code-point rule needs, so a per-code-unit port is faithful for 16-bit input
/// too: surrogates are name code points, and preprocessing has already replaced unpaired ones.
protocol CSSCodeUnit: FixedWidthInteger & UnsignedInteger { }
extension UInt8: CSSCodeUnit { }
extension UInt16: CSSCodeUnit { }

// MARK: - Character predicates (CSSParserIdioms.h, ASCIICType.h)

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
/// isASCIIWhitespace: space, \n, \t, \r, \f. \v is not included.
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
@inline(always) private func isNonPrintableByte(_ c: some CSSCodeUnit) -> Bool {
    c <= 0x08 || c == 0x0B || (c >= 0x0E && c <= 0x1F) || c == 0x7F
}

/// A bounds-checked read of the input that costs one unsigned compare, which is the
/// shape C++ gets for free by indexing with `size_t`.
///
/// `Span`'s subscript checks `0 <= index && index < count`, and nothing establishes
/// the first half for the optimizer because the index arrives as a parameter or from
/// a stored property. Comparing bit patterns as unsigned discharges both at once and
/// is not `unsafe`: a negative index fails the compare and reads as the EOF marker.
/// Worth 26% on the name scan, the hottest loop here.
///
/// Use this ONLY where the EOF-marker semantics are wanted anyway: in a loop whose
/// own condition already bounds the index, the select is pure overhead, measured at
/// 28% on all-whitespace input, so those loops index directly.
@inline(always) private func byteAt<Unit: CSSCodeUnit>(_ data: Span<Unit>, _ index: Int) -> Unit {
    UInt(bitPattern: index) < UInt(bitPattern: data.count) ? data[index] : 0
}

/// The 128-entry dispatch class. The C++ calls through a `std::array<CodePoint, 128>` of member
/// function pointers once per token; here it is a `switch`, so there is no indirect call.
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

/// The result of scanning a name or a quoted value: a range of the input, or, when the value
/// contained escapes, a range of the tokenizer's unescape buffer. `unescaped` says which.
private struct ScannedValue {
    var start: UInt32 = 0
    var length: UInt32 = 0
    var unescaped = false
}

/// The sign a number carried. The mapping onto `NumericSign`'s enumerators is written down in
/// `makeNumericTokenBits`, not here: `NumericSign` has no static_assert bridge the way
/// `CSSParserTokenType` and `CSSUnitType` do, so mirroring its numbering here would be unchecked.
private enum ScannedSign {
    case none, plus, minus
}

/// The result of scanning a number: its own range in the input, which is `CSSParserToken`'s
/// `originalText` and the range C++ hands to `charactersToDouble`.
private struct ScannedNumber {
    var start: UInt32 = 0
    var length: UInt32 = 0
    var isNonInteger = false
    var sign = ScannedSign.none
}

struct CSSTokenizerSwift<Unit: CSSCodeUnit>: ~Copyable {
    /// The input cursor. As in C++ it may advance past the end, so every read clamps and every
    /// report goes through `clampedOffset`.
    private var offset = 0
    /// Mirrors m_blockStack, owned here and growable, so nesting is unbounded and no buffer
    /// crosses the boundary for it.
    private var blockStack = UniqueArray<UInt8>()

    /// Code units of values that contained escapes, in the order the tokens referring to them
    /// were produced. UTF-16 rather than the input's code unit, because an escape can name any
    /// code point: `\1F3A8` unescapes to a surrogate pair even in 8-bit input.
    private var unescaped = UniqueArray<UInt16>()
    /// Appends one code point, UTF-16 encoded.
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

    /// Range of the unescape buffer filled since `mark`.
    @inline(always) private func unescapedValue(since mark: Int) -> ScannedValue {
        ScannedValue(
            start: UInt32(truncatingIfNeeded: mark),
            length: UInt32(truncatingIfNeeded: unescaped.count &- mark),
            unescaped: true)
    }

    public init() {}

    public var consumedOffset: Int { offset }

    var unescapedUnits: Span<UInt16> { unescaped.span }

    /// Drops the previous chunk's unescaped units, so a token value range is always an offset
    /// into the chunk currently being handed over.
    mutating func startChunk() { unescaped.removeAll() }

    // MARK: Input stream (CSSTokenizerInputStream)

    @inline(always) private func peek(_ data: Span<Unit>, _ lookahead: Int) -> Unit {
        // Wrapping add: `offset` is at most `data.count + 1` and `lookahead` is a small literal.
        // Past the end reads as the EOF marker (NUL); preprocessing has removed any real NULs.
        return byteAt(data, offset &+ lookahead)
    }

    @inline(always) private mutating func consume(_ data: Span<Unit>) -> Unit {
        let c = peek(data, 0)
        offset &+= 1
        return c
    }

    @inline(always) private mutating func advance(_ n: Int = 1) { offset &+= n }
    @inline(always) private mutating func reconsume() { offset &-= 1 }

    /// The cursor may be one past the end after consuming the EOF marker.
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
    //
    // Each of these calls the factory in CSSParserTokenBits.h for one token kind, so the kind is
    // spent here, where it is a literal. `@inline(always)` is what makes the factories fold: with
    // the kind constant, the switch inside each factory disappears.

    /// `valueIs8Bit` for any value that is a range of the input.
    private static var valueIs8Bit: Bool { Unit.bitWidth == 8 }

    @inline(always) private func emit(
        _ bits: WebCore.CSSParserTokenBits, _ start: Int, _ data: Span<Unit>
    ) -> EmittedToken {
        EmittedToken(
            bits: bits,
            start: UInt32(truncatingIfNeeded: start),
            end: UInt32(truncatingIfNeeded: clampedOffset(data)))
    }

    @inline(always) private func token(
        _ type: WebCore.CSSParserTokenType, _ start: Int, _ data: Span<Unit>,
        block: CSSBlockTypeSwift = .notBlock
    ) -> EmittedToken {
        emit(makeSimpleTokenBits(UInt32(type.rawValue), UInt32(block.rawValue)), start, data)
    }

    @inline(always) private func delimiter(_ c: Unit, _ start: Int, _ data: Span<Unit>) -> EmittedToken {
        emit(
            makeDelimiterTokenBits(
                UInt32(WebCore.DelimiterToken.rawValue), UInt32(truncatingIfNeeded: c)),
            start, data)
    }

    @inline(always) private func whitespace(
        _ count: Int, _ start: Int, _ data: Span<Unit>
    ) -> EmittedToken {
        emit(
            makeWhitespaceTokenBits(
                UInt32(WebCore.NonNewlineWhitespaceToken.rawValue),
                UInt32(truncatingIfNeeded: count)),
            start, data)
    }

    @inline(always) private func valueToken(
        _ type: WebCore.CSSParserTokenType, _ value: ScannedValue, _ start: Int, _ data: Span<Unit>,
        block: CSSBlockTypeSwift = .notBlock
    ) -> EmittedToken {
        emit(
            makeValueTokenBits(
                UInt32(type.rawValue), UInt32(block.rawValue),
                value.start, value.length, value.unescaped, Self.valueIs8Bit),
            start, data)
    }

    @inline(always) private func hashToken(
        _ value: ScannedValue, isId: Bool, _ start: Int, _ data: Span<Unit>
    ) -> EmittedToken {
        emit(
            makeHashTokenBits(
                UInt32(WebCore.HashToken.rawValue), isId,
                value.start, value.length, value.unescaped, Self.valueIs8Bit),
            start, data)
    }

    @inline(always) private mutating func pushBlock(_ type: WebCore.CSSParserTokenType) {
        blockStack.append(type.rawValue)
    }

    private mutating func blockStart(
        _ type: WebCore.CSSParserTokenType, _ start: Int, _ data: Span<Unit>
    ) -> EmittedToken {
        pushBlock(type)
        return token(type, start, data, block: .blockStart)
    }

    private mutating func blockEnd(
        _ type: WebCore.CSSParserTokenType, _ startType: WebCore.CSSParserTokenType, _ start: Int, _ data: Span<Unit>
    ) -> EmittedToken {
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
    mutating func nextToken(_ data: Span<Unit>) -> EmittedToken {
        let start = clampedOffset(data)
        let cc = consume(data)

        switch dispatchClass(cc) {
        case .endOfFile:
            return token(WebCore.EOFToken, start, data)

        case .whitespace:
            // The count includes the character just consumed, and stops at a newline so that
            // newlines tokenize separately.
            let runStart = clampedOffset(data)
            advanceUntilNewlineOrNonWhitespace(data)
            return whitespace(1 &+ (clampedOffset(data) &- runStart), start, data)

        case .newline:
            return token(WebCore.NewlineToken, start, data)

        case .stringStart:
            return consumeStringTokenUntil(data, cc, start)

        case .hash:
            let next = peek(data, 0)
            if isNameByte(next) || twoCharsAreValidEscape(next, peek(data, 1)) {
                let isId = nextCharsAreIdentifier(data)
                let name = consumeName(data)
                return hashToken(name, isId: isId, start, data)
            }
            return delimiter(cc, start, data)

        case .dollarSign:
            if consumeIfNext(data, 0x3D) { return token(WebCore.SuffixMatchToken, start, data) }
            return delimiter(cc, start, data)

        case .leftParenthesis:
            return blockStart(WebCore.LeftParenthesisToken, start, data)

        case .rightParenthesis:
            return blockEnd(WebCore.RightParenthesisToken, WebCore.LeftParenthesisToken, start, data)

        case .asterisk:
            if consumeIfNext(data, 0x3D) { return token(WebCore.SubstringMatchToken, start, data) }
            return delimiter(cc, start, data)

        case .plusOrFullStop:
            if nextCharsAreNumber(data, cc) {
                reconsume()
                return consumeNumericToken(data, start)
            }
            return delimiter(cc, start, data)

        case .comma:
            return token(WebCore.CommaToken, start, data)

        case .hyphenMinus:
            if nextCharsAreNumber(data, cc) {
                reconsume()
                return consumeNumericToken(data, start)
            }
            if peek(data, 0) == 0x2D, peek(data, 1) == 0x3E { // -->
                advance(2)
                return token(WebCore.CDCToken, start, data)
            }
            if nextCharsAreIdentifier(data, cc) {
                reconsume()
                return consumeIdentLikeToken(data, start)
            }
            return delimiter(cc, start, data)

        case .solidus:
            if consumeIfNext(data, 0x2A) { // /*
                consumeUntilCommentEndFound(data)
                return token(WebCore.CommentToken, start, data)
            }
            return delimiter(cc, start, data)

        case .asciiDigit:
            reconsume()
            return consumeNumericToken(data, start)

        case .colon:
            return token(WebCore.ColonToken, start, data)

        case .semiColon:
            return token(WebCore.SemicolonToken, start, data)

        case .lessThan:
            if peek(data, 0) == 0x21, peek(data, 1) == 0x2D, peek(data, 2) == 0x2D { // <!--
                advance(3)
                return token(WebCore.CDOToken, start, data)
            }
            return delimiter(cc, start, data)

        case .commercialAt:
            if nextCharsAreIdentifier(data) {
                let name = consumeName(data)
                return valueToken(WebCore.AtKeywordToken, name, start, data)
            }
            return delimiter(cc, start, data)

        case .nameStart:
            reconsume()
            return consumeIdentLikeToken(data, start)

        case .leftBracket:
            return blockStart(WebCore.LeftBracketToken, start, data)

        case .reverseSolidus:
            if twoCharsAreValidEscape(cc, peek(data, 0)) {
                reconsume()
                return consumeIdentLikeToken(data, start)
            }
            return delimiter(cc, start, data)

        case .rightBracket:
            return blockEnd(WebCore.RightBracketToken, WebCore.LeftBracketToken, start, data)

        case .circumflexAccent:
            if consumeIfNext(data, 0x3D) { return token(WebCore.PrefixMatchToken, start, data) }
            return delimiter(cc, start, data)

        case .leftBrace:
            return blockStart(WebCore.LeftBraceToken, start, data)

        case .verticalLine:
            if consumeIfNext(data, 0x3D) { return token(WebCore.DashMatchToken, start, data) }
            if consumeIfNext(data, 0x7C) { return token(WebCore.ColumnToken, start, data) }
            return delimiter(cc, start, data)

        case .rightBrace:
            return blockEnd(WebCore.RightBraceToken, WebCore.LeftBraceToken, start, data)

        case .tilde:
            if consumeIfNext(data, 0x3D) { return token(WebCore.IncludeMatchToken, start, data) }
            return delimiter(cc, start, data)

        case .delimiter:
            return delimiter(cc, start, data)
        }
    }

    // MARK: Numbers

    /// Mirrors CSSTokenizer::consumeNumber, which merges the spec's consume-a-number with
    /// convert-a-string-to-a-number. The conversion itself is left to C++; see the file comment.
    private mutating func consumeNumber(_ data: Span<Unit>) -> ScannedNumber {
        let startOffset = clampedOffset(data)

        var number = ScannedNumber()
        var length = 0

        var next = peek(data, 0)
        if next == 0x2B {
            length &+= 1
            number.sign = .plus
        } else if next == 0x2D {
            length &+= 1
            number.sign = .minus
        }

        // Wrapping: `length` counts characters of a number already found to start at the cursor,
        // so it is bounded by the input length.
        length = skipDigits(data, from: length)
        next = peek(data, length)
        if next == 0x2E, isASCIIDigitByte(peek(data, length &+ 1)) {
            number.isNonInteger = true
            length = skipDigits(data, from: length &+ 2)
            next = peek(data, length)
        }

        if next == 0x45 || next == 0x65 { // E e
            next = peek(data, length &+ 1)
            if isASCIIDigitByte(next) {
                number.isNonInteger = true
                length = skipDigits(data, from: length &+ 1)
            } else if next == 0x2B || next == 0x2D, isASCIIDigitByte(peek(data, length &+ 2)) {
                number.isNonInteger = true
                length = skipDigits(data, from: length &+ 3)
            }
        }

        advance(length)

        // CSSParserToken's originalText for a number is the whole consumed run,
        // which is also exactly the range C++ hands to charactersToDouble.
        number.start = UInt32(truncatingIfNeeded: startOffset)
        number.length = UInt32(truncatingIfNeeded: clampedOffset(data) &- startOffset)
        return number
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

    /// Mirrors CSSTokenizer::consumeNumericToken, and, for a dimension, the
    /// `convertToDimensionWithUnit(StringView)` post-pass C++ runs on the finished token. That
    /// post-pass resolves the unit's text to a `CSSUnitType`, and decides the token's value:
    /// `mergeIfAdjacent` joins the number and the unit into one view when they are physically
    /// adjacent and the number is shorter than sixteen characters, so `10px` has value `"10px"`
    /// and round-trips verbatim through custom property serialization, while `1\70x` has value
    /// `"px"`.
    ///
    /// `nonUnitPrefixLength` records which of those happened, and is not merely a length:
    /// `unitString()` is `value().substring(nonUnitPrefixLength)`, `CSSParserToken::operator==`
    /// selects which comparison a DimensionToken gets on whether it is zero, and custom property
    /// serialization reserializes from `value()`.
    private mutating func consumeNumericToken(_ data: Span<Unit>, _ start: Int) -> EmittedToken {
        let number = consumeNumber(data)

        if nextCharsAreIdentifier(data) {
            let unit = consumeName(data)
            let unitRange = Int(unit.start)..<Int(unit.start &+ unit.length)
            let unitType = unit.unescaped
                ? cssPrimitiveValueUnitFromTrie(unescaped.span.extracting(unitRange))
                : cssPrimitiveValueUnitFromTrie(data.extracting(unitRange))

            // mergeIfAdjacent's own conditions: both views the same width, physically adjacent,
            // and the number shorter than sixteen characters. `nonUnitPrefixLength` is four bits
            // wide, and the last condition is what keeps the number's length inside it.
            let merged = !unit.unescaped
                && number.length >= 1 && number.length < 16
                && unit.start == number.start &+ number.length
            return emit(
                makeNumericTokenBits(
                    UInt32(WebCore.DimensionToken.rawValue),
                    number.isNonInteger, number.sign == .plus, number.sign == .minus,
                    UInt32(unitType.rawValue),
                    merged ? number.start : unit.start,
                    merged ? number.length &+ unit.length : unit.length,
                    unit.unescaped,
                    merged ? number.length : 0,
                    number.start, number.length,
                    Self.valueIs8Bit),
                start, data)
        }

        if consumeIfNext(data, 0x25) {
            // convertToPercentage: the type and the unit change and nothing else does, so the
            // value stays the number's own range and the prefix length stays zero.
            return numericToken(WebCore.PercentageToken, unit: .Percentage, number, start, data)
        }

        return numericToken(WebCore.NumberToken, unit: .Number, number, start, data)
    }

    /// A NumberToken or a PercentageToken: `value()` is `originalText()` is the number, so there
    /// is no unit text and no merge to decide.
    @inline(always) private func numericToken(
        _ type: WebCore.CSSParserTokenType, unit: WebCore.CSSUnitType, _ number: ScannedNumber,
        _ start: Int, _ data: Span<Unit>
    ) -> EmittedToken {
        emit(
            makeNumericTokenBits(
                UInt32(type.rawValue),
                number.isNonInteger, number.sign == .plus, number.sign == .minus,
                UInt32(unit.rawValue),
                number.start, number.length, false,
                0,
                number.start, number.length,
                Self.valueIs8Bit),
            start, data)
    }

    // MARK: Identifiers

    private mutating func consumeIdentLikeToken(_ data: Span<Unit>, _ start: Int) -> EmittedToken {
        let name = consumeName(data)
        if consumeIfNext(data, 0x28) { // (
            if nameIsURL(data, name) {
                // Whitespace is skipped here rather than emitted, and a quoted argument makes
                // this a function token so that the string tokenizes normally.
                advanceUntilNonWhitespace(data)
                let next = peek(data, 0)
                if next != 0x22, next != 0x27 {
                    return consumeURLToken(data, start)
                }
            }
            pushBlock(WebCore.LeftParenthesisToken)
            return valueToken(WebCore.FunctionToken, name, start, data, block: .blockStart)
        }
        return valueToken(WebCore.IdentToken, name, start, data)
    }

    /// equalLettersIgnoringASCIICase(name, "url"), against either the input or the unescaped
    /// units, so `\75 rl(` is still recognised as a url token.
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

    /// The fast path returns a range of the input; the slow path unescapes into the unescape
    /// buffer and returns a range of that.
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

    private mutating func consumeStringTokenUntil(
        _ data: Span<Unit>, _ endingCodePoint: Unit, _ start: Int
    ) -> EmittedToken {
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
                return valueToken(WebCore.StringToken, value, start, data)
            }
            if isCSSNewlineByte(cc) {
                advance(size)
                return token(WebCore.BadStringToken, start, data)
            }
            if cc == 0 || cc == 0x5C { break }
            size &+= 1
        }

        // Slow path: unescape into the buffer. A backslash before a newline is a line
        // continuation and contributes nothing; a backslash at EOF likewise.
        let mark = unescaped.count
        while true {
            let cc = consume(data)
            if cc == endingCodePoint || cc == 0 {
                return valueToken(WebCore.StringToken, unescapedValue(since: mark), start, data)
            }
            if isCSSNewlineByte(cc) {
                reconsume()
                return token(WebCore.BadStringToken, start, data)
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

    private mutating func consumeURLToken(_ data: Span<Unit>, _ start: Int) -> EmittedToken {
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
                return valueToken(WebCore.UrlToken, value, start, data)
            }
            if cc <= 0x20 || cc == 0x5C || cc == 0x22 || cc == 0x27 || cc == 0x28 || cc == 0x7F {
                break
            }
            size &+= 1
        }

        // Slow path: unescape into the buffer. Nothing is appended for the terminating character,
        // so a trailing whitespace run before the closing paren does not end up in the value.
        let mark = unescaped.count
        while true {
            let cc = consume(data)
            if cc == 0x29 || cc == 0 {
                return valueToken(WebCore.UrlToken, unescapedValue(since: mark), start, data)
            }
            if isASCIIWhitespaceByte(cc) {
                advanceUntilNonWhitespace(data)
                if consumeIfNext(data, 0x29) || peek(data, 0) == 0 {
                    return valueToken(WebCore.UrlToken, unescapedValue(since: mark), start, data)
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
        return token(WebCore.BadUrlToken, start, data)
    }

    private mutating func consumeBadUrlRemnants(_ data: Span<Unit>) {
        while true {
            let cc = consume(data)
            if cc == 0x29 || cc == 0 { return }
            if twoCharsAreValidEscape(cc, peek(data, 0)) { consumeEscape(data) }
        }
    }

    // MARK: Escapes and comments

    private mutating func consumeSingleWhitespaceIfNext(_ data: Span<Unit>) {
        let next = peek(data, 0)
        if next == 0x0D, peek(data, 1) == 0x0A {
            advance(2)
        } else if isASCIIWhitespaceByte(next) {
            advance()
        }
    }

    /// The code point is only needed by `nameIsURL`; other callers want the cursor movement.
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

    private func nextCharsAreNumber(_ data: Span<Unit>, _ first: Unit) -> Bool {
        let second = peek(data, 0)
        if isASCIIDigitByte(first) { return true }
        if first == 0x2B || first == 0x2D {
            return isASCIIDigitByte(second) || (second == 0x2E && isASCIIDigitByte(peek(data, 1)))
        }
        if first == 0x2E { return isASCIIDigitByte(second) }
        return false
    }

    /// Consume, test, reconsume, written without moving the cursor so `self` stays immutable.
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
// `cssTokenizeSwiftAll8`/`16` are what CSSTokenizer's constructor drives when `Scanner::Swift`
// is selected.

/// A free function rather than a closure over the buffer, so nothing captures a `~Copyable`
/// container.
@inline(always) private func observerRecord(
    _ token: EmittedToken, isComment: Bool
) -> WebCore.CSSSwiftObserverRecord {
    var entry = WebCore.CSSSwiftObserverRecord()
    entry.start = token.start
    entry.end = token.end
    entry.isComment = isComment ? 1 : 0
    return entry
}

/// Tokenizes a whole stylesheet, handing the tokens to `sink` a chunk at a time.
///
/// Every buffer here belongs to Swift, and each chunk crosses to C++ as three `Span`s, which is
/// the direction a buffer handover can be made safe in. Owning them here rather than having C++
/// pass pointers in means the cursor and block stack never need a rewind-and-grow protocol when a
/// buffer fills up, and there is no fixed nesting cap.
///
/// Returns false if the sink could not take a chunk, which means C++ could not allocate
/// `m_tokens`. There is nothing to fall back to, since the C++ scanner reserves the same size
/// into the same vector.
@inline(always)
private func tokenizeAll<Unit: CSSCodeUnit>(
    _ span: Span<Unit>,
    _ sink: WebCore.CSSSwiftTokenSink
) -> Bool {
    // A value offset is parked in the token's pointer slot with its top bit saying which buffer
    // it indexes, so an input at or above 2 GB cannot have its offsets represented. There is no
    // fallback, so this reports failure rather than truncating.
    guard cssParserTokenBitsCanRepresentOffsets(numericCast(span.count)) else { return false }

    // Chunked so the buffer stays cache-resident: one entry per token for a whole document is
    // tens of megabytes, and writing that and reading it back costs more than the scan.
    let chunkCapacity = 1024

    var tokenizer = CSSTokenizerSwift<Unit>()
    var tokens = UniqueArray<WebCore.CSSParserTokenBits>()
    // Capped by the input's length: `CSSTokenizer` is also constructed per property value, where
    // reserving the full chunk would ask the allocator for 32,768 bytes to tokenize `10px`.
    // `count` is an exact upper bound on the number of tokens, not a heuristic, because every
    // token consumes at least one code unit and the EOF token breaks rather than being appended.
    tokens.reserveCapacity(min(chunkCapacity, span.count))

    // Asked once rather than per token or per chunk: with no observer this stays at capacity
    // zero, which costs three words of stack and no allocation.
    let wantsObserverRecords = sink.wantsObserverRecords()
    var observerRecords = UniqueArray<WebCore.CSSSwiftObserverRecord>()
    if wantsObserverRecords {
        // One record per token plus one per comment, so `chunkCapacity` is a floor, not a bound.
        observerRecords.reserveCapacity(chunkCapacity)
    }

    let endOfFileType = UInt32(WebCore.EOFToken.rawValue)
    let commentType = UInt32(WebCore.CommentToken.rawValue)

    while true {
        let token = tokenizer.nextToken(span)
        // The only thing read back off a finished token: end-of-file to stop the loop, and
        // CommentToken to keep comments out of the buffer.
        let type = token.bits.type
        if type == endOfFileType { break }

        // Comments never enter `m_tokens`: the C++ scanner drops them too, and
        // CSSParserToken::serialize has an ASSERT_NOT_REACHED for one.
        if type == commentType {
            if wantsObserverRecords { observerRecords.append(observerRecord(token, isComment: true)) }
            continue
        }

        tokens.append(token.bits)
        if wantsObserverRecords { observerRecords.append(observerRecord(token, isComment: false)) }

        if tokens.count == chunkCapacity {
            guard sink.takeChunk(tokens.span, tokenizer.unescapedUnits, observerRecords.span) else { return false }
            tokens.removeAll()
            observerRecords.removeAll()
            tokenizer.startChunk()
        }
    }

    // `observerRecords` and not just `tokens`: a comment produces a record and no token, so an
    // input whose tail is a comment has records left to hand over with an empty token chunk.
    if !tokens.isEmpty || !observerRecords.isEmpty {
        guard sink.takeChunk(tokens.span, tokenizer.unescapedUnits, observerRecords.span) else { return false }
    }
    sink.finish()
    return true
}

/// 8-bit input: the common case, a stylesheet that survives preprocessing as Latin-1.
///
/// One of this file's two `Span(_unsafeCxxSpan:)` sites; there is no safe way yet to import a
/// `std::span` where the callee is Swift (rdar://186723514). Both the count and the lifetime are
/// on trust: the initializer's `@lifetime(borrow span)` is on the imported `std::span` value, and
/// `_cxxOverrideLifetime` inside it makes that dependency vacuous, so nothing ties the borrow to
/// the owner. What holds in fact is that the span is `m_input.currentString()` and
/// `CSSTokenizerInputStream::m_string` is a `RefPtr<StringImpl>` outliving this call; narrowing
/// that member to a `StringView` or a raw span would invalidate this with no diagnostic.
///
/// The span also aliases memory C++ still reaches, and C++ is re-entered inside the borrow via
/// `takeChunk`, so nothing on that path may write it: `takeChunk` touches `m_input` only through
/// the const `rangeAt`, `StringImpl` character storage is immutable and never relocated, and
/// growing `m_stringPool` moves `RefPtr`s rather than character data.
@_expose(Cxx)
public func cssTokenizeSwiftAll8(
    _ data: WebCore.CSSTokenizerSpan8,
    _ sink: WebCore.CSSSwiftTokenSink
) -> Bool {
    tokenizeAll(unsafe Span<UInt8>(_unsafeCxxSpan: data), sink)
}

/// 16-bit input, a separate specialization of the same implementation, so neither width pays for
/// the other. The second `Span(_unsafeCxxSpan:)` site, with the same cause and the same
/// invariants as `cssTokenizeSwiftAll8` above (rdar://186723514).
@_expose(Cxx)
public func cssTokenizeSwiftAll16(
    _ data: WebCore.CSSTokenizerSpan16,
    _ sink: WebCore.CSSSwiftTokenSink
) -> Bool {
    tokenizeAll(unsafe Span<UInt16>(_unsafeCxxSpan: data), sink)
}
