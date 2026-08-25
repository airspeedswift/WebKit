/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#if JSC_SUPPORTS_SWIFT

// `internal`, not `public`: SWIFT_LIBRARY_LEVEL is `api` here, so a public import
// of a private module is rejected — hence also the `@_expose(Cxx)` entry points and
// xcconfig's -emit-clang-header-min-access internal.
internal import JavaScriptCore_Private.LiteralParserSwiftTypes

// Strict JSON.parse in Swift at both code-unit widths, selected by
// Options::useSwiftJSONParser(): lex<hint> (LiteralParser.cpp:742), lexIdentifier
// (:862), lexString<hint> (:930), lexNumber's int32 path (:1110), and
// parseRecursively's grammar (:1512). The object model stays in C++ behind the
// JSC::JSONSwiftObjectModel facade, as does parseJSONDouble. Reviver mode Disabled only.
//
// Anything this cannot finish returns .declined, and the C++ LiteralParser — which the
// entry point does not build until then — parses the document instead. A *malformed*
// document can instead return .failed and format the message itself (`formatError`), so
// that the C++ lexer does not run over the same bytes a second time.
//
// `@safe` on everything below that takes the facade, and `JSC_SWIFT_SAFE` on each of its
// methods (LiteralParserSwiftTypes.h): the facade *type* is unsafe, because a cell's lifetime
// is the collector's business, but no call on it is. SE-0458 lets the callee take
// responsibility for an unsafe-typed direct argument, `self` included, so the assertion is
// made once per declaration rather than at every call site — and it is the honest one, since
// an *escape* of the receiver still diagnoses where `SWIFT_IMMORTAL_REFERENCE` would have
// silenced it. What remains is twenty unchecked `RawSpan` loads, two `std::span` imports at
// the entries, and one facade call whose synthesized safe overload drops the attribute
// (`emitError`).

/// Mirrors `JSC::TokenType`. Raw values match so C++ can cast directly.
enum JSONTokenType: UInt8 {
    case lbracket = 0, rbracket, lbrace, rbrace
    case string, identifier, number, numberInt32, colon
    case lparen, rparen, comma, `true`, `false`
    case null, end, dot, assign, semi, error, errorSpace

    /// Island-only. Needs lexStringSlow: an escape, or unterminated. `start` is
    /// the C++ runStart and `offset` is where the scan stopped.
    case needsSlowString = 21
    /// Island-only. Off the int32 fast path. `start` is the C++ `initial`.
    case needsDoubleParse = 22
}

/// Which diagnostic a malformed document reports. Island-only vocabulary: no counterpart
/// crosses the boundary, since the message *text* is formatted here (`formatError`) and only
/// the finished pieces cross.
///
/// The two rules from `JSC::JSONSwiftParseFailed`'s declaration, restated where they are
/// enforced:
///
///  * a lexer-level kind outranks a grammar-level one, always — the C++'s
///    `getErrorMessage` prefers `m_lexErrorMessage`, so the island reports at the point of
///    detection and `errorMessage` keeps the first message;
///  * the three messages that are unreachable from strict `JSON.parse` are absent, and
///    must stay absent.
enum JSONErrorKind: UInt8 {
    /// Island-only, never crossing the boundary: resolve the kind from the refused token's
    /// type, which is what a *value* position does (`parsePrimitiveValue`'s family).
    case fromTokenType = 0
    // Lexer-level.
    /// The commonest failure of all by a wide margin, and what a control character inside a
    /// string reports too, the C++ scan stopping there.
    case unterminatedString = 1
    /// Reached in strict mode only, which is the island's only mode.
    case singleQuotes
    /// One code unit at `start`.
    case unrecognizedToken
    /// One code unit at `start`: the character after the backslash.
    case invalidEscapeCharacter
    /// Fewer than four units follow the `u`, so there is nothing to quote.
    case unicodeEscapeNeedsFourHexDigits
    /// Five code units at `start`: the `u` and the four that are not all hex digits.
    case invalidUnicodeEscape
    case invalidNumber
    case invalidDigitsAfterDecimalPoint
    case exponentSymbols

    // Grammar-level.
    case expectedRBrace
    case expectedRBracket
    case expectedColon
    case unexpectedTokenRBracket
    case unexpectedTokenRBrace
    case unexpectedTokenColon
    case unexpectedTokenLParen
    case unexpectedTokenRParen
    case unexpectedTokenComma
    case unexpectedTokenDot
    case unexpectedTokenAssign
    case unexpectedTokenSemi
    case unexpectedEOF
    /// The identifier's full extent at `start`; `formatError` applies the 200-unit cap.
    case unexpectedIdentifier
    case unexpectedCommaAtEndOfArray
    case propertyNameMustBeAStringLiteral
    /// The absence of a message rather than a message: `getErrorMessage`'s fallback,
    /// which is what a complete document followed by content that itself lexes cleanly
    /// reports (`[1]]`).
    case unableToParseJSONString
}

/// Mirrors `JSC::ParserMode`.
enum JSONParserMode: UInt8 {
    case strictJSON = 0, sloppyJSON, jsonp
}

/// `LiteralParserToken` (LiteralParser.h:110), with the union's pointer replaced by
/// an element offset so the token carries no lifetime.
struct JSONLexerToken {
    var numberValue: Double = 0
    var int32Value: Int32 = 0
    /// Strings, identifiers and the two decline cases: offset of the first unit.
    var start: UInt32 = 0
    var length: UInt32 = 0
    /// A `JSONTokenType` raw value.
    var type: UInt8 = JSONTokenType.error.rawValue

    init() {}
}

// MARK: - Character tables
//
// Transcribed from LiteralParser.cpp:215 and :475. Module-level and spelled as
// literals, both deliberately: a function-local InlineArray blocks vectorisation
// downstream, and a closure initialiser makes it a lazy global whose access guard
// lands on the per-token lookup.

/// `tokenTypesOfLatin1Characters` (LiteralParser.cpp:215).
let tokenTypesOfLatin1Characters: InlineArray<256, UInt8> = [
    19, 19, 19, 19, 19, 19, 19, 19, 19, 20, 20, 19, 19, 20, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    20, 19, 4, 19, 5, 19, 19, 4, 9, 10, 19, 19, 11, 6, 16, 19,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 18, 19, 17, 19, 19,
    19, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, 19, 1, 19, 5,
    19, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 2, 19, 3, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
]

/// `safeStringLatin1CharactersInStrictJSON` (LiteralParser.cpp:475). False exactly
/// for `c < 0x20`, `"` and `\`.
let safeStringLatin1CharactersInStrictJSON: InlineArray<256, Bool> = [
    false, false, false, false, false, false, false, false,
    false, false, false, false, false, false, false, false,
    false, false, false, false, false, false, false, false,
    false, false, false, false, false, false, false, false,
    true, true, false, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, false, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true,
]

/// `[0, 1, ... 7]`, for ranking the matching lanes of an 8-lane comparison.
let laneIndices8 = SIMD8<UInt16>(0, 1, 2, 3, 4, 5, 6, 7)

let laneIndices16 = SIMD16<UInt8>(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)

// MARK: - The code-unit width
//
// LiteralParser is a template over CharType and JSC instantiates it for both, so this
// does too. Per width is what was tuned — the SIMD scans and keyword compares, whose
// stride, lane count and load widths are the measurement; the rest is generic.
protocol JSONUnits {
    /// `CharType`. `ConvertibleFromBytes` is what `Span(viewing:)` and the loads
    /// below require.
    associatedtype Unit: FixedWidthInteger & UnsignedInteger & BitwiseCopyable
        & ConvertibleFromBytes

    /// `isLatin1` (ASCIICType.h). Constant-true for a byte, which folds the
    /// error guard in `lex` and the strict predicate's rescue away entirely.
    static func isLatin1(_ c: Unit) -> Bool

    /// `isValidIdentifierCharacter<CharType>` (:853). The two zero-width joiners
    /// are not representable in a byte, so the Latin1 form is shorter.
    static func isValidIdentifierCharacter(_ c: Unit) -> Bool

    /// `WTF::compareCharacters` for three and four units
    /// (FastCharacterComparison.h:96): one unaligned load against a folded
    /// constant. Per width, because the load widths differ.
    static func matches3(
        _ input: RawSpan, at index: Int, _ c0: Unit, _ c1: Unit, _ c2: Unit,
        _ units: Span<Unit>
    ) -> Bool
    static func matches4(
        _ input: RawSpan, at index: Int, _ c0: Unit, _ c1: Unit, _ c2: Unit, _ c3: Unit
    ) -> Bool

    /// `SIMD::find` for the strict and sloppy `vectorMatch` predicates: 16 lanes of
    /// bytes against 8 of units, and no `* 2` in the byte offset.
    static func findUnsafeStrict(
        _ input: RawSpan, _ units: Span<Unit>, from: Int, count: Int
    ) -> Int
    static func findUnsafeSloppy(
        _ input: RawSpan, _ units: Span<Unit>, from: Int, count: Int, terminator: Unit
    ) -> Int
}

// MARK: - Character predicates
//
// The width-independent ones. The C++ spells these with
// `static_cast<Latin1Character>` truncations and `isLatin1` rescues (:735-928).

/// `isJSONWhiteSpace` (:735). The C++'s table lookup reduces to exactly these
/// four values: its four `TokErrorSpace` entries are all below 0x100, so nothing
/// non-Latin1 can truncate onto one and survive the `isLatin1` test.
@inline(always) func isJSONWhiteSpace<U: FixedWidthInteger>(_ c: U) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
}

/// `isASCIIHexDigit` and `toASCIIHexValue` (wtf/ASCIICType.h) fused, for `\uNNNN`.
/// One function rather than a test and a convert, because the escape decoder needs both
/// answers about the same unit and `nil` carries the rejection.
@inline(always) func asciiHexValue<U: FixedWidthInteger & UnsignedInteger>(_ c: U) -> UInt8? {
    if c >= 0x30, c <= 0x39 { return UInt8(truncatingIfNeeded: c) &- 0x30 }
    if c >= 0x41, c <= 0x46 { return UInt8(truncatingIfNeeded: c) &- 0x41 &+ 10 }
    if c >= 0x61, c <= 0x66 { return UInt8(truncatingIfNeeded: c) &- 0x61 &+ 10 }
    return nil
}

/// The index into either Latin1 table: the C++'s `static_cast<Latin1Character>`.
/// The caller owns the `isLatin1` rescue the C++ pairs it with.
@inline(always) func tableIndex<U: FixedWidthInteger>(_ c: U) -> Int {
    Int(UInt8(truncatingIfNeeded: c))
}

/// `isSafeStringCharacterForIdentifier<Strict>` (:922, strict arm). The `!isLatin1`
/// rescues anything that truncated onto an unsafe entry; constant-false for a byte.
@inline(always) func isSafeStringCharacterForIdentifierStrict<T: JSONUnits>(
    _ c: T.Unit, _: T.Type
) -> Bool {
    safeStringLatin1CharactersInStrictJSON[tableIndex(c)] || !T.isLatin1(c)
}

/// `isSafeStringCharacterForIdentifier<Sloppy>` (:922, sloppy arm). Unlike the
/// strict variant this one does not truncate, so a non-Latin1 character stops the
/// scan.
@inline(always) func isSafeStringCharacterForIdentifierSloppy<T: JSONUnits>(
    _ c: T.Unit, _ terminator: T.Unit, _: T.Type
) -> Bool {
    (c >= 0x20 && T.isLatin1(c) && c != 0x5C && c != terminator) || c == 0x09
}

// MARK: - The lexer

/// `LiteralParser<CharType, Disabled>::Lexer`, for either width. The input span is
/// passed to each call rather than stored, as in WebCore's CSS island: storing it is
/// measurably worse.
struct JSONLexer<T: JSONUnits> {
    var currentToken = JSONLexerToken()
    /// `m_ptr`, as an element offset, so the lexer is POD.
    var offset: Int = 0
    /// The terminator of a `.needsSlowString` token, which `lexStringSlow` takes as
    /// an argument. `UInt16` at either width: it crosses to C++ as a `uint16_t`.
    var pendingTerminator: UInt16 = 0

    let mode: UInt8

    init(mode: JSONParserMode) {
        self.mode = mode.rawValue
    }

    /// `Lexer::lex<hint>` (:742). No `next()`/`nextMaybeIdentifier()` pair: the
    /// grammar passes a constant hint at each call site, keeping both scan shapes
    /// specialised and the call inlined.
    ///
    /// The wrapping cursor arithmetic and the *unsigned* spelling of every guard that
    /// dominates a `units[...]` read are load-bearing only in combination: together they
    /// are what let the optimizer discharge the read's bounds check. Neither can overflow,
    /// by the entry precondition.
    @inline(always)
    mutating func lex(
        _ input: RawSpan, _ units: Span<T.Unit>, _ count: Int, maybeIdentifier: Bool
    ) -> UInt8 {
        while UInt(bitPattern: offset) < UInt(bitPattern: count) && isJSONWhiteSpace(units[offset]) {
            offset &+= 1
        }

        // `== count`, as the C++ writes it (:757), not `>= count`. `>=` would discharge
        // the bounds check on the read below, and is measurably slower: a lower check
        // count is not the goal here.
        if offset == count {
            currentToken.type = JSONTokenType.end.rawValue
            return JSONTokenType.end.rawValue
        }

        currentToken.type = JSONTokenType.error.rawValue
        let character = units[offset]
        // Constant-true for a byte, so this guard is not in the Latin1 lexer at all.
        guard T.isLatin1(character) else {
            return fail()
        }

        let kind = tokenTypesOfLatin1Characters[tableIndex(character)]
        switch kind {
        case JSONTokenType.string.rawValue:
            // Single quotes are in the table because sloppy JSON accepts them;
            // strict JSON rejects them (:768).
            if character == 0x27 && mode == JSONParserMode.strictJSON.rawValue {
                return fail()
            }
            return lexString(input, units, count, terminator: character,
                             maybeIdentifier: maybeIdentifier)

        case JSONTokenType.identifier.rawValue:
            // true / false / null before falling back to an identifier (:781). The
            // length guards are `>=`, so a keyword ending at end-of-input matches.
            switch character {
            case 0x74: // t
                if count &- offset >= 4 && T.matches3(input, at: offset &+ 1, 0x72, 0x75, 0x65, units) {
                    offset &+= 4
                    currentToken.type = JSONTokenType.true.rawValue
                    return JSONTokenType.true.rawValue
                }
            case 0x66: // f
                if count &- offset >= 5 && T.matches4(input, at: offset &+ 1, 0x61, 0x6C, 0x73, 0x65) {
                    offset &+= 5
                    currentToken.type = JSONTokenType.false.rawValue
                    return JSONTokenType.false.rawValue
                }
            case 0x6E: // n
                if count &- offset >= 4 && T.matches3(input, at: offset &+ 1, 0x75, 0x6C, 0x6C, units) {
                    offset &+= 4
                    currentToken.type = JSONTokenType.null.rawValue
                    return JSONTokenType.null.rawValue
                }
            default:
                break
            }
            return lexIdentifier(input, units, count)

        case JSONTokenType.number.rawValue:
            return lexNumber(input, units, count)

        case JSONTokenType.error.rawValue, JSONTokenType.errorSpace.rawValue:
            // `.errorSpace` is unreachable — the whitespace loop consumed every
            // character the table maps to it — but the C++ lists it here too.
            return fail()

        default:
            // The single-character punctuation: [ ] { } : ( ) , . = ;
            currentToken.type = kind
            offset &+= 1
            return kind
        }
    }

    /// Sets up a `.error` token. Which error it was does not cross the boundary:
    /// the grammar declines and the C++ re-parse produces the diagnostic.
    @inline(always)
    mutating func fail() -> UInt8 {
        currentToken.type = JSONTokenType.error.rawValue
        return JSONTokenType.error.rawValue
    }

    /// `Lexer::lexIdentifier` (:862).
    @inline(always)
    mutating func lexIdentifier(
        _ input: RawSpan, _ units: Span<T.Unit>, _ count: Int
    ) -> UInt8 {
        let start = offset
        var i = offset
        while UInt(bitPattern: i) < UInt(bitPattern: count) && T.isValidIdentifierCharacter(units[i]) {
            i &+= 1
        }
        offset = i
        // `truncatingIfNeeded`, not `UInt32(_:)`: the trapping conversion emits
        // three checks for a bound the entry precondition already establishes.
        currentToken.start = UInt32(truncatingIfNeeded: start)
        currentToken.length = UInt32(truncatingIfNeeded: i &- start)
        currentToken.type = JSONTokenType.identifier.rawValue
        return JSONTokenType.identifier.rawValue
    }

    /// `Lexer::lexString<hint>` (:930).
    @inline(always)
    mutating func lexString(
        _ input: RawSpan, _ units: Span<T.Unit>, _ count: Int,
        terminator: T.Unit, maybeIdentifier: Bool
    ) -> UInt8 {
        offset &+= 1
        let runStart = offset

        if mode == JSONParserMode.strictJSON.rawValue {
            // terminator is '"' here; the ''' case errored out in lex().
            if maybeIdentifier {
                var i = offset
                while UInt(bitPattern: i) < UInt(bitPattern: count) && isSafeStringCharacterForIdentifierStrict(units[i], T.self) {
                    i &+= 1
                }
                offset = i
            } else {
                offset = T.findUnsafeStrict(input, units, from: offset, count: count)
            }
        } else {
            if maybeIdentifier {
                var i = offset
                while UInt(bitPattern: i) < UInt(bitPattern: count)
                    && isSafeStringCharacterForIdentifierSloppy(units[i], terminator, T.self) {
                    i &+= 1
                }
                offset = i
            } else {
                offset = T.findUnsafeSloppy(input, units, from: offset, count: count,
                                            terminator: terminator)
            }
        }

        if UInt(bitPattern: offset) < UInt(bitPattern: count) && units[offset] == terminator {
            currentToken.start = UInt32(truncatingIfNeeded: runStart)
            currentToken.length = UInt32(truncatingIfNeeded: offset &- runStart)
            offset &+= 1
            currentToken.type = JSONTokenType.string.rawValue
            return JSONTokenType.string.rawValue
        }

        // Escape, or unterminated: `lexStringSlow` in C++.
        currentToken.start = UInt32(truncatingIfNeeded: runStart)
        pendingTerminator = UInt16(truncatingIfNeeded: terminator)
        currentToken.type = JSONTokenType.needsSlowString.rawValue
        return JSONTokenType.needsSlowString.rawValue
    }

    /// `Lexer::lexNumber` (:1110), int32 fast path only.
    @inline(always)
    mutating func lexNumber(
        _ input: RawSpan, _ units: Span<T.Unit>, _ count: Int
    ) -> UInt8 {
        let initial = offset
        var negative = false
        if UInt(bitPattern: offset) < UInt(bitPattern: count) && units[offset] == 0x2D { // '-'
            negative = true
            offset &+= 1
        }
        let start = offset // does not include the '-'

        // (0 | [1-9][0-9]*)
        if UInt(bitPattern: offset) < UInt(bitPattern: count) && isASCIIDigit(units[offset]) {
            let character = units[offset]
            offset &+= 1
            if character != 0x30 { // not '0'
                while UInt(bitPattern: offset) < UInt(bitPattern: count) && isASCIIDigit(units[offset]) {
                    offset &+= 1
                }
            }
        } else {
            return fail()
        }

        // -999999999 ... 999999999 always fit in an Int32.
        let numberOfDigitsForSafeInt32 = 9
        // The `offset < count` is behavioural: a number running to end-of-input takes
        // the double path because the C++ tests the character *at* the cursor. So
        // `JSON.parse("3")` gives TokNumber where `JSON.parse("[3]")` gives
        // TokNumberInt32, and the two encode their JSValue differently.
        if offset < count {
            let c = units[offset]
            if c != 0x2E && c != 0x65 && c != 0x45 // '.', 'e', 'E'
                && (offset &- start) <= numberOfDigitsForSafeInt32 {
                // Wrapping: the branch above bounds this at nine digits, so no step
                // can overflow. The checked form emits four traps per iteration.
                var result: Int32 = 0
                var cursor = start
                repeat {
                    result = result &* 10 &+ Int32(truncatingIfNeeded: units[cursor]) &- 0x30
                    cursor &+= 1
                } while cursor < offset

                if !negative {
                    currentToken.int32Value = result
                    currentToken.type = JSONTokenType.numberInt32.rawValue
                    return JSONTokenType.numberInt32.rawValue
                }
                if result == 0 {
                    currentToken.numberValue = -0.0
                    currentToken.type = JSONTokenType.number.rawValue
                    return JSONTokenType.number.rawValue
                }
                currentToken.int32Value = 0 &- result
                currentToken.type = JSONTokenType.numberInt32.rawValue
                return JSONTokenType.numberInt32.rawValue
            }
        }

        // `WTF::parseJSONDouble`, then `lexNumberError` if it fails. Both in C++.
        currentToken.start = UInt32(truncatingIfNeeded: initial)
        currentToken.type = JSONTokenType.needsDoubleParse.rawValue
        return JSONTokenType.needsDoubleParse.rawValue
    }
}

@inline(always) func isASCIIDigit<U: FixedWidthInteger>(_ c: U) -> Bool { c >= 0x30 && c <= 0x39 }

// Every `RawSpan` read in the SIMD scans and keyword compares below goes through this, and at
// all twenty sites the offset is in bounds by an invariant the caller has just tested and
// states at the site. Those statements are the safety argument and each has to hold on its own.
//
// It is not simply a missed optimization: the loops establish facts about the element count
// (`i + 2 * stride <= count`) while the check is against the byte count, and
// `byteCount &- i >= 8` is the stronger predicate only where `i <= byteCount` is separately
// established, unsigned-wrapping into a weaker one otherwise — which is why clang declines the
// identical fold against a hardened `std::span`. Establishing both halves in the caller does
// discharge the check, at the price of turning each trap into a live `else` the caller has to
// supply a value for inside these hot loops. rdar://185372093 asks for the annotation that
// discharges it from the invariant instead; delete the `@unsafe` and the markers at the call
// sites when it lands.
//
// `-D JSON_ISLAND_CHECKED_LOADS` restores the check, and that build is the bounds audit: run
// the JSON tests under it after touching any cursor or bound here.
@unsafe
@inline(always) func loadBytes<T: BitwiseCopyable & ConvertibleFromBytes>(
    _ input: RawSpan, at byteOffset: Int, as type: T.Type
) -> T {
#if JSON_ISLAND_CHECKED_LOADS
    input.load(fromByteOffset: byteOffset, as: T.self)
#else
    unsafe input.unsafeLoadUnaligned(fromUncheckedByteOffset: byteOffset, as: T.self)
#endif
}

// MARK: - The SIMD string scans
//
// `SIMD::find` (SIMDHelpers.h:675) with `lexString`'s vector predicates (:947
// strict, :971 sloppy), in WTF's shape: scalar below one vector's worth, then whole
// vectors, then one *overlapping* last load, sound because the earlier iterations
// proved there is no match in the overlap. Two vectors under one `any` gate is what
// reaches parity with the C++; one vector and four are both slower.

/// The ranking half of `findFirstNonZeroIndex` (SIMDHelpers.h:423). Separate from
/// the mask so it stays off the loop-carried path, as WTF splits it too.
@inline(always) func rankFirstLane(_ mask: SIMDMask<SIMD8<Int16>>) -> Int {
    Int(SIMD8<UInt16>(repeating: .max).replacing(with: laneIndices8, where: mask).min())
}

@inline(always) func rankFirstLane(_ mask: SIMDMask<SIMD16<Int8>>) -> Int {
    Int(SIMD16<UInt8>(repeating: .max).replacing(with: laneIndices16, where: mask).min())
}

// The cursor arithmetic in the scans below is deliberately *checked*, unlike the
// lexer's: the checked `i * 2`'s no-overflow fact is what lets LLVM strength-reduce the
// vector loop's addresses, so replacing these with the wrapping operators makes a pure
// scan slower rather than faster.

// MARK: The 16-bit width

/// `CharType == char16_t`.
enum WideUnits: JSONUnits {
    typealias Unit = UInt16

    @inline(always) static func isLatin1(_ c: UInt16) -> Bool { c <= 0xFF }

    /// `isValidIdentifierCharacter<char16_t>` (:853-859).
    @inline(always) static func isValidIdentifierCharacter(_ c: UInt16) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
            || c == 0x5F || c == 0x24 || c == 0x200C || c == 0x200D
    }

    // MARK: Wide keyword compares
    //
    // `COMPARE_3UCHARS` / `COMPARE_4UCHARS` (FastCharacterComparison.h:96): one
    // unaligned load against a folded constant, little-endian as WTF's macros assume.
    // In bounds unchecked, the caller having tested `count - offset >= 4`.

    @inline(always) static func matches3(
        _ input: RawSpan, at index: Int, _ c0: UInt16, _ c1: UInt16, _ c2: UInt16,
        _ units: Span<UInt16>
    ) -> Bool {
        let pair = UInt32(c0) | (UInt32(c1) << 16)
        return unsafe loadBytes(input, at: index * 2, as: UInt32.self) == pair
            && units[index &+ 2] == c2
    }

    @inline(always) static func matches4(
        _ input: RawSpan, at index: Int, _ c0: UInt16, _ c1: UInt16, _ c2: UInt16, _ c3: UInt16
    ) -> Bool {
        let quad = UInt64(c0) | (UInt64(c1) << 16) | (UInt64(c2) << 32) | (UInt64(c3) << 48)
        return unsafe loadBytes(input, at: index * 2, as: UInt64.self) == quad
    }

    // MARK: The wide SIMD scans

    static let stride = 8 // SIMD::stride<char16_t>

    /// The strict-mode `vectorMatch` (:947). Full 16-bit compares, so a non-Latin1
    /// character never matches, which is what makes this *agree* with the scalar
    /// predicate's `!isLatin1` rescue rather than merely resemble it.
    @inline(always) static func strictMask(_ v: SIMD8<UInt16>) -> SIMDMask<SIMD8<Int16>> {
        (v .== SIMD8(repeating: 0x22)) .| (v .== SIMD8(repeating: 0x5C))
            .| (v .< SIMD8(repeating: 0x20))
    }

    /// The sloppy-mode `vectorMatch` (:971): the terminator, backslash, or a
    /// control character other than tab.
    @inline(always) static func sloppyMask(
        _ v: SIMD8<UInt16>, _ terminator: UInt16
    ) -> SIMDMask<SIMD8<Int16>> {
        let controls = (v .< SIMD8(repeating: 0x20)) .& .!(v .== SIMD8(repeating: 0x09))
        return (v .== SIMD8(repeating: terminator)) .| (v .== SIMD8(repeating: 0x5C)) .| controls
    }

    @inline(always) static func findUnsafeStrict(
        _ input: RawSpan, _ units: Span<UInt16>, from: Int, count: Int
    ) -> Int {
        // Every load below is in bounds unchecked, and the loop conditions are the
        // proof: `i + 2 * stride <= count` gives `i * 2 + 32 <= input.byteCount`, and
        // the arithmetic is checked so it cannot have wrapped.
        if count - from >= stride {
            var i = from
            while i + 2 * stride <= count {
                let m0 = strictMask(unsafe loadBytes(input, at: i * 2, as: SIMD8<UInt16>.self))
                let m1 = strictMask(unsafe loadBytes(input, at: i * 2 + 16, as: SIMD8<UInt16>.self))
                if any(m0 .| m1) {
                    if any(m0) { return i + rankFirstLane(m0) }
                    return i + stride + rankFirstLane(m1)
                }
                i += 2 * stride
            }
            while i + stride <= count {
                let m = strictMask(unsafe loadBytes(input, at: i * 2, as: SIMD8<UInt16>.self))
                if any(m) { return i + rankFirstLane(m) }
                i += stride
            }
            if i < count {
                // The overlapping last vector ends exactly at the end of the span,
                // and `tail >= from >= 0` by the outer test.
                let tail = count - stride
                let m = strictMask(unsafe loadBytes(input, at: tail * 2, as: SIMD8<UInt16>.self))
                if any(m) { return tail + rankFirstLane(m) }
            }
            return count
        }
        var i = from
        while i < count {
            let c = units[i]
            if c == 0x22 || c == 0x5C || c < 0x20 { return i }
            i += 1
        }
        return count
    }

    @inline(always) static func findUnsafeSloppy(
        _ input: RawSpan, _ units: Span<UInt16>, from: Int, count: Int, terminator: UInt16
    ) -> Int {
        if count - from >= stride {
            var i = from
            while i + 2 * stride <= count {
                let m0 = sloppyMask(
                    unsafe loadBytes(input, at: i * 2, as: SIMD8<UInt16>.self), terminator)
                let m1 = sloppyMask(
                    unsafe loadBytes(input, at: i * 2 + 16, as: SIMD8<UInt16>.self), terminator)
                if any(m0 .| m1) {
                    if any(m0) { return i + rankFirstLane(m0) }
                    return i + stride + rankFirstLane(m1)
                }
                i += 2 * stride
            }
            while i + stride <= count {
                let m = sloppyMask(
                    unsafe loadBytes(input, at: i * 2, as: SIMD8<UInt16>.self), terminator)
                if any(m) { return i + rankFirstLane(m) }
                i += stride
            }
            if i < count {
                let tail = count - stride
                let m = sloppyMask(
                    unsafe loadBytes(input, at: tail * 2, as: SIMD8<UInt16>.self), terminator)
                if any(m) { return tail + rankFirstLane(m) }
            }
            return count
        }
        var i = from
        while i < count {
            let c = units[i]
            // !isSafeStringCharacter<Sloppy>(c, terminator), as SIMD::find's scalar
            // arm evaluates it.
            if !((c >= 0x20 && c != 0x5C && c != terminator) || c == 0x09) && isLatin1(c) { return i }
            i += 1
        }
        return count
    }
}

// MARK: The 8-bit width

/// `CharType == Latin1Character`, which is what JSC gives a `JSString` whose every
/// character is Latin1 — nearly all real JSON. `isLatin1` is constant-true here, the
/// tables are indexed with no truncation, and the byte offset of element `i` is `i`.
enum Latin1Units: JSONUnits {
    typealias Unit = UInt8

    @inline(always) static func isLatin1(_ c: UInt8) -> Bool { true }

    /// `isValidIdentifierCharacter<Latin1Character>` (:853), minus the two zero-width
    /// joiners, which are not representable in a byte.
    @inline(always) static func isValidIdentifierCharacter(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
            || c == 0x5F || c == 0x24
    }

    // MARK: Latin1 keyword compares
    //
    // `COMPARE_3CHARS` / `COMPARE_4CHARS` (FastCharacterComparison.h:60): the wide
    // pair at half the widths, in bounds by the same argument without the `* 2`.
    @inline(always) static func matches3(
        _ input: RawSpan, at index: Int, _ c0: UInt8, _ c1: UInt8, _ c2: UInt8,
        _ units: Span<UInt8>
    ) -> Bool {
        let pair = UInt16(c0) | (UInt16(c1) << 8)
        return unsafe loadBytes(input, at: index, as: UInt16.self) == pair
            && units[index &+ 2] == c2
    }

    @inline(always) static func matches4(
        _ input: RawSpan, at index: Int, _ c0: UInt8, _ c1: UInt8, _ c2: UInt8, _ c3: UInt8
    ) -> Bool {
        let quad = UInt32(c0) | (UInt32(c1) << 8) | (UInt32(c2) << 16) | (UInt32(c3) << 24)
        return unsafe loadBytes(input, at: index, as: UInt32.self) == quad
    }

    // MARK: The Latin1 SIMD scans
    //
    // The wide pair at 16 lanes, with the element index as the byte offset, so the
    // checked-multiply finding above has nothing to apply to.

    static let stride = 16 // SIMD::stride<Latin1Character>

    @inline(always) static func strictMask(_ v: SIMD16<UInt8>) -> SIMDMask<SIMD16<Int8>> {
        (v .== SIMD16(repeating: 0x22)) .| (v .== SIMD16(repeating: 0x5C))
            .| (v .< SIMD16(repeating: 0x20))
    }

    @inline(always) static func sloppyMask(
        _ v: SIMD16<UInt8>, _ terminator: UInt8
    ) -> SIMDMask<SIMD16<Int8>> {
        let controls = (v .< SIMD16(repeating: 0x20)) .& .!(v .== SIMD16(repeating: 0x09))
        return (v .== SIMD16(repeating: terminator)) .| (v .== SIMD16(repeating: 0x5C)) .| controls
    }

    @inline(always) static func findUnsafeStrict(
        _ input: RawSpan, _ units: Span<UInt8>, from: Int, count: Int
    ) -> Int {
        if count - from >= stride {
            var i = from
            while i + 2 * stride <= count {
                let m0 = strictMask(unsafe loadBytes(input, at: i, as: SIMD16<UInt8>.self))
                let m1 = strictMask(unsafe loadBytes(input, at: i + 16, as: SIMD16<UInt8>.self))
                if any(m0 .| m1) {
                    if any(m0) { return i + rankFirstLane(m0) }
                    return i + stride + rankFirstLane(m1)
                }
                i += 2 * stride
            }
            while i + stride <= count {
                let m = strictMask(unsafe loadBytes(input, at: i, as: SIMD16<UInt8>.self))
                if any(m) { return i + rankFirstLane(m) }
                i += stride
            }
            if i < count {
                let tail = count - stride
                let m = strictMask(unsafe loadBytes(input, at: tail, as: SIMD16<UInt8>.self))
                if any(m) { return tail + rankFirstLane(m) }
            }
            return count
        }
        var i = from
        while i < count {
            let c = units[i]
            if c == 0x22 || c == 0x5C || c < 0x20 { return i }
            i += 1
        }
        return count
    }

    @inline(always) static func findUnsafeSloppy(
        _ input: RawSpan, _ units: Span<UInt8>, from: Int, count: Int, terminator: UInt8
    ) -> Int {
        if count - from >= stride {
            var i = from
            while i + 2 * stride <= count {
                let m0 = sloppyMask(unsafe loadBytes(input, at: i, as: SIMD16<UInt8>.self), terminator)
                let m1 = sloppyMask(unsafe loadBytes(input, at: i + 16, as: SIMD16<UInt8>.self), terminator)
                if any(m0 .| m1) {
                    if any(m0) { return i + rankFirstLane(m0) }
                    return i + stride + rankFirstLane(m1)
                }
                i += 2 * stride
            }
            while i + stride <= count {
                let m = sloppyMask(unsafe loadBytes(input, at: i, as: SIMD16<UInt8>.self), terminator)
                if any(m) { return i + rankFirstLane(m) }
                i += stride
            }
            if i < count {
                let tail = count - stride
                let m = sloppyMask(unsafe loadBytes(input, at: tail, as: SIMD16<UInt8>.self), terminator)
                if any(m) { return tail + rankFirstLane(m) }
            }
            return count
        }
        var i = from
        while i < count {
            let c = units[i]
            // The wide form's `isLatin1` conjunct is constant-true here.
            if !((c >= 0x20 && c != 0x5C && c != terminator) || c == 0x09) { return i }
            i += 1
        }
        return count
    }
}

// MARK: - The grammar
//
// `parseRecursively`'s control flow (:1512), building the graph through the facade,
// which owns the value stack and returns only a keep-going flag. Swift must not name
// a cell type, hold one, or sit inside the object model's non-atomic store sequence;
// LiteralParserSwiftTypes.h has the reasons. Strict JSON only.

/// Where the parse is: the whole of the grammar's state beyond the container stack.
enum JSONParsePosition: UInt8 {
    case value = 0
    /// A value, or `]` — only immediately after `[`, since strict JSON has no
    /// trailing commas.
    case valueOrClose
    case key
    /// A key, or `}` — only immediately after `{`.
    case keyOrClose
    case colon
    case commaOrClose
    case documentEnd
}

/// Mirrors `JSC::JSONSwiftParseStatus`; raw values match.
enum JSONParseStatus: UInt8 {
    case ok = 0
    case declined = 1
    case stopped = 2
    /// Malformed, and the island formatted the message itself through
    /// `model.errorMessage`, so the C++ allocates the `String` instead of lexing the
    /// document a second time.
    case failed = 3
}

/// MARK: - The message text, which the island owns
///
/// Every message strict `JSON.parse` can spell is a prefix, a run of the document, and a
/// suffix, with `getErrorMessage`'s "JSON Parse error: " (LiteralParser.h:146) folded into the
/// prefix. So the literals live here, next to the code that detects each condition, and what
/// crosses is the two ASCII parts as spans plus the run's offsets; the C++ half is one
/// `tryMakeString` and a bounds check. Each case cites the site in LiteralParser.cpp whose
/// literal it repeats, and a mistyped literal is the only way the two can disagree, no error
/// kind crossing the boundary.
///
/// `@inline(never)`: its caller is always-inline and sits inside the lexer's error arms, so
/// inlining this would put every message literal into the hot function.
@inline(never)
@safe
func formatError(
    _ model: JSC.JSONSwiftObjectModel, _ kind: JSONErrorKind,
    quoting start: Int, length: UInt32
) {
    let quoteStart = UInt32(truncatingIfNeeded: start)
    if kind == .unexpectedIdentifier {
        // :1320, truncation rule and all, which moved here with the message. The two-step
        // fallback for an allocation that cannot be made did not: a `tryMakeString` that
        // fails leaves no message, and the document then declines to the C++ re-parse, which
        // has that fallback (:1324) already.
        let shown = min(length, 200)
        emitError(model, "JSON Parse error: Unexpected identifier \"",
            quoteStart, shown, shown == length ? "\"" : "...\"")
        return
    }
    emitError(model, errorMessagePrefix(kind), quoteStart, length,
        errorMessageSuffix(kind))
}

/// The literal before the quoted run — the whole message, for the majority that quote
/// nothing.
private func errorMessagePrefix(_ kind: JSONErrorKind) -> String {
    switch kind {
    // The four that quote the document.
    case .unrecognizedToken: "JSON Parse error: Unrecognized token '" // :856
    case .invalidEscapeCharacter: "JSON Parse error: Invalid escape character " // :1124
    case .invalidUnicodeEscape: "JSON Parse error: \"\\" // :1110
    case .unexpectedIdentifier: "JSON Parse error: Unexpected identifier \"" // :1320

    // Lexer-level.
    case .unterminatedString: "JSON Parse error: Unterminated string" // :1066, :1131
    case .singleQuotes: "JSON Parse error: Single quotes (') are not allowed in JSON" // :779
    case .unicodeEscapeNeedsFourHexDigits:
        "JSON Parse error: \\u must be followed by 4 hex digits" // :1105
    case .invalidNumber: "JSON Parse error: Invalid number" // :1188, :1264
    case .invalidDigitsAfterDecimalPoint:
        "JSON Parse error: Invalid digits after decimal point" // :1235
    case .exponentSymbols:
        "JSON Parse error: Exponent symbols should be followed by an optional '+' or '-' and then by at least one number" // :1254

    // Grammar-level.
    case .expectedRBrace: "JSON Parse error: Expected '}'" // :1273
    case .expectedRBracket: "JSON Parse error: Expected ']'" // :1276
    case .expectedColon:
        "JSON Parse error: Expected ':' before value in object property definition" // :1279
    case .unexpectedTokenRBracket: "JSON Parse error: Unexpected token ']'" // :1316
    case .unexpectedTokenRBrace: "JSON Parse error: Unexpected token '}'" // :1319
    case .unexpectedTokenColon: "JSON Parse error: Unexpected token ':'" // :1344
    case .unexpectedTokenLParen: "JSON Parse error: Unexpected token '('" // :1347
    case .unexpectedTokenRParen: "JSON Parse error: Unexpected token ')'" // :1350
    case .unexpectedTokenComma: "JSON Parse error: Unexpected token ','" // :1353
    case .unexpectedTokenDot: "JSON Parse error: Unexpected token '.'" // :1356
    case .unexpectedTokenAssign: "JSON Parse error: Unexpected token '='" // :1359
    case .unexpectedTokenSemi: "JSON Parse error: Unexpected token ';'" // :1362
    case .unexpectedEOF: "JSON Parse error: Unexpected EOF" // :1365
    case .unexpectedCommaAtEndOfArray:
        "JSON Parse error: Unexpected comma at the end of array expression" // :1459, :1662
    case .propertyNameMustBeAStringLiteral:
        "JSON Parse error: Property name must be a string literal" // :1600, :1789, :1831

    // `getErrorMessage`'s fallback (LiteralParser.h:152), and `.fromTokenType` with it: that
    // kind is resolved to a real one before anything is reported, so reaching here with it
    // would be an island bug, and the fallback message is what the C++ produces for a
    // document it has no message for.
    case .unableToParseJSONString, .fromTokenType:
        "JSON Parse error: Unable to parse JSON string"
    }
}

/// The literal after the quoted run, for the three kinds that have one. `.unexpectedIdentifier`
/// is not here: its suffix is the truncation's, decided in `formatError`.
private func errorMessageSuffix(_ kind: JSONErrorKind) -> String {
    switch kind {
    case .unrecognizedToken: "'"
    case .invalidUnicodeEscape: "\" is not a valid unicode escape"
    default: ""
    }
}

/// The one crossing. `prefix` and `suffix` arrive as `Span<UInt8>` rather than pointers
/// because the C++ declaration annotates them `__counted_by` plus `noescape`, which is what
/// makes the importer offer a safe overload.
///
/// The one `unsafe` the facade still costs, and it is the *safe* overload that costs it:
/// `JSC_SWIFT_SAFE` discharges the receiver on the other fifteen facade members, and on
/// this same declaration when it is called as pointer-plus-count — but the `Span` overload
/// the importer synthesizes from `__counted_by` + `noescape` does not carry the attribute
/// over, so the safer spelling of one call is the only one that needs a marker. Not a
/// position problem: prefix and trailing both lose it.
@inline(always)
@safe
func emitError(
    _ model: JSC.JSONSwiftObjectModel, _ prefix: String,
    _ quoteStart: UInt32, _ quoteLength: UInt32, _ suffix: String
) {
    unsafe model.errorMessage(prefix.utf8Span.span, quoteStart, quoteLength,
        suffix.utf8Span.span)
}

/// `Lexer::lexStringSlow`'s scan (LiteralParser.cpp:1043), with the buffer left in C++.
///
/// What is in Swift here is the part that was unchecked: the C++ walks raw `m_ptr`/`m_end`
/// pointers with no bounds checking at all (the file is inside
/// `WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN`), bounds `\uNNNN`'s four digits with a hand-written
/// `(m_end - m_ptr) < 5`, builds spans from raw pointer pairs, and enters the middle of its own
/// `do`/`while` with a `goto`. This indexes a `Span` and loops. It also shortens a lifetime:
/// the C++ leaves the decoded characters in the builder and a *raw pointer to them* in the
/// token, valid only until the next cold string clears it, which is why it has to resolve a
/// property name before the next token is lexed. Here the buffer becomes a cell inside one call
/// and no pointer to it exists on either side.
///
/// What deliberately stays in C++ is the `StringBuilder`: it owns the 8-bit-to-16-bit
/// upconversion policy, and that policy decides the resulting string's representation and
/// therefore how it interns. So runs of literal input and decoded units are emitted to C++ as
/// they are produced, one call each, and every crossing here is cold.
///
/// Anything malformed declines instead of being reported, like the rest of the island:
/// the C++ re-parse from offset zero produces the message, which keeps every error
/// byte-identical for free. Strict JSON only, so the sloppy `\'` case cannot arise.
///
/// `@inline(never)` and a *free* function, not a mutating method: `mutating` passes `self` by
/// pointer, which would leave the grammar's cursor and position in memory across the call
/// instead of in registers, at a large cost in the hot function's size. Everything it needs
/// comes in by value and the new cursor goes back in the result.
@inline(never)
@safe
func decodeEscapedString<T: JSONUnits>(
    _ model: JSC.JSONSwiftObjectModel,
    _ input: RawSpan, _ units: Span<T.Unit>,
    runStart: Int, from: Int, terminator: T.Unit, isKey: Bool, _ width: T.Type
) -> (status: UInt8, endOffset: Int) {
    // `units.count`, not a `count` handed in beside the span, and that is the difference
    // between five surviving bounds checks and none. The caller holds the two as one fact
    // (`let count = units.count`), but this function is `@inline(never)`, so inside it a
    // passed-in `count` is an unrelated `Int` and no guard written against it can discharge
    // the subscript's own check. Derived here, `i < count` is a fact about the same value.
    let count = units.count
    // Where the fast scan started, and where it stopped — at a backslash, at a control
    // character, or at the end of the input. It cannot have stopped at the terminator,
    // or `lexString` would have returned `.string` instead of asking for this.
    var runFrom = runStart
    var i = from
    var decodedAnything = false
    guard model.escapeBegin() else { return (JSONParseStatus.stopped.rawValue, 0) }

    while true {
        if UInt(bitPattern: i) >= UInt(bitPattern: count) {
            return (JSONParseStatus.declined.rawValue, 0) // "Unterminated string"
        }
        let unit = units[i]

        if unit == terminator {
            // A run with no escape in it cannot reach here on the first pass, so the
            // builder always holds at least one decoded unit by now; the guard states
            // that rather than trusting it, since an empty builder would silently make
            // an empty string.
            if !decodedAnything { return (JSONParseStatus.declined.rawValue, 0) }
            if i > runFrom {
                guard emitRun(model, from: runFrom, to: i) else {
                    return (JSONParseStatus.stopped.rawValue, 0)
                }
            }
            let end = i &+ 1
            let r: JSC.JSONSwiftColdResult
            if isKey {
                r = model.escapeFinishKey(end)
            } else {
                r = model.escapeFinishValue(end)
            }
            // The cursor goes back in the result rather than being written through a
            // pointer to the grammar, which is the whole reason this is a free function.
            return (r.status, r.endOffset)
        }

        guard unit == 0x5C else {
            // A control character, which strict JSON rejects. The C++ reports it as an
            // unterminated string; declining gets that message for free.
            return (JSONParseStatus.declined.rawValue, 0)
        }
        if i > runFrom {
            guard emitRun(model, from: runFrom, to: i) else {
                return (JSONParseStatus.stopped.rawValue, 0)
            }
        }

        i &+= 1
        if UInt(bitPattern: i) >= UInt(bitPattern: count) {
            return (JSONParseStatus.declined.rawValue, 0) // "Unterminated string"
        }
        let decoded: UInt16
        switch units[i] {
        case 0x22: decoded = 0x22; i &+= 1 // \"
        case 0x5C: decoded = 0x5C; i &+= 1 // \\
        case 0x2F: decoded = 0x2F; i &+= 1 // \/
        case 0x62: decoded = 0x08; i &+= 1 // \b
        case 0x66: decoded = 0x0C; i &+= 1 // \f
        case 0x6E: decoded = 0x0A; i &+= 1 // \n
        case 0x72: decoded = 0x0D; i &+= 1 // \r
        case 0x74: decoded = 0x09; i &+= 1 // \t
        case 0x75:
            // The C++ bound is `(m_end - m_ptr) < 5` with the cursor on the `u`, so
            // four digits must follow it inside the input.
            //
            // Spelled `count &- i >= 5` and not `i &+ 5 <= count`: the second does not
            // actually prove the four reads below are in range, because `&+` is allowed to
            // wrap and a wrapped `i` satisfies it. Here `i` is already known to be in
            // `0..<count`, so `count &- i` is in `1...count` and cannot wrap either.
            guard count &- i >= 5 else { return (JSONParseStatus.declined.rawValue, 0) }
            var value: UInt16 = 0
            for digit in 1...4 {
                guard let nibble = asciiHexValue(units[i &+ digit]) else {
                    return (JSONParseStatus.declined.rawValue, 0)
                }
                value = (value << 4) | UInt16(nibble)
            }
            // `Lexer::convertUnicode` (Lexer.h:291) is this, spelled as two byte
            // converts: `(convertHex(c1, c2) << 8) | convertHex(c3, c4)`.
            decoded = value
            i &+= 5
        default:
            return (JSONParseStatus.declined.rawValue, 0)
        }
        guard model.escapeUnit(decoded) else {
            return (JSONParseStatus.stopped.rawValue, 0)
        }
        decodedAnything = true

        // The next literal run, found with the same SIMD scan the fast path uses, so an
        // escaped string is not scanned character by character between its escapes.
        runFrom = i
        i = T.findUnsafeStrict(input, units, from: i, count: count)
    }
}

@inline(always)
@safe
func emitRun(
    _ model: JSC.JSONSwiftObjectModel, from: Int, to: Int
) -> Bool {
    model.escapeRun(UInt32(truncatingIfNeeded: from),
                    UInt32(truncatingIfNeeded: to &- from))
}


/// `parseRecursively`'s recursive descent, iteratively, with the container stack as a
/// 64-bit mask and a depth: no allocation, no refcount traffic, and no heap-allocated
/// Swift state for the conservative stack scan to reason about. Deeper than 64
/// declines to the C++ parse, which has a soft stack limit of its own.
struct JSONSwiftGrammar<T: JSONUnits> {
    var lexer = JSONLexer<T>(mode: .strictJSON)

    /// Bit *i* is set when the container opened at depth *i* is an object.
    var objectMask: UInt64 = 0
    var depth: UInt32 = 0
    var position: JSONParsePosition = .value

    @inline(always)
    var innermostIsObject: Bool {
        depth != 0 && (objectMask >> (depth - 1)) & 1 == 1
    }

    /// The C++ has this as "am I in the array loop or the object loop".
    @inline(always)
    var positionAfterValue: JSONParsePosition {
        depth == 0 ? .documentEnd : .commaOrClose
    }

    @inline(always)
    mutating func pushContainer(isObject: Bool) -> Bool {
        // 64 containers, because the mask is 64 bits wide.
        if depth == 64 { return false }
        if isObject {
            objectMask |= UInt64(1) << depth
        } else {
            objectMask &= ~(UInt64(1) << depth)
        }
        depth += 1
        return true
    }

    // `@inline(always)` with one call site, so it duplicates nothing, and not for the
    // call: `mutating` passes `self` by pointer, and the optimizer then leaves the grammar's
    // state in the caller's frame instead of in registers. Inlined, SROA promotes it.
    @inline(always)
    @safe
    mutating func parse(
        _ input: RawSpan, _ model: JSC.JSONSwiftObjectModel
    ) -> UInt8 {
        // Hoisted once per document rather than re-derived per token.
        let units = Span<T.Unit>(viewing: input)
        let count = units.count

        while true {

            switch position {
            case .value, .valueOrClose:
                let type = lexer.lex(input, units, count, maybeIdentifier: false)
                switch type {
                case JSONTokenType.string.rawValue:
                    guard model.stringValue(lexer.currentToken.start,
                                           lexer.currentToken.length) else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = positionAfterValue

                case JSONTokenType.numberInt32.rawValue:
                    guard model.intValue(lexer.currentToken.int32Value) else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = positionAfterValue

                case JSONTokenType.lbrace.rawValue:
                    guard pushContainer(isObject: true) else {
                        return JSONParseStatus.declined.rawValue
                    }
                    guard model.beginObject() else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = .keyOrClose

                case JSONTokenType.lbracket.rawValue:
                    guard pushContainer(isObject: false) else {
                        return JSONParseStatus.declined.rawValue
                    }
                    guard model.beginArray() else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = .valueOrClose

                case JSONTokenType.number.rawValue:
                    guard model.doubleValue(lexer.currentToken.numberValue) else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = positionAfterValue

                case JSONTokenType.true.rawValue, JSONTokenType.false.rawValue,
                     JSONTokenType.null.rawValue:
                    // One case passing the type rather than three passing a constant. The
                    // facade entry is always-inline, so three would fold the dispatch at the
                    // cost of three copies of the store in this loop — see `literalValue`.
                    guard model.literalValue(type) else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = positionAfterValue

                case JSONTokenType.rbracket.rawValue where position == .valueOrClose:
                    // The empty array.
                    depth -= 1
                    guard model.endContainer() else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = positionAfterValue

                case JSONTokenType.needsSlowString.rawValue:
                    // Called from inside the loop rather than by unwinding to C++, so
                    // the shape matches the C++, which calls `lexStringSlow` inline.
                    let r = decodeEscapedString(
                        model, input, units,
                        runStart: Int(lexer.currentToken.start), from: lexer.offset,
                        terminator: T.Unit(truncatingIfNeeded: lexer.pendingTerminator),
                        isKey: false, T.self)
                    if r.status != JSONParseStatus.ok.rawValue { return r.status }
                    lexer.offset = r.endOffset
                    position = positionAfterValue

                case JSONTokenType.needsDoubleParse.rawValue:
                    let r = model.slowNumberValue(lexer.currentToken.start)
                    if r.status != JSONParseStatus.ok.rawValue { return r.status }
                    lexer.offset = r.endOffset
                    position = positionAfterValue

                default:
                    return JSONParseStatus.declined.rawValue
                }

            case .key, .keyOrClose:
                // `maybeIdentifier: false` even at a key, where the C++ passes
                // MaybeIdentifier (:1433). Sound because in *strict* JSON the hint
                // cannot change the token stream — which is also why the island is
                // strict-only — and faster: `true` here is worse at every width.
                let type = lexer.lex(input, units, count, maybeIdentifier: false)
                switch type {
                case JSONTokenType.string.rawValue:
                    // No `.identifier` case: `{a:1}` is an error in strict JSON, so it
                    // falls through to `declined` and the C++ reports it.
                    guard model.key(lexer.currentToken.start,
                                    lexer.currentToken.length) else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = .colon

                case JSONTokenType.rbrace.rawValue where position == .keyOrClose:
                    depth -= 1
                    guard model.endContainer() else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = positionAfterValue

                case JSONTokenType.needsSlowString.rawValue:
                    let r = decodeEscapedString(
                        model, input, units,
                        runStart: Int(lexer.currentToken.start), from: lexer.offset,
                        terminator: T.Unit(truncatingIfNeeded: lexer.pendingTerminator),
                        isKey: true, T.self)
                    if r.status != JSONParseStatus.ok.rawValue { return r.status }
                    lexer.offset = r.endOffset
                    position = .colon

                default:
                    return JSONParseStatus.declined.rawValue
                }

            case .colon:
                let type = lexer.lex(input, units, count, maybeIdentifier: false)
                if type != JSONTokenType.colon.rawValue {
                    return JSONParseStatus.declined.rawValue
                }
                position = .value

            case .commaOrClose:
                let type = lexer.lex(input, units, count, maybeIdentifier: false)
                let isObject = innermostIsObject
                if type == JSONTokenType.comma.rawValue {
                    position = isObject ? .key : .value
                } else if type == (isObject ? JSONTokenType.rbrace.rawValue
                                            : JSONTokenType.rbracket.rawValue) {
                    depth -= 1
                    guard model.endContainer() else {
                        return JSONParseStatus.stopped.rawValue
                    }
                    position = positionAfterValue
                } else {
                    return JSONParseStatus.declined.rawValue
                }

            case .documentEnd:
                let type = lexer.lex(input, units, count, maybeIdentifier: false)
                if type != JSONTokenType.end.rawValue {
                    return JSONParseStatus.declined.rawValue
                }
                return JSONParseStatus.ok.rawValue
            }
        }
    }
}

/// Parses a whole document, returning a `JSC::JSONSwiftParseStatus`. One entry point
/// per width: `@_expose(Cxx)` needs a concrete signature, and these two are what
/// force the grammar to be specialized rather than run through witnesses. A document
/// that is a bare primitive needs nothing special here: at depth 0 the position after
/// a value is `.documentEnd`, and the facade records the value as the result.
@_expose(Cxx)
func jsonParseDocument16(
    _ data: JSC.JSONLexerSpan16,
    _ model: JSC.JSONSwiftObjectModel
) -> UInt8 {
    let units = unsafe Span<UInt16>(_unsafeCxxSpan: data)
    // Fewer than 2^31 units, which `JSString::MaxLength` already guarantees. Stating
    // it licenses the wrapping `UInt32` conversions and discharges the overflow branches
    // in this width's byte-offset arithmetic. Deliberately absent from the 8-bit entry,
    // where the same fact re-lowers the SIMD reduce and is a large loss on short strings;
    // do not add it there without measuring.
    precondition(units.count <= Int(Int32.max))
    let raw = RawSpan(elements: units)
    var grammar = JSONSwiftGrammar<WideUnits>()
    return grammar.parse(raw, model)
}

/// The same for an all-Latin1 `JSString`, which is what JSC gives almost every real
/// JSON document.
@_expose(Cxx)
func jsonParseDocument8(
    _ data: JSC.JSONLexerSpan8,
    _ model: JSC.JSONSwiftObjectModel
) -> UInt8 {
    let units = unsafe Span<UInt8>(_unsafeCxxSpan: data)
    let raw = RawSpan(elements: units)
    var grammar = JSONSwiftGrammar<Latin1Units>()
    return grammar.parse(raw, model)
}

#endif // JSC_SUPPORTS_SWIFT
