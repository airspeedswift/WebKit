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

internal import WebCore_Private.HTMLFastPathParserTypes
// Operators that WebCore's headers declare use these JavaScriptCore and WTF types. Without their definitions, ==, !,
// << and * do not typecheck in this file.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import wtf.Core.Stopwatch
internal import WebCore_Private.Core.Attribute
internal import WebCore_Private.Core.ContainerNode
internal import WebCore_Private.Core.Document
internal import WebCore_Private.Core.Element
internal import WebCore_Private.Core.HTMLElement
internal import WebCore_Private.Core.HTMLElementFactory
internal import WebCore_Private.Core.HTMLNameCache
internal import WebCore_Private.Core.Node
internal import WebCore_Private.Core.NodeName
internal import WebCore_Private.Core.QualifiedName
internal import WebCore_Private.Core.Text

/// Parses `source`, an 8-bit fragment, as the children of `contextElement` into `destinationParent`.
///
/// Returns false if the fragment is outside the subset of HTML the fast path supports (HTMLDocumentParserFastPath.cpp).
/// The nodes already appended then stay, for the caller to discard.
///
/// The C++ caller owns the characters of `source`, which stay alive and unchanged for the call, and any byte is a
/// valid Latin1Character.
///
/// FIXME: Take a Span once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
func parseHTMLFragmentForFastPath(
    _ source: WebCore.HTMLFastPathLatin1Span,
    _ document: WebCore.Document,
    _ destinationParent: WebCore.ContainerNode,
    _ contextElement: WebCore.Element
) -> Bool {
    let input = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(source))
    return parseFragment(input, document, destinationParent, contextElement)
}

/// The 16-bit form of parseHTMLFragmentForFastPath(_:_:_:_:).
///
/// The C++ caller owns the characters of `source`, which stay alive and unchanged for the call, and any 16-bit value
/// is a valid char16_t.
///
/// FIXME: Take a Span once a std::span can cross safely (rdar://186723514).
@_expose(Cxx, "parseHTMLFragmentForFastPath")
func parseHTMLFragmentForFastPath16(
    _ source: WebCore.HTMLFastPathUTF16Span,
    _ document: WebCore.Document,
    _ destinationParent: WebCore.ContainerNode,
    _ contextElement: WebCore.Element
) -> Bool {
    let input = unsafe Span<UInt16>(_unsafeCxxSpan: source)
    return parseFragment(input, document, destinationParent, contextElement)
}

private func parseFragment<CodeUnit: HTMLFastPathCodeUnit>(
    _ input: Span<CodeUnit>,
    _ document: WebCore.Document,
    _ destinationParent: WebCore.ContainerNode,
    _ contextElement: WebCore.Element
) -> Bool {
    guard let context = FastPathTag(context: contextElement.elementName()) else {
        return false
    }
    // A fragment that starts with a start tag fails before it builds anything if the context does not permit that
    // tag, so check it before setting up the parse.
    if unit(input, 0) == lessThanSign && unit(input, 1) != solidus {
        var scanner = InputScanner(input: input, position: 1)
        guard scanner.scanPermittedChildTagName(of: ParentState(context: context)) != nil else {
            return false
        }
    }
    var parser = HTMLFastPathParser(input: input, document: document, destinationParent: destinationParent)
    return parser.parse(context)
}

/// A code unit of the fast path's input: a Latin-1 character or a UTF-16 code unit.
private protocol HTMLFastPathCodeUnit: FixedWidthInteger, UnsignedInteger {
    /// Consumes the character reference that starts `input`, just after its '&', as consumeHTMLEntity reads it, and
    /// writes the 0 to 3 characters it decodes to at `offset` of `decoded`, which has room for 3 there. Returns how many
    /// characters it read, shifted left by 2, or'ed with how many it wrote. `input` is not empty.
    static func consumeCharacterReference(
        _ input: Span<Self>,
        _ additionalAllowedCharacter: UInt16,
        _ decoded: inout MutableSpan<UInt16>,
        at offset: Int
    ) -> UInt64

    /// A String of `characters`, of their width.
    static func makeString(_ characters: Span<Self>) -> WTF.String

    /// HTMLNameCache's name for an attribute named `name`.
    static func makeAttributeQualifiedName(_ name: Span<Self>) -> WebCore.QualifiedName

    /// HTMLNameCache's atom for an attribute value of `value`.
    static func makeAttributeValue(_ value: Span<Self>) -> WTF.AtomString

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

// SIMD integer vectors have only the wrapping operators, so the lane arithmetic below uses them.

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

/// Four bits per code unit of sixteen given as their low bytes and their high bytes, the first in the least
/// significant: 0xF where the code unit is below 0x100 and equals the lane of `table` its low four bits select, and 0
/// elsewhere.
@inline(always)
func tableMatchNibbles(lowBytes: SIMD16<UInt8>, highBytes: SIMD16<UInt8>, _ table: SIMD16<UInt8>) -> UInt64 {
    // Zero in the lanes that match, and only in those.
    let difference = (neon_tbl(table, lowBytes & SIMD16(repeating: 0x0F)) &- lowBytes) | highBytes
    let mismatches = signLanes(difference | (SIMD16() &- difference))
    return ~laneNibbles(mismatches)
}

extension UInt8: HTMLFastPathCodeUnit {
    fileprivate static func consumeCharacterReference(
        _ input: Span<UInt8>,
        _ additionalAllowedCharacter: UInt16,
        _ decoded: inout MutableSpan<UInt16>,
        at offset: Int
    ) -> UInt64 {
        #if USE_SWIFT_HTML_TOKENIZER
        consumeHTMLEntity(input, additionalAllowedCharacter, &decoded, at: offset)
        #else
        // An empty UTF-16 source. A Span converted to a std::span must have an address, even when empty.
        let noCharacters = InlineArray<1, UInt16>(repeating: 0)
        return WebCore.consumeHTMLEntityForFastPath(
            WTF.latin1CharactersOfBytes(input),
            noCharacters.span.extracting(0..<0),
            additionalAllowedCharacter,
            &decoded,
            offset
        )
        #endif
    }

    @inline(always)
    fileprivate static func makeString(_ characters: Span<UInt8>) -> WTF.String {
        WTF.String(WTF.latin1CharactersOfBytes(characters))
    }

    @inline(always)
    fileprivate static func makeAttributeQualifiedName(_ name: Span<UInt8>) -> WebCore.QualifiedName {
        WebCore.HTMLNameCache.makeAttributeQualifiedName(WTF.latin1CharactersOfBytes(name))
    }

    @inline(always)
    fileprivate static func makeAttributeValue(_ value: Span<UInt8>) -> WTF.AtomString {
        WebCore.HTMLNameCache.makeAttributeValue(WTF.latin1CharactersOfBytes(value))
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
        _ decoded: inout MutableSpan<UInt16>,
        at offset: Int
    ) -> UInt64 {
        #if USE_SWIFT_HTML_TOKENIZER
        consumeHTMLEntity(input, additionalAllowedCharacter, &decoded, at: offset)
        #else
        // An empty Latin-1 source. A Span converted to a std::span must have an address, even when empty.
        let noCharacters = InlineArray<1, UInt8>(repeating: 0)
        return WebCore.consumeHTMLEntityForFastPath(
            WTF.latin1CharactersOfBytes(noCharacters.span.extracting(0..<0)),
            input,
            additionalAllowedCharacter,
            &decoded,
            offset
        )
        #endif
    }

    @inline(always)
    fileprivate static func makeString(_ characters: Span<UInt16>) -> WTF.String {
        WTF.String(characters)
    }

    @inline(always)
    fileprivate static func makeAttributeQualifiedName(_ name: Span<UInt16>) -> WebCore.QualifiedName {
        WebCore.HTMLNameCache.makeAttributeQualifiedName(name)
    }

    @inline(always)
    fileprivate static func makeAttributeValue(_ value: Span<UInt16>) -> WTF.AtomString {
        WebCore.HTMLNameCache.makeAttributeValue(value)
    }

    // A Span<UInt16> of n code units spans 2n bytes, and the callers pass an offset with 16 code units after it, so
    // the byte offsets below cannot overflow.

    @inline(always)
    static func matchNibbles(_ input: Span<UInt16>, at offset: Int, _ table: SIMD16<UInt8>) -> UInt64 {
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

// Settings::defaultMaximumHTMLParserDOMTreeDepth.
private let maximumElementDepth = 512
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
private let solidus: UInt32 = 0x2F
private let lessThanSign: UInt32 = 0x3C
private let equalsSign: UInt32 = 0x3D
private let greaterThanSign: UInt32 = 0x3E
private let hyphenMinus: UInt32 = 0x2D
private let lowLine: UInt32 = 0x5F

// These subtract and compare unsigned, so a code unit below the range wraps to a large value and is outside it.
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
    isASCIIAlpha(c) || isASCIIDigit(c) || c == hyphenMinus || c == lowLine
}

@inline(always)
private func isCharacterAfterTagNameOrAttribute(_ c: UInt32) -> Bool {
    isASCIIWhitespace(c) || c == greaterThanSign || c == solidus
}

@inline(always)
private func isCharacterAfterUnquotedAttributeValue(_ c: UInt32) -> Bool {
    isASCIIWhitespace(c) || c == greaterThanSign
}

// Where a run of text ends or turns escaped: '<', '&', '\r' and NUL, tested as one bit set over the code units below
// 0x3D.
private let textDelimiters: UInt64 = 1 << 0x3C | 1 << 0x26 | 1 << 0x0D | 1 << 0x00

@inline(always)
private func isTextDelimiter(_ c: UInt32) -> Bool {
    c < 0x3D && textDelimiters & 1 << UInt64(c) != 0
}

/// The offset of the first text delimiter in `input` at or after `start`, which is at most `input.count`, or
/// `input.count` if there is none.
///
/// Tests sixteen code units at a time. The last block overlaps the one before it instead of reading past the end.
@inline(never)
private func indexOfTextDelimiter<CodeUnit: HTMLFastPathCodeUnit>(_ input: Span<CodeUnit>, from start: Int) -> Int {
    // NUL, '&', '<' and '\r', each in the lane of its low four bits; the other lanes match nothing.
    let table = SIMD16<UInt8>(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x26, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x3C, 0x0D, 0xFF, 0x00)
    let count = input.count
    // start <= offset <= count throughout, and a match's lane is below 16, so none of this arithmetic overflows.
    var offset = start
    while count &- offset >= 16 {
        let matches = CodeUnit.matchNibbles(input, at: offset, table)
        if matches != 0 {
            return offset &+ matches.trailingZeroBitCount >> 2
        }
        offset &+= 16
    }
    if count &- offset > 0 {
        if count >= 16 {
            // The last sixteen code units, without those before `offset`, of which there are fewer than 16.
            let matches = CodeUnit.matchNibbles(input, at: count &- 16, table) >> (64 &- 4 &* (count &- offset))
            return matches != 0 ? offset &+ matches.trailingZeroBitCount >> 2 : count
        }
        while UInt(bitPattern: offset) < UInt(bitPattern: count) {
            if isTextDelimiter(UInt32(input[offset])) {
                return offset
            }
            offset &+= 1
        }
    }
    return count
}

/// The offset of the first code unit in `input` at or after `start` that is not a space, which is at most
/// `input.count`.
@inline(never)
private func indexOfNonSpace<CodeUnit: HTMLFastPathCodeUnit>(_ input: Span<CodeUnit>, from start: Int) -> Int {
    // ' ' in the lane of its low four bits; the other lanes match nothing.
    let table = SIMD16<UInt8>(0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)
    let count = input.count
    // start <= offset <= count throughout, and a lane is below 16, so none of this arithmetic overflows.
    var offset = start
    while count &- offset >= 16 {
        let others = ~CodeUnit.matchNibbles(input, at: offset, table)
        if others != 0 {
            return offset &+ others.trailingZeroBitCount >> 2
        }
        offset &+= 16
    }
    while unit(input, offset) == space {
        offset &+= 1
    }
    return offset
}

/// The tags the fast path supports.
private enum FastPathTag {
    case a, b, body, br, button, div, footer, i, input, li, label, option, ol, p, select, span, strong, ul

    /// The tag of a context element whose children the fast path can parse, or nil.
    ///
    /// A void element has no children.
    init?(context: WebCore.ElementName) {
        switch context {
        case .HTML_a: self = .a
        case .HTML_b: self = .b
        case .HTML_body: self = .body
        case .HTML_button: self = .button
        case .HTML_div: self = .div
        case .HTML_footer: self = .footer
        case .HTML_i: self = .i
        case .HTML_li: self = .li
        case .HTML_label: self = .label
        case .HTML_option: self = .option
        case .HTML_ol: self = .ol
        case .HTML_p: self = .p
        case .HTML_select: self = .select
        case .HTML_span: self = .span
        case .HTML_strong: self = .strong
        case .HTML_ul: self = .ul
        default: return nil
        }
    }

    var tagName: WebCore.TagName {
        switch self {
        case .a: .a
        case .b: .b
        case .body: .body
        case .br: .br
        case .button: .button
        case .div: .div
        case .footer: .footer
        case .i: .i
        case .input: .input
        case .li: .li
        case .label: .label
        case .option: .option
        case .ol: .ol
        case .p: .p
        case .select: .select
        case .span: .span
        case .strong: .strong
        case .ul: .ul
        }
    }

    var isVoid: Bool {
        switch self {
        case .br, .input: true
        default: false
        }
    }

    /// Whether the tag may appear in phrasing content if `inPhrasingContent`, or else in flow content.
    ///
    /// <body> and <option> appear only where they are expected by name, and <a> and <li> have rules of their own.
    func isPermitted(inPhrasingContent: Bool) -> Bool {
        switch self {
        case .b, .br, .button, .i, .input, .label, .select, .span, .strong: true
        case .a, .div, .footer, .li, .ol, .p, .ul: !inPhrasingContent
        case .body, .option: false
        }
    }
}

// A tag name packed into an integer, one lowercase ASCII letter per byte, the first in the least significant byte.
// Packed names of up to eight letters are equal exactly when the names are.

// Multiplying a packed supported tag name by this and keeping the top five bits of the product gives a different
// slot for each supported tag, and not slot 0, the slot of the empty name.
private let tagNameHashMultiplier: UInt64 = 0xd37c_9961_1d77_5b7d

/// The packed name of the supported tag in `slot` (see tagNameHashMultiplier), and the tag; (0, nil) for a slot with no
/// tag.
private func tagNameSlot(_ slot: UInt64) -> (name: UInt64, tag: FastPathTag?) {
    switch slot {
    case 3: (0x74_7570_6e69, .input)
    case 4: (0x61, .a)
    case 7: (0x6c75, .ul)
    case 8: (0x6c6f, .ol)
    case 10: (0x696c, .li)
    case 11: (0x6e61_7073, .span)
    case 13: (0x766964, .div)
    case 14: (0x7262, .br)
    case 15: (0x6e6f_7474_7562, .button)
    case 16: (0x70, .p)
    case 17: (0x676e_6f72_7473, .strong)
    case 18: (0x7265_746f_6f66, .footer)
    case 19: (0x6e6f_6974_706f, .option)
    case 21: (0x7463_656c_6573, .select)
    case 23: (0x69, .i)
    case 25: (0x7964_6f62, .body)
    case 28: (0x6c_6562_616c, .label)
    case 30: (0x62, .b)
    default: (0, nil)
    }
}

/// The supported tag whose packed name is `name`, or nil.
@inline(always)
private func tag(named name: UInt64) -> FastPathTag? {
    // The product wraps: only its top bits are kept.
    let candidate = tagNameSlot((name &* tagNameHashMultiplier) >> 59)
    return candidate.name == name ? candidate.tag : nil
}

// The packed name of a supported tag (see tag(named:)) and its length.
@inline(always)
private func name(of tag: FastPathTag) -> (name: UInt64, length: Int) {
    switch tag {
    case .a: (0x61, 1)
    case .b: (0x62, 1)
    case .body: (0x7964_6f62, 4)
    case .br: (0x7262, 2)
    case .button: (0x6e6f_7474_7562, 6)
    case .div: (0x766964, 3)
    case .footer: (0x7265_746f_6f66, 6)
    case .i: (0x69, 1)
    case .input: (0x74_7570_6e69, 5)
    case .li: (0x696c, 2)
    case .label: (0x6c_6562_616c, 5)
    case .option: (0x6e6f_6974_706f, 6)
    case .ol: (0x6c6f, 2)
    case .p: (0x70, 1)
    case .select: (0x7463_656c_6573, 6)
    case .span: (0x6e61_7073, 4)
    case .strong: (0x676e_6f72_7473, 6)
    case .ul: (0x6c75, 2)
    }
}

// Each byte of a word of eight code units' low bytes, in its top bit: whether the byte is an ASCII letter, either case.
@inline(always)
private func asciiLetterBytes(_ lowBytes: UInt64) -> UInt64 {
    let folded = lowBytes | 0x2020_2020_2020_2020
    let lowSevenBits = folded & 0x7F7F_7F7F_7F7F_7F7F
    // Top bit set where the low seven bits are at least 'a', and where they are past 'z'. Neither sum carries into the
    // next byte.
    let atLeastA = lowSevenBits + 0x1F1F_1F1F_1F1F_1F1F
    let pastZ = lowSevenBits + 0x0505_0505_0505_0505
    // Top bit set where a byte is past 'z' or not ASCII; subtracting it from 0x80 clears the bit without a borrow.
    let notLetter = (pastZ | folded) & 0x8080_8080_8080_8080
    return atLeastA & (0x8080_8080_8080_8080 - notLetter)
}

/// The code unit of `units` (eightCodeUnits(_:at:)) whose low byte is at bit `shift`, a multiple of 8 below 64.
@inline(always)
private func codeUnit(of units: (lowBytes: UInt64, highBytes: UInt64), at shift: UInt64) -> UInt32 {
    UInt32(truncatingIfNeeded: units.lowBytes >> shift & 0xFF | (units.highBytes >> shift & 0xFF) << 8)
}

// Each byte of a word in its top bit: whether the byte is nonzero.
@inline(always)
private func nonzeroBytes(_ word: UInt64) -> UInt64 {
    ((word & 0x7F7F_7F7F_7F7F_7F7F) + 0x7F7F_7F7F_7F7F_7F7F | word) & 0x8080_8080_8080_8080
}

/// The code unit at `index` of `input`, or endOfInput past its end.
@inline(always)
private func unit<CodeUnit: HTMLFastPathCodeUnit>(_ input: Span<CodeUnit>, _ index: Int) -> UInt32 {
    UInt(bitPattern: index) < UInt(bitPattern: input.count) ? UInt32(input[index]) : endOfInput
}

/// Advances `index` past the ASCII whitespace at it in `input`.
@inline(always)
private func skipWhitespace<CodeUnit: HTMLFastPathCodeUnit>(_ input: Span<CodeUnit>, _ index: inout Int) {
    var cursor = index
    while isASCIIWhitespace(unit(input, cursor)) {
        // A code unit was read at cursor, so cursor < input.count.
        cursor += 1
    }
    index = cursor
}

/// How decodeEscapedCharacters(_:from:into:at:terminator:additionalAllowedCharacter:) stopped.
private enum DecodeStop {
    case terminator
    case nullCharacter
    case endOfInput
    /// `decoded` has no room for the next character or character reference.
    case decodedIsFull
}

/// Decodes `input` from `cursor` into `decoded` from `index`, as the C++ parser copies escaped text and attribute values
/// into its buffer, and advances both: up to `terminator`, a NUL or the end of the input, or until `decoded` has no
/// room for the next character or character reference. `terminator` is below 0x40.
@inline(always)
private func decodeEscapedCharacters<CodeUnit: HTMLFastPathCodeUnit>(
    _ input: Span<CodeUnit>,
    from cursor: inout Int,
    into decoded: inout MutableSpan<UInt16>,
    at index: inout Int,
    terminator: UInt32,
    additionalAllowedCharacter: UInt16
) -> DecodeStop {
    // The terminator, '&', '\r' and NUL, as one bit set.
    let delimiters: UInt64 = 1 << UInt64(terminator) | 1 << 0x26 | 1 << 0x0D | 1 << 0x00
    // cursor <= input.count and index <= decoded.count throughout, and each advances only past a code unit read or a
    // character written, so none of this arithmetic overflows.
    while true {
        var c = unit(input, cursor)
        switch c {
        case terminator:
            return .terminator
        case nullCharacter:
            return .nullCharacter
        case endOfInput:
            return .endOfInput
        case ampersand:
            if decoded.count &- index < 3 {
                return .decodedIsFull
            }
            decodeCharacterReference(input, &cursor, &decoded, &index, additionalAllowedCharacter)
        case carriageReturn:
            if UInt(bitPattern: index) >= UInt(bitPattern: decoded.count) {
                return .decodedIsFull
            }
            // Normalize "\r\n" to "\n" according to https://infra.spec.whatwg.org/#normalize-newlines.
            cursor += 1
            if unit(input, cursor) == newlineCharacter {
                cursor += 1
            }
            decoded[index] = UInt16(truncatingIfNeeded: newlineCharacter)
            index += 1
        default:
            // The code units up to the next delimiter or the end of the input, as they are.
            while true {
                if UInt(bitPattern: index) >= UInt(bitPattern: decoded.count) {
                    return .decodedIsFull
                }
                decoded[index] = UInt16(truncatingIfNeeded: c)
                index += 1
                cursor += 1
                if UInt(bitPattern: cursor) >= UInt(bitPattern: input.count) {
                    break
                }
                c = UInt32(input[cursor])
                if c < 0x40 && delimiters & 1 << UInt64(c) != 0 {
                    break
                }
            }
        }
    }
}

/// Decodes the character reference at the '&' at `cursor` into `decoded` at `index`, which has room for 3 characters
/// there, and advances both.
///
/// With fewer than two characters left after the '&', or none that consumeHTMLEntity recognizes, the '&' is literal.
@inline(never)
private func decodeCharacterReference<CodeUnit: HTMLFastPathCodeUnit>(
    _ input: Span<CodeUnit>,
    _ cursor: inout Int,
    _ decoded: inout MutableSpan<UInt16>,
    _ index: inout Int,
    _ additionalAllowedCharacter: UInt16
) {
    // The '&' was read at cursor, so cursor < input.count; consumeHTMLEntity reads at most the rest of the input and
    // writes at most 3 characters; so none of this arithmetic overflows.
    cursor &+= 1
    if input.count &- cursor >= 2 {
        let result = CodeUnit.consumeCharacterReference(
            input.extracting(droppingFirst: cursor),
            additionalAllowedCharacter,
            &decoded,
            at: index
        )
        cursor &+= Int(truncatingIfNeeded: result >> 2)
        let length = Int(truncatingIfNeeded: result & 3)
        if length > 0 {
            index += length
            return
        }
    }
    decoded[index] = UInt16(truncatingIfNeeded: ampersand)
    index += 1
}

/// The element whose children are being parsed, as far as the rules for its children go: its tag, whether it is itself
/// in phrasing content, and whether it or an element that contains it is an <a>, or an <li>.
private struct ParentState {
    var tag: FastPathTag
    var inPhrasingContent: Bool
    var insideOfTagA: Bool
    var insideOfTagLi: Bool
}

extension ParentState {
    /// The state of a `context` element, whose children are the fragment's.
    init(context: FastPathTag) {
        self.init(tag: context, inPhrasingContent: false, insideOfTagA: context == .a, insideOfTagLi: context == .li)
    }
}

/// What an open element closes back to: the element that contains it, or nil for the destination parent, and that
/// element's state.
private struct OpenElement {
    let parent: WebCore.HTMLElement?
    let parentState: ParentState
}

/// A run of text the parser scanned, to append as a Text node unless it is empty.
private enum TextRun {
    case empty
    /// '\n' followed by `spaceCount` spaces, at most maximumSharedSpaceCount.
    case sharedWhitespace(spaceCount: Int)
    /// The code units of the input from `start` to `end`.
    case characters(start: Int, end: Int)
    /// The first `count` characters of the decoded characters.
    case decoded(count: Int)
}

/// Where an attribute value is: `length` code units at `offset` of the input, or the first `length` decoded
/// characters if `isDecoded`.
private typealias AttributeValue = (offset: Int, length: Int, isDecoded: Bool)

/// Where the name of an attribute already set on the element being parsed is in the input.
private struct AttributeNameLocation {
    let start: Int
    let length: Int
}

/// The input, the position in it, and whether the parse failed.
///
/// Scans the names of start tags.
private struct InputScanner<CodeUnit: HTMLFastPathCodeUnit>: ~Escapable {
    let input: Span<CodeUnit>
    var position: Int
    var failed = false

    @_lifetime(copy input)
    init(input: Span<CodeUnit>, position: Int) {
        self.input = input
        self.position = position
    }

    /// Scans the name of a start tag among the children of `parent`, and returns its tag and whether the child is in
    /// phrasing content, or nil if `parent` does not permit it.
    @inline(always)
    mutating func scanPermittedChildTagName(of parent: ParentState) -> (tag: FastPathTag, inPhrasingContent: Bool)? {
        // The children the parent takes: those permitted in phrasing content if inPhrasingContent, or else in flow
        // content; or else only expectedTag.
        var inPhrasingContent = false
        var expectedTag: FastPathTag? = nil
        switch parent.tag {
        case .a:
            inPhrasingContent = parent.inPhrasingContent
        case .body, .div, .footer, .li:
            break
        case .b, .button, .i, .label, .p, .span, .strong:
            inPhrasingContent = true
        case .ol, .ul:
            expectedTag = .li
        case .select:
            expectedTag = .option
        case .option, .br, .input:
            // <option> contains only text.
            return nil
        }
        let scannedTag = scanTagName()
        guard !failed, let tag = scannedTag else {
            return nil
        }
        if let expectedTag {
            return tag == expectedTag ? (tag, inPhrasingContent) : nil
        }
        switch tag {
        case .a:
            // <a> must not nest at any depth, because the HTML parser would close the outer one at the inner one.
            if parent.insideOfTagA {
                return nil
            }
        case .li:
            // <li><li></li></li> makes sibling <li>s, so a nested <li> fails unless its parent is an <ol> or <ul>.
            if inPhrasingContent || parent.insideOfTagLi {
                return nil
            }
        default:
            guard tag.isPermitted(inPhrasingContent: inPhrasingContent) else {
                return nil
            }
        }
        return (tag, inPhrasingContent)
    }

    /// Scans a start tag's name, in either case, and the whitespace after it. A name that is not followed by
    /// whitespace, '>' or '/' fails the parse; one that is not a supported tag is nil.
    @inline(always)
    mutating func scanTagName() -> FastPathTag? {
        let input = self.input
        // start <= cursor <= input.count, so none of this arithmetic overflows.
        let start = position
        if input.count - start >= 8 {
            let units = CodeUnit.eightCodeUnits(input, at: start)
            // The top bit of each byte: whether that code unit is not an ASCII letter.
            let notLetters = (0x8080_8080_8080_8080 - asciiLetterBytes(units.lowBytes)) | nonzeroBytes(units.highBytes)
            if notLetters != 0 {
                // Eight times the name's length, at most 56.
                let nameBits = UInt64(truncatingIfNeeded: notLetters.trailingZeroBitCount - 7)
                var cursor = start &+ Int(truncatingIfNeeded: nameBits >> 3)
                if isCharacterAfterTagNameOrAttribute(codeUnit(of: units, at: nameBits)) {
                    skipWhitespace(input, &cursor)
                    position = cursor
                    // 1 << nameBits is at least 1.
                    return tag(named: (units.lowBytes | 0x2020_2020_2020_2020) & ((1 << nameBits) - 1))
                }
                position = cursor
                failed = true
                return nil
            }
        }
        // A name of eight letters or more, or one near the end of the input.
        var cursor = start
        var name: UInt64 = 0
        var length = 0
        var c = unit(input, cursor)
        while isASCIIAlpha(c) {
            if length < 8 {
                name |= UInt64(c | 0x20) << UInt64(truncatingIfNeeded: length &* 8)
            }
            length &+= 1
            cursor &+= 1
            c = unit(input, cursor)
        }
        if isCharacterAfterTagNameOrAttribute(c) {
            skipWhitespace(input, &cursor)
            position = cursor
            return length <= 6 ? tag(named: name) : nil
        }
        position = cursor
        failed = true
        return nil
    }
}

/// Parses the fast path's subset of HTML (HTMLDocumentParserFastPath.cpp) and builds the DOM for it as it goes, in the
/// same order as the C++ parser, so a fragment it fails on leaves the same nodes behind.
///
/// All of its state belongs to one parse, so a parse started by a DOM call during this one does not disturb it.
private struct HTMLFastPathParser<CodeUnit: HTMLFastPathCodeUnit>: ~Copyable, ~Escapable {
    /// The input, the position in it, and whether the parse failed.
    var scanner: InputScanner<CodeUnit>
    let document: WebCore.Document
    let destinationParent: WebCore.ContainerNode
    /// The attributes of the element being parsed, in order and without repeated names, are the first `attributeCount`.
    ///
    /// The slots past them hold an earlier element's, to be overwritten.
    var attributes: [WebCore.Attribute] = []
    /// Where the name of each of `attributes` is in the input.
    var attributeNames: [AttributeNameLocation] = []
    var attributeCount = 0
    /// An attribute name of more than 16 code units with its ASCII upper-case letters lowered.
    var foldedName: [CodeUnit] = []
    /// The characters of the escaped text or attribute value being parsed, from the start.
    var decoded: [UInt16] = []

    @_lifetime(copy input)
    init(input: Span<CodeUnit>, document: WebCore.Document, destinationParent: WebCore.ContainerNode) {
        self.scanner = InputScanner(input: input, position: 0)
        self.document = document
        self.destinationParent = destinationParent
    }

    var input: Span<CodeUnit> {
        @_lifetime(copy self)
        get { scanner.input }
    }

    var position: Int {
        get { scanner.position }
        set { scanner.position = newValue }
    }

    var failed: Bool {
        get { scanner.failed }
        set { scanner.failed = newValue }
    }

    /// Parses the whole input as the children of a `context` element.
    ///
    /// The loop parses the children of the innermost open element, or of destinationParent while no element is open.
    /// The start tag of an element that is not void opens it, and its end tag closes it.
    mutating func parse(_ context: FastPathTag) -> Bool {
        let input = self.input
        var parent = ParentState(context: context)
        // The innermost open element, or nil while none is open.
        var current: WebCore.HTMLElement? = nil
        // An entry for each open element, outermost first: the first ones in openParents and openParentStates, the
        // rest in moreOpenElements. There are openElementCount of them, fewer than maximumElementDepth.
        var openParents = [32 of WebCore.HTMLElement?](repeating: nil)
        // A slot is written when its element opens, so the value they start with is never read.
        var openParentStates = [32 of ParentState](
            repeating: ParentState(tag: .a, inPhrasingContent: false, insideOfTagA: false, insideOfTagLi: false)
        )
        var moreOpenElements: [OpenElement] = []
        var openElementCount = 0
        while true {
            let text = scanText()
            if failed {
                return false
            }
            switch text {
            case .empty:
                break
            case .sharedWhitespace(let spaceCount):
                let textNode = WebCore.Text.create(
                    document,
                    consuming: WebCore.newlineThenWhitespaceStringForFastPath(UInt32(spaceCount))
                )
                append(textNode.get(), to: current)
            case .characters(let start, let end):
                let textNode = WebCore.Text.create(
                    document,
                    consuming: CodeUnit.makeString(input.extracting(start..<end))
                )
                append(textNode.get(), to: current)
            case .decoded(let count):
                let textNode = WebCore.Text.create(document, consuming: WTF.String(decoded.span.extracting(0..<count)))
                append(textNode.get(), to: current)
            }
            if UInt(bitPattern: position) >= UInt(bitPattern: input.count) {
                // The input ends inside an element unless none is open.
                return current == nil
            }
            // At the '<' that ended the text, so position < input.count.
            position += 1
            if unit(input, position) == solidus {
                guard let element = current else {
                    // An end tag with no open element.
                    return false
                }
                // At the '/', so position < input.count.
                position += 1
                guard scanEndTag(parent.tag) else {
                    return false
                }
                element.finishParsingChildren()
                // An element is open, so this does not wrap.
                openElementCount &-= 1
                if openElementCount < openParents.count {
                    var parents = openParents.mutableSpan
                    current = parents[openElementCount].take()
                    let states = openParentStates.mutableSpan
                    parent = states[openElementCount]
                } else {
                    let enclosing = moreOpenElements.removeLast()
                    current = enclosing.parent
                    parent = enclosing.parentState
                }
                continue
            }
            if openElementCount >= maximumElementDepth - 1 {
                return false
            }
            guard let child = scanner.scanPermittedChildTagName(of: parent) else {
                return false
            }
            // Every supported tag is known to the factory.
            // swift-format-ignore: NeverForceUnwrap
            let element = WebCore.HTMLElementFactory.createKnownElement(child.tag.tagName, document, true).get()!
            guard parseAttributes(of: element) else {
                return false
            }
            append(element, to: current)
            element.beginParsingChildren()
            if child.tag.isVoid {
                element.finishParsingChildren()
                continue
            }
            if openElementCount < openParents.count {
                var parents = openParents.mutableSpan
                parents[openElementCount] = current.take()
                var states = openParentStates.mutableSpan
                states[openElementCount] = parent
            } else {
                moreOpenElements.append(OpenElement(parent: current.take(), parentState: parent))
            }
            openElementCount += 1
            current = consume element
            parent = ParentState(
                tag: child.tag,
                inPhrasingContent: child.inPhrasingContent,
                insideOfTagA: parent.insideOfTagA || child.tag == .a,
                insideOfTagLi: parent.insideOfTagLi || child.tag == .li
            )
        }
    }

    /// Appends `child` to `parent`, or to destinationParent if `parent` is nil.
    @inline(always)
    func append(_ child: WebCore.Node, to parent: WebCore.HTMLElement?) {
        if let parent {
            if !parent.isConnected() {
                parent.parserAppendChildIntoIsolatedTree(child)
            } else {
                parent.parserAppendChild(child)
            }
        } else if !destinationParent.isConnected() {
            destinationParent.parserAppendChildIntoIsolatedTree(child)
        } else {
            destinationParent.parserAppendChild(child)
        }
    }

    /// Scans the rest of `tag`'s end tag after its '/': the name, exactly or else with its ASCII letters in either
    /// case, then whitespace and '>'.
    @inline(always)
    mutating func scanEndTag(_ tag: FastPathTag) -> Bool {
        let input = self.input
        let (name, length) = name(of: tag)
        // start <= input.count, and the name has at most 6 letters, so none of this arithmetic overflows.
        let start = position
        var cursor: Int
        if input.count &- start >= 8 {
            // The name and the code unit after it are among the eight code units at start.
            let units = CodeUnit.eightCodeUnits(input, at: start)
            let nameBits = UInt64(truncatingIfNeeded: length) * 8
            // 1 << nameBits is at least 1.
            let nameMask: UInt64 = (1 << nameBits) - 1
            let lowBytes = units.lowBytes & nameMask
            if units.highBytes & nameMask != 0
                || (lowBytes != name && lowBytes | 0x2020_2020_2020_2020 & nameMask != name)
            {
                return false
            }
            if codeUnit(of: units, at: nameBits) == greaterThanSign {
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
                let letter = UInt32(truncatingIfNeeded: name >> UInt64(truncatingIfNeeded: index &* 8)) & 0xff
                if UInt32(endTagName[index]) | 0x20 != letter {
                    return false
                }
                index &+= 1
            }
            cursor = start &+ length
            skipWhitespace(input, &cursor)
        }
        if unit(input, cursor) == greaterThanSign {
            position = cursor + 1
            return true
        }
        position = cursor
        return false
    }

    /// Scans a start tag's attributes up to and including its '>', and sets them on `element`.
    ///
    /// Each name and value is interned with HTMLNameCache, name then value, attribute by attribute, including those of
    /// an attribute whose name repeats an earlier one's, which is dropped.
    @inline(always)
    mutating func parseAttributes(of element: WebCore.HTMLElement) -> Bool {
        let input = self.input
        attributeCount = 0
        var hasDuplicateAttribute = false
        // cursor <= input.count throughout. It advances only past code units read, or within a window of sixteen code
        // units that remain, so none of the arithmetic on it overflows.
        var cursor = position
        // One bit per hash of the length and the first character, with ASCII case ignored, of each name so far.
        // Names that are equal ignoring ASCII case have the same hash.
        var nameHashes: UInt64 = 0
        while true {
            let nameStart = cursor
            var c = unit(input, cursor)
            // No name, at '>': the attributes end. Tested first because most start tags end this way.
            if c == greaterThanSign {
                cursor += 1
                break
            }
            var isFolded = false
            // `window` classifies the sixteen code units at nameStart when that many remain. nameBits is four times
            // the name's length, or 64 if the name runs past the window or there is no window.
            var window = AttributeWindow(nameCharacters: 0, upperCaseLetters: 0, valueDelimiters: 0)
            var nameBits = 64
            if input.count &- nameStart >= 16 {
                window = CodeUnit.attributeWindow(input, at: nameStart)
                nameBits = (~window.nameCharacters).trailingZeroBitCount
            }
            let isInWindow = nameBits < 64
            if isInWindow {
                // 1 << nameBits is at least 1.
                isFolded = window.upperCaseLetters & ((1 << UInt64(truncatingIfNeeded: nameBits)) - 1) != 0
                cursor = nameStart &+ nameBits >> 2
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
                    return false
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
            if nameLength < 1 || startsWithOn(nameStart, nameLength) {
                // No name ends the attributes, at '>' or "/>".
                if c == greaterThanSign {
                    cursor &+= 1
                    break
                }
                if c == solidus {
                    cursor &+= 1
                    skipWhitespace(input, &cursor)
                    if unit(input, cursor) == greaterThanSign {
                        cursor += 1
                        break
                    }
                }
                position = cursor
                failed = true
                return false
            }
            // A hash, which wraps.
            let nameHash = (unit(input, nameStart) | 0x20) &* 3 &+ UInt32(truncatingIfNeeded: nameLength)
            let nameHashBit: UInt64 = 1 << UInt64(nameHash & 63)
            let isDuplicate = nameHashes & nameHashBit != 0 && repeatsAttributeName(nameStart, nameLength)
            nameHashes |= nameHashBit
            var value: AttributeValue = (0, 0, false)
            if isInWindow && c == equalsSign {
                // '=' straight after the name, at a lane of the window, and the value after it.
                cursor &+= 1
                let quote = unit(input, cursor)
                switch quote {
                case quotationMark, apostrophe:
                    let valueStart = cursor + 1
                    // The value's first code unit is at lane nameLength + 2, at most 17. Where the window holds no
                    // delimiter from there, the search goes on after it.
                    let valueLane = nameLength &+ 2
                    var end = valueStart
                    if valueLane < 16 {
                        let delimiters = window.valueDelimiters >> UInt64(truncatingIfNeeded: valueLane &* 4)
                        end = delimiters != 0 ? valueStart &+ delimiters.trailingZeroBitCount >> 2 : nameStart &+ 16
                    }
                    if unit(input, end) == quote {
                        value = (valueStart, end - valueStart, false)
                        cursor = end + 1
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
                        valueLane < 16 ? ~window.nameCharacters >> UInt64(truncatingIfNeeded: valueLane &* 4) : 0
                    if otherCharacters != 0 {
                        let end = cursor &+ otherCharacters.trailingZeroBitCount >> 2
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
            } else {
                skipWhitespace(input, &cursor)
                if unit(input, cursor) == equalsSign {
                    cursor += 1
                    value = scanAttributeValue(&cursor)
                }
            }
            if failed {
                position = cursor
                return parseAttributesAfterFailure(
                    of: element,
                    failedName: AttributeNameLocation(start: nameStart, length: nameLength),
                    isFolded: isFolded,
                    isDuplicate: isDuplicate,
                    hasDuplicateAttribute: hasDuplicateAttribute
                )
            }
            skipWhitespace(input, &cursor)
            let attribute = WebCore.Attribute(
                consuming: makeAttributeName(nameStart, nameLength, isFolded: isFolded),
                consuming: makeAttributeValue(value)
            )
            if isDuplicate {
                hasDuplicateAttribute = true
            } else {
                keepAttribute(consume attribute, AttributeNameLocation(start: nameStart, length: nameLength))
            }
        }
        position = cursor
        element.parserSetAttributes(attributes.span.extracting(0..<attributeCount), .ParserFastPath)
        if hasDuplicateAttribute {
            element.setHasDuplicateAttribute(true)
        }
        return true
    }

    /// Reads the rest of a start tag's attributes, at `position`, after one whose value fails to parse.
    ///
    /// As the C++ parser does, it interns each name and each value it can read, and if the tag then ends, sets the
    /// attributes on `element`, which stays out of the DOM. The attribute whose value failed is `failedName`, with an
    /// empty value. Returns false.
    @inline(never)
    mutating func parseAttributesAfterFailure(
        of element: WebCore.HTMLElement,
        failedName: AttributeNameLocation,
        isFolded: Bool,
        isDuplicate: Bool,
        hasDuplicateAttribute: Bool
    ) -> Bool {
        let input = self.input
        var hasDuplicateAttribute = hasDuplicateAttribute
        var nameLocation = failedName
        var name = makeAttributeName(failedName.start, failedName.length, isFolded: isFolded)
        var value = emptyAttributeValue()
        var isDuplicate = isDuplicate
        // cursor <= input.count throughout, and advances only past code units read, so it does not overflow.
        var cursor = position
        skipWhitespace(input, &cursor)
        while true {
            if isDuplicate {
                hasDuplicateAttribute = true
            } else {
                keepAttribute(WebCore.Attribute(name, value), nameLocation)
            }
            // The next name: lower-case letters, then any other name characters.
            let nameStart = cursor
            var c = unit(input, cursor)
            var isFolded = false
            while isASCIILower(c) {
                cursor &+= 1
                c = unit(input, cursor)
            }
            if UInt(bitPattern: cursor) >= UInt(bitPattern: input.count) {
                return false
            }
            while isAttributeNameCharacter(c) {
                if isASCIIUpper(c) {
                    isFolded = true
                }
                cursor &+= 1
                c = unit(input, cursor)
            }
            let nameLength = cursor &- nameStart
            if nameLength < 1 || startsWithOn(nameStart, nameLength) {
                // No name ends the attributes, at '>' or "/>".
                if c == solidus {
                    cursor &+= 1
                    skipWhitespace(input, &cursor)
                    c = unit(input, cursor)
                }
                if c == greaterThanSign {
                    element.parserSetAttributes(attributes.span.extracting(0..<attributeCount), .ParserFastPath)
                    if hasDuplicateAttribute {
                        element.setHasDuplicateAttribute(true)
                    }
                }
                return false
            }
            nameLocation = AttributeNameLocation(start: nameStart, length: nameLength)
            name = makeAttributeName(nameStart, nameLength, isFolded: isFolded)
            value = emptyAttributeValue()
            skipWhitespace(input, &cursor)
            if unit(input, cursor) == equalsSign {
                cursor += 1
                value = scanAttributeValueAfterFailure(&cursor)
                skipWhitespace(input, &cursor)
            }
            isDuplicate = repeatsAttributeName(nameStart, nameLength)
        }
    }

    /// Scans an attribute value after its equals sign at `cursor` once the parse has failed, as the C++ parser does.
    ///
    /// Returns its atom, or the empty atom for a value that fails or needs decoding. Advances `cursor` past the value,
    /// or just past the opening quote of a quoted value that fails or needs decoding.
    mutating func scanAttributeValueAfterFailure(_ cursor: inout Int) -> WTF.AtomString {
        let input = self.input
        // cursor <= input.count throughout, and advances only past code units read, so it does not overflow.
        skipWhitespace(input, &cursor)
        let start = cursor
        let quote = unit(input, start)
        if quote == quotationMark || quote == apostrophe {
            cursor += 1
            var end = cursor
            scan: while UInt(bitPattern: end) < UInt(bitPattern: input.count) {
                switch UInt32(input[end]) {
                case quote, ampersand, carriageReturn, nullCharacter:
                    break scan
                default:
                    end += 1
                }
            }
            guard unit(input, end) == quote else {
                return emptyAttributeValue()
            }
            let value = makeAttributeValue((cursor, end - cursor, false))
            cursor = end + 1
            return value
        }
        while isAttributeNameCharacter(unit(input, cursor)) {
            cursor &+= 1
        }
        guard isCharacterAfterUnquotedAttributeValue(unit(input, cursor)) else {
            return emptyAttributeValue()
        }
        return makeAttributeValue((start, cursor &- start, false))
    }

    /// Whether the attribute name of `length` code units at `start` is over two characters and starts with "on".
    ///
    /// ASCII case is ignored. The fast path does not set such attributes, likely event handlers, and treats them as no
    /// name.
    @inline(always)
    func startsWithOn(_ start: Int, _ length: Int) -> Bool {
        // length > 2 code units remain at start, so start + 1 < input.count.
        length > 2 && unit(input, start) | 0x20 == 0x6F && unit(input, start + 1) | 0x20 == 0x6E
    }

    /// Whether the attribute name of `length` code units at `start` equals, ignoring ASCII case, the name of one of
    /// the element's attributes so far.
    @inline(never)
    func repeatsAttributeName(_ start: Int, _ length: Int) -> Bool {
        let input = self.input
        let names = attributeNames.span.extracting(0..<attributeCount)
        var i = 0
        while UInt(bitPattern: i) < UInt(bitPattern: names.count) {
            let other = names[i]
            // Both names are in the input, so start + k and other.start + k are below input.count.
            if other.length == length {
                // Attribute names are ASCII letters, digits, '-' and '_', so setting bit 5 folds case and nothing else.
                var k = 0
                while k < length && unit(input, start &+ k) | 0x20 == unit(input, other.start &+ k) | 0x20 {
                    k += 1
                }
                if k >= length {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    /// HTMLNameCache's name for the attribute named by the `length` code units at `start`, lowered first if
    /// `isFolded`.
    @inline(always)
    mutating func makeAttributeName(_ start: Int, _ length: Int, isFolded: Bool) -> WebCore.QualifiedName {
        // The name is in the input, so start + length <= input.count.
        let name = input.extracting(start..<(start &+ length))
        return isFolded ? makeFoldedAttributeName(name) : CodeUnit.makeAttributeQualifiedName(name)
    }

    @inline(never)
    mutating func makeFoldedAttributeName(_ name: Span<CodeUnit>) -> WebCore.QualifiedName {
        if name.count <= 16 {
            var folded = [16 of CodeUnit](repeating: 0)
            var i = 0
            while UInt(bitPattern: i) < UInt(bitPattern: name.count) {
                let c = name[i]
                folded[i] = isASCIIUpper(UInt32(c)) ? c | 0x20 : c
                i += 1
            }
            return CodeUnit.makeAttributeQualifiedName(folded.span.extracting(0..<name.count))
        }
        foldedName.removeAll(keepingCapacity: true)
        var i = 0
        while UInt(bitPattern: i) < UInt(bitPattern: name.count) {
            let c = name[i]
            foldedName.append(isASCIIUpper(UInt32(c)) ? c | 0x20 : c)
            i += 1
        }
        return CodeUnit.makeAttributeQualifiedName(foldedName.span)
    }

    /// HTMLNameCache's atom for `value`.
    @inline(always)
    func makeAttributeValue(_ value: AttributeValue) -> WTF.AtomString {
        if value.isDecoded {
            return WebCore.HTMLNameCache.makeAttributeValue(decoded.span.extracting(0..<value.length))
        }
        // The value is in the input, so offset + length <= input.count.
        return CodeUnit.makeAttributeValue(input.extracting(value.offset..<(value.offset &+ value.length)))
    }

    /// The empty atom.
    ///
    /// The empty slice of the input stands for the empty value, since a Span converted to a std::span must have an
    /// address.
    @inline(always)
    func emptyAttributeValue() -> WTF.AtomString {
        CodeUnit.makeAttributeValue(input.extracting(0..<0))
    }

    /// Adds an attribute to the element's, in the next slot of `attributes`.
    @inline(always)
    mutating func keepAttribute(_ attribute: consuming WebCore.Attribute, _ nameLocation: AttributeNameLocation) {
        let i = attributeCount
        // There are fewer attributes than code units in the input, so i + 1 does not overflow.
        attributeCount = i &+ 1
        if i < attributes.count {
            attributes[i] = attribute
            attributeNames[i] = nameLocation
            return
        }
        if attributes.capacity == 0 {
            // As HTMLToken::AttributeList's inline capacity.
            attributes.reserveCapacity(10)
            attributeNames.reserveCapacity(10)
        }
        attributes.append(attribute)
        attributeNames.append(nameLocation)
    }

    /// Scans an attribute value after its `=` at `cursor`, quoted or not, and advances `cursor` past it.
    ///
    /// Returns where the value is. On failure, `cursor` is where the C++ parser stops.
    @inline(never)
    mutating func scanAttributeValue(_ cursor: inout Int) -> AttributeValue {
        let input = self.input
        skipWhitespace(input, &cursor)
        let start = cursor
        let quote = unit(input, start)
        switch quote {
        case quotationMark, apostrophe:
            break
        default:
            // An unquoted value: name characters up to whitespace or '>'. cursor advances only past code units read.
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
        return scanQuotedAttributeValue(quote, from: start + 1, searchingFrom: start + 1, &cursor)
    }

    /// Scans a value quoted by `quote` that starts at `valueStart`, and advances `cursor` past its closing quote.
    ///
    /// The code units from `valueStart` up to `searchStart` are known not to be delimiters. Returns where the value is.
    /// On failure, `cursor` is where the C++ parser stops: just after the opening quote, or, once the value is being
    /// decoded, at the NUL or the end of the input.
    @inline(never)
    mutating func scanQuotedAttributeValue(
        _ quote: UInt32,
        from valueStart: Int,
        searchingFrom searchStart: Int,
        _ cursor: inout Int
    ) -> AttributeValue {
        let input = self.input
        // valueStart <= end <= input.count, and end advances only past code units read, so none of this overflows.
        var end = searchStart
        scan: while UInt(bitPattern: end) < UInt(bitPattern: input.count) {
            switch UInt32(input[end]) {
            case quote, ampersand, carriageReturn, nullCharacter:
                break scan
            default:
                end += 1
            }
        }
        switch unit(input, end) {
        case quote:
            cursor = end &+ 1
            return (valueStart, end &- valueStart, false)
        case ampersand, carriageReturn:
            break
        default:
            // A NUL, or no closing quote.
            cursor = valueStart
            failed = true
            return (0, 0, false)
        }
        let run = decodeEscapedRun(from: valueStart, terminator: quote, additionalAllowedCharacter: UInt16(truncatingIfNeeded: quote))
        guard run.stop == .terminator else {
            cursor = run.end
            failed = true
            return (0, 0, false)
        }
        // Past the closing quote, read at run.end.
        cursor = run.end &+ 1
        return (0, run.length, true)
    }

    /// Scans a run of text up to the next `<` or the end of the input.
    @inline(always)
    mutating func scanText() -> TextRun {
        let input = self.input
        // start <= cursor <= input.count, and cursor advances only past code units read, so none of this overflows.
        let start = position
        var cursor = start
        // '\n' then only spaces, up to '<' or the end, has no length limit, and up to 32 spaces use
        // NewlineThenWhitespaceStringsTable's string.
        if unit(input, cursor) == newlineCharacter {
            cursor = indexOfNonSpace(input, from: cursor + 1)
            switch unit(input, cursor) {
            case endOfInput, lessThanSign:
                position = cursor
                let spaceCount = cursor &- start &- 1
                if spaceCount <= maximumSharedSpaceCount {
                    return .sharedWhitespace(spaceCount: spaceCount)
                }
                return .characters(start: start, end: cursor)
            default:
                // Not only whitespace: scan the rest as text.
                break
            }
        }
        // A run that is empty, as between most tags, ends at its first code unit without a search.
        if UInt(bitPattern: cursor) < UInt(bitPattern: input.count), !isTextDelimiter(UInt32(input[cursor])) {
            cursor = indexOfTextDelimiter(input, from: cursor + 1)
        }
        switch unit(input, cursor) {
        case nullCharacter:
            position = cursor
            failed = true
            return .empty
        case ampersand, carriageReturn:
            return scanEscapedText(from: start)
        default:
            break
        }
        position = cursor
        // The C++ parser keeps this length as an unsigned, which holds any input's length (at most String::MaxLength).
        let length = cursor &- start
        if length >= Int(WebCore.Text.defaultLengthLimit) {
            failed = true
            return .empty
        }
        return length > 0 ? .characters(start: start, end: cursor) : .empty
    }

    /// Scans a run of text from `start` that has character references or carriage returns, into the decoded
    /// characters.
    @inline(always)
    mutating func scanEscapedText(from start: Int) -> TextRun {
        let run = decodeEscapedRun(from: start, terminator: lessThanSign, additionalAllowedCharacter: 0)
        position = run.end
        if run.stop == .nullCharacter || run.length >= Int(WebCore.Text.defaultLengthLimit) {
            failed = true
            return .empty
        }
        return run.length > 0 ? .decoded(count: run.length) : .empty
    }

    /// Decodes the input from `start` into `decoded`, from its start, up to `terminator`, a NUL or the end of the
    /// input, and returns where and how it stopped and the number of characters decoded. `decoded` grows as needed.
    @inline(never)
    mutating func decodeEscapedRun(
        from start: Int,
        terminator: UInt32,
        additionalAllowedCharacter: UInt16
    ) -> (stop: DecodeStop, end: Int, length: Int) {
        let input = self.input
        var cursor = start
        var index = 0
        if decoded.isEmpty {
            // Room for most runs, so most parses allocate this once.
            decoded = [UInt16](repeating: 0, count: 256)
        }
        while true {
            let stop: DecodeStop
            do {
                var characters = decoded.mutableSpan
                stop = decodeEscapedCharacters(
                    input,
                    from: &cursor,
                    into: &characters,
                    at: &index,
                    terminator: terminator,
                    additionalAllowedCharacter: additionalAllowedCharacter
                )
            }
            if stop != .decodedIsFull {
                return (stop, cursor, index)
            }
            let count = decoded.count
            decoded.append(contentsOf: repeatElement(0, count: count))
        }
    }
}

#endif // USE_SWIFT_HTML_FAST_PATH
