// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

// Only this file's boundary types, not the WebCore_Private umbrella, which reaches JavaScriptCore
// headers whose inner structs sit in explicit submodules nothing imports.
public import WebCore_Private.CSSTokenizerSwiftTypes
// A header can appear in only one submodule, and `CSSUnitType` shares one with the unit constants.
internal import WebCore_Private.CSSUnitsSwiftTypes

// Swift tokenizer for the CSS parser, a port of CSSTokenizer.cpp and CSSTokenizerInputStream.h,
// used when WebCore is built with WK_USE_SWIFT_CSS.
//
// Each token is written as `CSSParserTokenBits`, `CSSParserToken`'s own storage, by the factory
// for its kind in CSSParserTokenBitsSwift.swift. In place of a value pointer it carries an offset,
// which C++ turns into a pointer in `resolveValuePointer`; the offset's top bit says whether it
// indexes the input or the chunk's unescape buffer, which holds values that contained escapes.
//
// Numbers are converted by C++'s charactersToDouble. Until then the union carries the number's
// own range, because once a dimension's number and unit are merged the number is not recoverable
// from the value.

// Swift imports the unscoped `WebCore.CSSParserTokenType` enumerators as global constants, so
// they are spelled `WebCore.IdentToken`.

/// Mirrors CSSParserToken::BlockType.
@c
enum CSSBlockTypeSwift: UInt8 {
    case notBlock = 0
    case blockStart, blockEnd
}

/// A finished token.
///
/// The offsets are for the observer: `CSSParserTokenBits` has no room for an extent.
struct EmittedToken {
    var bits: WebCore.CSSParserTokenBits
    var start: UInt32
    var end: UInt32
}

/// Generic over the code unit so one implementation serves both `StringImpl` widths.
///
/// Nothing here looks above U+007F except to ask whether a unit is ASCII, which is all the CSS
/// syntax spec's name-code-point rule needs, so working per code unit is correct for 16-bit input
/// too: surrogates are name code points, and preprocessing has replaced unpaired ones.
protocol CSSCodeUnit: FixedWidthInteger & UnsignedInteger {}
extension UInt8: CSSCodeUnit {}
extension UInt16: CSSCodeUnit {}

// MARK: - Character predicates (CSSParserIdioms.h, ASCIICType.h)

@inline(always)
private func isASCIIByte(_ c: some CSSCodeUnit) -> Bool { c <= 0x7F }
@inline(always)
private func isASCIIDigitByte(_ c: some CSSCodeUnit) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(always)
private func isASCIIAlphaByte(_ c: some CSSCodeUnit) -> Bool {
    ((c | 0x20) >= 0x61) && ((c | 0x20) <= 0x7A)
}
@inline(always)
private func isASCIIHexDigitByte(_ c: some CSSCodeUnit) -> Bool {
    isASCIIDigitByte(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66)
}
@inline(always)
private func hexValue(_ c: some CSSCodeUnit) -> UInt32 {
    // Callers guard with isASCIIHexDigitByte, so both subtractions are in range.
    isASCIIDigitByte(c) ? UInt32(c &- 0x30) : UInt32((c | 0x20) &- 0x61) &+ 10
}
/// isASCIIWhitespace: space, \n, \t, \r, \f. \v is not included.
@inline(always)
private func isASCIIWhitespaceByte(_ c: some CSSCodeUnit) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D || c == 0x0C
}
/// isCSSNewline: \n, \r, \f.
@inline(always)
private func isCSSNewlineByte(_ c: some CSSCodeUnit) -> Bool {
    c == 0x0A || c == 0x0D || c == 0x0C
}
/// isNameStartCodePoint: ASCII alpha, '_', or any non-ASCII.
@inline(always)
private func isNameStartByte(_ c: some CSSCodeUnit) -> Bool {
    isASCIIAlphaByte(c) || c == 0x5F || !isASCIIByte(c)
}
/// Whether a code unit is a name code point: a name-start code point, a digit, or `-`.
///
/// CSSTokenizer's `isNameCodePoint`.
@inline(always)
private func isNameByte(_ c: some CSSCodeUnit) -> Bool {
    isNameStartByte(c) || isASCIIDigitByte(c) || c == 0x2D
}
@inline(always)
private func isNonPrintableByte(_ c: some CSSCodeUnit) -> Bool {
    c <= 0x08 || c == 0x0B || (c >= 0x0E && c <= 0x1F) || c == 0x7F
}

/// Reads past the end as the EOF marker.
///
/// The guard is spelled as `Span`'s own precondition is, signed and two-sided, so the optimizer
/// can prove the precondition from it; an unsigned one-sided compare does not always let it.
/// Loops whose condition already bounds the index subscript directly instead.
@inline(always)
private func byteAt<Unit: CSSCodeUnit>(_ data: Span<Unit>, _ index: Int) -> Unit {
    data.indices.contains(index) ? data[index] : 0
}

/// The 128-entry dispatch class, a `switch` in place of CSSTokenizer::codePoints' table of member
/// function pointers.
private enum Dispatch {
    case endOfFile, whitespace, newline, stringStart, hash, dollarSign
    case leftParenthesis, rightParenthesis, asterisk, plusOrFullStop, comma
    case hyphenMinus, solidus, asciiDigit, colon, semiColon, lessThan
    case commercialAt, nameStart, leftBracket, reverseSolidus, rightBracket
    case circumflexAccent, leftBrace, verticalLine, rightBrace, tilde
    case delimiter
}

@inline(always)
private func dispatchClass(_ c: some CSSCodeUnit) -> Dispatch {
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

/// The sign a number carried. `makeNumericTokenBits` maps it onto the imported `NumericSign`.
private enum ScannedSign {
    case none, plus, minus
}

/// The result of scanning a number: its own range in the input.
///
/// The range is the `originalText` of a `CSSParserToken`, and what C++ hands to
/// `charactersToDouble`.
private struct ScannedNumber {
    var start: UInt32 = 0
    var length: UInt32 = 0
    var isNonInteger = false
    var sign = ScannedSign.none
}

struct CSSTokenizerSwift<Unit: CSSCodeUnit>: ~Copyable {
    /// The input cursor.
    ///
    /// As in C++ it may advance past the end, so every read clamps and every report goes
    /// through `clampedOffset`.
    private var offset = 0
    /// Owned here and growable, so nesting depth is unbounded.
    private var blockStack = UniqueArray<UInt8>()

    /// Code units of values that contained escapes, in the order the tokens referring to them
    /// were produced.
    ///
    /// UTF-16 rather than the input's code unit, because an escape can name any code point:
    /// `\1F3A8` unescapes to a surrogate pair even in 8-bit input.
    private var unescaped = UniqueArray<UInt16>()
    /// Appends one code point, UTF-16 encoded.
    @inline(always)
    private mutating func appendUnescaped(_ codePoint: UInt32) {
        if codePoint > 0xFFFF {
            let value = codePoint &- 0x10000
            unescaped.append(UInt16(truncatingIfNeeded: 0xD800 &+ (value >> 10)))
            unescaped.append(UInt16(truncatingIfNeeded: 0xDC00 &+ (value & 0x3FF)))
            return
        }
        unescaped.append(UInt16(truncatingIfNeeded: codePoint))
    }

    @inline(always)
    private mutating func appendUnescaped(unit: Unit) {
        appendUnescaped(UInt32(truncatingIfNeeded: unit))
    }

    /// Range of the unescape buffer filled since `mark`.
    @inline(always)
    private func unescapedValue(since mark: Int) -> ScannedValue {
        ScannedValue(
            start: UInt32(truncatingIfNeeded: mark),
            length: UInt32(truncatingIfNeeded: unescaped.count &- mark),
            unescaped: true
        )
    }

    /// A tokenizer at the start of its input.
    public init() {}

    /// How far the cursor has advanced, which may be past the end of the input.
    public var consumedOffset: Int { offset }

    var unescapedUnits: Span<UInt16> { unescaped.span }

    /// Drops the previous chunk's unescaped units, so a token value range is always an offset
    /// into the chunk currently being handed over.
    mutating func startChunk() { unescaped.removeAll() }

    // MARK: Input stream (CSSTokenizerInputStream)

    @inline(always)
    private func peek(_ data: Span<Unit>, _ lookahead: Int) -> Unit {
        // Wrapping add: `offset` is at most `data.count + 1` and `lookahead` is a small literal.
        // Past the end reads as the EOF marker (NUL); preprocessing has removed any real NULs.
        byteAt(data, offset &+ lookahead)
    }

    @inline(always)
    private mutating func consume(_ data: Span<Unit>) -> Unit {
        let c = peek(data, 0)
        offset &+= 1
        return c
    }

    @inline(always)
    private mutating func advance(_ n: Int = 1) { offset &+= n }
    @inline(always)
    private mutating func reconsume() { offset &-= 1 }

    /// The cursor may be one past the end after consuming the EOF marker.
    @inline(always)
    private func clampedOffset(_ data: Span<Unit>) -> Int {
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

    @inline(always)
    private mutating func consumeIfNext(_ data: Span<Unit>, _ c: Unit) -> Bool {
        if peek(data, 0) == c {
            advance()
            return true
        }
        return false
    }

    @inline(always)
    private func twoCharsAreValidEscape(_ first: Unit, _ second: Unit) -> Bool {
        first == 0x5C && !isCSSNewlineByte(second)
    }

    private func nextTwoCharsAreValidEscape(_ data: Span<Unit>) -> Bool {
        twoCharsAreValidEscape(peek(data, 0), peek(data, 1))
    }

    // MARK: Token construction helpers
    //
    // Each of these calls the factory for one token kind with the kind as a literal;
    // `@inline(always)` lets the switch inside each factory fold away.

    /// `valueIs8Bit` for any value that is a range of the input.
    private static var valueIs8Bit: Bool { Unit.bitWidth == 8 }

    @inline(always)
    private func emit(
        _ bits: WebCore.CSSParserTokenBits,
        _ start: Int,
        _ data: Span<Unit>
    ) -> EmittedToken {
        EmittedToken(
            bits: bits,
            start: UInt32(truncatingIfNeeded: start),
            end: UInt32(truncatingIfNeeded: clampedOffset(data))
        )
    }

    @inline(always)
    private func token(
        _ type: WebCore.CSSParserTokenType,
        _ start: Int,
        _ data: Span<Unit>,
        block: CSSBlockTypeSwift = .notBlock
    ) -> EmittedToken {
        emit(makeSimpleTokenBits(UInt32(type.rawValue), UInt32(block.rawValue)), start, data)
    }

    @inline(always)
    private func delimiter(_ c: Unit, _ start: Int, _ data: Span<Unit>) -> EmittedToken {
        emit(
            makeDelimiterTokenBits(
                UInt32(WebCore.DelimiterToken.rawValue),
                UInt32(truncatingIfNeeded: c)
            ),
            start,
            data
        )
    }

    @inline(always)
    private func whitespace(
        _ count: Int,
        _ start: Int,
        _ data: Span<Unit>
    ) -> EmittedToken {
        emit(
            makeWhitespaceTokenBits(
                UInt32(WebCore.NonNewlineWhitespaceToken.rawValue),
                UInt32(truncatingIfNeeded: count)
            ),
            start,
            data
        )
    }

    @inline(always)
    private func valueToken(
        _ type: WebCore.CSSParserTokenType,
        _ value: ScannedValue,
        _ start: Int,
        _ data: Span<Unit>,
        block: CSSBlockTypeSwift = .notBlock
    ) -> EmittedToken {
        emit(
            makeValueTokenBits(
                UInt32(type.rawValue),
                UInt32(block.rawValue),
                value.start,
                value.length,
                value.unescaped,
                Self.valueIs8Bit
            ),
            start,
            data
        )
    }

    @inline(always)
    private func hashToken(
        _ value: ScannedValue,
        isId: Bool,
        _ start: Int,
        _ data: Span<Unit>
    ) -> EmittedToken {
        emit(
            makeHashTokenBits(
                UInt32(WebCore.HashToken.rawValue),
                isId,
                value.start,
                value.length,
                value.unescaped,
                Self.valueIs8Bit
            ),
            start,
            data
        )
    }

    @inline(always)
    private mutating func pushBlock(_ type: WebCore.CSSParserTokenType) {
        blockStack.append(type.rawValue)
    }

    private mutating func blockStart(
        _ type: WebCore.CSSParserTokenType,
        _ start: Int,
        _ data: Span<Unit>
    ) -> EmittedToken {
        pushBlock(type)
        return token(type, start, data, block: .blockStart)
    }

    private mutating func blockEnd(
        _ type: WebCore.CSSParserTokenType,
        _ startType: WebCore.CSSParserTokenType,
        _ start: Int,
        _ data: Span<Unit>
    ) -> EmittedToken {
        // The unsigned compare both bounds-checks and tests for an empty stack.
        let top = blockStack.count &- 1
        if UInt(bitPattern: top) < UInt(bitPattern: blockStack.count),
            blockStack[top] == startType.rawValue
        {
            _ = blockStack.removeLast()
            return token(type, start, data, block: .blockEnd)
        }
        return token(type, start, data)
    }

    // MARK: - The tokenizer

    /// Returns the next token; `.endOfFile` when the input is exhausted.
    ///
    /// Mirrors CSSTokenizer::nextToken.
    ///
    /// `@inline(always)` because past the inliner's threshold this would cost the entry points a
    /// call per token.
    @inline(always)
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

    /// Mirrors CSSTokenizer::consumeNumber.
    ///
    /// The conversion itself is left to C++.
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
    @inline(always)
    private func skipDigits(_ data: Span<Unit>, from: Int) -> Int {
        var relative = from
        let count = data.count
        // Per-digit, so wrapping: `offset &+ relative` is bounded by the input.
        while offset &+ relative < count, isASCIIDigitByte(data[offset &+ relative]) {
            relative &+= 1
        }
        return relative
    }

    /// Mirrors CSSTokenizer::consumeNumericToken and, for a dimension, the
    /// `convertToDimensionWithUnit(StringView)` pass C++ runs on the finished token, which
    /// resolves the unit and decides the value: `mergeIfAdjacent` joins number and unit when they
    /// are adjacent and the number is shorter than sixteen characters, so `10px` has value
    /// `"10px"` while `1\70x` has value `"px"`. `nonUnitPrefixLength` records which.
    private mutating func consumeNumericToken(_ data: Span<Unit>, _ start: Int) -> EmittedToken {
        let number = consumeNumber(data)

        if nextCharsAreIdentifier(data) {
            let unit = consumeName(data)
            let unitRange = Int(unit.start)..<Int(unit.start &+ unit.length)
            let unitType =
                unit.unescaped
                ? cssPrimitiveValueUnitFromTrie(unescaped.span.extracting(unitRange))
                : cssPrimitiveValueUnitFromTrie(data.extracting(unitRange))

            // mergeIfAdjacent's own conditions: both views the same width, physically adjacent,
            // and the number shorter than sixteen characters. `nonUnitPrefixLength` is four bits
            // wide, and the last condition is what keeps the number's length inside it.
            let merged =
                !unit.unescaped
                && number.length >= 1 && number.length < 16
                && unit.start == number.start &+ number.length
            return emit(
                makeNumericTokenBits(
                    UInt32(WebCore.DimensionToken.rawValue),
                    number.isNonInteger,
                    number.sign == .plus,
                    number.sign == .minus,
                    UInt32(unitType.rawValue),
                    merged ? number.start : unit.start,
                    merged ? number.length &+ unit.length : unit.length,
                    unit.unescaped,
                    merged ? number.length : 0,
                    number.start,
                    number.length,
                    Self.valueIs8Bit
                ),
                start,
                data
            )
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
    @inline(always)
    private func numericToken(
        _ type: WebCore.CSSParserTokenType,
        unit: WebCore.CSSUnitType,
        _ number: ScannedNumber,
        _ start: Int,
        _ data: Span<Unit>
    ) -> EmittedToken {
        emit(
            makeNumericTokenBits(
                UInt32(type.rawValue),
                number.isNonInteger,
                number.sign == .plus,
                number.sign == .minus,
                UInt32(unit.rawValue),
                number.start,
                number.length,
                false,
                0,
                number.start,
                number.length,
                Self.valueIs8Bit
            ),
            start,
            data
        )
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
                unescaped: false
            )
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
        _ data: Span<Unit>,
        _ endingCodePoint: Unit,
        _ start: Int
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

/// A free function rather than a closure over the buffer, so nothing captures a `~Copyable`
/// container.
@inline(always)
private func observerRecord(
    _ token: EmittedToken,
    isComment: Bool
) -> WebCore.CSSSwiftObserverRecord {
    var entry = WebCore.CSSSwiftObserverRecord()
    entry.start = token.start
    entry.end = token.end
    entry.isComment = isComment ? 1 : 0
    return entry
}

/// The stack staging buffer's token count. `withTemporaryAllocation` uses the stack only for
/// requests of at most 1024 bytes (`_isStackAllocationSafe`), and 42 tokens of 24 bytes is 1008.
private let stackTokenCapacity = 42

/// The longest input staged on the stack, well above a typical declaration or property value.
///
/// A full buffer is handed over as a chunk, so correctness does not depend on it.
private let stackInputLimit = 512

/// Chunked so the buffer stays cache-resident.
private let heapTokenCapacity = 1024

/// Where finished tokens wait for the next `takeChunk`: `OutputSpan` over a stack buffer for a
/// short input, `UniqueArray` for a long one. A protocol so that `tokenizeAll(_:_:_:)` is
/// specialized for each. `withTemporaryAllocation`'s own heap fallback is not used because it
/// runs the body as a separate function, where the `CSSParserTokenBits` bitfield accessors are
/// not inlined.
private protocol CSSTokenStaging: ~Copyable, ~Escapable {
    var tokenCapacity: Int { get }
    var isFull: Bool { get }
    var isEmpty: Bool { get }
    mutating func append(_ bits: WebCore.CSSParserTokenBits)
    /// Hands the staged tokens to `sink` and empties the buffer. Returns what `takeChunk` did.
    mutating func takeChunk(
        _ sink: inout WebCore.CSSSwiftTokenSink,
        _ unescapedUnits: Span<UInt16>,
        _ records: Span<WebCore.CSSSwiftObserverRecord>
    ) -> Bool
}

extension OutputSpan: CSSTokenStaging where Element == WebCore.CSSParserTokenBits {
    var tokenCapacity: Int { capacity }

    @inline(always)
    mutating func takeChunk(
        _ sink: inout WebCore.CSSSwiftTokenSink,
        _ unescapedUnits: Span<UInt16>,
        _ records: Span<WebCore.CSSSwiftObserverRecord>
    ) -> Bool {
        guard sink.takeChunk(span, unescapedUnits, records) else { return false }
        removeAll()
        return true
    }
}

private struct CSSHeapTokenStaging: ~Copyable, CSSTokenStaging {
    private var tokens = UniqueArray<WebCore.CSSParserTokenBits>()

    init(capacity: Int) { tokens.reserveCapacity(capacity) }

    var tokenCapacity: Int { tokens.capacity }
    var isFull: Bool { tokens.count == tokens.capacity }
    var isEmpty: Bool { tokens.isEmpty }
    @inline(always)
    mutating func append(_ bits: WebCore.CSSParserTokenBits) { tokens.append(bits) }

    @inline(always)
    mutating func takeChunk(
        _ sink: inout WebCore.CSSSwiftTokenSink,
        _ unescapedUnits: Span<UInt16>,
        _ records: Span<WebCore.CSSSwiftObserverRecord>
    ) -> Bool {
        guard sink.takeChunk(tokens.span, unescapedUnits, records) else { return false }
        tokens.removeAll()
        return true
    }
}

/// Tokenizes a whole stylesheet, handing the tokens to `sink` a chunk at a time.
///
/// Swift owns every buffer, so a full buffer is handed over rather than grown, and nesting depth
/// is unbounded.
///
/// Returns false if the input is too long for its offsets to be tagged or the sink rejected a
/// chunk.
@inline(always)
private func tokenizeAll<Unit: CSSCodeUnit>(
    _ span: Span<Unit>,
    _ sink: inout WebCore.CSSSwiftTokenSink
) -> Bool {
    guard cssParserTokenBitsCanRepresentOffsets(numericCast(span.count)) else { return false }

    if span.count <= stackInputLimit {
        return withTemporaryAllocation(of: WebCore.CSSParserTokenBits.self, capacity: stackTokenCapacity) { tokens in
            tokenizeAll(span, &sink, &tokens)
        }
    }

    // Every token consumes at least one code unit, so the input length bounds the token count.
    var tokens = CSSHeapTokenStaging(capacity: min(heapTokenCapacity, span.count))
    return tokenizeAll(span, &sink, &tokens)
}

@inline(always)
private func tokenizeAll<Unit: CSSCodeUnit, Staging: CSSTokenStaging & ~Copyable & ~Escapable>(
    _ span: Span<Unit>,
    _ sink: inout WebCore.CSSSwiftTokenSink,
    _ tokens: inout Staging
) -> Bool {
    var tokenizer = CSSTokenizerSwift<Unit>()

    // With no observer this stays at capacity zero and never allocates.
    let wantsObserverRecords = sink.wantsObserverRecords()
    var observerRecords = UniqueArray<WebCore.CSSSwiftObserverRecord>()
    if wantsObserverRecords {
        // One record per token plus one per comment, so this is a floor.
        observerRecords.reserveCapacity(tokens.tokenCapacity)
    }

    let endOfFileType = UInt32(WebCore.EOFToken.rawValue)
    let commentType = UInt32(WebCore.CommentToken.rawValue)

    while true {
        let token = tokenizer.nextToken(span)
        let type = token.bits.type
        if type == endOfFileType { break }

        // Comments never enter `m_tokens`, as in the C++ scanner.
        if type == commentType {
            if wantsObserverRecords { observerRecords.append(observerRecord(token, isComment: true)) }
            continue
        }

        tokens.append(token.bits)
        if wantsObserverRecords { observerRecords.append(observerRecord(token, isComment: false)) }

        if tokens.isFull {
            guard tokens.takeChunk(&sink, tokenizer.unescapedUnits, observerRecords.span) else { return false }
            observerRecords.removeAll()
            tokenizer.startChunk()
        }
    }

    // A trailing comment leaves a record with no token.
    if !tokens.isEmpty || !observerRecords.isEmpty {
        guard tokens.takeChunk(&sink, tokenizer.unescapedUnits, observerRecords.span) else { return false }
    }
    sink.finish()
    return true
}

/// 8-bit input, the common case.
///
/// `Span(_unsafeCxxSpan:)` because a `std::span` passed to a Swift callee cannot yet be imported
/// safely (rdar://186723514). Its lifetime dependency is vacuous, so the borrow holds only because
/// `CSSTokenizerInputStream::m_string` is a `RefPtr<StringImpl>` that outlives this call; making
/// that member a `StringView` or raw span would silently invalidate this.
///
/// C++ is re-entered through `takeChunk` during the borrow and must not write the span:
/// `takeChunk` reads `m_input` only through the const `rangeAt`, `StringImpl` character storage
/// is immutable, and growing `m_stringPool` moves `RefPtr`s, not characters.
@_expose(Cxx)
public func cssTokenizeSwiftAll8(
    _ data: WebCore.CSSTokenizerSpan8,
    _ sink: inout WebCore.CSSSwiftTokenSink
) -> Bool {
    tokenizeAll(unsafe Span<UInt8>(_unsafeCxxSpan: data), &sink)
}

/// 16-bit input.
///
/// Same `Span(_unsafeCxxSpan:)` invariants as `cssTokenizeSwiftAll8`
/// (rdar://186723514).
@_expose(Cxx)
public func cssTokenizeSwiftAll16(
    _ data: WebCore.CSSTokenizerSpan16,
    _ sink: inout WebCore.CSSSwiftTokenSink
) -> Bool {
    tokenizeAll(unsafe Span<UInt16>(_unsafeCxxSpan: data), &sink)
}
