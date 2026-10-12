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

#if USE_SWIFT_HTML_FAST_PATH

public import WebCore_Private.HTMLFastPathParserTypes

/// Scans an 8-bit fragment parsed in `context`, writing its ops (HTMLFastPathParserTypes.h) into `ops` and the
/// characters of its escaped text and attribute values into `decoded`, as far as each has room.
///
/// Returns the decoded character count shifted left by 32, or'ed with the op word count, or UInt64.max if the fast
/// path fails. A count larger than its buffer means the buffer was too small. The C++ caller owns the buffers for the
/// call, and they do not overlap.
///
/// FIXME: Take Span and MutableSpan parameters once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
public func scanHTMLFragmentForFastPath(
    _ source: WebCore.HTMLFastPathLatin1Span,
    _ context: WebCore.HTMLFastPathTag,
    _ ops: WebCore.HTMLFastPathOpSpan,
    _ decoded: WebCore.HTMLFastPathDecodedSpan
) -> UInt64 {
    let input = unsafe Span<UInt8>(_unsafeCxxSpan: source)
    let opWords = unsafe MutableSpan<UInt32>(_unsafeCxxSpan: ops)
    let decodedCharacters = unsafe MutableSpan<UInt16>(_unsafeCxxSpan: decoded)
    return scanFragment(input, context, opWords, decodedCharacters)
}

/// The 16-bit form of scanHTMLFragmentForFastPath(_:_:_:_:).
///
/// FIXME: Take Span and MutableSpan parameters once a std::span can cross safely (rdar://186723514).
@_expose(Cxx, "scanHTMLFragmentForFastPath")
public func scanHTMLFragmentForFastPath16(
    _ source: WebCore.HTMLFastPathUTF16Span,
    _ context: WebCore.HTMLFastPathTag,
    _ ops: WebCore.HTMLFastPathOpSpan,
    _ decoded: WebCore.HTMLFastPathDecodedSpan
) -> UInt64 {
    let input = unsafe Span<UInt16>(_unsafeCxxSpan: source)
    let opWords = unsafe MutableSpan<UInt32>(_unsafeCxxSpan: ops)
    let decodedCharacters = unsafe MutableSpan<UInt16>(_unsafeCxxSpan: decoded)
    return scanFragment(input, context, opWords, decodedCharacters)
}

/// A code unit of the fast path's input: a Latin-1 character or a UTF-16 code unit.
private protocol HTMLFastPathCodeUnit: FixedWidthInteger, UnsignedInteger {
    /// Consumes the character reference that starts `input`, just after its '&', as consumeHTMLEntity reads it, and
    /// writes the 0 to 3 characters it decodes to at the start of `decoded`, which has room for 3. Returns how many
    /// characters it read, shifted left by 2, or'ed with how many it wrote. `input` is not empty.
    static func consumeCharacterReference(
        _ input: Span<Self>,
        _ additionalAllowedCharacter: UInt16,
        _ decoded: inout MutableSpan<UInt16>
    ) -> UInt64

    /// Four bits per code unit `offset` to `offset + 15` of `input`, the first in the least significant: 0xF where
    /// the code unit is below 0x100 and equals the lane of `table` its low four bits select, and 0 elsewhere.
    static func matchNibbles(_ input: Span<Self>, at offset: Int, _ table: SIMD16<UInt8>) -> UInt64

    /// Code units `offset` to `offset + 7` of `input`, the first in the least significant byte: their low bytes, and
    /// their high bytes (zero for Latin-1 characters).
    static func eightCodeUnits(_ input: Span<Self>, at offset: Int) -> (lowBytes: UInt64, highBytes: UInt64)

    /// The classes of code units `offset` to `offset + 15` of `input`, where an attribute starts.
    static func attributeWindow(_ input: Span<Self>, at offset: Int) -> AttributeWindow
}

/// Four bits per code unit of sixteen, the first in the least significant, as matchNibbles(_:at:_:) gives them: 0xF
/// where the code unit is in the class, and 0 elsewhere.
private struct AttributeWindow {
    /// Attribute name characters (isAttributeNameCharacter).
    var nameCharacters: UInt64
    /// ASCII upper-case letters.
    var upperCaseLetters: UInt64
    /// The code units that end a quoted attribute value or need decoding: either quote, '&', '\r' and NUL.
    var valueDelimiters: UInt64
}

/// Sixteen lanes of 0 or 0xFF, as four bits per lane, the first in the least significant.
@inline(always)
private func laneNibbles(_ lanes: SIMD16<UInt8>) -> UInt64 {
    bitCast(SIMD8<UInt8>(truncatingIfNeeded: bitCast(lanes, to: SIMD8<UInt16>.self) &>> 4), to: UInt64.self)
}

/// attributeWindow(_:at:) for sixteen code units given as their low bytes and their high bytes.
@inline(always)
private func classifyAttributeWindow(lowBytes: SIMD16<UInt8>, highBytes: SIMD16<UInt8>) -> AttributeWindow {
    // A code unit's class is the bits its low four bits select in the first table, and its next four in the second:
    // 0x01 'a'-'o', 0x02 'p'-'z', 0x04 digits, 0x08 '-', 0x10 '_', 0x40 'A'-'O' and 0x80 'P'-'Z'.
    let lowNibbleClasses = SIMD16<UInt8>(
        0x86,
        0xC7,
        0xC7,
        0xC7,
        0xC7,
        0xC7,
        0xC7,
        0xC7,
        0xC7,
        0xC7,
        0xC3,
        0x41,
        0x41,
        0x49,
        0x41,
        0x51
    )
    let highNibbleClasses = SIMD16<UInt8>(
        0x00,
        0x00,
        0x08,
        0x04,
        0x40,
        0x90,
        0x01,
        0x02,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00
    )
    // A code unit with a nonzero high byte gets an index of 0x80 or more into the second table, which selects 0.
    let highIndex = lowBytes &>> 4 | highBytes | (SIMD16() &- highBytes)
    let classes = neon_tbl(lowNibbleClasses, lowBytes & SIMD16(repeating: 0x0F)) & neon_tbl(highNibbleClasses, highIndex)
    // NUL, '"', '&', '\'' and '\r', each in the lane of its low four bits; the other lanes match nothing.
    let delimiters = SIMD16<UInt8>(0x00, 0xFF, 0x22, 0xFF, 0xFF, 0xFF, 0x26, 0x27, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0D, 0xFF, 0x00)
    return AttributeWindow(
        nameCharacters: laneNibbles(signLanes(classes | (SIMD16() &- classes))),
        upperCaseLetters: laneNibbles(signLanes(classes | classes &<< 1)),
        valueDelimiters: tableMatchNibbles(lowBytes: lowBytes, highBytes: highBytes, delimiters)
    )
}

/// matchNibbles(_:at:_:) for sixteen code units given as their low bytes and their high bytes.
@inline(always)
private func tableMatchNibbles(lowBytes: SIMD16<UInt8>, highBytes: SIMD16<UInt8>, _ table: SIMD16<UInt8>) -> UInt64 {
    // Zero in the lanes that match, and only in those.
    let difference = (neon_tbl(table, lowBytes & SIMD16(repeating: 0x0F)) &- lowBytes) | highBytes
    let mismatches = signLanes(difference | (SIMD16() &- difference))
    return UInt64.max
        &- bitCast(
            SIMD8<UInt8>(truncatingIfNeeded: bitCast(mismatches, to: SIMD8<UInt16>.self) &>> 4),
            to: UInt64.self
        )
}

extension UInt8: HTMLFastPathCodeUnit {
    fileprivate static func consumeCharacterReference(
        _ input: Span<UInt8>,
        _ additionalAllowedCharacter: UInt16,
        _ decoded: inout MutableSpan<UInt16>
    ) -> UInt64 {
        // An empty UTF-16 source. A Span converted to a std::span must have an address, even when empty.
        let noCharacters = InlineArray<1, UInt16>(repeating: 0)
        return WebCore.consumeHTMLEntityForFastPath(
            input,
            noCharacters.span.extracting(0..<0),
            additionalAllowedCharacter,
            &decoded
        )
    }

    @inline(always)
    fileprivate static func matchNibbles(_ input: Span<UInt8>, at offset: Int, _ table: SIMD16<UInt8>) -> UInt64 {
        tableMatchNibbles(lowBytes: load16(input, at: offset), highBytes: SIMD16(), table)
    }

    @inline(always)
    fileprivate static func eightCodeUnits(_ input: Span<UInt8>, at offset: Int) -> (lowBytes: UInt64, highBytes: UInt64) {
        (UInt64(littleEndian: input.bytes.load(fromByteOffset: offset, as: UInt64.self)), 0)
    }

    @inline(always)
    fileprivate static func attributeWindow(_ input: Span<UInt8>, at offset: Int) -> AttributeWindow {
        classifyAttributeWindow(lowBytes: load16(input, at: offset), highBytes: SIMD16())
    }
}

extension UInt16: HTMLFastPathCodeUnit {
    fileprivate static func consumeCharacterReference(
        _ input: Span<UInt16>,
        _ additionalAllowedCharacter: UInt16,
        _ decoded: inout MutableSpan<UInt16>
    ) -> UInt64 {
        // An empty Latin-1 source. A Span converted to a std::span must have an address, even when empty.
        let noCharacters = InlineArray<1, UInt8>(repeating: 0)
        return WebCore.consumeHTMLEntityForFastPath(
            noCharacters.span.extracting(0..<0),
            input,
            additionalAllowedCharacter,
            &decoded
        )
    }

    @inline(always)
    fileprivate static func matchNibbles(_ input: Span<UInt16>, at offset: Int, _ table: SIMD16<UInt8>) -> UInt64 {
        let bytes = input.bytes
        let low = bytes.load(fromByteOffset: offset &* 2, as: SIMD8<UInt16>.self)
        let high = bytes.load(fromByteOffset: offset &* 2 &+ 16, as: SIMD8<UInt16>.self)
        return tableMatchNibbles(
            lowBytes: narrowToLowBytes(low, high),
            highBytes: narrowToLowBytes(low &>> 8, high &>> 8),
            table
        )
    }

    @inline(always)
    fileprivate static func eightCodeUnits(_ input: Span<UInt16>, at offset: Int) -> (lowBytes: UInt64, highBytes: UInt64) {
        let units = input.bytes.load(fromByteOffset: offset &* 2, as: SIMD8<UInt16>.self)
        return (
            UInt64(littleEndian: bitCast(SIMD8<UInt8>(truncatingIfNeeded: units), to: UInt64.self)),
            UInt64(littleEndian: bitCast(SIMD8<UInt8>(truncatingIfNeeded: units &>> 8), to: UInt64.self))
        )
    }

    @inline(always)
    fileprivate static func attributeWindow(_ input: Span<UInt16>, at offset: Int) -> AttributeWindow {
        let bytes = input.bytes
        let low = bytes.load(fromByteOffset: offset &* 2, as: SIMD8<UInt16>.self)
        let high = bytes.load(fromByteOffset: offset &* 2 &+ 16, as: SIMD8<UInt16>.self)
        return classifyAttributeWindow(
            lowBytes: narrowToLowBytes(low, high),
            highBytes: narrowToLowBytes(low &>> 8, high &>> 8)
        )
    }
}

private func scanFragment<CodeUnit: HTMLFastPathCodeUnit>(
    _ input: Span<CodeUnit>,
    _ context: WebCore.HTMLFastPathTag,
    _ ops: consuming MutableSpan<UInt32>,
    _ decoded: consuming MutableSpan<UInt16>
) -> UInt64 {
    var scanner = HTMLFastPathScanner(input: input, ops: ops, decoded: decoded)
    let accepted = scanner.parse(context)
    return accepted ? UInt64(scanner.decodedIndex) &<< 32 | UInt64(scanner.opIndex) : UInt64.max
}

// This file avoids Swift enums and the ==, prefix !, << and * operators: looking them up imports every WebCore C++
// overload, and some of those name JavaScriptCore types this module cannot see.

// SettingsBase::defaultMaximumHTMLParserDOMTreeDepth.
private let maximumElementDepth = 512
// Text::defaultLengthLimit.
private let textLengthLimit = 0x1_0000
// NewlineThenWhitespaceStringsTable::maxSpaceCount.
private let maximumSharedSpaceCount = 32

// Code units are compared as UInt32, with endOfInput standing for the position past the last one.
private let endOfInput: UInt32 = 0x1_0000
private let nullCharacter: UInt32 = 0x00
private let tabCharacter: UInt32 = 0x09
private let newlineCharacter: UInt32 = 0x0A
private let formFeedCharacter: UInt32 = 0x0C
private let carriageReturn: UInt32 = 0x0D
private let space: UInt32 = 0x20
private let quotationMark: UInt32 = 0x22
private let ampersand: UInt32 = 0x26
private let apostrophe: UInt32 = 0x27
private let hyphenMinus: UInt32 = 0x2D
private let solidus: UInt32 = 0x2F
private let lessThanSign: UInt32 = 0x3C
private let equalsSign: UInt32 = 0x3D
private let greaterThanSign: UInt32 = 0x3E
private let lowLine: UInt32 = 0x5F

@inline(always)
private func isEqual(_ a: UInt32, _ b: UInt32) -> Bool {
    switch a {
    case b: true
    default: false
    }
}

@inline(always)
private func isASCIILower(_ c: UInt32) -> Bool { c &- 0x61 < 26 }
@inline(always)
private func isASCIIUpper(_ c: UInt32) -> Bool { c &- 0x41 < 26 }
@inline(always)
private func isASCIIAlpha(_ c: UInt32) -> Bool { isASCIILower(c | 0x20) }
@inline(always)
private func isASCIIDigit(_ c: UInt32) -> Bool { c &- 0x30 < 10 }

@inline(always)
private func isASCIIWhitespace(_ c: UInt32) -> Bool {
    switch c {
    case space, newlineCharacter, tabCharacter, carriageReturn, formFeedCharacter: true
    default: false
    }
}

// https://html.spec.whatwg.org/#syntax-attribute-name, restricted to the characters the fast path accepts. The same
// set is accepted in an unquoted attribute value.
@inline(always)
private func isAttributeNameCharacter(_ c: UInt32) -> Bool {
    isASCIIAlpha(c) || isASCIIDigit(c) || isEqual(c, hyphenMinus) || isEqual(c, lowLine)
}

@inline(always)
private func isCharacterAfterTagNameOrAttribute(_ c: UInt32) -> Bool {
    isASCIIWhitespace(c) || isEqual(c, greaterThanSign) || isEqual(c, solidus)
}

@inline(always)
private func isCharacterAfterUnquotedAttributeValue(_ c: UInt32) -> Bool {
    isASCIIWhitespace(c) || isEqual(c, greaterThanSign)
}

// Where a run of text ends or turns escaped: '<', '&', '\r' and NUL, tested as one bit set over the code units below
// 0x3D.
private let textDelimiters: UInt64 = 1 &<< 0x3C | 1 &<< 0x26 | 1 &<< 0x0D | 1 &<< 0x00

@inline(always)
private func isTextDelimiter(_ c: UInt32) -> Bool {
    c < 0x3D && textDelimiters & 1 &<< UInt64(c) != 0
}

// How many code units of a run of text are tested one by one before the rest is searched sixteen at a time.
private let textScalarPrefixLength = 8

/// The offset of the first text delimiter in `input` at or after `start`, or `input.count` if there is none.
///
/// Tests sixteen code units at a time. The last block overlaps the one before it instead of reading past the end.
@inline(never)
private func indexOfTextDelimiter<CodeUnit: HTMLFastPathCodeUnit>(_ input: Span<CodeUnit>, from start: Int) -> Int {
    // NUL, '&', '<' and '\r', each in the lane of its low four bits; the other lanes match nothing.
    let table = SIMD16<UInt8>(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x26, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x3C, 0x0D, 0xFF, 0x00)
    let count = input.count
    var offset = start
    while count &- offset >= 16 {
        let matches = CodeUnit.matchNibbles(input, at: offset, table)
        if matches != 0 {
            return offset &+ matches.trailingZeroBitCount &>> 2
        }
        offset &+= 16
    }
    if count &- offset > 0 {
        if count >= 16 {
            // The last sixteen code units, without those before `offset`.
            let matches = CodeUnit.matchNibbles(input, at: count &- 16, table) &>> (64 &- 4 &* (count &- offset))
            return matches != 0 ? offset &+ matches.trailingZeroBitCount &>> 2 : count
        }
        while UInt(bitPattern: offset) < UInt(bitPattern: count) {
            if isTextDelimiter(UInt32(truncatingIfNeeded: input[offset])) {
                return offset
            }
            offset &+= 1
        }
    }
    return count
}

/// Whether `tag` may appear in phrasing content, if `inPhrasingContent`, or else in flow content. `<body>` and
/// `<option>` appear only where they are expected by name.
private func isPermitted(_ tag: WebCore.HTMLFastPathTag, inPhrasingContent: Bool) -> Bool {
    switch tag {
    case .B, .Br, .Button, .I, .Input, .Label, .Select, .Span, .Strong: true
    case .A, .Div, .Footer, .Li, .Ol, .P, .Ul: inPhrasingContent ? false : true
    default: false
    }
}

private func isVoid(_ tag: WebCore.HTMLFastPathTag) -> Bool {
    switch tag {
    case .Br, .Input: true
    default: false
    }
}

// A tag name packed into an integer, one lowercase ASCII letter per byte, the first in the least significant byte.
// Packed names of up to eight letters are equal exactly when the names are.

// Multiplying a packed supported tag name by this and keeping the top five bits of the product gives a different
// slot for each supported tag, and not slot 0, the slot of the empty name.
private let tagNameHashMultiplier: UInt64 = 0xd37c_9961_1d77_5b7d

/// The packed name of the supported tag in `slot` (see tagNameHashMultiplier), and the tag; (0, Unsupported) for a slot
/// with no tag.
private func tagNameSlot(_ slot: UInt64) -> (name: UInt64, tag: WebCore.HTMLFastPathTag) {
    switch slot {
    case 3: (0x74_7570_6e69, .Input)
    case 4: (0x61, .A)
    case 7: (0x6c75, .Ul)
    case 8: (0x6c6f, .Ol)
    case 10: (0x696c, .Li)
    case 11: (0x6e61_7073, .Span)
    case 13: (0x766964, .Div)
    case 14: (0x7262, .Br)
    case 15: (0x6e6f_7474_7562, .Button)
    case 16: (0x70, .P)
    case 17: (0x676e_6f72_7473, .Strong)
    case 18: (0x7265_746f_6f66, .Footer)
    case 19: (0x6e6f_6974_706f, .Option)
    case 21: (0x7463_656c_6573, .Select)
    case 23: (0x69, .I)
    case 25: (0x7964_6f62, .Body)
    case 28: (0x6c_6562_616c, .Label)
    case 30: (0x62, .B)
    default: (0, .Unsupported)
    }
}

/// The supported tag whose packed name is `name`, or Unsupported.
@inline(always)
private func tag(named name: UInt64) -> WebCore.HTMLFastPathTag {
    let candidate = tagNameSlot((name &* tagNameHashMultiplier) &>> 59)
    return candidate.name != name ? .Unsupported : candidate.tag
}

// The packed name of a supported tag (see tag(named:)) and its length.
@inline(never)
private func name(of tag: WebCore.HTMLFastPathTag) -> (name: UInt64, length: Int) {
    switch tag {
    case .A: (0x61, 1)
    case .B: (0x62, 1)
    case .Body: (0x7964_6f62, 4)
    case .Br: (0x7262, 2)
    case .Button: (0x6e6f_7474_7562, 6)
    case .Div: (0x766964, 3)
    case .Footer: (0x7265_746f_6f66, 6)
    case .I: (0x69, 1)
    case .Input: (0x74_7570_6e69, 5)
    case .Li: (0x696c, 2)
    case .Label: (0x6c_6562_616c, 5)
    case .Option: (0x6e6f_6974_706f, 6)
    case .Ol: (0x6c6f, 2)
    case .P: (0x70, 1)
    case .Select: (0x7463_656c_6573, 6)
    case .Span: (0x6e61_7073, 4)
    case .Strong: (0x676e_6f72_7473, 6)
    case .Ul: (0x6c75, 2)
    default: (0, 0)
    }
}

// Each byte of a word of eight code units' low bytes, in its top bit: whether the byte is an ASCII letter, either case.
@inline(always)
private func asciiLetterBytes(_ lowBytes: UInt64) -> UInt64 {
    let folded = lowBytes | 0x2020_2020_2020_2020
    let lowSevenBits = folded & 0x7F7F_7F7F_7F7F_7F7F
    // Top bit set where the low seven bits are at least 'a', and where they are past 'z'. Neither sum carries into the
    // next byte.
    let atLeastA = lowSevenBits &+ 0x1F1F_1F1F_1F1F_1F1F
    let pastZ = lowSevenBits &+ 0x0505_0505_0505_0505
    // Top bit set where a byte is past 'z' or not ASCII; subtracting it from 0x80 clears the bit without a borrow.
    let notLetter = (pastZ | folded) & 0x8080_8080_8080_8080
    return atLeastA & (0x8080_8080_8080_8080 &- notLetter)
}

/// The code unit of `units` (eightCodeUnits(_:at:)) whose low byte is at bit `shift`, a multiple of 8 below 64.
@inline(always)
private func codeUnit(of units: (lowBytes: UInt64, highBytes: UInt64), at shift: UInt64) -> UInt32 {
    UInt32(truncatingIfNeeded: units.lowBytes &>> shift & 0xFF | (units.highBytes &>> shift & 0xFF) &<< 8)
}

// Each byte of a word in its top bit: whether the byte is nonzero.
@inline(always)
private func nonzeroBytes(_ word: UInt64) -> UInt64 {
    ((word & 0x7F7F_7F7F_7F7F_7F7F) &+ 0x7F7F_7F7F_7F7F_7F7F | word) & 0x8080_8080_8080_8080
}

/// The code unit at `index` of `input`, or endOfInput past its end.
@inline(always)
private func unit<CodeUnit: HTMLFastPathCodeUnit>(_ input: Span<CodeUnit>, _ index: Int) -> UInt32 {
    UInt(bitPattern: index) < UInt(bitPattern: input.count) ? UInt32(truncatingIfNeeded: input[index]) : endOfInput
}

/// Advances `index` past the ASCII whitespace at it in `input`.
@inline(always)
private func skipWhitespace<CodeUnit: HTMLFastPathCodeUnit>(_ input: Span<CodeUnit>, _ index: inout Int) {
    var cursor = index
    while isASCIIWhitespace(unit(input, cursor)) {
        // A code unit was read at cursor, so cursor < input.count.
        cursor &+= 1
    }
    index = cursor
}

/// Parses the fast path's subset of HTML without building DOM, recording what to build as ops
/// (HTMLFastPathParserTypes.h). `opIndex` and `decodedIndex` count every word and character, including those that
/// did not fit.
private struct HTMLFastPathScanner<CodeUnit: HTMLFastPathCodeUnit>: ~Copyable, ~Escapable {
    let input: Span<CodeUnit>
    var ops: MutableSpan<UInt32>
    var decoded: MutableSpan<UInt16>
    var position = 0
    var opIndex = 0
    var decodedIndex = 0
    var failed = false

    @_lifetime(copy input, copy ops, copy decoded)
    init(input: Span<CodeUnit>, ops: consuming MutableSpan<UInt32>, decoded: consuming MutableSpan<UInt16>) {
        self.input = input
        self.ops = ops
        self.decoded = decoded
    }

    /// Writes `word` at `opIndex` of the ops if it fits, and advances `opIndex` past it.
    @inline(always)
    mutating func emit(_ word: UInt32) {
        let i = opIndex
        if UInt(bitPattern: i) < UInt(bitPattern: ops.count) {
            ops[i] = word
        }
        opIndex = i &+ 1
    }

    /// Writes an attribute's four words at `opIndex` of the ops if they fit, and advances `opIndex` past them.
    @inline(always)
    mutating func emitAttribute(_ nameOffset: UInt32, _ nameLength: UInt32, _ valueOffset: UInt32, _ valueLength: UInt32) {
        let i = opIndex
        if ops.count &- i >= 4 {
            var words = ops._mutatingExtracting(i..<(i &+ 4))
            words[0] = nameOffset
            words[1] = nameLength
            words[2] = valueOffset
            words[3] = valueLength
        }
        opIndex = i &+ 4
    }

    /// Writes a Text op for `length` code units at `offset` of the input, or of the decoded characters if `decoded`,
    /// if it fits.
    @inline(always)
    mutating func emitText(_ offset: Int, _ length: Int, decoded: Bool) {
        let i = opIndex
        if ops.count &- i >= 2 {
            var words = ops._mutatingExtracting(i..<(i &+ 2))
            words[0] = UInt32(WebCore.HTMLFastPathOp.Text.rawValue) | UInt32(truncatingIfNeeded: length) &<< 1
            words[1] = UInt32(truncatingIfNeeded: offset) | (decoded ? 1 &<< 31 : 0)
        }
        opIndex = i &+ 2
    }

    /// Writes `character` at `index` of the decoded characters if it fits, and advances `index` past it.
    @inline(always)
    mutating func appendDecoded(_ character: UInt16, at index: inout Int) {
        let i = index
        if UInt(bitPattern: i) < UInt(bitPattern: decoded.count) {
            decoded[i] = character
        }
        index = i &+ 1
    }

    @inline(always)
    mutating func appendDecoded(_ character: UInt16) {
        var index = decodedIndex
        appendDecoded(character, at: &index)
        decodedIndex = index
    }

    /// Writes `first`, the code unit at `cursor`, and the code units after it up to the end of the input or the first
    /// below 0x40 whose bit is set in `delimiters`, at `index` of the decoded characters as far as they fit, and
    /// advances `cursor` and `index` past them.
    @inline(always)
    mutating func appendDecodedRun(_ first: UInt32, from cursor: inout Int, at index: inout Int, delimiters: UInt64) {
        let input = self.input
        var run = decoded._mutatingExtracting(droppingFirst: index)
        var c = first
        var end = cursor
        var length = 0
        while true {
            if UInt(bitPattern: length) < UInt(bitPattern: run.count) {
                run[length] = UInt16(truncatingIfNeeded: c)
            }
            length &+= 1
            end &+= 1
            if UInt(bitPattern: end) >= UInt(bitPattern: input.count) {
                break
            }
            c = UInt32(truncatingIfNeeded: input[end])
            if c < 0x40, delimiters & 1 &<< UInt64(c) != 0 {
                break
            }
        }
        cursor = end
        index &+= length
    }

    /// Parses the whole input as the children of a `context` element.
    ///
    /// The loop parses the children of the innermost open element, or of `context` while no element is open. The start
    /// tag of an element that is not void opens it, and its end tag closes it.
    @inline(always)
    mutating func parse(_ context: WebCore.HTMLFastPathTag) -> Bool {
        let input = self.input
        // The element whose children are being parsed; whether it is itself in phrasing content; and whether it or an
        // element that contains it is an <a>, or an <li>.
        var parentTag = context
        var parentInPhrasingContent = false
        var insideOfTagA = false
        var insideOfTagLi = false
        switch context {
        case .A:
            insideOfTagA = true
        case .Li:
            insideOfTagLi = true
        case .B, .Body, .Button, .Div, .Footer, .I, .Label, .Option, .Ol, .P, .Select, .Span, .Strong, .Ul:
            break
        default:
            return false
        }
        // Fail before setting up the open elements if `context` does not permit a leading start tag.
        if isEqual(unit(input, 0), lessThanSign) {
            position = 1
            if case .none = scanPermittedChildTagName(
                of: context,
                parentInPhrasingContent: false,
                insideOfTagA: insideOfTagA,
                insideOfTagLi: insideOfTagLi
            ) {
                return false
            }
            position = 0
        }
        // The elements that contain the open element whose children are being parsed, outermost first, each as the raw
        // value of its tag (below 0x20) or'ed with the other three values above (0x20 for phrasing content, 0x40 for
        // <a>, 0x80 for <li>). There are fewer than maximumElementDepth of them.
        var openElements = [512 of UInt8](repeating: 0)
        var depth = 0
        while true {
            scanText()
            if failed {
                return false
            }
            let lessThanSignPosition = position
            if UInt(bitPattern: lessThanSignPosition) >= UInt(bitPattern: input.count) {
                if depth != 0 {
                    // The input ends inside an element.
                    return false
                }
                return true
            }
            position = lessThanSignPosition &+ 1
            if isEqual(unit(input, position), solidus) {
                if depth != 0 {
                    // At the '/' of the open element's end tag.
                    position &+= 1
                    guard scanEndTag(parentTag) else {
                        return false
                    }
                    emit(UInt32(WebCore.HTMLFastPathOp.End.rawValue))
                    depth &-= 1
                    let element = openElements[depth]
                    parentTag = WebCore.HTMLFastPathTag(rawValue: element & 0x1F)!
                    parentInPhrasingContent = element & 0x20 != 0
                    insideOfTagA = element & 0x40 != 0
                    insideOfTagLi = element & 0x80 != 0
                    continue
                }
                // An end tag with no open element.
                return false
            }
            if depth &+ 1 >= maximumElementDepth {
                return false
            }
            guard
                let child = scanPermittedChildTagName(
                    of: parentTag,
                    parentInPhrasingContent: parentInPhrasingContent,
                    insideOfTagA: insideOfTagA,
                    insideOfTagLi: insideOfTagLi
                )
            else {
                return false
            }
            let tag = child.tag
            let isVoid = isVoid(tag)
            emit(UInt32(WebCore.HTMLFastPathOp.Element.rawValue) | UInt32(tag.rawValue) &<< 4 | (isVoid ? 1 &<< 9 : 0))
            parseAttributes()
            if failed {
                return false
            }
            emit(WebCore.HTMLFastPathOpWord.EndOfAttributes.rawValue)
            if isVoid {
                continue
            }
            openElements[depth] =
                parentTag.rawValue
                | (parentInPhrasingContent ? 0x20 : 0) | (insideOfTagA ? 0x40 : 0) | (insideOfTagLi ? 0x80 : 0)
            depth &+= 1
            parentTag = tag
            parentInPhrasingContent = child.inPhrasingContent
            switch tag {
            case .A:
                insideOfTagA = true
            case .Li:
                insideOfTagLi = true
            default:
                break
            }
        }
    }

    /// Scans the name of a start tag among the children of `parentTag`, and returns its tag and whether the child is
    /// in phrasing content, or nil if `parentTag` does not permit it. `parentTag` is itself in phrasing content if
    /// `parentInPhrasingContent`, and it or an element that contains it is an <a> if `insideOfTagA`, and an <li> if
    /// `insideOfTagLi`.
    @inline(always)
    mutating func scanPermittedChildTagName(
        of parentTag: WebCore.HTMLFastPathTag,
        parentInPhrasingContent: Bool,
        insideOfTagA: Bool,
        insideOfTagLi: Bool
    ) -> (tag: WebCore.HTMLFastPathTag, inPhrasingContent: Bool)? {
        // The children parentTag takes: those permitted in phrasing content if inPhrasingContent, or else in flow
        // content; or else only expectedTag.
        var inPhrasingContent = false
        var expectedTag = WebCore.HTMLFastPathTag.Unsupported
        switch parentTag {
        case .A:
            inPhrasingContent = parentInPhrasingContent
        case .Body, .Div, .Footer, .Li:
            break
        case .B, .Button, .I, .Label, .P, .Span, .Strong:
            inPhrasingContent = true
        case .Ol, .Ul:
            expectedTag = .Li
        case .Select:
            expectedTag = .Option
        default:
            // <option> contains only text.
            return nil
        }
        let tag = scanTagName()
        if failed {
            return nil
        }
        switch expectedTag {
        case .Unsupported:
            switch tag {
            case .A:
                // <a> must not nest at any depth, because the HTML parser would close the outer one at the inner one.
                if insideOfTagA {
                    return nil
                }
            case .Li:
                // <li><li></li></li> makes sibling <li>s, so a nested <li> fails unless its parent is an <ol> or <ul>.
                if inPhrasingContent || insideOfTagLi {
                    return nil
                }
            default:
                guard isPermitted(tag, inPhrasingContent: inPhrasingContent) else {
                    return nil
                }
            }
        default:
            if tag.rawValue != expectedTag.rawValue {
                return nil
            }
        }
        return (tag, inPhrasingContent)
    }

    /// Scans the rest of `tag`'s end tag after its '/': the name, exactly or else with its ASCII letters in either
    /// case, then whitespace and '>'.
    @inline(always)
    mutating func scanEndTag(_ tag: WebCore.HTMLFastPathTag) -> Bool {
        let input = self.input
        let (name, length) = name(of: tag)
        let start = position
        var cursor: Int
        // start is at most input.count.
        if input.count &- start >= 8 {
            // The name and the code unit after it are among the eight code units at start: a supported tag's name has
            // at most six letters.
            let units = CodeUnit.eightCodeUnits(input, at: start)
            let nameBits = UInt64(truncatingIfNeeded: length) &* 8
            let nameMask: UInt64 = (1 &<< nameBits) &- 1
            let lowBytes = units.lowBytes & nameMask
            if units.highBytes & nameMask != 0
                || (lowBytes != name && lowBytes | 0x2020_2020_2020_2020 & nameMask != name)
            {
                return false
            }
            if isEqual(codeUnit(of: units, at: nameBits), greaterThanSign) {
                position = start &+ length &+ 1
                return true
            }
            cursor = start &+ length
            skipWhitespace(input, &cursor)
        } else {
            if input.count &- start < length {
                return false
            }
            let endTagName = input.extracting(start..<(start &+ length))
            var index = 0
            while UInt(bitPattern: index) < UInt(bitPattern: endTagName.count) {
                let letter = UInt32(truncatingIfNeeded: name &>> UInt64(truncatingIfNeeded: index &* 8)) & 0xff
                if UInt32(truncatingIfNeeded: endTagName[index]) | 0x20 != letter {
                    return false
                }
                index &+= 1
            }
            cursor = start &+ length
            skipWhitespace(input, &cursor)
        }
        if isEqual(unit(input, cursor), greaterThanSign) {
            position = cursor &+ 1
            return true
        }
        position = cursor
        return false
    }

    /// Scans a start tag's name, in either case, and the whitespace after it. A name that is not followed by
    /// whitespace, '>' or '/' fails the parse; one that is not a supported tag is Unsupported.
    @inline(always)
    mutating func scanTagName() -> WebCore.HTMLFastPathTag {
        let input = self.input
        let start = position
        // start is at most input.count.
        if input.count &- start >= 8 {
            let units = CodeUnit.eightCodeUnits(input, at: start)
            // The top bit of each byte: whether that code unit is not an ASCII letter.
            let notLetters = (0x8080_8080_8080_8080 &- asciiLetterBytes(units.lowBytes)) | nonzeroBytes(units.highBytes)
            if notLetters != 0 {
                // Eight times the name's length, at most 56.
                let nameBits = UInt64(truncatingIfNeeded: notLetters.trailingZeroBitCount &- 7)
                var cursor = start &+ Int(truncatingIfNeeded: nameBits &>> 3)
                if isCharacterAfterTagNameOrAttribute(codeUnit(of: units, at: nameBits)) {
                    skipWhitespace(input, &cursor)
                    position = cursor
                    return tag(named: (units.lowBytes | 0x2020_2020_2020_2020) & ((1 &<< nameBits) &- 1))
                }
                position = cursor
                failed = true
                return .Unsupported
            }
        }
        // A name of eight letters or more, or one near the end of the input.
        var cursor = start
        var name: UInt64 = 0
        var length = 0
        var c = unit(input, cursor)
        while isASCIIAlpha(c) {
            if length < 8 {
                name |= UInt64(c | 0x20) &<< UInt64(truncatingIfNeeded: length &* 8)
            }
            length &+= 1
            cursor &+= 1
            c = unit(input, cursor)
        }
        if isCharacterAfterTagNameOrAttribute(c) {
            skipWhitespace(input, &cursor)
            position = cursor
            return length <= 6 ? tag(named: name) : .Unsupported
        }
        position = cursor
        failed = true
        return .Unsupported
    }

    /// Scans a start tag's attributes up to and including its '>'.
    ///
    /// An attribute whose name repeats an earlier one's is marked in its name offset word, and its element in its
    /// first word (HTMLFastPathParserTypes.h).
    @inline(always)
    mutating func parseAttributes() {
        let input = self.input
        var cursor = position
        let elementIndex = opIndex &- 1
        // One bit per hash of the length and the first character, with ASCII case ignored, of each name so far.
        // Names that are equal ignoring ASCII case have the same hash.
        var nameHashes: UInt64 = 0
        while true {
            let nameStart = cursor
            var c = unit(input, cursor)
            // No name, at '>': the attributes end. Tested first because most start tags end this way.
            if isEqual(c, greaterThanSign) {
                position = cursor &+ 1
                return
            }
            var isFolded = false
            // `window` classifies the sixteen code units at nameStart when that many remain. nameBits is four times
            // the name's length, or 64 if the name runs past the window or there is no window.
            var window = AttributeWindow(nameCharacters: 0, upperCaseLetters: 0, valueDelimiters: 0)
            var nameBits = 64
            if _fastPath(input.count &- nameStart >= 16) {
                window = CodeUnit.attributeWindow(input, at: nameStart)
                nameBits = (UInt64.max &- window.nameCharacters).trailingZeroBitCount
            }
            let isInWindow = nameBits < 64
            if _fastPath(isInWindow) {
                isFolded = window.upperCaseLetters & ((1 &<< UInt64(truncatingIfNeeded: nameBits)) &- 1) != 0
                cursor = nameStart &+ nameBits &>> 2
                c = unit(input, cursor)
            } else {
                // A name of sixteen characters or more, or one near the end of the input.
                while isASCIILower(c) {
                    cursor &+= 1
                    c = unit(input, cursor)
                }
                if UInt(bitPattern: cursor) >= UInt(bitPattern: input.count) {
                    position = cursor
                    failed = true
                    return
                }
                while isAttributeNameCharacter(c) {
                    if isASCIIUpper(c) {
                        isFolded = true
                    }
                    cursor &+= 1
                    c = unit(input, cursor)
                }
            }
            let nameLength = cursor &- nameStart
            // A name over two characters starting with "on", likely an event handler, is treated as no name.
            let startsWithOn =
                nameLength > 2
                && isEqual(unit(input, nameStart) | 0x20, 0x6F)
                && isEqual(unit(input, nameStart &+ 1) | 0x20, 0x6E)
            if nameLength < 1 || startsWithOn {
                // No name ends the attributes, at '>' or "/>".
                if isEqual(c, greaterThanSign) {
                    position = cursor &+ 1
                    return
                }
                if isEqual(c, solidus) {
                    cursor &+= 1
                    skipWhitespace(input, &cursor)
                    if isEqual(unit(input, cursor), greaterThanSign) {
                        position = cursor &+ 1
                        return
                    }
                }
                position = cursor
                failed = true
                return
            }
            let nameHash = (unit(input, nameStart) | 0x20) &* 3 &+ UInt32(truncatingIfNeeded: nameLength)
            let nameHashBit: UInt64 = 1 &<< UInt64(nameHash & 63)
            let isDuplicate =
                nameHashes & nameHashBit != 0
                && repeatsAttributeName(nameStart, nameLength, after: elementIndex)
            nameHashes |= nameHashBit
            var value = (offset: 0, length: 0, isDecoded: false)
            if isInWindow && isEqual(c, equalsSign) {
                // '=' straight after the name, at a lane of the window, and the value after it.
                cursor &+= 1
                let quote = unit(input, cursor)
                switch quote {
                case quotationMark, apostrophe:
                    let valueStart = cursor &+ 1
                    // The value's first code unit is at lane nameLength + 2, at most 17. Where the window holds no
                    // delimiter from there, the search goes on after it.
                    let valueLane = nameLength &+ 2
                    var end = valueStart
                    if valueLane < 16 {
                        let delimiters = window.valueDelimiters &>> UInt64(truncatingIfNeeded: valueLane &* 4)
                        end = delimiters != 0 ? valueStart &+ delimiters.trailingZeroBitCount &>> 2 : nameStart &+ 16
                    }
                    if isEqual(unit(input, end), quote) {
                        value = (valueStart, end &- valueStart, false)
                        cursor = end &+ 1
                    } else {
                        value = scanQuotedAttributeValue(quote, from: valueStart, searchingFrom: end, &cursor)
                    }
                case space, newlineCharacter, tabCharacter, carriageReturn, formFeedCharacter:
                    value = scanAttributeValue(&cursor)
                default:
                    // An unquoted value, from lane nameLength + 1, at most 16: name characters up to whitespace or
                    // '>'. One that goes past the window is scanned from its start.
                    let valueLane = nameLength &+ 1
                    let otherCharacters =
                        valueLane < 16
                        ? (UInt64.max &- window.nameCharacters) &>> UInt64(truncatingIfNeeded: valueLane &* 4) : 0
                    if otherCharacters != 0 {
                        let end = cursor &+ otherCharacters.trailingZeroBitCount &>> 2
                        if isCharacterAfterUnquotedAttributeValue(unit(input, end)) {
                            value = (cursor, end &- cursor, false)
                        } else {
                            failed = true
                        }
                        cursor = end
                    } else {
                        value = scanAttributeValue(&cursor)
                    }
                }
                if failed {
                    position = cursor
                    return
                }
                skipWhitespace(input, &cursor)
            } else {
                skipWhitespace(input, &cursor)
                if isEqual(unit(input, cursor), equalsSign) {
                    cursor &+= 1
                    value = scanAttributeValue(&cursor)
                    if failed {
                        position = cursor
                        return
                    }
                    skipWhitespace(input, &cursor)
                }
            }
            if isDuplicate {
                ops[elementIndex] |= 1 &<< 10
            }
            emitAttribute(
                UInt32(truncatingIfNeeded: nameStart) | (isDuplicate ? 1 &<< 31 : 0),
                UInt32(truncatingIfNeeded: nameLength) | (isFolded ? 1 &<< 31 : 0),
                UInt32(truncatingIfNeeded: value.offset),
                UInt32(truncatingIfNeeded: value.length) | (value.isDecoded ? 1 &<< 31 : 0)
            )
        }
    }

    /// Whether the attribute name of `length` code units at `start` equals, ignoring ASCII case, the name of an
    /// earlier attribute of the element whose first op word is at `elementIndex`.
    @inline(never)
    func repeatsAttributeName(_ start: Int, _ length: Int, after elementIndex: Int) -> Bool {
        let input = self.input
        // Only the names whose words fit in the ops are compared.
        let end = Swift.min(opIndex, ops.count)
        var index = elementIndex &+ 1
        while index &+ 1 < end {
            let otherStart = Int(ops[index] & 0x7fff_ffff)
            if Int(ops[index &+ 1] & 0x7fff_ffff) != length {
                index &+= 4
                continue
            }
            // Attribute names are ASCII letters, digits, '-' and '_', so setting bit 5 folds case and nothing else.
            var k = 0
            while k < length && isEqual(unit(input, start &+ k) | 0x20, unit(input, otherStart &+ k) | 0x20) {
                k &+= 1
            }
            if k >= length {
                return true
            }
            index &+= 4
        }
        return false
    }

    /// Scans an attribute value after its `=` at `cursor`, quoted or not, and advances `cursor` past it.
    ///
    /// Returns its extent in the input, or in the decoded characters if it has character references or carriage
    /// returns.
    @inline(never)
    mutating func scanAttributeValue(_ cursor: inout Int) -> (offset: Int, length: Int, isDecoded: Bool) {
        let input = self.input
        skipWhitespace(input, &cursor)
        let start = cursor
        let quote = unit(input, start)
        switch quote {
        case quotationMark, apostrophe:
            break
        default:
            var end = start
            var c = quote
            while isAttributeNameCharacter(c) {
                end &+= 1
                c = unit(input, end)
            }
            cursor = end
            if isCharacterAfterUnquotedAttributeValue(c) {
                return (start, end &- start, false)
            }
            failed = true
            return (0, 0, false)
        }
        // The quote was read at start, so start < input.count.
        return scanQuotedAttributeValue(quote, from: start &+ 1, searchingFrom: start &+ 1, &cursor)
    }

    /// Scans a value quoted by `quote` that starts at `valueStart`, and advances `cursor` past its closing quote.
    ///
    /// The code units from `valueStart` up to `searchStart` are known not to be delimiters. Returns the value's extent
    /// in the input, or in the decoded characters if it has character references or carriage returns.
    @inline(never)
    mutating func scanQuotedAttributeValue(
        _ quote: UInt32,
        from valueStart: Int,
        searchingFrom searchStart: Int,
        _ cursor: inout Int
    ) -> (offset: Int, length: Int, isDecoded: Bool) {
        let input = self.input
        var end = searchStart
        scan: while UInt(bitPattern: end) < UInt(bitPattern: input.count) {
            switch UInt32(truncatingIfNeeded: input[end]) {
            case quote, ampersand, carriageReturn, nullCharacter:
                break scan
            default:
                end &+= 1
            }
        }
        switch unit(input, end) {
        case quote:
            cursor = end &+ 1
            return (valueStart, end &- valueStart, false)
        case ampersand, carriageReturn:
            break
        default:
            cursor = end
            failed = true
            return (0, 0, false)
        }
        var valueCursor = valueStart
        let decodedStart = decodedIndex
        var index = decodedIndex
        // The quote (below 0x40), '&', '\r' and NUL, as one bit set.
        let valueDelimiters: UInt64 = 1 &<< UInt64(quote) | 1 &<< 0x26 | 1 &<< 0x0D | 1 &<< 0x00
        scan: while true {
            let c = unit(input, valueCursor)
            switch c {
            case quote:
                break scan
            case ampersand:
                position = valueCursor
                decodedIndex = index
                scanCharacterReference(additionalAllowedCharacter: UInt16(truncatingIfNeeded: quote))
                valueCursor = position
                index = decodedIndex
            case carriageReturn:
                // Normalize "\r\n" to "\n" according to https://infra.spec.whatwg.org/#normalize-newlines.
                valueCursor &+= 1
                if isEqual(unit(input, valueCursor), newlineCharacter) {
                    valueCursor &+= 1
                }
                appendDecoded(UInt16(truncatingIfNeeded: newlineCharacter), at: &index)
            case nullCharacter, endOfInput:
                cursor = valueCursor
                decodedIndex = index
                failed = true
                return (0, 0, false)
            default:
                appendDecodedRun(c, from: &valueCursor, at: &index, delimiters: valueDelimiters)
            }
        }
        decodedIndex = index
        cursor = valueCursor &+ 1
        return (decodedStart, decodedIndex &- decodedStart, true)
    }

    /// Scans a run of text up to the next `<` or the end of the input.
    ///
    /// Emits it unless it is empty.
    @inline(always)
    mutating func scanText() {
        let input = self.input
        let start = position
        var cursor = start
        // '\n' followed only by spaces up to '<' or the end skips the length limit, and up to 32 spaces is a shared string.
        if isEqual(unit(input, cursor), newlineCharacter) {
            cursor &+= 1
            while isEqual(unit(input, cursor), space) {
                cursor &+= 1
            }
            switch unit(input, cursor) {
            case endOfInput, lessThanSign:
                position = cursor
                let spaceCount = cursor &- start &- 1
                if spaceCount <= maximumSharedSpaceCount {
                    emit(UInt32(WebCore.HTMLFastPathOp.Whitespace.rawValue) | UInt32(truncatingIfNeeded: spaceCount) &<< 4)
                } else {
                    emitText(start, cursor &- start, decoded: false)
                }
                return
            default:
                // Not only whitespace: scan the rest as text.
                break
            }
        }
        // Test the first code units one by one so a short run ends without a SIMD search.
        let prefixEnd = Swift.min(UInt(bitPattern: cursor) &+ UInt(textScalarPrefixLength), UInt(bitPattern: input.count))
        while UInt(bitPattern: cursor) < prefixEnd {
            if isTextDelimiter(UInt32(truncatingIfNeeded: input[cursor])) {
                break
            }
            cursor &+= 1
        }
        if UInt(bitPattern: cursor) >= prefixEnd, UInt(bitPattern: cursor) < UInt(bitPattern: input.count) {
            cursor = indexOfTextDelimiter(input, from: cursor)
        }
        switch unit(input, cursor) {
        case nullCharacter:
            position = cursor
            failed = true
            return
        case ampersand, carriageReturn:
            scanEscapedText()
            return
        default:
            break
        }
        position = cursor
        let length = cursor &- start
        if length >= textLengthLimit {
            failed = true
            return
        }
        if length > 0 {
            emitText(start, length, decoded: false)
        }
    }

    /// Scans a run of text that has character references or carriage returns, from `position`, into the decoded
    /// characters.
    @inline(always)
    mutating func scanEscapedText() {
        let input = self.input
        let decodedStart = decodedIndex
        var cursor = position
        var index = decodedIndex
        scan: while true {
            let c = unit(input, cursor)
            switch c {
            case lessThanSign, endOfInput:
                break scan
            case ampersand:
                position = cursor
                decodedIndex = index
                scanCharacterReference(additionalAllowedCharacter: 0)
                cursor = position
                index = decodedIndex
            case carriageReturn:
                // Normalize "\r\n" to "\n" according to https://infra.spec.whatwg.org/#normalize-newlines.
                cursor &+= 1
                if isEqual(unit(input, cursor), newlineCharacter) {
                    cursor &+= 1
                }
                appendDecoded(UInt16(truncatingIfNeeded: newlineCharacter), at: &index)
            case nullCharacter:
                position = cursor
                decodedIndex = index
                failed = true
                return
            default:
                appendDecodedRun(c, from: &cursor, at: &index, delimiters: textDelimiters)
            }
        }
        position = cursor
        decodedIndex = index
        let length = decodedIndex &- decodedStart
        if length >= textLengthLimit {
            failed = true
            return
        }
        if length > 0 {
            emitText(decodedStart, length, decoded: true)
        }
    }

    /// Decodes the character reference at a '&'.
    ///
    /// With fewer than two characters left after it, or none that consumeHTMLEntity recognizes, the '&' is literal.
    @inline(never)
    mutating func scanCharacterReference(additionalAllowedCharacter: UInt16) {
        // The '&' was read at position, so position < input.count.
        position &+= 1
        if input.count &- position >= 2 {
            let source = input.extracting(droppingFirst: position)
            let result: UInt64
            if decoded.count &- decodedIndex >= 3 {
                var tail = decoded._mutatingExtracting(droppingFirst: decodedIndex)
                result = CodeUnit.consumeCharacterReference(source, additionalAllowedCharacter, &tail)
            } else {
                // Fewer than 3 characters fit: decode into `characters`, then write those that fit.
                var characters = InlineArray<3, UInt16>(repeating: 0)
                do {
                    var span = characters.mutableSpan
                    result = CodeUnit.consumeCharacterReference(source, additionalAllowedCharacter, &span)
                }
                var index = decodedIndex
                var k = 0
                while k < Int(truncatingIfNeeded: result & 3) {
                    appendDecoded(characters[k], at: &index)
                    k &+= 1
                }
            }
            position += Int(truncatingIfNeeded: result &>> 2)
            let length = Int(truncatingIfNeeded: result & 3)
            if length > 0 {
                decodedIndex &+= length
                return
            }
        }
        appendDecoded(UInt16(truncatingIfNeeded: ampersand))
    }
}

#endif // USE_SWIFT_HTML_FAST_PATH
