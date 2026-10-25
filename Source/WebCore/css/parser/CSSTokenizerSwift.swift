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

#if USE_SWIFT_CSS_TOKENIZER

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

internal import WebCore_Private.Core.CSSParserToken
internal import WebCore_Private.Core.CSSTokenizerSwiftTypes

// The CSS tokenizer's scanner (https://drafts.csswg.org/css-syntax/#tokenization), used in place of
// CSSTokenizer::nextToken and the functions it calls. CSSTokenizer's constructor preprocesses the
// input and calls one entry point per character width; the scanner reports each token to the
// CSSTokenizerSink, which builds it in the tokenizer's token list from offsets into the input, or, for a
// value the scanner built, from CSSTokenizerScannerState.unescaped.

// CharacterNames.h's replacementCharacter and ICU's UCHAR_MAX_VALUE; CSSTokenizer.cpp checks both.
private let replacementCharacter: UInt32 = 0xFFFD
private let maximumCodePoint: UInt32 = 0x10FFFF

// kEndOfFileMarker: reads past the end of the input return it. Preprocessing has replaced every NUL, so
// inside the input it never appears.
private let endOfFileMarker = 0

@inline(always)
private func code(_ type: WebCore.CSSParserTokenType) -> UInt8 {
    UInt8(type.rawValue)
}

@inline(always)
private func code(_ blockType: WebCore.CSSParserToken.BlockType) -> UInt8 {
    UInt8(blockType.rawValue)
}

/// A level of the block stack: 1, 2 and 3 for the opening token types `(`, `[` and `{`, the only ones
/// pushed (a function token pushes `(`).
@inline(always)
private func blockCode(_ type: WebCore.CSSParserTokenType) -> UInt8 {
    type == WebCore.LeftParenthesisToken ? 1 : type == WebCore.LeftBracketToken ? 2 : 3
}

/// The block code of a closing bracket's opener, the code unit divided by 32: `)` is 0x29, `]` 0x5D and
/// `}` 0x7D.
@inline(always)
private func blockCode(closer: UInt64) -> UInt64 {
    closer >> 5
}

/// The token types of `)`, `]` and `}`, each at the byte its block code indexes.
@inline(always)
private func closerType(_ blockCode: UInt64) -> UInt8 {
    let types =
        UInt64(code(WebCore.RightParenthesisToken)) << 8 | UInt64(code(WebCore.RightBracketToken)) << 16
        | UInt64(code(WebCore.RightBraceToken)) << 24
    // The block code is 1, 2 or 3, so the shift is below 64.
    return UInt8(truncatingIfNeeded: types &>> (blockCode * 8))
}

@inline(always)
private func code(_ sign: WebCore.NumericSign) -> UInt8 {
    UInt8(sign.rawValue)
}

/// A code unit of 8-bit or 16-bit input.
///
/// Nothing here looks above U+007F except to ask whether a code unit is ASCII, which is all the name code
/// point rule needs, so scanning by code unit is right for 16-bit input too: surrogates are name code
/// points, and preprocessing has replaced unpaired ones.
///
/// FIXME: Make this and its witnesses private again once a private protocol links under LTO on Windows. With more
/// than one object file per module (the CMake build's -num-threads), a private protocol's requirement descriptors are
/// linkonce_odr aliases to offsets into the protocol descriptor, which LLVM's COFF bitcode symbol table rejects as an
/// "Invalid weak external" (IRSymtab.cpp), so WebCore.dll does not link.
protocol CSSCodeUnit: FixedWidthInteger & UnsignedInteger {
    /// The index of the first of the first sixteen code units of `units`, which holds seventeen, that is a
    /// `*` followed by a `/`; 16 when there is none.
    static func commentEndIndex(_ units: Span<Self>) -> Int

    /// The number of leading code units of `units`, which holds sixteen, that are a space or a tab; 16 when
    /// all are.
    static func leadingSpaceOrTabCount(_ units: Span<Self>) -> Int
}

extension UInt8: CSSCodeUnit {
    @inline(always)
    static func commentEndIndex(_ units: Span<UInt8>) -> Int {
        // A lane of `pair` is zero where the code unit is `*` and the next is `/`; `(pair - 1) & ~pair` sets
        // the top bit of exactly those lanes.
        let pair = (load16(units, at: 0) ^ 0x2A) | (load16(units, at: 1) ^ 0x2F)
        let found = (pair &- 1) & ~pair
        guard anyHighBit(found) else { return 16 }
        return highBitMask(found).trailingZeroBitCount
    }

    @inline(always)
    static func leadingSpaceOrTabCount(_ units: Span<UInt8>) -> Int {
        // `x | (0 - x)` has its top bit set exactly when `x` is not zero, so a lane of `other` has its top bit
        // set exactly when the code unit is neither a space nor a tab.
        let v = load16(units, at: 0)
        let space = v ^ 0x20
        let tab = v ^ 0x09
        let other = bitCast((space | (0 &- space)) & (tab | (0 &- tab)), to: SIMD2<UInt64>.self)
        return leadingClearLanes(other[0] & 0x8080_8080_8080_8080, other[1] & 0x8080_8080_8080_8080)
    }
}

extension UInt16: CSSCodeUnit {
    @inline(always)
    static func commentEndIndex(_ units: Span<UInt16>) -> Int {
        // As for 8-bit input, comparing whole code units, so that U+012A is not a `*`.
        let bytes = units.bytes
        let low =
            (bytes.load(fromByteOffset: 0, as: SIMD8<UInt16>.self) ^ 0x2A)
            | (bytes.load(fromByteOffset: 2, as: SIMD8<UInt16>.self) ^ 0x2F)
        let high =
            (bytes.load(fromByteOffset: 16, as: SIMD8<UInt16>.self) ^ 0x2A)
            | (bytes.load(fromByteOffset: 18, as: SIMD8<UInt16>.self) ^ 0x2F)
        let found = narrowToLowBytes(((low &- 1) & ~low) &>> 8, ((high &- 1) & ~high) &>> 8)
        guard anyHighBit(found) else { return 16 }
        return highBitMask(found).trailingZeroBitCount
    }

    @inline(always)
    static func leadingSpaceOrTabCount(_ units: Span<UInt16>) -> Int {
        // As for 8-bit input, comparing whole code units, so that U+0120 is not a space; then the top bit of
        // each lane's high byte, gathered into eight bits per lane.
        let bytes = units.bytes
        let low = bytes.load(fromByteOffset: 0, as: SIMD8<UInt16>.self)
        let high = bytes.load(fromByteOffset: 16, as: SIMD8<UInt16>.self)
        let lowSpace = low ^ 0x20
        let lowTab = low ^ 0x09
        let highSpace = high ^ 0x20
        let highTab = high ^ 0x09
        let other = narrowToLowBytes(
            ((lowSpace | (0 &- lowSpace)) & (lowTab | (0 &- lowTab))) &>> 8,
            ((highSpace | (0 &- highSpace)) & (highTab | (0 &- highTab))) &>> 8
        )
        let words = bitCast(other, to: SIMD2<UInt64>.self)
        return leadingClearLanes(words[0] & 0x8080_8080_8080_8080, words[1] & 0x8080_8080_8080_8080)
    }
}

/// The number of eight-bit lanes before the first set bit of the 128-bit value `low`, `high`; 16 when there is none.
///
/// Only each lane's top bit may be set.
@inline(always)
private func leadingClearLanes(_ low: UInt64, _ high: UInt64) -> Int {
    if low | high == 0 { return 16 }
    return low != 0 ? low.trailingZeroBitCount >> 3 : 8 + high.trailingZeroBitCount >> 3
}

// MARK: - Character classes (CSSParserIdioms.h, ASCIICType.h)

@inline(always)
private func isASCIIDigit(_ c: some CSSCodeUnit) -> Bool { c >= 0x30 && c <= 0x39 }

@inline(always)
private func isASCIIHexDigit(_ c: some CSSCodeUnit) -> Bool {
    isASCIIDigit(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66)
}

/// Only for a code unit that `isASCIIHexDigit` accepted, so neither subtraction wraps.
@inline(always)
private func hexValue(_ c: some CSSCodeUnit) -> UInt32 {
    isASCIIDigit(c) ? UInt32(truncatingIfNeeded: c &- 0x30) : UInt32(truncatingIfNeeded: (c | 0x20) &- 0x57)
}

/// 10^n for n from 0 to 22, the powers of ten a Double holds exactly.
@inline(always)
private func exactPowerOfTen(_ n: Int) -> Double {
    switch n {
    case 0: 1e0
    case 1: 1e1
    case 2: 1e2
    case 3: 1e3
    case 4: 1e4
    case 5: 1e5
    case 6: 1e6
    case 7: 1e7
    case 8: 1e8
    case 9: 1e9
    case 10: 1e10
    case 11: 1e11
    case 12: 1e12
    case 13: 1e13
    case 14: 1e14
    case 15: 1e15
    case 16: 1e16
    case 17: 1e17
    case 18: 1e18
    case 19: 1e19
    case 20: 1e20
    case 21: 1e21
    default: 1e22
    }
}

/// `significand` x 10^(exponent - fractionLength), negated if `isNegative`, when one correctly rounded operation gives
/// the value charactersToDouble would; NaN otherwise.
///
/// At scale 0 that is the significand's conversion. Otherwise a significand below 10^15 and 10^n up to 10^22 are
/// exact doubles, so the product or quotient is correctly rounded.
@inline(always)
private func exactValue(
    _ significand: UInt64,
    exponent: UInt64,
    exponentIsNegative: Bool,
    fractionLength: Int,
    isNegative: Bool
) -> Double {
    guard exponent <= 64 else {
        return .nan
    }
    // Both terms are at most 64, so neither operation overflows.
    let power = Int(truncatingIfNeeded: exponent)
    let scale = (exponentIsNegative ? 0 &- power : power) &- fractionLength
    let magnitude: Double
    if scale == 0 {
        magnitude = Double(significand)
    } else if significand >= 1_000_000_000_000_000 {
        return .nan
    } else if (0...22).contains(scale) {
        magnitude = Double(significand) * exactPowerOfTen(scale)
    } else if (-22..<0).contains(scale) {
        magnitude = Double(significand) / exactPowerOfTen(-scale)
    } else {
        return .nan
    }
    return isNegative ? -magnitude : magnitude
}

/// Bit `c & 63` of `low` for `c` below 0x40, of `high` for `c` from 0x40, as 0 or 1: a character class test
/// with no branch on the character.
@inline(always)
private func classBit(_ c: some CSSCodeUnit, low: UInt64, high: UInt64) -> UInt64 {
    let w = UInt64(truncatingIfNeeded: c)
    let mask = w & 0x40 == 0 ? low : high
    return (mask >> (w & 63)) & 1
}

/// Whether `c` is non-ASCII or in the ASCII class given by `low` and `high` (see `classBit`).
@inline(always)
private func isNonASCIIOrInClass(_ c: some CSSCodeUnit, low: UInt64, high: UInt64) -> Bool {
    let nonASCII: UInt64 = c >> 7 != 0 ? 1 : 0
    return classBit(c, low: low, high: high) | nonASCII != 0
}

/// isASCIIWhitespace: space, `\t`, `\n`, `\f` and `\r`, but not `\v`.
@inline(always)
private func isASCIIWhitespace(_ c: some CSSCodeUnit) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D
}

/// A space or a tab: the whitespace that is not a newline.
@inline(always)
private func isSpaceOrTab(_ c: some CSSCodeUnit) -> Bool {
    c == 0x20 || c == 0x09
}

/// isCSSNewline: `\n`, `\r` and `\f`.
@inline(always)
private func isCSSNewline(_ c: some CSSCodeUnit) -> Bool {
    c == 0x0A || c == 0x0D || c == 0x0C
}

// The `high` mask 0x07FF_FFFE_87FF_FFFE is `A`-`Z`, `_` and `a`-`z`; the `low` mask 0x03FF_2000_0000_0000 is
// `-` and `0`-`9`.
@inline(always)
private func isNameStartCodePoint(_ c: some CSSCodeUnit) -> Bool {
    isNonASCIIOrInClass(c, low: 0, high: 0x07FF_FFFE_87FF_FFFE)
}

@inline(always)
private func isNameCodePoint(_ c: some CSSCodeUnit) -> Bool {
    isNonASCIIOrInClass(c, low: 0x03FF_2000_0000_0000, high: 0x07FF_FFFE_87FF_FFFE)
}

// The `low` mask 0x3401 is the end-of-file marker, `\n`, `\f` and `\r`; the `high` mask 0x1000_0000 is `\`.
// Spelled as a class test so that a run of string characters costs no branch that depends on them.
@inline(always)
private func isStringSpecialCodePoint(_ c: some CSSCodeUnit) -> Bool {
    let ascii: UInt64 = c >> 7 == 0 ? 1 : 0
    return classBit(c, low: 0x3401, high: 0x1000_0000) & ascii != 0
}

// https://drafts.csswg.org/css-syntax/#non-printable-code-point
@inline(always)
private func isNonPrintableCodePoint(_ c: some CSSCodeUnit) -> Bool {
    c <= 0x08 || c == 0x0B || (c >= 0x0E && c <= 0x1F) || c == 0x7F
}

// https://drafts.csswg.org/css-syntax/#check-if-two-code-points-are-a-valid-escape
@inline(always)
private func twoCharsAreValidEscape<Unit: CSSCodeUnit>(_ first: Unit, _ second: Unit) -> Bool {
    first == 0x5C && !isCSSNewline(second)
}

/// The code unit at `index`, or the end-of-file marker past the end of the input.
///
/// The test is spelled as `Span`'s own precondition, so the optimizer removes the subscript's check.
@inline(always)
private func character<Unit: CSSCodeUnit>(_ data: Span<Unit>, _ index: Int) -> Unit {
    data.indices.contains(index) ? data[index] : Unit(endOfFileMarker)
}

/// The handler CSSTokenizer::codePoints gives each ASCII character; no entry is a delimiter, and every
/// non-ASCII code unit starts a name.
private enum Dispatch {
    case endOfFile, whitespace, newline, stringStart, hash, dollarSign
    case leftParenthesis, blockEnd, asterisk, plusOrFullStop, comma
    case hyphenMinus, solidus, asciiDigit, colon, semiColon, lessThan
    case commercialAt, nameStart, leftBracket, reverseSolidus
    case circumflexAccent, leftBrace, verticalLine, tilde
    case delimiter
}

/// Each case lists single values, not ranges, so that the switch lowers to one table.
///
/// Name starts fall to the default case: one comparison for non-ASCII, one bit test for ASCII.
@inline(always)
private func dispatch(_ c: some CSSCodeUnit) -> Dispatch {
    switch UInt64(truncatingIfNeeded: c) {
    case 0x00: return .endOfFile
    case 0x09, 0x20: return .whitespace
    case 0x0A, 0x0C, 0x0D: return .newline
    case 0x22, 0x27: return .stringStart
    case 0x23: return .hash
    case 0x24: return .dollarSign
    case 0x28: return .leftParenthesis
    case 0x29, 0x5D, 0x7D: return .blockEnd
    case 0x2A: return .asterisk
    case 0x2B, 0x2E: return .plusOrFullStop
    case 0x2C: return .comma
    case 0x2D: return .hyphenMinus
    case 0x2F: return .solidus
    case 0x3A: return .colon
    case 0x3B: return .semiColon
    case 0x3C: return .lessThan
    case 0x40: return .commercialAt
    case 0x5B: return .leftBracket
    case 0x5C: return .reverseSolidus
    case 0x5E: return .circumflexAccent
    case 0x7B: return .leftBrace
    case 0x7C: return .verticalLine
    case 0x7E: return .tilde
    case 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39: return .asciiDigit
    default:
        if UInt64(truncatingIfNeeded: c) >= 0x80 { return .nameStart }
        return classBit(c, low: 0, high: 0x07FF_FFFE_87FF_FFFE) != 0 ? .nameStart : .delimiter
    }
}

/// What one call of `nextToken` did.
private enum Step {
    case token, comment, endOfFile, failed
}

@inline(always)
private func step(_ appended: Bool) -> Step {
    appended ? .token : .failed
}

/// A name, string or URL: a range of the input, or, when the scanner built it, the whole of
/// `CSSTokenizerScannerState.unescaped`.
private struct ScannedValue {
    var start = 0
    var length = 0
    var unescaped = false
}

/// A number's text in the input, its sign included, and what CSSParserToken records of it.
private struct ScannedNumber {
    var start = 0
    var length = 0
    var isInteger = true
    var sign = WebCore.NoSign
    /// The value, when one correctly rounded operation gives it (exactValue); NaN for any other number,
    /// which the sink converts.
    var value = Double.nan
}

/// The offsets the sink takes.
///
/// The input is a `StringView`, whose length is an `unsigned`, and every offset passed is clamped to that length.
@inline(always)
private func offset32(_ offset: Int) -> UInt32 {
    UInt32(truncatingIfNeeded: offset)
}

/// The scanner's state other than its cursor: the block stack and the buffer the scanner builds values in.
///
/// It stays in memory, so that the token loop keeps the cursor in a register and the functions it calls out
/// of line take and return the cursor by value.
private struct CSSTokenizerScannerState: ~Copyable {
    /// CSSTokenizer's block stack of opening token types, of unbounded depth, each level as its `blockCode`.
    ///
    /// The first 32 levels are in `blockStackInline`, level `k` in bits `2k ..< 2k + 2`;
    /// level `k >= 32` is `blockStackSpill[k - 32]`.
    private var blockStackInline: UInt64 = 0
    private var blockStackDepth = 0
    private var blockStackSpill = UniqueArray<UInt8>()

    /// The value being built, UTF-16 whatever the input's width, because an escape can name any code point.
    ///
    /// It holds one value at a time, which the sink copies into the tokenizer's string pool.
    var unescaped = UniqueArray<UInt16>()

    init() {}

    @inline(always)
    mutating func pushBlock(_ type: WebCore.CSSParserTokenType) {
        let code = blockCode(type)
        if blockStackDepth < 32 {
            // The depth is below 32, so the shift is below 64 and masking it changes nothing.
            let shift = UInt64(truncatingIfNeeded: blockStackDepth &* 2)
            blockStackInline = (blockStackInline & ~(3 &<< shift)) | (UInt64(code) &<< shift)
        } else {
            pushSpilledBlock(code)
        }
        // At most one level per code unit of input.
        blockStackDepth &+= 1
    }

    @inline(never)
    private mutating func pushSpilledBlock(_ code: UInt8) {
        blockStackSpill.append(code)
    }

    @inline(always)
    func isInnermostBlock(code: UInt64) -> Bool {
        guard blockStackDepth > 0 else { return false }
        let top = blockStackDepth - 1
        if top < 32 {
            // As in pushBlock, the shift is below 64.
            return (blockStackInline &>> UInt64(truncatingIfNeeded: top &* 2)) & 3 == code
        }
        return UInt64(blockStackSpill[top - 32]) == code
    }

    @inline(always)
    mutating func popBlock() {
        if blockStackDepth > 32 {
            _ = blockStackSpill.removeLast()
        }
        // Called only after isInnermostBlock found a level, so the depth is at least one.
        blockStackDepth &-= 1
    }

    @inline(always)
    mutating func startUnescaping() {
        unescaped.removeAll()
        // A Span of storage, never of a null base, even when the value turns out empty.
        if unescaped.capacity == 0 {
            unescaped.reserveCapacity(256)
        }
    }

    /// Appends a code point as UTF-16, as StringBuilder::append(char32_t) does.
    @inline(always)
    mutating func appendUnescaped(_ codePoint: UInt32) {
        if codePoint > 0xFFFF {
            unescaped.append(UInt16(truncatingIfNeeded: (codePoint >> 10) + 0xD7C0))
            unescaped.append(UInt16(truncatingIfNeeded: (codePoint & 0x3FF) | 0xDC00))
            return
        }
        unescaped.append(UInt16(truncatingIfNeeded: codePoint))
    }

    @inline(always)
    mutating func appendUnescaped(unit: some CSSCodeUnit) {
        unescaped.append(UInt16(truncatingIfNeeded: unit))
    }

    /// Appends `count` code units of `data` from `start`, which contain no escape.
    @inline(always)
    mutating func appendUnescaped<Unit: CSSCodeUnit>(_ data: Span<Unit>, from start: Int, count: Int) {
        // A range within the input.
        let run = data.extracting(start..<start &+ count)
        unescaped.append(addingCount: count) { output in
            for i in run.indices {
                output.append(UInt16(truncatingIfNeeded: run[i]))
            }
        }
    }
}

/// The input cursor and the scanning functions; the rest of the scanner's state is a
/// `CSSTokenizerScannerState` passed alongside.
private struct CSSTokenizerScanner<Unit: CSSCodeUnit> {
    /// The input cursor.
    ///
    /// Like CSSTokenizerInputStream's, it moves past the end when the end-of-file marker is consumed, by at most three,
    /// so offsets reported to the sink go through `clampedOffset`.
    var offset = 0

    init() {}

    private init(offset: Int) {
        self.offset = offset
    }

    // MARK: Input (CSSTokenizerInputStream)

    @inline(always)
    func clampedOffset(_ data: Span<Unit>) -> Int {
        offset < data.count ? offset : data.count
    }

    @inline(always)
    private func peek(_ data: Span<Unit>, _ lookahead: Int) -> Unit {
        // `offset` is at most the input's length plus three and `lookahead` a small constant.
        character(data, offset &+ lookahead)
    }

    @inline(always)
    private mutating func consume(_ data: Span<Unit>) -> Unit {
        let c = peek(data, 0)
        // At most the input's length plus three.
        offset &+= 1
        return c
    }

    @inline(always)
    private mutating func advance(_ count: Int = 1) {
        // A count of code units already read, or one past the end.
        offset &+= count
    }

    /// Steps back over the code unit `consume` just returned, so `offset` is at least one.
    @inline(always)
    private mutating func reconsume() {
        offset &-= 1
    }

    @inline(always)
    private mutating func consumeIfNext(_ data: Span<Unit>, _ c: Unit) -> Bool {
        guard peek(data, 0) == c else { return false }
        advance()
        return true
    }

    private mutating func advanceUntilNonWhitespace(_ data: Span<Unit>) {
        while data.indices.contains(offset), isASCIIWhitespace(data[offset]) {
            offset += 1
        }
    }

    private mutating func advanceUntilNewlineOrNonWhitespace(_ data: Span<Unit>) {
        // The run's first code unit has been consumed. Most runs are one to three code units long, so the next two
        // are tested one at a time, then sixteen at a time while sixteen remain.
        for _ in 0..<2 {
            guard data.indices.contains(offset), isSpaceOrTab(data[offset]) else { return }
            offset += 1
        }
        while true {
            let rest = data.extracting(droppingFirst: offset)
            guard rest.count >= 16 else { break }
            let count = Unit.leadingSpaceOrTabCount(rest.extracting(0..<16))
            if count < 16 {
                // At most the input's length.
                offset &+= count
                return
            }
            // At most the input's length.
            offset &+= 16
        }
        while data.indices.contains(offset) {
            let c = data[offset]
            if !isASCIIWhitespace(c) || isCSSNewline(c) {
                return
            }
            offset += 1
        }
    }

    /// CSSTokenizerInputStream::skipWhilePredicate<isASCIIDigit>, also appending the run's digits to `value`,
    /// which wraps past 19 significant digits. `lookahead` and the result are relative to the cursor.
    @inline(always)
    private func skipDigits(_ data: Span<Unit>, from lookahead: Int, value: inout UInt64) -> Int {
        // `lookahead` counts code units already read, so the sum is at most the input's length.
        var i = offset &+ lookahead
        var accumulated = value
        while data.indices.contains(i) {
            // Below '0' wraps to above 9.
            let digit = UInt64(truncatingIfNeeded: data[i]) &- 0x30
            if digit > 9 {
                break
            }
            // Wraps past 19 digits, where the value is not used.
            accumulated = accumulated &* 10 &+ digit
            i += 1
        }
        value = accumulated
        // `i` starts at or after the cursor and only grows.
        return i &- offset
    }

    // MARK: Tokens

    @inline(always)
    private func simpleToken(
        _ type: WebCore.CSSParserTokenType,
        _ sink: inout WebCore.CSSTokenizerSink,
        _ blockType: WebCore.CSSParserToken.BlockType = WebCore.CSSParserToken.NotBlock
    ) -> Step {
        step(sink.simpleToken(code(type), code(blockType)))
    }

    @inline(always)
    private func delimiter(_ c: Unit, _ sink: inout WebCore.CSSTokenizerSink) -> Step {
        step(sink.delimiterToken(UInt16(truncatingIfNeeded: c)))
    }

    @inline(always)
    private func valueToken(
        _ type: WebCore.CSSParserTokenType,
        _ value: ScannedValue,
        _ state: borrowing CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink,
        _ blockType: WebCore.CSSParserToken.BlockType = WebCore.CSSParserToken.NotBlock
    ) -> Step {
        poolIfUnescaped(value, state, &sink)
        return step(sink.valueToken(code(type), code(blockType), value.unescaped, offset32(value.start), offset32(value.length)))
    }

    @inline(always)
    private func hashToken(
        _ isIdentifier: Bool,
        _ value: ScannedValue,
        _ state: borrowing CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        poolIfUnescaped(value, state, &sink)
        return step(sink.hashToken(isIdentifier, value.unescaped, offset32(value.start), offset32(value.length)))
    }

    /// A value the scanner built is in `state.unescaped`, which the sink pools for the next token.
    @inline(always)
    private func poolIfUnescaped(
        _ value: ScannedValue,
        _ state: borrowing CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) {
        if value.unescaped {
            sink.poolValue(state.unescaped.span)
        }
    }

    @inline(always)
    private mutating func blockStart(
        _ type: WebCore.CSSParserTokenType,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        state.pushBlock(type)
        return simpleToken(type, &sink, WebCore.CSSParserToken.BlockStart)
    }

    /// A closing bracket ends the innermost block when that block's opener has the same block code.
    @inline(always)
    private mutating func blockEnd(
        _ closer: UInt64,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        let blockCode = blockCode(closer: closer)
        let type = closerType(blockCode)
        if state.isInnermostBlock(code: blockCode) {
            state.popBlock()
            return step(sink.simpleToken(type, code(WebCore.CSSParserToken.BlockEnd)))
        }
        return step(sink.simpleToken(type, code(WebCore.CSSParserToken.NotBlock)))
    }

    // MARK: - The scanner

    /// Reports one token to `sink`, as CSSTokenizer::nextToken does; comments are reported only by the result.
    ///
    /// `@inline(always)` because the entry points would otherwise pay a call per token.
    @inline(always)
    mutating func nextToken(
        _ data: Span<Unit>,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        let cc = consume(data)
        switch dispatch(cc) {
        case .endOfFile:
            return .endOfFile

        case .whitespace:
            let runStart = clampedOffset(data)
            advanceUntilNewlineOrNonWhitespace(data)
            // Both offsets are in the input, the second no smaller than the first.
            return step(sink.whitespaceToken(offset32(1 &+ (clampedOffset(data) &- runStart))))

        case .newline:
            return simpleToken(WebCore.NewlineToken, &sink)

        case .stringStart:
            return consumeStringTokenUntil(data, cc, &state, &sink)

        case .hash:
            let next = peek(data, 0)
            let afterNext = peek(data, 1)
            if isNameCodePoint(next) || twoCharsAreValidEscape(next, afterNext) {
                let isIdentifier = nextCharsAreIdentifier(data)
                let name = consumeName(data, &state)
                return hashToken(isIdentifier, name, state, &sink)
            }
            return delimiter(cc, &sink)

        case .dollarSign:
            if consumeIfNext(data, 0x3D) {
                return simpleToken(WebCore.SuffixMatchToken, &sink)
            }
            return delimiter(cc, &sink)

        case .leftParenthesis:
            return blockStart(WebCore.LeftParenthesisToken, &state, &sink)

        case .blockEnd:
            return blockEnd(UInt64(truncatingIfNeeded: cc), &state, &sink)

        case .asterisk:
            if consumeIfNext(data, 0x3D) {
                return simpleToken(WebCore.SubstringMatchToken, &sink)
            }
            return delimiter(cc, &sink)

        case .plusOrFullStop:
            if nextCharsAreNumber(data, cc) {
                reconsume()
                return consumeNumericToken(data, &state, &sink)
            }
            return delimiter(cc, &sink)

        case .comma:
            return simpleToken(WebCore.CommaToken, &sink)

        case .hyphenMinus:
            if nextCharsAreNumber(data, cc) {
                reconsume()
                return consumeNumericToken(data, &state, &sink)
            }
            if peek(data, 0) == 0x2D, peek(data, 1) == 0x3E {
                advance(2)
                return simpleToken(WebCore.CDCToken, &sink)
            }
            if nextCharsAreIdentifier(data, cc) {
                reconsume()
                return consumeIdentLikeToken(data, &state, &sink)
            }
            return delimiter(cc, &sink)

        case .solidus:
            if consumeIfNext(data, 0x2A) {
                consumeUntilCommentEndFound(data)
                return .comment
            }
            return delimiter(cc, &sink)

        case .asciiDigit:
            reconsume()
            return consumeNumericToken(data, &state, &sink)

        case .colon:
            return simpleToken(WebCore.ColonToken, &sink)

        case .semiColon:
            return simpleToken(WebCore.SemicolonToken, &sink)

        case .lessThan:
            if peek(data, 0) == 0x21, peek(data, 1) == 0x2D, peek(data, 2) == 0x2D {
                advance(3)
                return simpleToken(WebCore.CDOToken, &sink)
            }
            return delimiter(cc, &sink)

        case .commercialAt:
            if nextCharsAreIdentifier(data) {
                let name = consumeName(data, &state)
                return valueToken(WebCore.AtKeywordToken, name, state, &sink)
            }
            return delimiter(cc, &sink)

        case .nameStart:
            reconsume()
            return consumeIdentLikeToken(data, &state, &sink)

        case .leftBracket:
            return blockStart(WebCore.LeftBracketToken, &state, &sink)

        case .reverseSolidus:
            if twoCharsAreValidEscape(cc, peek(data, 0)) {
                reconsume()
                return consumeIdentLikeToken(data, &state, &sink)
            }
            return delimiter(cc, &sink)

        case .circumflexAccent:
            if consumeIfNext(data, 0x3D) {
                return simpleToken(WebCore.PrefixMatchToken, &sink)
            }
            return delimiter(cc, &sink)

        case .leftBrace:
            return blockStart(WebCore.LeftBraceToken, &state, &sink)

        case .verticalLine:
            if consumeIfNext(data, 0x3D) {
                return simpleToken(WebCore.DashMatchToken, &sink)
            }
            if consumeIfNext(data, 0x7C) {
                return simpleToken(WebCore.ColumnToken, &sink)
            }
            return delimiter(cc, &sink)

        case .tilde:
            if consumeIfNext(data, 0x3D) {
                return simpleToken(WebCore.IncludeMatchToken, &sink)
            }
            return delimiter(cc, &sink)

        case .delimiter:
            return delimiter(cc, &sink)
        }
    }

    // MARK: Numbers

    // https://drafts.csswg.org/css-syntax/#consume-a-number. The sink converts the text with charactersToDouble
    // unless exactValue gives the value.
    private mutating func consumeNumber(_ data: Span<Unit>) -> ScannedNumber {
        var number = ScannedNumber()
        number.start = clampedOffset(data)

        // Lookaheads are counts of code units already read, so they stay within the input.
        var length = 0
        var next = peek(data, 0)
        if next == 0x2B {
            length = 1
            number.sign = WebCore.PlusSign
        } else if next == 0x2D {
            length = 1
            number.sign = WebCore.MinusSign
        }

        // The digits of the integer part and the fraction, as one integer.
        let signLength = length
        var significand: UInt64 = 0
        length = skipDigits(data, from: length, value: &significand)
        let integerLength = length &- signLength
        var fractionLength = 0
        next = peek(data, length)
        if next == 0x2E, isASCIIDigit(peek(data, length &+ 1)) {
            number.isInteger = false
            let fractionStart = length &+ 1
            length = skipDigits(data, from: fractionStart, value: &significand)
            fractionLength = length &- fractionStart
            next = peek(data, length)
        }

        var exponent: UInt64 = 0
        var exponentLength = 0
        var exponentIsNegative = false
        if next == 0x45 || next == 0x65 {
            next = peek(data, length &+ 1)
            var exponentStart = 0
            if isASCIIDigit(next) {
                exponentStart = length &+ 1
            } else if next == 0x2B || next == 0x2D, isASCIIDigit(peek(data, length &+ 2)) {
                exponentIsNegative = next == 0x2D
                exponentStart = length &+ 2
            }
            if exponentStart != 0 {
                number.isInteger = false
                length = skipDigits(data, from: exponentStart, value: &exponent)
                exponentLength = length &- exponentStart
            }
        }

        // Lengths of runs within the input, so neither sum overflows.
        if integerLength &+ fractionLength <= 19, exponentLength <= 19 {
            number.value = exactValue(
                significand,
                exponent: exponent,
                exponentIsNegative: exponentIsNegative,
                fractionLength: fractionLength,
                isNegative: number.sign == WebCore.MinusSign
            )
        }

        advance(length)
        // Both are offsets into the input, the first no smaller than the second.
        number.length = clampedOffset(data) &- number.start
        return number
    }

    @inline(always)
    private mutating func consumeNumericToken(
        _ data: Span<Unit>,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        let (result, end) = Self.consumeNumericToken(at: offset, data, &state, &sink)
        offset = end
        return result
    }

    @inline(never)
    private static func consumeNumericToken(
        at offset: Int,
        _ data: Span<Unit>,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> (Step, Int) {
        var scanner = Self(offset: offset)
        let result = scanner.scanNumericToken(data, &state, &sink)
        return (result, scanner.offset)
    }

    @inline(always)
    private mutating func consumeIdentLikeToken(
        _ data: Span<Unit>,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        let (result, end) = Self.consumeIdentLikeToken(at: offset, data, &state, &sink)
        offset = end
        return result
    }

    @inline(never)
    private static func consumeIdentLikeToken(
        at offset: Int,
        _ data: Span<Unit>,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> (Step, Int) {
        var scanner = Self(offset: offset)
        let result = scanner.scanIdentLikeToken(data, &state, &sink)
        return (result, scanner.offset)
    }

    @inline(always)
    private mutating func consumeName(_ data: Span<Unit>, _ state: inout CSSTokenizerScannerState) -> ScannedValue {
        let (name, end) = Self.consumeName(at: offset, data, &state)
        offset = end
        return name
    }

    @inline(never)
    private static func consumeName(
        at offset: Int,
        _ data: Span<Unit>,
        _ state: inout CSSTokenizerScannerState
    ) -> (ScannedValue, Int) {
        var scanner = Self(offset: offset)
        let name = scanner.scanName(data, &state)
        return (name, scanner.offset)
    }

    @inline(always)
    private mutating func consumeEscape(_ data: Span<Unit>) -> UInt32 {
        let (codePoint, end) = Self.consumeEscape(at: offset, data)
        offset = end
        return codePoint
    }

    @inline(never)
    private static func consumeEscape(at offset: Int, _ data: Span<Unit>) -> (UInt32, Int) {
        var scanner = Self(offset: offset)
        let codePoint = scanner.scanEscape(data)
        return (codePoint, scanner.offset)
    }

    // https://drafts.csswg.org/css-syntax/#consume-a-numeric-token
    @inline(always)
    private mutating func scanNumericToken(
        _ data: Span<Unit>,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        let number = consumeNumber(data)
        let isInteger = number.isInteger
        let sign = code(number.sign)
        let start = offset32(number.start)
        let length = offset32(number.length)
        if nextCharsAreIdentifier(data) {
            let unit = consumeName(data, &state)
            poolIfUnescaped(unit, state, &sink)
            let kind = unit.unescaped ? WebCore.CSSTokenizerPooledDimension : WebCore.CSSTokenizerDimension
            return step(sink.numericToken(kind, isInteger, sign, start, length, offset32(unit.start), offset32(unit.length), number.value))
        }
        if consumeIfNext(data, 0x25) {
            return step(sink.numericToken(WebCore.CSSTokenizerPercentage, isInteger, sign, start, length, 0, 0, number.value))
        }
        return step(sink.numericToken(WebCore.CSSTokenizerNumber, isInteger, sign, start, length, 0, 0, number.value))
    }

    // MARK: Names

    // https://drafts.csswg.org/css-syntax/#consume-ident-like-token
    @inline(always)
    private mutating func scanIdentLikeToken(
        _ data: Span<Unit>,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        let name = consumeName(data, &state)
        guard consumeIfNext(data, 0x28) else {
            return valueToken(WebCore.IdentToken, name, state, &sink)
        }
        if nameIsURL(data, name, state) {
            // Whitespace before a quoted argument makes no token.
            advanceUntilNonWhitespace(data)
            let next = peek(data, 0)
            if next != 0x22, next != 0x27 {
                // The unescaped name is pooled, though the URL token does not take it, so escapedStringsForAdoption() includes it.
                poolIfUnescaped(name, state, &sink)
                return consumeURLToken(data, &state, &sink)
            }
        }
        state.pushBlock(WebCore.LeftParenthesisToken)
        return valueToken(WebCore.FunctionToken, name, state, &sink, WebCore.CSSParserToken.BlockStart)
    }

    /// equalLettersIgnoringASCIICase(name, "url"_s).
    private func nameIsURL(_ data: Span<Unit>, _ name: ScannedValue, _ state: borrowing CSSTokenizerScannerState) -> Bool {
        if name.unescaped {
            let value = state.unescaped.span
            guard value.count == 3 else { return false }
            return (value[0] | 0x20) == 0x75 && (value[1] | 0x20) == 0x72 && (value[2] | 0x20) == 0x6C
        }
        guard name.length == 3 else { return false }
        // The name's three code units are in the input.
        let u = character(data, name.start)
        let r = character(data, name.start &+ 1)
        let l = character(data, name.start &+ 2)
        return (u | 0x20) == 0x75 && (r | 0x20) == 0x72 && (l | 0x20) == 0x6C
    }

    // https://drafts.csswg.org/css-syntax/#consume-a-name
    @inline(always)
    private mutating func scanName(_ data: Span<Unit>, _ state: inout CSSTokenizerScannerState) -> ScannedValue {
        // Names without escapes are ranges of the input.
        var i = offset
        while true {
            let cc = character(data, i)
            if isNameCodePoint(cc) {
                // At most the input's length.
                i &+= 1
                continue
            }
            // A NUL inside the input, which preprocessing has removed, would take the slow path.
            if cc == Unit(endOfFileMarker), i < data.count {
                break
            }
            if cc == 0x5C {
                break
            }
            let start = clampedOffset(data)
            offset = i
            // `start` is the cursor, at most `i`.
            return ScannedValue(start: start, length: i &- start)
        }

        state.startUnescaping()
        while true {
            let cc = consume(data)
            if isNameCodePoint(cc) {
                state.appendUnescaped(unit: cc)
                continue
            }
            if twoCharsAreValidEscape(cc, peek(data, 0)) {
                state.appendUnescaped(consumeEscape(data))
                continue
            }
            reconsume()
            return ScannedValue(unescaped: true)
        }
    }

    // MARK: Strings

    // https://drafts.csswg.org/css-syntax/#consume-a-string-token
    private mutating func consumeStringTokenUntil(
        _ data: Span<Unit>,
        _ endingCodePoint: Unit,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        // Strings closed by their quote, without an escape, are ranges of the input.
        var size = 0
        while true {
            let cc = peek(data, size)
            if cc == endingCodePoint {
                let start = clampedOffset(data)
                // The quote is in the input.
                advance(size &+ 1)
                return valueToken(WebCore.StringToken, ScannedValue(start: start, length: size), state, &sink)
            }
            if isCSSNewline(cc) {
                advance(size)
                return simpleToken(WebCore.BadStringToken, &sink)
            }
            if cc == Unit(endOfFileMarker) || cc == 0x5C {
                break
            }
            // Within the input: the end-of-file marker stops the loop.
            size &+= 1
        }

        // The `size` code units at the cursor are plain, and the one after them ends the string or is a
        // backslash.
        state.startUnescaping()
        while true {
            state.appendUnescaped(data, from: offset, count: size)
            advance(size)
            let cc = consume(data)
            if cc == endingCodePoint || cc == Unit(endOfFileMarker) {
                return valueToken(WebCore.StringToken, ScannedValue(unescaped: true), state, &sink)
            }
            if isCSSNewline(cc) {
                reconsume()
                return simpleToken(WebCore.BadStringToken, &sink)
            }
            // A backslash at the end of the input is dropped.
            let next = peek(data, 0)
            if isCSSNewline(next) {
                consumeSingleWhitespaceIfNext(data)
            } else if next != Unit(endOfFileMarker) {
                state.appendUnescaped(consumeEscape(data))
            }
            size = 0
            while true {
                let c = peek(data, size)
                if c == endingCodePoint || isStringSpecialCodePoint(c) {
                    break
                }
                // Within the input: the end-of-file marker stops the loop.
                size &+= 1
            }
        }
    }

    // MARK: URLs

    // https://drafts.csswg.org/css-syntax/#consume-url-token
    private mutating func consumeURLToken(
        _ data: Span<Unit>,
        _ state: inout CSSTokenizerScannerState,
        _ sink: inout WebCore.CSSTokenizerSink
    ) -> Step {
        advanceUntilNonWhitespace(data)

        // URLs closed by ')', without escapes or whitespace, are ranges of the input.
        var size = 0
        while true {
            let cc = peek(data, size)
            if cc == 0x29 {
                let start = clampedOffset(data)
                // The `)` is in the input.
                advance(size &+ 1)
                return valueToken(WebCore.UrlToken, ScannedValue(start: start, length: size), state, &sink)
            }
            if cc <= 0x20 || cc == 0x5C || cc == 0x22 || cc == 0x27 || cc == 0x28 || cc == 0x7F {
                break
            }
            // Within the input: the end-of-file marker stops the loop.
            size &+= 1
        }

        state.startUnescaping()
        while true {
            let cc = consume(data)
            if cc == 0x29 || cc == Unit(endOfFileMarker) {
                return valueToken(WebCore.UrlToken, ScannedValue(unescaped: true), state, &sink)
            }
            if isASCIIWhitespace(cc) {
                advanceUntilNonWhitespace(data)
                if consumeIfNext(data, 0x29) || peek(data, 0) == Unit(endOfFileMarker) {
                    return valueToken(WebCore.UrlToken, ScannedValue(unescaped: true), state, &sink)
                }
                break
            }
            if cc == 0x22 || cc == 0x27 || cc == 0x28 || isNonPrintableCodePoint(cc) {
                break
            }
            if cc == 0x5C {
                if twoCharsAreValidEscape(cc, peek(data, 0)) {
                    state.appendUnescaped(consumeEscape(data))
                    continue
                }
                break
            }
            state.appendUnescaped(unit: cc)
        }

        consumeBadUrlRemnants(data)
        return simpleToken(WebCore.BadUrlToken, &sink)
    }

    // https://drafts.csswg.org/css-syntax/#consume-the-remnants-of-a-bad-url
    private mutating func consumeBadUrlRemnants(_ data: Span<Unit>) {
        while true {
            let cc = consume(data)
            if cc == 0x29 || cc == Unit(endOfFileMarker) {
                return
            }
            if twoCharsAreValidEscape(cc, peek(data, 0)) {
                _ = consumeEscape(data)
            }
        }
    }

    // MARK: Escapes and comments

    private mutating func consumeSingleWhitespaceIfNext(_ data: Span<Unit>) {
        // \r\n counts as one.
        let next = peek(data, 0)
        if next == 0x0D, peek(data, 1) == 0x0A {
            advance(2)
        } else if isASCIIWhitespace(next) {
            advance()
        }
    }

    // https://drafts.csswg.org/css-syntax/#consume-an-escaped-code-point
    @inline(always)
    private mutating func scanEscape(_ data: Span<Unit>) -> UInt32 {
        let cc = consume(data)
        if isASCIIHexDigit(cc) {
            var codePoint = hexValue(cc)
            var consumedHexDigits = 1
            while consumedHexDigits < 6, isASCIIHexDigit(peek(data, 0)) {
                // codePoint * 16 + value: at most five digits so far, so nothing is shifted out.
                codePoint = codePoint << 4 | hexValue(consume(data))
                consumedHexDigits += 1
            }
            consumeSingleWhitespaceIfNext(data)
            if codePoint == 0 || (codePoint >= 0xD800 && codePoint <= 0xDFFF) || codePoint > maximumCodePoint {
                return replacementCharacter
            }
            return codePoint
        }
        if cc == Unit(endOfFileMarker) {
            return replacementCharacter
        }
        return UInt32(truncatingIfNeeded: cc)
    }

    private mutating func consumeUntilCommentEndFound(_ data: Span<Unit>) {
        // Sixteen code units at a time while the one after them, which a `*` in the last needs, is in the input.
        while true {
            let rest = data.extracting(droppingFirst: offset)
            guard rest.count >= 17 else { break }
            let index = Unit.commentEndIndex(rest.extracting(0..<17))
            if index < 16 {
                // At most the input's length.
                offset &+= index &+ 2
                return
            }
            // At most the input's length minus one.
            offset &+= 16
        }
        var c = consume(data)
        while true {
            if c == Unit(endOfFileMarker) {
                return
            }
            if c != 0x2A {
                c = consume(data)
                continue
            }
            c = consume(data)
            if c == 0x2F {
                return
            }
        }
    }

    // MARK: Lookahead

    // https://drafts.csswg.org/css-syntax/#starts-with-a-number, with `first` already consumed.
    private func nextCharsAreNumber(_ data: Span<Unit>, _ first: Unit) -> Bool {
        let second = peek(data, 0)
        if isASCIIDigit(first) {
            return true
        }
        if first == 0x2B || first == 0x2D {
            let third = peek(data, 1)
            return isASCIIDigit(second) || (second == 0x2E && isASCIIDigit(third))
        }
        if first == 0x2E {
            return isASCIIDigit(second)
        }
        return false
    }

    // https://drafts.csswg.org/css-syntax/#would-start-an-identifier, with `first` already consumed.
    private func nextCharsAreIdentifier(_ data: Span<Unit>, _ first: Unit) -> Bool {
        let second = peek(data, 0)
        if isNameStartCodePoint(first) || twoCharsAreValidEscape(first, second) {
            return true
        }
        if first == 0x2D {
            let third = peek(data, 1)
            return isNameStartCodePoint(second) || second == 0x2D || twoCharsAreValidEscape(second, third)
        }
        return false
    }

    /// The same, at the cursor.
    private func nextCharsAreIdentifier(_ data: Span<Unit>) -> Bool {
        let first = peek(data, 0)
        let second = peek(data, 1)
        if isNameStartCodePoint(first) || twoCharsAreValidEscape(first, second) {
            return true
        }
        if first == 0x2D {
            let third = peek(data, 2)
            return isNameStartCodePoint(second) || second == 0x2D || twoCharsAreValidEscape(second, third)
        }
        return false
    }
}

// MARK: - Preprocessing

/// Whether `units` holds a surrogate that is not half of a pair, read a code point at a time as
/// `CodePointIterator` does: a lead followed by a trail is a pair, and any other surrogate is unpaired.
private func hasUnpairedSurrogate(_ units: Span<UInt16>) -> Bool {
    var offset = 0
    while true {
        // Sixteen code units at a time, while sixteen remain. `0xD7FF - c` is at least 0xF800 exactly when
        // `c` is a surrogate.
        while true {
            let rest = units.extracting(droppingFirst: offset)
            guard rest.count >= 16 else { break }
            let bytes = rest.extracting(0..<16).bytes
            let low = 0xD7FF &- bytes.load(fromByteOffset: 0, as: SIMD8<UInt16>.self)
            let high = 0xD7FF &- bytes.load(fromByteOffset: 16, as: SIMD8<UInt16>.self)
            if anyLane(pointwiseMax(low, high), atLeast: 0xF800) { break }
            // At most the input's length.
            offset &+= 16
        }
        // One at a time through the sixteen that hold a surrogate, or the fewer than sixteen at the end. A pair
        // may end one code unit past them.
        // `offset` is at most the input's length.
        let end = min(units.count, offset &+ 16)
        while offset < end {
            let c = units[offset]
            if c & 0xF800 == 0xD800 {
                // `offset` is below the input's length.
                let next = offset &+ 1
                guard c & 0xFC00 == 0xD800, units.indices.contains(next), units[next] & 0xFC00 == 0xDC00 else { return true }
                offset = next + 1
            } else {
                offset += 1
            }
        }
        if offset >= units.count { return false }
    }
}

// MARK: - Entry points

@inline(always)
private func tokenize<Unit: CSSCodeUnit>(_ data: Span<Unit>, _ sink: inout WebCore.CSSTokenizerSink) -> Bool {
    let observing = sink.hasObserver()
    var scanner = CSSTokenizerScanner<Unit>()
    var state = CSSTokenizerScannerState()
    while true {
        let start = scanner.clampedOffset(data)
        switch scanner.nextToken(data, &state, &sink) {
        case .token:
            if observing {
                sink.observeToken(offset32(start))
            }
        case .comment:
            // Comments make no token.
            if observing {
                sink.observeComment(offset32(start), offset32(scanner.clampedOffset(data)))
            }
        case .endOfFile:
            if observing {
                sink.observeToken(offset32(start))
            }
            return true
        case .failed:
            return false
        }
    }
}

/// Whether 16-bit input holds a surrogate that is not half of a pair, which CSSTokenizer's preprocessing
/// replaces with U+FFFD.
///
/// - `input` is the input of the CSSTokenizer whose constructor calls this, before preprocessing: characters
///   owned by the constructor's caller for the tokenizer's lifetime. They stay allocated, at their length,
///   for the call. Nothing writes them during the call, which calls nothing. The elements are `char16_t`,
///   which has no invalid bit patterns. There is no output buffer.
///
/// FIXME: Receive the input as a `Span` once an exposed function can (rdar://186723514).
@_expose(Cxx)
func cssHasUnpairedSurrogate(_ input: WebCore.CSSTokenizerSpan16) -> Bool {
    hasUnpairedSurrogate(unsafe Span<UInt16>(_unsafeCxxSpan: input))
}

/// Tokenizes 8-bit input into `sink`.
///
/// Returns false when a token could not be allocated.
///
/// - `input` is the preprocessed input of the CSSTokenizer that calls this: characters owned by the
///   constructor's caller for the tokenizer's lifetime, or by the tokenizer's string pool when
///   preprocessing copied them. They stay allocated, at their length, for the call. Nothing writes them
///   during the call: the sink's members append tokens to the token list and `String`s to the string
///   pool, neither of which moves characters, and read the input through `rangeAt`. The elements are
///   `Latin1Character`, which has no invalid bit patterns. There is no output buffer.
/// - `sink` is a `CSSTokenizerSinkState` on the constructor's stack, the only place one is made. While it
///   is live, the members Swift calls reach `CSSParserToken`'s constructors and converters,
///   `charactersToDouble`, `StringImpl::create8BitIfPossible`, `CSSTokenizer::registerString` (which appends
///   to the string pool), `CSSTokenizer::tokenCount`, `CSSTokenizerInputStream::rangeAt` and `length`,
///   `Vector::tryAppend` and the observer wrapper's `addToken` and `addComment`; none reaches the sink by
///   another path, calls back into Swift, runs script or uses another thread.
///
/// FIXME: Receive the input as a `Span` once an exposed function can (rdar://186723514).
@_expose(Cxx)
func cssTokenize8(_ input: WebCore.CSSTokenizerSpan8, _ sink: inout WebCore.CSSTokenizerSink) -> Bool {
    tokenize(unsafe Span<UInt8>(_unsafeCxxSpan: input), &sink)
}

/// Tokenizes 16-bit input into `sink`.
///
/// The input's and the sink's guarantees are those of `cssTokenize8`, with `char16_t` elements, which have no
/// invalid bit patterns.
///
/// FIXME: Receive the input as a `Span` once an exposed function can (rdar://186723514).
@_expose(Cxx)
func cssTokenize16(_ input: WebCore.CSSTokenizerSpan16, _ sink: inout WebCore.CSSTokenizerSink) -> Bool {
    tokenize(unsafe Span<UInt16>(_unsafeCxxSpan: input), &sink)
}

#endif // USE_SWIFT_CSS_TOKENIZER
