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

// swift-format-ignore-file: UseEarlyExits

#if USE_SWIFT_JSON_PARSER

internal import JavaScriptCore_Private.LiteralParserSwiftTypes

// LiteralParser's lexer and grammar: JSON, the JSON subset eval accepts, and JSONP. The C++ entry points in
// LiteralParserSwiftFacade.cpp call these with the characters, a JSONParseEntry, the parse's options and the sink.
// Every value is made by the sink; this side holds offsets only.

/// Parses Latin-1 characters. `iterative` builds objects and arrays as LiteralParser.cpp's parse() builds them, and
/// `recordsRanges` records source ranges for the reviver. Returns true if the parse's value is in `sink`, and false
/// if `sink` holds the message or an exception is pending on the VM.
///
/// `input` is the characters of a `String`, a `StringView` or a byte span that the C++ caller owns and keeps alive
/// for the whole call. A `StringImpl`'s characters never change, and no caller writes the other kinds while it
/// parses, including the C++ this calls through `sink`. Every bit pattern of `Latin1Character` is a valid
/// value, and there is no output span.
///
/// `sink` is the JSONParseState on the stack of parseWithSink() in LiteralParserSwiftFacade.cpp, which alone
/// constructs it. Swift reaches it only through its member functions, which reach the state through no other
/// path; the JavaScript they can run (a __proto__ setter in SloppyJSON) and a collection cannot name it.
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jsonParse8(
    _ input: JSC.JSONParseInput8,
    _ entry: UInt8,
    _ iterative: Bool,
    _ recordsRanges: Bool,
    _ needsFullSourceInfo: Bool,
    _ sink: inout JSC.JSONParseSink8
) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    var parser = JSONParser<UInt8, JSC.JSONParseSink8>(
        entry: entry,
        iterative: iterative,
        recordsRanges: recordsRanges,
        needsFullSourceInfo: needsFullSourceInfo
    )
    return parser.parse(characters, &sink)
}

/// Parses UTF-16 code units, under the same conditions as `jsonParse8`. Every `char16_t` is a valid value.
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jsonParse16(
    _ input: JSC.JSONParseInput16,
    _ entry: UInt8,
    _ iterative: Bool,
    _ recordsRanges: Bool,
    _ needsFullSourceInfo: Bool,
    _ sink: inout JSC.JSONParseSink16
) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: input)
    var parser = JSONParser<UInt16, JSC.JSONParseSink16>(
        entry: entry,
        iterative: iterative,
        recordsRanges: recordsRanges,
        needsFullSourceInfo: needsFullSourceInfo
    )
    return parser.parse(characters, &sink)
}

/// Parses Latin-1 characters as `jsonParse8` does, for a StrictJSON `entry` that is not iterative.
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jsonParseStrict8(_ input: JSC.JSONParseInput8, _ entry: UInt8, _ sink: inout JSC.JSONParseSinkStrict8) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    var parser = JSONParser<UInt8, JSC.JSONParseSinkStrict8>(
        entry: entry,
        iterative: false,
        recordsRanges: false,
        needsFullSourceInfo: false
    )
    return parser.parse(characters, &sink)
}

/// Parses UTF-16 code units as `jsonParse16` does, for a StrictJSON `entry` that is not iterative.
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jsonParseStrict16(_ input: JSC.JSONParseInput16, _ entry: UInt8, _ sink: inout JSC.JSONParseSinkStrict16) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: input)
    var parser = JSONParser<UInt16, JSC.JSONParseSinkStrict16>(
        entry: entry,
        iterative: false,
        recordsRanges: false,
        needsFullSourceInfo: false
    )
    return parser.parse(characters, &sink)
}

/// Parses Latin-1 characters as `jsonParse8` does, for JSONParseEntry.Eval when it is not iterative.
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jsonParseSloppy8(_ input: JSC.JSONParseInput8, _ sink: inout JSC.JSONParseSinkSloppy8) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    var parser = JSONParser<UInt8, JSC.JSONParseSinkSloppy8>(
        entry: JSC.JSONParseEntry.Eval.rawValue,
        iterative: false,
        recordsRanges: false,
        needsFullSourceInfo: false
    )
    return parser.parse(characters, &sink)
}

/// Parses UTF-16 code units as `jsonParse16` does, for JSONParseEntry.Eval when it is not iterative.
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jsonParseSloppy16(_ input: JSC.JSONParseInput16, _ sink: inout JSC.JSONParseSinkSloppy16) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: input)
    var parser = JSONParser<UInt16, JSC.JSONParseSinkSloppy16>(
        entry: JSC.JSONParseEntry.Eval.rawValue,
        iterative: false,
        recordsRanges: false,
        needsFullSourceInfo: false
    )
    return parser.parse(characters, &sink)
}

/// LiteralParserSwiftTypes.h's JSONParseSink at one width, for one JSONParseSinkMode. `fixedMode` is the mode of a
/// sink for one mode, whose parse is not iterative and so records no source ranges, and nil for a sink for any parse.
private protocol JSONSink: ~Copyable {
    associatedtype CodeUnit: JSONCharacter
    static var fixedMode: JSONMode? { get }
    mutating func beginArray(_ start: Int) -> Bool
    mutating func endArray(_ end: Int) -> Bool
    mutating func beginObject(_ start: Int) -> Bool
    mutating func endObject(_ end: Int) -> Bool
    mutating func beginCacheScope()
    mutating func key(_ characters: Span<CodeUnit>, _ charactersToEnd: Int)
    mutating func decodedKey(_ characters8: Span<UInt8>, _ characters16: Span<UInt16>)
    mutating func consumeCachedKey(_ remaining: Span<CodeUnit>) -> Int
    mutating func setValueRange(_ start: Int, _ end: Int)
    mutating func stringValue(_ start: Int, _ length: Int, _ cache: Bool) -> Bool
    mutating func decodedStringValue(_ characters8: Span<UInt8>, _ characters16: Span<UInt16>) -> Bool
    mutating func cachedStringValue(_ remaining: Span<CodeUnit>, _ length: inout Int) -> Bool
    mutating func int32Value(_ value: Int32) -> Bool
    mutating func numberValue(_ value: Double) -> Bool
    mutating func literalValue(_ literal: JSC.JSONParseLiteral) -> Bool
    mutating func parseNumber(_ remaining: Span<CodeUnit>, _ length: inout Int) -> Double
    mutating func fail(_ failure: JSC.JSONParseFailure)
    mutating func appendJSONPPathEntry(_ type: UInt8, _ start: Int, _ length: Int, _ index: Int32) -> Bool
    mutating func beginJSONPValue()
    mutating func endJSONPValue()
}

extension JSC.JSONParseSink8: JSONSink {
    fileprivate typealias CodeUnit = UInt8
    fileprivate static var fixedMode: JSONMode? { nil }
}

extension JSC.JSONParseSink16: JSONSink {
    fileprivate typealias CodeUnit = UInt16
    fileprivate static var fixedMode: JSONMode? { nil }
}

extension JSC.JSONParseSinkStrict8: JSONSink {
    fileprivate typealias CodeUnit = UInt8
    fileprivate static var fixedMode: JSONMode? { .strict }
}

extension JSC.JSONParseSinkStrict16: JSONSink {
    fileprivate typealias CodeUnit = UInt16
    fileprivate static var fixedMode: JSONMode? { .strict }
}

extension JSC.JSONParseSinkSloppy8: JSONSink {
    fileprivate typealias CodeUnit = UInt8
    fileprivate static var fixedMode: JSONMode? { .sloppy }
}

extension JSC.JSONParseSinkSloppy16: JSONSink {
    fileprivate typealias CodeUnit = UInt16
    fileprivate static var fixedMode: JSONMode? { .sloppy }
}

/// LiteralParser's JSONPPathEntryType.
private enum JSONPPathEntryType: UInt8 {
    case declareVar
    case dot
    case lookup
    case call
}

/// LiteralParser's ParserMode.
private enum JSONMode {
    case strict
    case sloppy
    case jsonp
}

private enum JSONToken {
    case leftBracket
    case rightBracket
    case leftBrace
    case rightBrace
    case string
    case identifier
    case number
    case numberInt32
    case colon
    case leftParenthesis
    case rightParenthesis
    case comma
    case trueLiteral
    case falseLiteral
    case nullLiteral
    case end
    case dot
    case assign
    case semicolon
    case error
}

/// What the lexer found wrong, at an offset into the characters where the message quotes them.
private enum JSONLexError {
    case singleQuote
    case unrecognizedToken(Int)
    case unterminatedString
    case shortUnicodeEscape
    case invalidUnicodeEscape(Int)
    case invalidEscape(Int)
    case invalidNumber
    case invalidDecimalDigits
    case invalidExponent
}

/// A message for an error the grammar found.
private enum JSONParseMessage: UInt8 {
    case couldNotParseStatement
    case couldNotParseValue
    case expectedColon
    case expectedRightBracket
    case expectedRightBrace
    case propertyNameNotString
    case unexpectedEOF
    case trailingComma
    case unexpectedContent
    case unexpectedIdentifier
    case unexpectedLeftParenthesis
    case unexpectedRightParenthesis
    case unexpectedComma
    case unexpectedDot
    case unexpectedColon
    case unexpectedSemicolon
    case unexpectedAssign
    case unexpectedRightBracket
    case unexpectedFalse
    case unexpectedNull
    case unexpectedTrue
    case unexpectedLeftBrace
    case unexpectedRightBrace

    var text: String {
        switch self {
        case .couldNotParseStatement:
            "Could not parse statement"
        case .couldNotParseValue:
            "Could not parse value expression"
        case .expectedColon:
            "Expected ':' before value in object property definition"
        case .expectedRightBracket:
            "Expected ']'"
        case .expectedRightBrace:
            "Expected '}'"
        case .propertyNameNotString:
            "Property name must be a string literal"
        case .unexpectedEOF:
            "Unexpected EOF"
        case .trailingComma:
            "Unexpected comma at the end of array expression"
        case .unexpectedContent:
            "Unexpected content at end of JSON literal"
        case .unexpectedIdentifier:
            "Unexpected identifier"
        case .unexpectedLeftParenthesis:
            "Unexpected token '('"
        case .unexpectedRightParenthesis:
            "Unexpected token ')'"
        case .unexpectedComma:
            "Unexpected token ','"
        case .unexpectedDot:
            "Unexpected token '.'"
        case .unexpectedColon:
            "Unexpected token ':'"
        case .unexpectedSemicolon:
            "Unexpected token ';'"
        case .unexpectedAssign:
            "Unexpected token '='"
        case .unexpectedRightBracket:
            "Unexpected token ']'"
        case .unexpectedFalse:
            "Unexpected token 'false'"
        case .unexpectedNull:
            "Unexpected token 'null'"
        case .unexpectedTrue:
            "Unexpected token 'true'"
        case .unexpectedLeftBrace:
            "Unexpected token '{'"
        case .unexpectedRightBrace:
            "Unexpected token '}'"
        }
    }
}

private enum JSONParseError {
    case message(JSONParseMessage)
    case unexpectedIdentifier(start: Int, length: Int)
}

private enum JSONStep {
    case value
    case key(consumed: Bool, sliced: Bool)
    case afterValue
    case arrayStart(afterComma: Bool)
}

/// The open containers, one bit each, set for an object.
///
/// Up to 64 of the innermost are in `objects`, and `innermost` is the bit of the innermost one, or 0 when none is open.
/// Each full word of the containers around them is appended to the caller's array, so nesting allocates nothing until
/// it is deeper than 64.
private struct JSONContainers {
    var objects: UInt64 = 0
    var innermost: UInt64 = 0

    @inline(always)
    var isEmpty: Bool { innermost == 0 }

    @inline(always)
    var innermostIsObject: Bool { objects & innermost != 0 }

    @inline(always)
    mutating func push(isObject: Bool, _ spilled: inout UniqueArray<UInt64>) {
        if innermost == 1 << 63 {
            spillContainers(objects, &spilled)
        }
        let next = innermost << 1
        innermost = next == 0 ? 1 : next
        objects = isObject ? objects | innermost : objects & ~innermost
    }

    @inline(always)
    mutating func pop(_ spilled: inout UniqueArray<UInt64>) {
        innermost >>= 1
        if innermost == 0 && !spilled.isEmpty {
            objects = refillContainers(&spilled)
            innermost = 1 << 63
        }
    }
}

@inline(never)
private func spillContainers(_ objects: UInt64, _ spilled: inout UniqueArray<UInt64>) {
    spilled.append(objects)
}

@inline(never)
private func refillContainers(_ spilled: inout UniqueArray<UInt64>) -> UInt64 {
    spilled.removeLast()
}

private let quote = 0x22
private let apostrophe = 0x27
private let backslash = 0x5C

/// Whether `index` is in `0..<count`, compared as a span's subscript compares it, so that the subscript's own check
/// after it is redundant.
@inline(always)
private func isInBounds(_ index: Int, _ count: Int) -> Bool {
    UInt(bitPattern: index) < UInt(bitPattern: count)
}

@inline(always)
private func isJSONWhiteSpace<Unit: FixedWidthInteger & UnsignedInteger>(_ character: Unit) -> Bool {
    character == 0x20 || character == 0x0A || character == 0x0D || character == 0x09
}

@inline(always)
private func isASCIIDigit<Unit: FixedWidthInteger & UnsignedInteger>(_ character: Unit) -> Bool {
    character >= 0x30 && character <= 0x39
}

@inline(always)
private func asciiHexValue<Unit: FixedWidthInteger & UnsignedInteger>(_ character: Unit) -> UInt16? {
    if character >= 0x30 && character <= 0x39 {
        return UInt16(truncatingIfNeeded: character) - 0x30
    }
    if character >= 0x41 && character <= 0x46 {
        return UInt16(truncatingIfNeeded: character) - 0x41 + 10
    }
    if character >= 0x61 && character <= 0x66 {
        return UInt16(truncatingIfNeeded: character) - 0x61 + 10
    }
    return nil
}

@inline(always)
private func isValidIdentifierCharacter<Unit: FixedWidthInteger & UnsignedInteger>(_ character: Unit) -> Bool {
    if character <= 0x7A {
        let c = UInt8(truncatingIfNeeded: character)
        return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
    }
    return Unit.bitWidth == 16 && (character == 0x200C || character == 0x200D)
}

/// The safe string characters of StrictJSON: all but controls, '"' and '\'.
@inline(always)
private func isSafeStrictStringCharacter<Unit: FixedWidthInteger & UnsignedInteger>(_ character: Unit) -> Bool {
    character > 0xFF || (character >= 0x20 && character != quote && character != backslash)
}

/// The safe string characters of SloppyJSON and JSONP: tab too, and the terminator is either quote.
@inline(always)
private func isSafeSloppyStringCharacter<Unit: FixedWidthInteger & UnsignedInteger>(_ character: Unit, _ terminator: Unit) -> Bool {
    character > 0xFF || (character >= 0x20 && character != backslash && character != terminator) || character == 0x09
}

/// The first key of an object in SloppyJSON at 16 bits stops at any character beyond Latin-1.
@inline(always)
private func isSafeSloppyIdentifierStringCharacter<Unit: FixedWidthInteger & UnsignedInteger>(_ character: Unit, _ terminator: Unit) -> Bool
{
    (character >= 0x20 && character <= 0xFF && character != backslash && character != terminator) || character == 0x09
}

/// Which characters are safe in a string: those of `isSafeStrictStringCharacter`, `isSafeSloppyStringCharacter`, or
/// `isSafeSloppyIdentifierStringCharacter`.
private enum SafeStringCharacters {
    case strict
    case sloppy
    case sloppyIdentifier
}

@inline(always)
private func isSafeStringCharacter<Unit: FixedWidthInteger & UnsignedInteger>(
    _ character: Unit,
    _ kind: SafeStringCharacters,
    _ terminator: Unit
) -> Bool {
    switch kind {
    case .strict:
        isSafeStrictStringCharacter(character)
    case .sloppy:
        isSafeSloppyStringCharacter(character, terminator)
    case .sloppyIdentifier:
        isSafeSloppyIdentifierStringCharacter(character, terminator)
    }
}

/// The high bit of each lane is set where the lane is zero.
@inline(always)
private func zeroLanes(_ v: SIMD16<UInt8>) -> SIMD16<UInt8> {
    (v &- SIMD16(repeating: 1)) & ~v
}

@inline(always)
private func zeroLanes(_ v: SIMD8<UInt16>) -> SIMD8<UInt16> {
    (v &- SIMD8(repeating: 1)) & ~v
}

/// The high bit of each lane is set where the character is not safe.
///
/// In StrictJSON, each of the three differences sets the high bit of a lane below 0x80 exactly where it is a quote, a
/// backslash or a control, and `~v` clears it in the lanes from 0x80 on, which are safe.
@inline(always)
private func unsafeLanes(_ v: SIMD16<UInt8>, _ kind: SafeStringCharacters, _ terminator: SIMD16<UInt8>) -> SIMD16<UInt8> {
    if kind == .strict {
        return
            (((v ^ SIMD16(repeating: 0x22)) &- SIMD16(repeating: 1)) | ((v ^ SIMD16(repeating: 0x5C)) &- SIMD16(repeating: 1))
            | (v &- SIMD16(repeating: 0x20))) & ~v
    }
    let control = zeroLanes(v & SIMD16(repeating: 0xE0))
    let backslashes = zeroLanes(v ^ SIMD16(repeating: 0x5C))
    return zeroLanes(v ^ terminator) | backslashes | (control & ~zeroLanes(v ^ SIMD16(repeating: 0x09)))
}

@inline(always)
private func unsafeLanes(_ v: SIMD8<UInt16>, _ kind: SafeStringCharacters, _ terminator: SIMD8<UInt16>) -> SIMD8<UInt16> {
    if kind == .strict {
        return
            (((v ^ SIMD8(repeating: 0x22)) &- SIMD8(repeating: 1)) | ((v ^ SIMD8(repeating: 0x5C)) &- SIMD8(repeating: 1))
            | (v &- SIMD8(repeating: 0x20))) & ~v
    }
    let control = zeroLanes(v & SIMD8(repeating: 0xFFE0))
    let backslashes = zeroLanes(v ^ SIMD8(repeating: 0x5C))
    let lanes = zeroLanes(v ^ terminator) | backslashes | (control & ~zeroLanes(v ^ SIMD8(repeating: 0x09)))
    if kind == .sloppyIdentifier {
        return lanes | ~zeroLanes(v & SIMD8(repeating: 0xFF00))
    }
    return lanes
}

/// The high bit of each byte of the word is set where the byte is zero.
///
/// Each byte is tested on its own, with no carry between bytes.
@inline(always)
private func zeroBytes(_ w: UInt64) -> UInt64 {
    ~(((w & 0x7F7F_7F7F_7F7F_7F7F) + 0x7F7F_7F7F_7F7F_7F7F) | w | 0x7F7F_7F7F_7F7F_7F7F)
}

/// The high bit of the lowest-addressed byte that is not safe is set, and no bit below it.
///
/// The differences borrow across bytes, but a borrow starts only at a byte that is not safe (or, outside StrictJSON, a
/// tab), so the bytes it reaches lie above that one.
@inline(always)
private func unsafeBytes(_ w: UInt64, _ kind: SafeStringCharacters, _ terminator: UInt64) -> UInt64 {
    if kind == .strict {
        return
            (((w ^ 0x2222_2222_2222_2222) &- 0x0101_0101_0101_0101) | ((w ^ 0x5C5C_5C5C_5C5C_5C5C) &- 0x0101_0101_0101_0101)
            | (w &- 0x2020_2020_2020_2020)) & ~w & 0x8080_8080_8080_8080
    }
    // The same differences, with the terminator for the quote: every byte that is not safe gets its high bit, and
    // only a tab among the safe bytes can, with what it borrows. So unless the lowest such byte is a tab, it is the
    // answer; a tab takes the exact test.
    let flagged =
        (((w ^ terminator) &- 0x0101_0101_0101_0101) | ((w ^ 0x5C5C_5C5C_5C5C_5C5C) &- 0x0101_0101_0101_0101)
            | (w &- 0x2020_2020_2020_2020)) & ~w & 0x8080_8080_8080_8080
    // flagged is nonzero and has only bit 7 of each byte set, so this is at least 0.
    if flagged == 0 || (w >> UInt64(flagged.trailingZeroBitCount &- 7)) & 0xFF != 0x09 {
        return flagged
    }
    let control = zeroBytes(w & 0xE0E0_E0E0_E0E0_E0E0)
    let backslashes = zeroBytes(w ^ 0x5C5C_5C5C_5C5C_5C5C)
    return zeroBytes(w ^ terminator) | backslashes | (control & ~zeroBytes(w ^ 0x0909_0909_0909_0909))
}

/// The high bit of the lowest-addressed 16-bit unit of the word that is not safe in StrictJSON is set, and no bit
/// below it, as unsafeBytes does for bytes: a unit from 0x8000 on is safe, and the differences borrow only from a
/// unit that is not safe, into the units above it.
@inline(always)
private func unsafeStrictUnits(_ w: UInt64) -> UInt64 {
    (((w ^ 0x0022_0022_0022_0022) &- 0x0001_0001_0001_0001) | ((w ^ 0x005C_005C_005C_005C) &- 0x0001_0001_0001_0001)
        | (w &- 0x0020_0020_0020_0020)) & ~w & 0x8000_8000_8000_8000
}

/// Whether the high bit of any lane is set.
///
/// Tested on the vector's two 64-bit words: on x86-64 a reduction over the lanes is a longer chain.
@inline(always)
private func hasSetHighBit(_ v: SIMD16<UInt8>) -> Bool {
    let words = bitCast(v, to: SIMD2<UInt64>.self)
    return (words[0] | words[1]) & 0x8080_8080_8080_8080 != 0
}

@inline(always)
private func hasSetHighBit(_ v: SIMD8<UInt16>) -> Bool {
    let words = bitCast(v, to: SIMD2<UInt64>.self)
    return (words[0] | words[1]) & 0x8000_8000_8000_8000 != 0
}

/// The first lane whose high bit is set, in a vector that has one.
///
/// Lane 0 is the lowest-addressed character.
@inline(always)
private func firstSetLane(_ v: SIMD16<UInt8>) -> Int {
    let words = bitCast(v & SIMD16(repeating: 0x80), to: SIMD2<UInt64>.self)
    return words[0] != 0 ? words[0].trailingZeroBitCount / 8 : 8 + words[1].trailingZeroBitCount / 8
}

/// The first of the 32 lanes of `first` and then `second` whose high bit is set.
///
/// One of them is.
@inline(always)
private func firstSetLane(_ first: SIMD16<UInt8>, _ second: SIMD16<UInt8>) -> Int {
    // Four bits per lane, in lane order: each lane is spread over its byte, and the middle eight bits of each pair of
    // lanes are kept.
    @inline(always)
    func nibbles(_ v: SIMD16<UInt8>) -> UInt64 {
        let spread = bitCast(bitCast(v, to: SIMD16<Int8>.self) &>> 7, to: SIMD8<UInt16>.self)
        return bitCast(SIMD8<UInt8>(truncatingIfNeeded: spread &>> 4), to: UInt64.self)
    }
    let low = nibbles(first)
    let high = nibbles(second)
    let word = low != 0 ? low : high
    return word.trailingZeroBitCount / 4 + (low != 0 ? 0 : 16)
}

@inline(always)
private func firstSetLane(_ v: SIMD8<UInt16>) -> Int {
    let words = bitCast(v & SIMD8(repeating: 0x8000), to: SIMD2<UInt64>.self)
    return words[0] != 0 ? words[0].trailingZeroBitCount / 16 : 4 + words[1].trailingZeroBitCount / 16
}

/// A string with escapes, decoded at the width LiteralParser's StringBuilder gives it: 8 bits, in `characters8`,
/// until a code unit above 0xFF or more than one 16-bit character at once is appended, and then 16 bits, in
/// `characters16`.
private struct DecodedString: ~Copyable {
    var characters8 = UniqueArray<UInt8>()
    var characters16 = UniqueArray<UInt16>()

    mutating func removeAll() {
        characters8.removeAll()
        characters16.removeAll()
    }

    mutating func append(_ unit: UInt16) {
        if characters16.isEmpty && unit <= 0xFF {
            characters8.append(UInt8(truncatingIfNeeded: unit))
            return
        }
        widen()
        characters16.append(unit)
    }

    mutating func append(_ run: Span<UInt8>) {
        if characters16.isEmpty {
            characters8.append(copying: run)
            return
        }
        for i in run.indices {
            characters16.append(UInt16(run[i]))
        }
    }

    mutating func append(_ run: Span<UInt16>) {
        if run.count <= 1 {
            if run.count == 1 {
                append(run[0])
            }
            return
        }
        widen()
        characters16.append(copying: run)
    }

    @inline(never)
    mutating func widen() {
        if !characters16.isEmpty {
            return
        }
        characters16.reserveCapacity(characters8.count + 1)
        for i in characters8.indices {
            characters16.append(UInt16(characters8[i]))
        }
        characters8.removeAll()
    }
}

/// A character width the parser reads.
private protocol JSONCharacter: FixedWidthInteger & UnsignedInteger {
    /// The offset of the first character at or after `start` that is not safe, or the input's count.
    static func findUnsafeStringCharacter(_ input: Span<Self>, from start: Int, _ kind: SafeStringCharacters, terminator: Self) -> Int
    static func append(_ run: Span<Self>, to string: inout DecodedString)
    /// Appends the characters to the message, and returns false if it could not be allocated.
    @discardableResult
    static func append(_ characters: Span<Self>, to message: inout JSC.JSONParseErrorMessage) -> Bool
}

// Both widths compare the first 16 characters 8 bytes at a time in a general-purpose register, where most strings
// end (at 16 bits, StrictJSON only), and then call a function, one per kind, that compares 32 bytes per step while 32
// remain, then 16, then one character at a time. The word compares are inlined into the lexer. The vector compares
// are not: on Windows x64 the vector registers they use are saved by the callee, so inlining them would save registers
// on every string token rather than only on the strings that reach them.
extension UInt8: JSONCharacter {
    fileprivate static func append(_ run: Span<UInt8>, to string: inout DecodedString) {
        string.append(run)
    }

    fileprivate static func append(_ characters: Span<UInt8>, to message: inout JSC.JSONParseErrorMessage) -> Bool {
        // A std::span is made only from a span with an address, which an empty Span<UInt16>() lacks.
        let none = InlineArray<1, UInt16>(repeating: 0)
        return message.append(characters, none.span.extracting(first: 0))
    }

    @inline(always)
    fileprivate static func findUnsafeStringCharacter(
        _ input: Span<UInt8>,
        from start: Int,
        _ kind: SafeStringCharacters,
        terminator: UInt8
    ) -> Int {
        let bytes = input.bytes
        let byteCount = bytes.byteCount
        var index = start
        if byteCount >= 8 && UInt(bitPattern: index) <= UInt(bitPattern: byteCount - 8) {
            let terminatorWord = bitCast(SIMD8<UInt8>(repeating: terminator), to: UInt64.self)
            let first = unsafeBytes(UInt64(littleEndian: bytes.load(fromByteOffset: index, as: UInt64.self)), kind, terminatorWord)
            if first != 0 {
                return index + first.trailingZeroBitCount / 8
            }
            index += 8
            if UInt(bitPattern: index) <= UInt(bitPattern: byteCount - 8) {
                let second = unsafeBytes(UInt64(littleEndian: bytes.load(fromByteOffset: index, as: UInt64.self)), kind, terminatorWord)
                if second != 0 {
                    return index + second.trailingZeroBitCount / 8
                }
                index += 8
            }
        }
        switch kind {
        case .strict:
            return findUnsafeStrictStringCharacterWithVectors(input, from: index, terminator: terminator)
        case .sloppy:
            return findUnsafeSloppyStringCharacterWithVectors(input, from: index, terminator: terminator)
        case .sloppyIdentifier:
            return findUnsafeSloppyIdentifierStringCharacterWithVectors(input, from: index, terminator: terminator)
        }
    }

    /// findUnsafeStringCharacterWithVectors for one kind, so that no step tests the kind.
    @inline(never)
    fileprivate static func findUnsafeStrictStringCharacterWithVectors(_ input: Span<UInt8>, from start: Int, terminator: UInt8) -> Int {
        findUnsafeStringCharacterWithVectors(input, from: start, .strict, terminator: terminator)
    }

    /// findUnsafeStringCharacterWithVectors for one kind, so that no step tests the kind.
    @inline(never)
    fileprivate static func findUnsafeSloppyStringCharacterWithVectors(_ input: Span<UInt8>, from start: Int, terminator: UInt8) -> Int {
        findUnsafeStringCharacterWithVectors(input, from: start, .sloppy, terminator: terminator)
    }

    /// findUnsafeStringCharacterWithVectors for one kind, so that no step tests the kind.
    @inline(never)
    fileprivate static func findUnsafeSloppyIdentifierStringCharacterWithVectors(
        _ input: Span<UInt8>,
        from start: Int,
        terminator: UInt8
    ) -> Int {
        findUnsafeStringCharacterWithVectors(input, from: start, .sloppyIdentifier, terminator: terminator)
    }

    /// findUnsafeStringCharacter past its word compares.
    @inline(always)
    fileprivate static func findUnsafeStringCharacterWithVectors(
        _ input: Span<UInt8>,
        from start: Int,
        _ kind: SafeStringCharacters,
        terminator: UInt8
    ) -> Int {
        let bytes = input.bytes
        let byteCount = bytes.byteCount
        let terminators = SIMD16<UInt8>(repeating: terminator)
        var index = start
        // A block of 32 bytes at a time: the loop's condition bounds each block's loads.
        var rest = bytes.extracting(droppingFirst: index)
        while rest.byteCount >= 32 {
            let first = unsafeLanes(rest.load(fromByteOffset: 0, as: SIMD16<UInt8>.self), kind, terminators)
            let second = unsafeLanes(rest.load(fromByteOffset: 16, as: SIMD16<UInt8>.self), kind, terminators)
            if hasSetHighBit(first | second) {
                return byteCount - rest.byteCount + firstSetLane(first, second)
            }
            rest = rest.extracting(droppingFirst: 32)
        }
        index = byteCount - rest.byteCount
        if byteCount >= 16 && index <= byteCount - 16 {
            let lanes = unsafeLanes(bytes.load(fromByteOffset: index, as: SIMD16<UInt8>.self), kind, terminators)
            if hasSetHighBit(lanes) {
                return index + firstSetLane(lanes)
            }
            index += 16
        }
        while isInBounds(index, input.count) && isSafeStringCharacter(input[index], kind, terminator) {
            index += 1
        }
        return index
    }
}

extension UInt16: JSONCharacter {
    fileprivate static func append(_ run: Span<UInt16>, to string: inout DecodedString) {
        string.append(run)
    }

    fileprivate static func append(_ characters: Span<UInt16>, to message: inout JSC.JSONParseErrorMessage) -> Bool {
        let none = InlineArray<1, UInt8>(repeating: 0)
        return message.append(none.span.extracting(first: 0), characters)
    }

    @inline(always)
    fileprivate static func findUnsafeStringCharacter(
        _ input: Span<UInt16>,
        from start: Int,
        _ kind: SafeStringCharacters,
        terminator: UInt16
    ) -> Int {
        let bytes = input.bytes
        let byteCount = bytes.byteCount
        // start <= input.count, so this is at most the byte count; the compiler does not see that.
        var offset = start &* 2
        // StrictJSON strings are mostly short: their first 16 characters, as at 8 bits, four at a time before the
        // vectors.
        if kind == .strict && byteCount >= 32 && offset >= 0 && offset <= byteCount - 32 {
            let head = bytes.extracting(offset..<(offset + 32))
            for word in 0..<4 {
                let units = unsafeStrictUnits(UInt64(littleEndian: head.load(fromByteOffset: word * 8, as: UInt64.self)))
                if units != 0 {
                    return (offset + word * 8) / 2 + units.trailingZeroBitCount / 16
                }
            }
            offset += 32
        }
        switch kind {
        case .strict:
            return findUnsafeStrictStringCharacterWithVectors(input, from: offset / 2, terminator: terminator)
        case .sloppy:
            return findUnsafeSloppyStringCharacterWithVectors(input, from: offset / 2, terminator: terminator)
        case .sloppyIdentifier:
            return findUnsafeSloppyIdentifierStringCharacterWithVectors(input, from: offset / 2, terminator: terminator)
        }
    }

    /// findUnsafeStringCharacterWithVectors for one kind, so that no step tests the kind.
    @inline(never)
    fileprivate static func findUnsafeStrictStringCharacterWithVectors(_ input: Span<UInt16>, from start: Int, terminator: UInt16) -> Int {
        findUnsafeStringCharacterWithVectors(input, from: start, .strict, terminator: terminator)
    }

    /// findUnsafeStringCharacterWithVectors for one kind, so that no step tests the kind.
    @inline(never)
    fileprivate static func findUnsafeSloppyStringCharacterWithVectors(_ input: Span<UInt16>, from start: Int, terminator: UInt16) -> Int {
        findUnsafeStringCharacterWithVectors(input, from: start, .sloppy, terminator: terminator)
    }

    /// findUnsafeStringCharacterWithVectors for one kind, so that no step tests the kind.
    @inline(never)
    fileprivate static func findUnsafeSloppyIdentifierStringCharacterWithVectors(
        _ input: Span<UInt16>,
        from start: Int,
        terminator: UInt16
    ) -> Int {
        findUnsafeStringCharacterWithVectors(input, from: start, .sloppyIdentifier, terminator: terminator)
    }

    /// findUnsafeStringCharacter past its word compares.
    @inline(always)
    fileprivate static func findUnsafeStringCharacterWithVectors(
        _ input: Span<UInt16>,
        from start: Int,
        _ kind: SafeStringCharacters,
        terminator: UInt16
    ) -> Int {
        let bytes = input.bytes
        let byteCount = bytes.byteCount
        let terminators = SIMD8<UInt16>(repeating: terminator)
        // start <= input.count, so this is at most the byte count; the compiler does not see that.
        var offset = start &* 2
        // The loop's condition bounds each block, so its loads need no check.
        while byteCount >= 32 && offset >= 0 && offset <= byteCount - 32 {
            let block = bytes.extracting(offset..<(offset + 32))
            let first = unsafeLanes(block.load(fromByteOffset: 0, as: SIMD8<UInt16>.self), kind, terminators)
            let second = unsafeLanes(block.load(fromByteOffset: 16, as: SIMD8<UInt16>.self), kind, terminators)
            if hasSetHighBit(first | second) {
                // The high byte of each lane, in lane order: one byte per character.
                let narrowed = SIMD16<UInt8>(
                    lowHalf: SIMD8<UInt8>(truncatingIfNeeded: first &>> 8),
                    highHalf: SIMD8<UInt8>(truncatingIfNeeded: second &>> 8)
                )
                return offset / 2 + firstSetLane(narrowed)
            }
            offset += 32
        }
        if byteCount >= 16 && offset <= byteCount - 16 {
            let lanes = unsafeLanes(bytes.load(fromByteOffset: offset, as: SIMD8<UInt16>.self), kind, terminators)
            if hasSetHighBit(lanes) {
                return offset / 2 + firstSetLane(lanes)
            }
            offset += 16
        }
        var index = offset / 2
        while isInBounds(index, input.count) && isSafeStringCharacter(input[index], kind, terminator) {
            index += 1
        }
        return index
    }
}

private struct JSONParser<Unit: JSONCharacter, Sink: JSONSink & ~Copyable>: ~Copyable where Sink.CodeUnit == Unit {
    let entry: UInt8
    let entryMode: JSONMode
    let isIterative: Bool
    let isRecordingRanges: Bool
    // JSONP: a call cannot be applied when the caller needs the program's source information.
    let needsFullSourceInfo: Bool

    // The lexer: the offset of the next character, and the current token.
    var position = 0
    var token = JSONToken.error
    var tokenStart = 0
    var tokenEnd = 0
    // A string or identifier token: its characters in the input, unless they are in `decoded`.
    var stringStart = 0
    var stringLength = 0
    var stringIsDecoded = false
    var decoded = DecodedString()
    var int32Token: Int32 = 0
    var numberToken = 0.0

    // The open containers outside a JSONContainers' innermost 64, released when the parse ends.
    var spilledContainers = UniqueArray<UInt64>()

    var lexError: JSONLexError?
    var parseError: JSONParseError?
    // The sink stopped the parse: an exception is pending, or it recorded the message.
    var stoppedBySink = false

    init(entry: UInt8, iterative: Bool, recordsRanges: Bool, needsFullSourceInfo: Bool) {
        self.entry = entry
        self.isIterative = iterative
        self.isRecordingRanges = recordsRanges
        self.needsFullSourceInfo = needsFullSourceInfo
        switch entry {
        case JSC.JSONParseEntry.Eval.rawValue:
            entryMode = .sloppy
        case JSC.JSONParseEntry.Program.rawValue:
            entryMode = .jsonp
        default:
            entryMode = .strict
        }
    }

    // A sink for one mode is given only that mode's entries, which are not iterative, so these are constants for it.
    @inline(always)
    var mode: JSONMode { Sink.fixedMode ?? entryMode }

    @inline(always)
    var iterative: Bool { Sink.fixedMode == nil && isIterative }

    @inline(always)
    var recordsRanges: Bool { Sink.fixedMode == nil && isRecordingRanges }

    // MARK: - The lexer

    /// Sets the current token to the single-character token at `start`.
    @inline(always)
    mutating func setPunctuator(_ type: JSONToken, at start: Int) -> JSONToken {
        tokenStart = start
        position = start + 1
        tokenEnd = start + 1
        token = type
        return type
    }

    /// The next token.
    ///
    /// A bracket, brace, comma or colon is taken without the lexer, after any whitespace.
    @inline(always)
    mutating func next(_ input: Span<Unit>, _ sink: inout Sink, maybeIdentifier: Bool = false) -> JSONToken {
        var start = position
        while isInBounds(start, input.count) {
            switch input[start] {
            case 0x2C:
                return setPunctuator(.comma, at: start)
            case 0x3A:
                return setPunctuator(.colon, at: start)
            case 0x5B:
                return setPunctuator(.leftBracket, at: start)
            case 0x5D:
                return setPunctuator(.rightBracket, at: start)
            case 0x7B:
                return setPunctuator(.leftBrace, at: start)
            case 0x7D:
                return setPunctuator(.rightBrace, at: start)
            case 0x20, 0x0A, 0x0D, 0x09:
                start += 1
                continue
            default:
                break
            }
            break
        }
        position = start
        token = lex(input, &sink, maybeIdentifier: maybeIdentifier)
        tokenEnd = position
        return token
    }

    /// LiteralParser's nextAfterValue: the token after a value, where ',', '}' and ']' are the common ones, after any
    /// whitespace.
    @inline(always)
    mutating func nextAfterValue(_ input: Span<Unit>, _ sink: inout Sink) -> JSONToken {
        var start = position
        while isInBounds(start, input.count) {
            switch input[start] {
            case 0x2C:
                return setPunctuator(.comma, at: start)
            case 0x5D:
                return setPunctuator(.rightBracket, at: start)
            case 0x7D:
                return setPunctuator(.rightBrace, at: start)
            case 0x20, 0x0A, 0x0D, 0x09:
                start += 1
                continue
            default:
                break
            }
            break
        }
        position = start
        token = lex(input, &sink, maybeIdentifier: false)
        tokenEnd = position
        return token
    }

    /// The token where a property name is expected: a string, or an identifier other than true, false and null, is
    /// lexed without the generic token dispatch.
    ///
    /// Returns whether `key` and `keyCharactersToEnd` were set to the name's characters and the count from its first
    /// character to the end of the input, which is so for a string with no escape and, outside StrictJSON, for an
    /// identifier.
    @inline(always)
    @_lifetime(key: copy key, copy input)
    mutating func nextPropertyName(
        _ input: Span<Unit>,
        _ sink: inout Sink,
        maybeIdentifier: Bool,
        _ key: inout Span<Unit>,
        _ keyCharactersToEnd: inout Int
    ) -> Bool {
        let count = input.count
        var start = position
        while isInBounds(start, count) && isJSONWhiteSpace(input[start]) {
            start += 1
        }
        position = start
        if isInBounds(start, count) {
            let character = input[start]
            let isString = character == quote || (character == apostrophe && mode != .strict)
            var isIdentifier = false
            if character <= 0x7A {
                switch UInt8(truncatingIfNeeded: character) {
                case 0x24, 0x41...0x5A, 0x5F, 0x61...0x65, 0x67...0x6D, 0x6F...0x73, 0x75...0x7A: // $ A-Z _ a-z but f n t
                    isIdentifier = true
                default:
                    break
                }
            }
            if isString {
                tokenStart = start
                let runStart = start + 1
                if let end = lexStringRun(input, runStart: runStart, terminator: character, maybeIdentifier: maybeIdentifier) {
                    token = .string
                    tokenEnd = position
                    key = input.extracting(first: end).extracting(droppingFirst: runStart)
                    keyCharactersToEnd = count - runStart
                    return true
                }
                token = lexStringSlow(input, &sink, runStart: runStart, terminator: character)
                tokenEnd = position
                return false
            }
            if isIdentifier {
                tokenStart = start
                token = lexIdentifier(input)
                tokenEnd = position
                if mode == .strict {
                    return false
                }
                key = input.extracting(first: position).extracting(droppingFirst: start)
                keyCharactersToEnd = count - start
                return true
            }
        }
        _ = next(input, &sink, maybeIdentifier: maybeIdentifier)
        return false
    }

    /// Takes true, false or null at the current position, whose first character is `character`, matched as lex()
    /// matches them, reports it and moves to the token after it.
    ///
    /// Returns nil, with nothing consumed, when no keyword is there.
    @inline(always)
    mutating func consumeKeywordValue(_ input: Span<Unit>, _ sink: inout Sink, _ character: Unit) -> Bool? {
        let count = input.count
        let start = position
        let succeeded: Bool
        switch character {
        case 0x74: // t
            guard count - start >= 4 else {
                return nil
            }
            let word = input.extracting(droppingFirst: start).extracting(0..<4)
            guard word[1] == 0x72 && word[2] == 0x75 && word[3] == 0x65 else {
                return nil
            }
            token = .trueLiteral
            // At least 4 characters remain, so this cannot overflow.
            position = start &+ 4
            succeeded = sink.literalValue(.True)
        case 0x66: // f
            guard count - start >= 5 else {
                return nil
            }
            let word = input.extracting(droppingFirst: start).extracting(0..<5)
            guard word[1] == 0x61 && word[2] == 0x6C && word[3] == 0x73 && word[4] == 0x65 else {
                return nil
            }
            token = .falseLiteral
            // At least 5 characters remain, so this cannot overflow.
            position = start &+ 5
            succeeded = sink.literalValue(.False)
        case 0x6E: // n
            guard count - start >= 4 else {
                return nil
            }
            let word = input.extracting(droppingFirst: start).extracting(0..<4)
            guard word[1] == 0x75 && word[2] == 0x6C && word[3] == 0x6C else {
                return nil
            }
            token = .nullLiteral
            // At least 4 characters remain, so this cannot overflow.
            position = start &+ 4
            succeeded = sink.literalValue(.Null)
        default:
            return nil
        }
        tokenStart = start
        tokenEnd = position
        if !succeeded {
            return stop()
        }
        _ = nextAfterValue(input, &sink)
        return true
    }

    @inline(never)
    mutating func lex(_ input: Span<Unit>, _ sink: inout Sink, maybeIdentifier: Bool) -> JSONToken {
        let count = input.count
        var start = position
        while isInBounds(start, count) && isJSONWhiteSpace(input[start]) {
            start += 1
        }
        position = start
        tokenStart = start
        if !isInBounds(start, count) {
            return .end
        }

        let character = input[start]
        if character <= 0xFF {
            switch UInt8(truncatingIfNeeded: character) {
            case 0x22, 0x27: // " '
                if character == apostrophe && mode == .strict {
                    lexError = .singleQuote
                    return .error
                }
                return lexString(input, &sink, terminator: character, maybeIdentifier: maybeIdentifier)
            case 0x74: // t
                if count - position >= 4 && input[position + 1] == 0x72 && input[position + 2] == 0x75 && input[position + 3] == 0x65 {
                    // At least 4 characters remain, so this cannot overflow.
                    position &+= 4
                    return .trueLiteral
                }
                return lexIdentifier(input)
            case 0x66: // f
                if count - position >= 5 && input[position + 1] == 0x61 && input[position + 2] == 0x6C && input[position + 3] == 0x73
                    && input[position + 4] == 0x65
                {
                    // At least 5 characters remain, so this cannot overflow.
                    position &+= 5
                    return .falseLiteral
                }
                return lexIdentifier(input)
            case 0x6E: // n
                if count - position >= 4 && input[position + 1] == 0x75 && input[position + 2] == 0x6C && input[position + 3] == 0x6C {
                    // At least 4 characters remain, so this cannot overflow.
                    position &+= 4
                    return .nullLiteral
                }
                return lexIdentifier(input)
            case 0x24, 0x41...0x5A, 0x5F, 0x61...0x7A: // $ A-Z _ a-z
                return lexIdentifier(input)
            case 0x2D, 0x30...0x39: // - 0-9
                return lexNumber(input, &sink)
            case 0x5B:
                position += 1
                return .leftBracket
            case 0x5D:
                position += 1
                return .rightBracket
            case 0x7B:
                position += 1
                return .leftBrace
            case 0x7D:
                position += 1
                return .rightBrace
            case 0x3A:
                position += 1
                return .colon
            case 0x28:
                position += 1
                return .leftParenthesis
            case 0x29:
                position += 1
                return .rightParenthesis
            case 0x2C:
                position += 1
                return .comma
            case 0x2E:
                position += 1
                return .dot
            case 0x3D:
                position += 1
                return .assign
            case 0x3B:
                position += 1
                return .semicolon
            default:
                break
            }
        }
        lexError = .unrecognizedToken(position)
        return .error
    }

    mutating func lexIdentifier(_ input: Span<Unit>) -> JSONToken {
        let start = position
        var end = start
        while isInBounds(end, input.count) && isValidIdentifierCharacter(input[end]) {
            end += 1
        }
        position = end
        stringStart = start
        // end is at least start, so this cannot overflow.
        stringLength = end &- start
        stringIsDecoded = false
        return .identifier
    }

    /// Each kind gets its own copy of the word compares, so that none of them tests the kind.
    @inline(always)
    func findUnsafeStringCharacter(_ input: Span<Unit>, from start: Int, _ kind: SafeStringCharacters, terminator: Unit) -> Int {
        switch kind {
        case .strict:
            Unit.findUnsafeStringCharacter(input, from: start, .strict, terminator: terminator)
        case .sloppy:
            Unit.findUnsafeStringCharacter(input, from: start, .sloppy, terminator: terminator)
        case .sloppyIdentifier:
            Unit.findUnsafeStringCharacter(input, from: start, .sloppyIdentifier, terminator: terminator)
        }
    }

    /// The string at the current position, which is at its opening quote.
    ///
    /// A string with no escape and no character the mode rejects is a run of the input, taken here; any other goes to
    /// lexStringSlow.
    @inline(always)
    mutating func lexString(_ input: Span<Unit>, _ sink: inout Sink, terminator: Unit, maybeIdentifier: Bool) -> JSONToken {
        // position is at the opening quote, below the count, so this cannot overflow.
        let runStart = position &+ 1
        if lexStringRun(input, runStart: runStart, terminator: terminator, maybeIdentifier: maybeIdentifier) != nil {
            return .string
        }
        return lexStringSlow(input, &sink, runStart: runStart, terminator: terminator)
    }

    /// The string whose characters start at `runStart`, when they are a run of the input up to its closing quote:
    /// returns the quote's index, with `position` after it.
    ///
    /// Otherwise returns nil, with `position` at the first character the run cannot take.
    @inline(always)
    mutating func lexStringRun(_ input: Span<Unit>, runStart: Int, terminator: Unit, maybeIdentifier: Bool) -> Int? {
        let kind: SafeStringCharacters = mode == .strict ? .strict : maybeIdentifier ? .sloppyIdentifier : .sloppy
        let end = findUnsafeStringCharacter(input, from: runStart, kind, terminator: terminator)

        if isInBounds(end, input.count) && input[end] == terminator {
            stringStart = runStart
            // end is at least runStart, so this cannot overflow.
            stringLength = end &- runStart
            stringIsDecoded = false
            position = end + 1
            return end
        }
        position = end
        return nil
    }

    @inline(never)
    mutating func lexStringSlow(_ input: Span<Unit>, _ sink: inout Sink, runStart initialRunStart: Int, terminator: Unit) -> JSONToken {
        let count = input.count
        var runStart = initialRunStart
        var decodedIsEmpty = true
        var isFirstRun = true
        repeat {
            if !isFirstRun {
                runStart = position
                position = findUnsafeStringCharacter(input, from: position, mode == .strict ? .strict : .sloppy, terminator: terminator)
                if !decodedIsEmpty && runStart < position {
                    Unit.append(input.extracting(runStart..<position), to: &decoded)
                }
            }
            isFirstRun = false

            if mode != .sloppy && isInBounds(position, count) && input[position] == backslash {
                if decodedIsEmpty {
                    decoded.removeAll()
                    if runStart < position {
                        Unit.append(input.extracting(runStart..<position), to: &decoded)
                    }
                    decodedIsEmpty = false
                }
                position += 1
                if !isInBounds(position, count) {
                    lexError = .unterminatedString
                    return .error
                }
                switch input[position] {
                case 0x22:
                    decoded.append(0x22)
                    position += 1
                case 0x5C:
                    decoded.append(0x5C)
                    position += 1
                case 0x2F:
                    decoded.append(0x2F)
                    position += 1
                case 0x62: // b
                    decoded.append(0x08)
                    position += 1
                case 0x66: // f
                    decoded.append(0x0C)
                    position += 1
                case 0x6E: // n
                    decoded.append(0x0A)
                    position += 1
                case 0x72: // r
                    decoded.append(0x0D)
                    position += 1
                case 0x74: // t
                    decoded.append(0x09)
                    position += 1
                case 0x75: // u, then 4 hex digits
                    if count - position < 5 {
                        lexError = .shortUnicodeEscape
                        return .error
                    }
                    var unit: UInt16 = 0
                    for i in 1..<5 {
                        guard let digit = asciiHexValue(input[position + i]) else {
                            lexError = .invalidUnicodeEscape(position)
                            return .error
                        }
                        unit = unit << 4 | digit
                    }
                    decoded.append(unit)
                    position += 5
                default:
                    if input[position] == apostrophe && mode != .strict {
                        decoded.append(0x27)
                        position += 1
                        break
                    }
                    lexError = .invalidEscape(position)
                    return .error
                }
            }
        } while mode != .sloppy && position != runStart && isInBounds(position, count) && input[position] != terminator

        if !isInBounds(position, count) || input[position] != terminator {
            lexError = .unterminatedString
            return .error
        }

        if decodedIsEmpty {
            stringStart = runStart
            stringLength = position - runStart
            stringIsDecoded = false
        } else {
            stringIsDecoded = true
        }
        position += 1
        return .string
    }

    @inline(always)
    mutating func lexNumber(_ input: Span<Unit>, _ sink: inout Sink) -> JSONToken {
        let initial = position
        if let token = lexShortNumber(input) {
            return token
        }
        return lexNumberSlow(input, &sink, from: initial)
    }

    /// The token of a number of at most 9 digits with no fraction or exponent, or of input that cannot start one;
    /// nil for any other number, with `position` after its integer digits.
    @inline(always)
    mutating func lexShortNumber(_ input: Span<Unit>) -> JSONToken? {
        let count = input.count
        var index = position
        guard isInBounds(index, count) else {
            lexError = .invalidNumber
            return .error
        }
        var character = input[index]
        let negative = character == 0x2D
        if negative {
            index += 1
            guard isInBounds(index, count) else {
                position = index
                lexError = .invalidNumber
                return .error
            }
            character = input[index]
        }
        let start = index

        var accumulated: UInt32 = 0
        if isASCIIDigit(character) {
            index += 1
            accumulated = UInt32(truncatingIfNeeded: character) - 0x30
            if character != 0x30 {
                while isInBounds(index, count) && isASCIIDigit(input[index]) {
                    // Wraps past 9 digits, as LiteralParser.cpp's lexer does; such a value is not used.
                    accumulated = accumulated &* 10 &+ (UInt32(truncatingIfNeeded: input[index]) &- 0x30)
                    index += 1
                }
            }
        } else {
            position = index
            lexError = .invalidNumber
            return .error
        }
        position = index

        // The numbers from -999999999 to 999999999 are always in range of Int32.
        let numberOfDigitsForSafeInt32 = 9
        if isInBounds(index, count), input[index] != 0x2E && input[index] != 0x65 && input[index] != 0x45,
            index - start <= numberOfDigitsForSafeInt32
        {
            let result = Int32(truncatingIfNeeded: accumulated)
            if !negative {
                int32Token = result
                return .numberInt32
            }
            if result == 0 {
                numberToken = -0.0
                return .number
            }
            // At most 9 digits, so this cannot overflow.
            int32Token = 0 &- result
            return .numberInt32
        }
        return nil
    }

    /// A number that is not a short integer: fractions, exponents, more than 9 digits, and errors.
    @inline(never)
    mutating func lexNumberSlow(_ input: Span<Unit>, _ sink: inout Sink, from initial: Int) -> JSONToken {
        var length = 0
        let value = sink.parseNumber(input.extracting(droppingFirst: initial), &length)
        if length != 0 {
            // length is at most the count of characters after initial, so this cannot overflow.
            position = initial &+ length
            numberToken = value
            return .number
        }
        return lexNumberError(input)
    }

    @inline(never)
    mutating func lexNumberError(_ input: Span<Unit>) -> JSONToken {
        let count = input.count
        // ('.' [0-9]+)?
        if isInBounds(position, count) && input[position] == 0x2E {
            position += 1
            if !isInBounds(position, count) || !isASCIIDigit(input[position]) {
                lexError = .invalidDecimalDigits
                return .error
            }
            position += 1
            while isInBounds(position, count) && isASCIIDigit(input[position]) {
                position += 1
            }
        }

        // ([eE][+-]? [0-9]+)?
        if isInBounds(position, count) && (input[position] == 0x65 || input[position] == 0x45) {
            position += 1
            if isInBounds(position, count) && (input[position] == 0x2D || input[position] == 0x2B) {
                position += 1
            }
            if !isInBounds(position, count) || !isASCIIDigit(input[position]) {
                lexError = .invalidExponent
                return .error
            }
            position += 1
            while isInBounds(position, count) && isASCIIDigit(input[position]) {
                position += 1
            }
        }

        lexError = .invalidNumber
        return .error
    }

    @inline(always)
    mutating func consumeColon(_ input: Span<Unit>, _ sink: inout Sink) -> Bool {
        while isInBounds(position, input.count) {
            let character = input[position]
            if character == 0x3A {
                position += 1
                return true
            }
            if !isJSONWhiteSpace(character) {
                break
            }
            position += 1
        }
        return next(input, &sink) == .colon
    }

    /// The next key, when JSONCache predicts it: StrictJSON only.
    @inline(always)
    mutating func consumeCachedKey(_ input: Span<Unit>, _ sink: inout Sink, consumedColon: inout Bool) -> Bool {
        if isInBounds(position, input.count) && input[position] != quote {
            while isInBounds(position, input.count) && isJSONWhiteSpace(input[position]) {
                position += 1
            }
        }
        // JSONCache matches only Latin1 names.
        // position is at most the count, so this cannot overflow.
        let afterQuote = position &+ 1
        if Unit.bitWidth == 16 && isInBounds(afterQuote, input.count) && input[position] == quote && input[afterQuote] > 0xFF {
            return false
        }
        let length = sink.consumeCachedKey(input.extracting(droppingFirst: position))
        if length == 0 {
            return false
        }
        // length is at most the count of characters after position, so this cannot overflow.
        position &+= length
        consumedColon = true
        return true
    }

    /// Whether the container opened by the current token is empty: if so, its closer is the current token.
    ///
    /// Otherwise the whitespace after the opener is skipped.
    @inline(always)
    mutating func consumeEmptyContainerEnd(_ input: Span<Unit>, closer: Unit) -> Bool {
        var end = position
        while isInBounds(end, input.count) {
            let character = input[end]
            if character == closer {
                _ = setPunctuator(closer == 0x5D ? .rightBracket : .rightBrace, at: end)
                return true
            }
            if !isJSONWhiteSpace(character) {
                break
            }
            end += 1
        }
        position = end
        return false
    }

    // MARK: - Values

    mutating func fail(_ message: JSONParseMessage) -> Bool {
        parseError = .message(message)
        return false
    }

    mutating func stop() -> Bool {
        stoppedBySink = true
        return false
    }

    var isPropertyKey: Bool {
        token == .string || (mode != .strict && token == .identifier)
    }

    /// Reports the current property name: `key` and `keyCharactersToEnd` when `sliced`, as nextPropertyName set them.
    mutating func reportKey(_ input: Span<Unit>, _ sink: inout Sink, _ key: Span<Unit>, _ keyCharactersToEnd: Int, sliced: Bool) {
        var key = key
        var keyCharactersToEnd = keyCharactersToEnd
        if !sliced {
            if token == .string && stringIsDecoded {
                sink.decodedKey(decoded.characters8.span, decoded.characters16.span)
                return
            }
            // stringStart + stringLength is the string's end, at most the count, so this cannot overflow.
            key = input.extracting(stringStart..<stringStart &+ stringLength)
            keyCharactersToEnd = input.count - stringStart
        }
        sink.key(key, keyCharactersToEnd)
    }

    @inline(always)
    mutating func reportString(_ sink: inout Sink, cache: Bool) -> Bool {
        if stringIsDecoded {
            return sink.decodedStringValue(decoded.characters8.span, decoded.characters16.span)
        }
        return sink.stringValue(stringStart, stringLength, cache)
    }

    /// A number where the innermost container expects a value.
    @inline(always)
    mutating func parseNumberValue(_ input: Span<Unit>, _ sink: inout Sink) -> Bool {
        let initial = position
        tokenStart = initial
        if let short = lexShortNumber(input) {
            token = short
            tokenEnd = position
            if short == .numberInt32 {
                guard sink.int32Value(int32Token) else {
                    return stop()
                }
                _ = nextAfterValue(input, &sink)
                return true
            }
            return parsePrimitiveValue(input, &sink)
        }
        var length = 0
        let value = sink.parseNumber(input.extracting(droppingFirst: initial), &length)
        if length == 0 {
            token = lexNumberError(input)
            tokenEnd = position
            return parsePrimitiveValue(input, &sink)
        }
        // length is at most the count of characters after initial, so this cannot overflow.
        position = initial &+ length
        token = .number
        tokenEnd = position
        guard sink.numberValue(value) else {
            return stop()
        }
        _ = nextAfterValue(input, &sink)
        return true
    }

    /// LiteralParser::parsePrimitiveValue.
    @inline(always)
    mutating func parsePrimitiveValue(_ input: Span<Unit>, _ sink: inout Sink) -> Bool {
        let succeeded: Bool
        switch token {
        case .string:
            succeeded = reportString(&sink, cache: false)
        case .numberInt32:
            succeeded = sink.int32Value(int32Token)
        case .number:
            succeeded = sink.numberValue(numberToken)
        case .nullLiteral:
            succeeded = sink.literalValue(.Null)
        case .trueLiteral:
            succeeded = sink.literalValue(.True)
        case .falseLiteral:
            succeeded = sink.literalValue(.False)
        case .rightBracket:
            return fail(.unexpectedRightBracket)
        case .rightBrace:
            return fail(.unexpectedRightBrace)
        case .identifier:
            parseError = .unexpectedIdentifier(start: stringStart, length: stringLength)
            return false
        case .colon:
            return fail(.unexpectedColon)
        case .leftParenthesis:
            return fail(.unexpectedLeftParenthesis)
        case .rightParenthesis:
            return fail(.unexpectedRightParenthesis)
        case .comma:
            return fail(.unexpectedComma)
        case .dot:
            return fail(.unexpectedDot)
        case .assign:
            return fail(.unexpectedAssign)
        case .semicolon:
            return fail(.unexpectedSemicolon)
        case .end:
            return fail(.unexpectedEOF)
        case .leftBracket, .leftBrace, .error:
            return fail(.couldNotParseValue)
        }
        if !succeeded {
            return stop()
        }
        _ = nextAfterValue(input, &sink)
        return true
    }

    // MARK: - The grammar

    /// LiteralParser.cpp's parseRecursively, and its parse() from StartParseExpression: the value at the current token,
    /// in every mode.
    ///
    /// Nesting does not recurse: the open containers are a JSONContainers. An iterative parse, like LiteralParser.cpp's
    /// parse(), uses no cached key, transition or string from JSONCache. A parse that records source ranges takes each
    /// primitive value through the `.value` step, which records its range.
    mutating func parseRecursively(_ input: Span<Unit>, _ sink: inout Sink) -> Bool {
        var containers = JSONContainers()
        let isStrict = mode == .strict && !iterative
        var consumedColon = false
        var key = input.extracting(first: 0)
        var keyCharactersToEnd = 0
        var step = JSONStep.value
        while true {
            switch step {
            case .value:
                switch token {
                case .leftBracket:
                    let start = tokenStart
                    if consumeEmptyContainerEnd(input, closer: 0x5D) {
                        guard sink.beginArray(start) && sink.endArray(tokenEnd) else {
                            return stop()
                        }
                        _ = nextAfterValue(input, &sink)
                        step = .afterValue
                        continue
                    }
                    guard sink.beginArray(tokenStart) else {
                        return stop()
                    }
                    containers.push(isObject: false, &spilledContainers)
                    step = .arrayStart(afterComma: false)
                case .leftBrace:
                    let start = tokenStart
                    if consumeEmptyContainerEnd(input, closer: 0x7D) {
                        guard sink.beginObject(start) && sink.endObject(tokenEnd) else {
                            return stop()
                        }
                        _ = nextAfterValue(input, &sink)
                        step = .afterValue
                        continue
                    }
                    guard sink.beginObject(tokenStart) else {
                        return stop()
                    }
                    let consumed = isStrict && consumeCachedKey(input, &sink, consumedColon: &consumedColon)
                    var sliced = false
                    if !consumed {
                        if isStrict {
                            _ = next(input, &sink, maybeIdentifier: Unit.bitWidth == 16 && !iterative)
                        } else {
                            sliced = nextPropertyName(
                                input,
                                &sink,
                                maybeIdentifier: Unit.bitWidth == 16 && !iterative,
                                &key,
                                &keyCharactersToEnd
                            )
                        }
                    }
                    if consumed || isPropertyKey {
                        containers.push(isObject: true, &spilledContainers)
                        step = .key(consumed: consumed, sliced: sliced)
                    } else if token != .rightBrace {
                        return fail(.expectedRightBrace)
                    } else {
                        guard sink.endObject(tokenEnd) else {
                            return stop()
                        }
                        _ = nextAfterValue(input, &sink)
                        step = .afterValue
                    }
                default:
                    if recordsRanges {
                        sink.setValueRange(tokenStart, tokenEnd)
                    }
                    guard parsePrimitiveValue(input, &sink) else {
                        return false
                    }
                    step = .afterValue
                }

            case .arrayStart(let afterComma):
                // Dispatching on the first character skips the generic token dispatch.
                let character: Unit = !recordsRanges && isInBounds(position, input.count) ? input[position] : 0
                if character == quote {
                    tokenStart = position
                    token = lexString(input, &sink, terminator: Unit(truncatingIfNeeded: quote), maybeIdentifier: false)
                    tokenEnd = position
                    guard parsePrimitiveValue(input, &sink) else {
                        return false
                    }
                    step = .afterValue
                } else if character == 0x2D || isASCIIDigit(character) {
                    guard parseNumberValue(input, &sink) else {
                        return false
                    }
                    step = .afterValue
                } else if next(input, &sink) == .rightBracket {
                    if afterComma {
                        return fail(.trailingComma)
                    }
                    guard sink.endArray(tokenEnd) else {
                        return stop()
                    }
                    containers.pop(&spilledContainers)
                    _ = nextAfterValue(input, &sink)
                    step = .afterValue
                } else {
                    step = .value
                }

            case .key(let consumed, let sliced):
                if !consumed {
                    reportKey(input, &sink, key, keyCharactersToEnd, sliced: sliced)
                }
                if !consumedColon && !consumeColon(input, &sink) {
                    return fail(.expectedColon)
                }
                consumedColon = false
                if recordsRanges {
                    _ = next(input, &sink)
                    step = .value
                    continue
                }

                // Dispatching on the first character skips the generic token dispatch. A string after whitespace is
                // neither looked up in JSONCache nor recorded there.
                var character: Unit = 0
                var cachesString = isStrict && Unit.bitWidth == 8
                while isInBounds(position, input.count) {
                    character = input[position]
                    if !isJSONWhiteSpace(character) {
                        break
                    }
                    character = 0
                    cachesString = false
                    position += 1
                }
                step = .afterValue
                if character == quote {
                    if cachesString {
                        var length = 0
                        let succeeded = sink.cachedStringValue(input.extracting(droppingFirst: position), &length)
                        if length != 0 {
                            guard succeeded else {
                                return stop()
                            }
                            // length is at most the count of characters after position, so this cannot overflow.
                            position &+= length
                            _ = nextAfterValue(input, &sink)
                            continue
                        }
                    }
                    tokenStart = position
                    token = lexString(input, &sink, terminator: Unit(truncatingIfNeeded: quote), maybeIdentifier: false)
                    tokenEnd = position
                    if token == .string {
                        guard reportString(&sink, cache: cachesString && !stringIsDecoded) else {
                            return stop()
                        }
                        _ = nextAfterValue(input, &sink)
                    } else {
                        guard parsePrimitiveValue(input, &sink) else {
                            return false
                        }
                    }
                } else if character == 0x2D || isASCIIDigit(character) {
                    guard parseNumberValue(input, &sink) else {
                        return false
                    }
                } else if let succeeded = consumeKeywordValue(input, &sink, character) {
                    guard succeeded else {
                        return false
                    }
                } else {
                    _ = next(input, &sink)
                    step = .value
                }

            case .afterValue:
                if containers.isEmpty {
                    return true
                }
                if !containers.innermostIsObject {
                    if token == .comma {
                        step = .arrayStart(afterComma: true)
                        continue
                    }
                    if token != .rightBracket {
                        return fail(.expectedRightBracket)
                    }
                    guard sink.endArray(tokenEnd) else {
                        return stop()
                    }
                } else {
                    if token == .comma {
                        if isStrict && consumeCachedKey(input, &sink, consumedColon: &consumedColon) {
                            step = .key(consumed: true, sliced: false)
                            continue
                        }
                        var sliced = false
                        if isStrict {
                            _ = next(input, &sink)
                        } else {
                            sliced = nextPropertyName(input, &sink, maybeIdentifier: false, &key, &keyCharactersToEnd)
                        }
                        if !isPropertyKey {
                            return fail(.propertyNameNotString)
                        }
                        step = .key(consumed: false, sliced: sliced)
                        continue
                    }
                    if token != .rightBrace {
                        return fail(.expectedRightBrace)
                    }
                    guard sink.endObject(tokenEnd) else {
                        return stop()
                    }
                }
                containers.pop(&spilledContainers)
                _ = nextAfterValue(input, &sink)
            }
        }
    }

    /// LiteralParser::evalRecursivelyEntry.
    mutating func evalRecursively(_ input: Span<Unit>, _ sink: inout Sink) -> Bool {
        if token == .leftParenthesis {
            _ = next(input, &sink)
            let succeeded = parseRecursively(input, &sink)
            if stoppedBySink {
                return false
            }
            if token != .rightParenthesis {
                return fail(.unexpectedContent)
            }
            _ = next(input, &sink)
            return succeeded
        }
        if token == .leftBrace {
            return fail(.unexpectedLeftBrace)
        }
        return parseRecursively(input, &sink)
    }

    /// LiteralParser.cpp's parse() from StartParseStatement.
    mutating func parseStatement(_ input: Span<Unit>, _ sink: inout Sink) -> Bool {
        switch token {
        case .leftBracket, .number, .numberInt32, .string:
            return parsePrimitiveValue(input, &sink)
        case .leftParenthesis:
            _ = next(input, &sink)
            guard parseRecursively(input, &sink) else {
                return false
            }
            if token != .rightParenthesis {
                return false
            }
            if next(input, &sink) == .end {
                return true
            }
            return fail(.unexpectedContent)
        case .rightBracket:
            return fail(.unexpectedRightBracket)
        case .leftBrace:
            return fail(.unexpectedLeftBrace)
        case .rightBrace:
            return fail(.unexpectedRightBrace)
        case .identifier:
            return fail(.unexpectedIdentifier)
        case .colon:
            return fail(.unexpectedColon)
        case .rightParenthesis:
            return fail(.unexpectedRightParenthesis)
        case .comma:
            return fail(.unexpectedComma)
        case .trueLiteral:
            return fail(.unexpectedTrue)
        case .falseLiteral:
            return fail(.unexpectedFalse)
        case .nullLiteral:
            return fail(.unexpectedNull)
        case .end:
            return fail(.unexpectedEOF)
        case .dot:
            return fail(.unexpectedDot)
        case .assign:
            return fail(.unexpectedAssign)
        case .semicolon:
            return fail(.unexpectedSemicolon)
        case .error:
            return fail(.couldNotParseStatement)
        }
    }

    /// LiteralParser::tryJSONPParse.
    mutating func parseJSONP(_ input: Span<Unit>, _ sink: inout Sink) -> Bool {
        if next(input, &sink) != .identifier {
            return false
        }
        repeat {
            let isVar = stringLength == 3 && input[stringStart] == 0x76 && input[stringStart + 1] == 0x61 && input[stringStart + 2] == 0x72
            if isVar && next(input, &sink) != .identifier {
                return false
            }
            var lastEntryType = isVar ? JSONPPathEntryType.declareVar : .dot
            guard sink.appendJSONPPathEntry(lastEntryType.rawValue, stringStart, stringLength, 0) else {
                return false
            }
            var isCall = false
            var tokenType = next(input, &sink)
            if isVar && tokenType != .assign {
                return false
            }
            pathLoop: while tokenType != .assign {
                switch tokenType {
                case .leftBracket:
                    let numberType = next(input, &sink)
                    let index: Int32
                    if numberType == .numberInt32 {
                        index = int32Token
                    } else if numberType == .number {
                        // An index must be the number truncateDoubleToInt32 makes of it.
                        guard numberToken >= -2147483648.0 && numberToken <= 2147483647.0 && numberToken == numberToken.rounded(.towardZero)
                        else {
                            return false
                        }
                        index = Int32(numberToken)
                    } else {
                        return false
                    }
                    if index < 0 {
                        return false
                    }
                    lastEntryType = .lookup
                    _ = sink.appendJSONPPathEntry(lastEntryType.rawValue, 0, 0, index)
                    if next(input, &sink) != .rightBracket {
                        return false
                    }
                case .dot:
                    if next(input, &sink) != .identifier {
                        return false
                    }
                    lastEntryType = .dot
                    _ = sink.appendJSONPPathEntry(lastEntryType.rawValue, stringStart, stringLength, 0)
                case .leftParenthesis:
                    guard lastEntryType == .dot && !needsFullSourceInfo else {
                        return false
                    }
                    _ = sink.appendJSONPPathEntry(JSONPPathEntryType.call.rawValue, 0, 0, 0)
                    isCall = true
                    break pathLoop
                default:
                    return false
                }
                tokenType = next(input, &sink)
            }

            _ = next(input, &sink)
            sink.beginJSONPValue()
            guard parseRecursively(input, &sink) else {
                return false
            }
            sink.endJSONPValue()
            if isCall {
                if token != .rightParenthesis {
                    return false
                }
                _ = next(input, &sink)
            }
            if token != .semicolon {
                break
            }
            _ = next(input, &sink)
        } while token == .identifier
        return token == .end
    }

    mutating func parseEntry(_ input: Span<Unit>, _ sink: inout Sink) -> Bool {
        // A sink for one mode is given only that mode's entries, so the others are not compiled for it.
        switch entry {
        case JSC.JSONParseEntry.PrimitiveValue.rawValue where Sink.fixedMode != .sloppy:
            _ = next(input, &sink)
            guard parsePrimitiveValue(input, &sink) else {
                return false
            }
            if token != .end {
                return fail(.unexpectedContent)
            }
            return true
        case JSC.JSONParseEntry.Eval.rawValue where Sink.fixedMode != .strict:
            _ = next(input, &sink)
            guard iterative ? parseStatement(input, &sink) : evalRecursively(input, &sink) else {
                return false
            }
            if token == .semicolon {
                _ = next(input, &sink)
            }
            return token == .end
        case JSC.JSONParseEntry.Program.rawValue where Sink.fixedMode == nil:
            return parseJSONP(input, &sink)
        default:
            _ = next(input, &sink)
            if !iterative && (token == .leftBracket || token == .leftBrace) {
                sink.beginCacheScope()
            }
            guard parseRecursively(input, &sink) else {
                return false
            }
            return token == .end
        }
    }

    mutating func parse(_ input: Span<Unit>, _ sink: inout Sink) -> Bool {
        if parseEntry(input, &sink) {
            return true
        }
        if !stoppedBySink {
            sink.fail(parseFailure(lexError, parseError))
        }
        return false
    }
}

// MARK: - Error messages

/// Why a parse failed, as JSONParseFailure's kind.
///
/// A JSONParseMessage is `message` plus its raw value.
private enum JSONParseErrorKind: UInt8 {
    case none
    case singleQuote
    case unrecognizedToken
    case unterminatedString
    case shortUnicodeEscape
    case invalidUnicodeEscape
    case invalidEscape
    case invalidNumber
    case invalidDecimalDigits
    case invalidExponent
    case unexpectedIdentifier
    case message
}

/// LiteralParser::getErrorMessage's choice: a lexer error, else a parser error, else none, with the characters its
/// message quotes.
private func parseFailure(_ lexError: JSONLexError?, _ parseError: JSONParseError?) -> JSC.JSONParseFailure {
    func failure(_ kind: JSONParseErrorKind, _ offset: Int = 0, _ length: Int = 0) -> JSC.JSONParseFailure {
        JSC.JSONParseFailure(kind: kind.rawValue, offset: offset, length: length)
    }
    if let lexError {
        switch lexError {
        case .singleQuote:
            return failure(.singleQuote)
        case .unrecognizedToken(let offset):
            return failure(.unrecognizedToken, offset, 1)
        case .unterminatedString:
            return failure(.unterminatedString)
        case .shortUnicodeEscape:
            return failure(.shortUnicodeEscape)
        case .invalidUnicodeEscape(let offset):
            return failure(.invalidUnicodeEscape, offset, 5)
        case .invalidEscape(let offset):
            return failure(.invalidEscape, offset, 1)
        case .invalidNumber:
            return failure(.invalidNumber)
        case .invalidDecimalDigits:
            return failure(.invalidDecimalDigits)
        case .invalidExponent:
            return failure(.invalidExponent)
        }
    }
    switch parseError {
    case .message(let message):
        return JSC.JSONParseFailure(kind: JSONParseErrorKind.message.rawValue + message.rawValue, offset: 0, length: 0)
    case .unexpectedIdentifier(let start, let length):
        return failure(.unexpectedIdentifier, start, length)
    case nil:
        return failure(.none)
    }
}

/// Builds LiteralParser::getErrorMessage()'s text for `failure`, which a parse of `input` recorded. `input` is the
/// characters that parse read, which the C++ caller still owns and has not changed; nothing writes them while this
/// runs, JSONParseErrorMessage's functions included, and every bit pattern of `Latin1Character` is a valid value.
///
/// `message` is the JSONParseErrorMessageBuilder on getErrorMessage()'s stack; append() and clear() reach only its
/// StringBuilder.
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jsonParseErrorMessage8(_ input: JSC.JSONParseInput8, _ failure: JSC.JSONParseFailure, _ message: inout JSC.JSONParseErrorMessage) {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    appendErrorMessage(failure, characters, &message)
}

/// Builds the message for a parse of UTF-16 code units, under the same conditions as `jsonParseErrorMessage8`.
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jsonParseErrorMessage16(_ input: JSC.JSONParseInput16, _ failure: JSC.JSONParseFailure, _ message: inout JSC.JSONParseErrorMessage) {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: input)
    appendErrorMessage(failure, characters, &message)
}

/// Appends ASCII text to the message, and returns false if it could not be allocated.
@discardableResult
private func appendText(_ text: String, _ message: inout JSC.JSONParseErrorMessage) -> Bool {
    UInt8.append(text.utf8.span, to: &message)
}

/// LiteralParser's message for the identifier `identifier`: its first `shownLength` characters, then "..." if that is
/// fewer.
///
/// Returns false if it could not be allocated.
private func appendUnexpectedIdentifier<Unit: JSONCharacter>(
    _ identifier: Span<Unit>,
    shownLength: Int,
    _ message: inout JSC.JSONParseErrorMessage
) -> Bool {
    appendText("JSON Parse error: Unexpected identifier \"", &message)
    Unit.append(identifier.extracting(first: shownLength), to: &message)
    return appendText(shownLength < identifier.count ? "...\"" : "\"", &message)
}

private func appendErrorMessage<Unit: JSONCharacter>(
    _ failure: JSC.JSONParseFailure,
    _ input: Span<Unit>,
    _ message: inout JSC.JSONParseErrorMessage
) {
    // The parse that recorded `failure` checked that these characters are in the input.
    let quoted = input.extracting(failure.offset..<failure.offset + failure.length)
    if failure.kind >= JSONParseErrorKind.message.rawValue,
        let parseMessage = JSONParseMessage(rawValue: failure.kind - JSONParseErrorKind.message.rawValue)
    {
        appendText("JSON Parse error: ", &message)
        appendText(parseMessage.text, &message)
        return
    }
    if JSONParseErrorKind(rawValue: failure.kind) == .unexpectedIdentifier {
        // A message that cannot be allocated is made again with 10 characters of the identifier, then with none.
        if !appendUnexpectedIdentifier(quoted, shownLength: min(quoted.count, 200), &message) {
            message.clear()
            if quoted.count <= 10 || !appendUnexpectedIdentifier(quoted, shownLength: 10, &message) {
                message.clear()
                appendText("JSON Parse error: Unexpected identifier", &message)
            }
        }
        return
    }
    appendText("JSON Parse error: ", &message)
    switch JSONParseErrorKind(rawValue: failure.kind) ?? .none {
    case .none, .unexpectedIdentifier, .message:
        appendText("Unable to parse JSON string", &message)
    case .singleQuote:
        appendText("Single quotes (') are not allowed in JSON", &message)
    case .unrecognizedToken:
        appendText("Unrecognized token '", &message)
        Unit.append(quoted, to: &message)
        appendText("'", &message)
    case .unterminatedString:
        appendText("Unterminated string", &message)
    case .shortUnicodeEscape:
        appendText("\\u must be followed by 4 hex digits", &message)
    case .invalidUnicodeEscape:
        appendText("\"\\", &message)
        Unit.append(quoted, to: &message)
        appendText("\" is not a valid unicode escape", &message)
    case .invalidEscape:
        appendText("Invalid escape character ", &message)
        Unit.append(quoted, to: &message)
    case .invalidNumber:
        appendText("Invalid number", &message)
    case .invalidDecimalDigits:
        appendText("Invalid digits after decimal point", &message)
    case .invalidExponent:
        appendText("Exponent symbols should be followed by an optional '+' or '-' and then by at least one number", &message)
    }
}

#endif // USE_SWIFT_JSON_PARSER
