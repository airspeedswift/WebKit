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

#if USE_SWIFT_HTML_TOKENIZER

internal import WebCore_Private.Core.SegmentedString
internal import WebCore_Private.Core.HTMLToken
internal import WebCore_Private.Core.HTMLTokenizer
internal import WebCore_Private.Core.HTMLEntityParser
internal import WebCore_Private.Core.HTMLEntityTable
internal import WebCore_Private.Core.CSSTokenizerInputStream // kEndOfFileMarker
// Operators that WebCore's headers declare use these JavaScriptCore and WTF types. Without their definitions, ==, !,
// << and * do not typecheck in this file.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import wtf.Core.Stopwatch

/// Runs HTMLTokenizer::processToken on `tokenizer` and `source`.
///
/// Tokenizes `source` until the token is complete or `source` runs out. Returns true if the token is ready.
@_expose(Cxx)
func processHTMLTokenizerToken(
    _ tokenizer: inout WebCore.HTMLTokenizer,
    _ source: inout WebCore.SegmentedString,
    _ additionalAllowedCharacter: UInt16
) -> Bool {
    // With no end tag to flush and nothing to read, the preprocessor's peek fails without changing anything.
    if !tokenizer.hasBufferedEndTag && source.isEmpty() {
        return tokenizer.haveBufferedCharacterToken
    }
    return processToken(&tokenizer, &source, additionalAllowedCharacter)
}

/// The body of HTMLTokenizer::processToken.
///
/// It takes the tokenizer as an argument so that processHTMLTokenizerToken saves no registers before its check.
@inline(never)
private func processToken(
    _ tokenizer: inout WebCore.HTMLTokenizer,
    _ source: inout WebCore.SegmentedString,
    _ additionalAllowedCharacter: UInt16
) -> Bool {
    tokenizer.processToken(from: &source, additionalAllowedCharacter: additionalAllowedCharacter)
}

/// HTMLTokenizer::State, in the same order, which HTMLTokenizer::processToken checks with a static_assert.
private enum TokenizerState: UInt32, CaseIterable {
    case data
    case characterReferenceInData
    case rcdata
    case characterReferenceInRCDATA
    case rawtext
    case scriptData
    case plaintext
    case tagOpen
    case endTagOpen
    case tagName
    case rcdataLessThanSign
    case rcdataEndTagOpen
    case rcdataEndTagName
    case rawtextLessThanSign
    case rawtextEndTagOpen
    case rawtextEndTagName
    case scriptDataLessThanSign
    case scriptDataEndTagOpen
    case scriptDataEndTagName
    case scriptDataEscapeStart
    case scriptDataEscapeStartDash
    case scriptDataEscaped
    case scriptDataEscapedDash
    case scriptDataEscapedDashDash
    case scriptDataEscapedLessThanSign
    case scriptDataEscapedEndTagOpen
    case scriptDataEscapedEndTagName
    case scriptDataDoubleEscapeStart
    case scriptDataDoubleEscaped
    case scriptDataDoubleEscapedDash
    case scriptDataDoubleEscapedDashDash
    case scriptDataDoubleEscapedLessThanSign
    case scriptDataDoubleEscapeEnd
    case beforeAttributeName
    case attributeName
    case afterAttributeName
    case beforeAttributeValue
    case attributeValueDoubleQuoted
    case attributeValueSingleQuoted
    case attributeValueUnquoted
    case characterReferenceInAttributeValue
    case afterAttributeValueQuoted
    case selfClosingStartTag
    case processingInstructionOpen
    case processingInstructionTarget
    case afterProcessingInstructionTarget
    case processingInstructionData
    case processingInstructionQuestionMark
    case bogusComment
    case continueBogusComment
    case markupDeclarationOpen
    case commentStart
    case commentStartDash
    case comment
    case commentEndDash
    case commentEnd
    case commentEndBang
    case doctype
    case beforeDOCTYPEName
    case doctypeName
    case afterDOCTYPEName
    case afterDOCTYPEPublicKeyword
    case beforeDOCTYPEPublicIdentifier
    case doctypePublicIdentifierDoubleQuoted
    case doctypePublicIdentifierSingleQuoted
    case afterDOCTYPEPublicIdentifier
    case betweenDOCTYPEPublicAndSystemIdentifiers
    case afterDOCTYPESystemKeyword
    case beforeDOCTYPESystemIdentifier
    case doctypeSystemIdentifierDoubleQuoted
    case doctypeSystemIdentifierSingleQuoted
    case afterDOCTYPESystemIdentifier
    case bogusDOCTYPE
    case cdataSection
    case cdataSectionRightSquareBracket
    case cdataSectionDoubleRightSquareBracket

    var isEndTagBuffering: Bool {
        switch self {
        case .rcdataEndTagOpen, .rcdataEndTagName, .rawtextEndTagOpen, .rawtextEndTagName, .scriptDataEndTagOpen,
            .scriptDataEndTagName, .scriptDataEscapedEndTagOpen, .scriptDataEscapedEndTagName:
            true
        default:
            false
        }
    }
}

private var endOfFileMarker: UInt16 { UInt16(WebCore.kEndOfFileMarker.value) }
private let characterTabulation: UInt16 = 0x09
private let newlineCharacter: UInt16 = 0x0A
private let formFeed: UInt16 = 0x0C
private let carriageReturn: UInt16 = 0x0D
private let space: UInt16 = 0x20
private let exclamationMark: UInt16 = 0x21
private let quotationMark: UInt16 = 0x22
private let ampersand: UInt16 = 0x26
private let apostrophe: UInt16 = 0x27
private let hyphenMinus: UInt16 = 0x2D
private let solidus: UInt16 = 0x2F
private let lessThanSign: UInt16 = 0x3C
private let equalsSign: UInt16 = 0x3D
private let greaterThanSign: UInt16 = 0x3E
private let questionMark: UInt16 = 0x3F
private let leftSquareBracket: UInt16 = 0x5B
private let rightSquareBracket: UInt16 = 0x5D
private let lowLine: UInt16 = 0x5F
private let replacementCharacter: UInt16 = 0xFFFD

// MarkupTokenizerInlines.h's isTokenizerWhitespace, which is not in a module Swift can import.
private func isTokenizerWhitespace(_ character: UInt16) -> Bool {
    character == space || character == newlineCharacter || character == characterTabulation || character == formFeed
}

/// HTMLTokenizer.cpp's isReplacedNullCharacter: whether `character`, the current character of `source` as the input
/// stream preprocessor reads it, is the U+FFFD that it reads for a '\0'.
@inline(always)
private func isReplacedNullCharacter(_ source: inout WebCore.SegmentedString, _ character: UInt16) -> Bool {
    character == replacementCharacter && source.currentCharacter() == 0
}

private func isASCIIAlpha(_ character: UInt16) -> Bool {
    // Wraps on purpose: anything below 'a' becomes too large.
    (character | 0x20) &- 0x61 < 26
}

private func isASCIIAlphanumeric(_ character: UInt16) -> Bool {
    // Wraps on purpose: anything below '0' becomes too large.
    character &- 0x30 < 10 || isASCIIAlpha(character)
}

private func isASCIIUpper(_ character: UInt16) -> Bool {
    // Wraps on purpose: anything below 'A' becomes too large.
    character &- 0x41 < 26
}

private func toASCIILower(_ character: UInt16) -> UInt16 {
    isASCIIUpper(character) ? character | 0x20 : character
}

/// The lowercase form of an ASCII letter.
private func convertASCIIAlphaToLower(_ character: UInt16) -> UInt8 {
    UInt8(truncatingIfNeeded: character | 0x20)
}

// https://html.spec.whatwg.org/multipage/parsing.html#data-state
// In the Data state, '<' switches to TagOpenState, '&' switches to a character
// reference, and '\0' is a parse error. '\r' and '\n' require special handling
// for line counting and newline normalization in the input stream preprocessor.
// Everything else is plain text that can be emitted as-is.
private func isDataStateSpecialCharacter(_ character: UInt8) -> Bool {
    character == 0x3C || character == 0x26 || character == 0x0D || character == 0x0A || character == 0
}

// https://html.spec.whatwg.org/multipage/parsing.html#attribute-value-(double-quoted)-state
// https://html.spec.whatwg.org/multipage/parsing.html#attribute-value-(single-quoted)-state
// In quoted attribute value states, the closing quote ends the value, '&' starts
// a character reference, and '\0' is a parse error. '\r' and '\n' require special
// handling for line counting and newline normalization. Everything else is plain
// text that can be appended to the attribute value as-is.
private func isQuotedAttributeValueSpecialCharacter(_ character: UInt8, quote: UInt8) -> Bool {
    character == quote || character == 0x26 || character == 0x0D || character == 0x0A || character == 0
}

// In the RAWTEXT and script data states, '<' may start an end tag and '\0' is a parse error. '\r' and '\n' require
// special handling for line counting and newline normalization. Everything else is plain text. The RCDATA state also
// stops at '&', as the data state does.
private func isRawTextSpecialCharacter(_ character: UInt8) -> Bool {
    character == 0x3C || character == 0x0D || character == 0x0A || character == 0
}

// The script data escaped and double escaped states also stop at '-', which may end the escape.
private func isScriptDataEscapedSpecialCharacter(_ character: UInt8) -> Bool {
    character == 0x2D || isRawTextSpecialCharacter(character)
}

// https://html.spec.whatwg.org/multipage/parsing.html#attribute-value-(unquoted)-state
// In the unquoted attribute value state, whitespace and '>' end the value, '&' starts a character reference, and '\0'
// is a parse error. '\r' requires special handling for newline normalization. Everything else, including the parse
// errors '"', '\'', '<', '=' and '`', is plain text that can be appended to the attribute value as-is.
private func isAttributeValueUnquotedSpecialCharacter(_ character: UInt8) -> Bool {
    isTokenizerWhitespace(UInt16(character)) || character == 0x26 || character == 0x3E || character == 0x0D || character == 0
}

// https://html.spec.whatwg.org/multipage/parsing.html#attribute-name-state
// In the attribute name state, whitespace, '/', '=' and '>' end the name, and so does '<' with the pre-HTML5 parser
// quirks. '\0' is a parse error or the end of the input, and '\r' requires special handling for newline normalization.
// Everything else, including the parse errors '"' and '\'', is appended to the name, lowercased if an ASCII letter.
// '<' is special here with or without the quirks, so that the state decides.
private func isAttributeNameSpecialCharacter(_ character: UInt8) -> Bool {
    isTokenizerWhitespace(UInt16(character)) || character == 0x2F || character == 0x3D || character == 0x3E
        || character == 0x3C || character == 0x0D || character == 0
}

// In the comment, bogus comment, CDATA section and DOCTYPE identifier states, '\0' is a parse error or the end of the
// input, and '\r' and '\n' require special handling for line counting and newline normalization. Each state also stops
// at the characters that can end it: '-' in a comment, '>' in a bogus comment, ']' in a CDATA section, and the quote
// and '>' in a DOCTYPE identifier.
private func isNewlineOrNullCharacter(_ character: UInt8) -> Bool {
    character == 0x0D || character == 0x0A || character == 0
}

private func isCommentSpecialCharacter(_ character: UInt8) -> Bool {
    character == 0x2D || isNewlineOrNullCharacter(character)
}

private func isBogusCommentSpecialCharacter(_ character: UInt8) -> Bool {
    character == 0x3E || isNewlineOrNullCharacter(character)
}

private func isCDATASectionSpecialCharacter(_ character: UInt8) -> Bool {
    character == 0x5D || isNewlineOrNullCharacter(character)
}

private func isDOCTYPEIdentifierSpecialCharacter(_ character: UInt8, quote: UInt8) -> Bool {
    character == quote || character == 0x3E || isNewlineOrNullCharacter(character)
}

// The characters that end a run in plainTextLength, each in the lane its low four bits select, for tableMatchNibbles.
// The other lanes hold values that no character matches.

/// isDataStateSpecialCharacter as a table.
///
/// NUL, '&', '\n', '<' and '\r'. Also the characters that end a run in RCDATA.
private var dataStateSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x26, 0xFF, 0xFF, 0xFF, 0x0A, 0xFF, 0x3C, 0x0D, 0xFF, 0x00)
}

/// isQuotedAttributeValueSpecialCharacter with '"': NUL, '"', '&', '\n' and '\r'.
private var doubleQuotedAttributeValueSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0x22, 0xFF, 0xFF, 0xFF, 0x26, 0xFF, 0xFF, 0xFF, 0x0A, 0xFF, 0xFF, 0x0D, 0xFF, 0x00)
}

/// isQuotedAttributeValueSpecialCharacter with '\'': NUL, '&', '\'', '\n' and '\r'.
private var singleQuotedAttributeValueSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x26, 0x27, 0xFF, 0xFF, 0x0A, 0xFF, 0xFF, 0x0D, 0xFF, 0x00)
}

/// isRawTextSpecialCharacter: NUL, '\n', '<' and '\r'.
private var rawTextSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0A, 0xFF, 0x3C, 0x0D, 0xFF, 0x00)
}

/// A hyphen-minus, whose low four bits are those of a carriage return.
///
/// With rawTextSpecialCharacters, for isScriptDataEscapedSpecialCharacter.
private var hyphenMinusCharacter: SIMD16<UInt8> {
    SIMD16(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x2D, 0xFF, 0x00)
}

/// isAttributeValueUnquotedSpecialCharacter but ' ': NUL, '\t', '\n', '\f', '\r', '&' and '>'.
private var unquotedAttributeValueSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x26, 0xFF, 0xFF, 0x09, 0x0A, 0xFF, 0x0C, 0x0D, 0x3E, 0x00)
}

/// The space character, whose low four bits are those of NUL.
///
/// With unquotedAttributeValueSpecialCharacters, for isAttributeValueUnquotedSpecialCharacter.
private var spaceCharacter: SIMD16<UInt8> {
    SIMD16(0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)
}

/// isAttributeNameSpecialCharacter without the space, less-than sign and equals sign.
///
/// NUL, '\t', '\n', '\f', '\r', '>' and '/'.
private var attributeNameSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x09, 0x0A, 0xFF, 0x0C, 0x0D, 0x3E, 0x2F)
}

/// The space, less-than sign and equals sign, whose low four bits are those of NUL, form feed and carriage return.
///
/// With attributeNameSpecialCharacters, for isAttributeNameSpecialCharacter.
private var attributeNameAdditionalSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x3C, 0x3D, 0xFF, 0x00)
}

/// isNewlineOrNullCharacter as a table.
///
/// NUL, '\n' and '\r'. With hyphenMinusCharacter, isCommentSpecialCharacter; with rightSquareBracketCharacter,
/// isCDATASectionSpecialCharacter.
private var newlineAndNullCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0A, 0xFF, 0xFF, 0x0D, 0xFF, 0x00)
}

/// isBogusCommentSpecialCharacter: NUL, '\n', '\r' and '>'.
private var bogusCommentSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0A, 0xFF, 0xFF, 0x0D, 0x3E, 0x00)
}

/// isDOCTYPEIdentifierSpecialCharacter with '"': NUL, '"', '\n', '\r' and '>'.
private var doubleQuotedDOCTYPEIdentifierSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0x22, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0A, 0xFF, 0xFF, 0x0D, 0x3E, 0x00)
}

/// isDOCTYPEIdentifierSpecialCharacter with '\'': NUL, '\'', '\n', '\r' and '>'.
private var singleQuotedDOCTYPEIdentifierSpecialCharacters: SIMD16<UInt8> {
    SIMD16(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x27, 0xFF, 0xFF, 0x0A, 0xFF, 0xFF, 0x0D, 0x3E, 0x00)
}

/// A right square bracket, whose low four bits are those of a carriage return.
///
/// With newlineAndNullCharacters, for isCDATASectionSpecialCharacter.
private var rightSquareBracketCharacter: SIMD16<UInt8> {
    SIMD16(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x5D, 0xFF, 0x00)
}

/// The second table that a run also ends at, for characters whose low four bits are those of a special character.
///
/// None, '-', ' ', ']', or the ' ', '<' and '=' of an attribute name.
private enum AdditionalSpecialCharacters {
    case none
    case hyphenMinus
    case space
    case rightSquareBracket
    case attributeName

    @inline(always)
    var table: SIMD16<UInt8>? {
        switch self {
        case .none: nil
        case .hyphenMinus: hyphenMinusCharacter
        case .space: spaceCharacter
        case .rightSquareBracket: rightSquareBracketCharacter
        case .attributeName: attributeNameAdditionalSpecialCharacters
        }
    }
}

/// A code unit of a SegmentedString substring, as plainTextLength reads it.
private protocol PlainTextCodeUnit: FixedWidthInteger, UnsignedInteger {
    /// tableMatchNibbles of code units `offset` to `offset + 15` of `characters` against `specialCharacters`, and
    /// against `additionalSpecialCharacters`. A code unit above 0xFF matches neither.
    static func specialCharacterMatches(
        _ characters: Span<Self>,
        at offset: Int,
        _ specialCharacters: SIMD16<UInt8>,
        or additionalSpecialCharacters: AdditionalSpecialCharacters
    ) -> UInt64
}

extension UInt8: PlainTextCodeUnit {
    @inline(always)
    fileprivate static func specialCharacterMatches(
        _ characters: Span<UInt8>,
        at offset: Int,
        _ specialCharacters: SIMD16<UInt8>,
        or additionalSpecialCharacters: AdditionalSpecialCharacters
    ) -> UInt64 {
        let block = load16(characters, at: offset)
        let matches = tableMatchNibbles(lowBytes: block, highBytes: SIMD16(), specialCharacters)
        guard let table = additionalSpecialCharacters.table else {
            return matches
        }
        return matches | tableMatchNibbles(lowBytes: block, highBytes: SIMD16(), table)
    }
}

extension UInt16: PlainTextCodeUnit {
    @inline(always)
    fileprivate static func specialCharacterMatches(
        _ characters: Span<UInt16>,
        at offset: Int,
        _ specialCharacters: SIMD16<UInt8>,
        or additionalSpecialCharacters: AdditionalSpecialCharacters
    ) -> UInt64 {
        let matches = matchNibbles(characters, at: offset, specialCharacters)
        guard let table = additionalSpecialCharacters.table else {
            return matches
        }
        return matches | matchNibbles(characters, at: offset, table)
    }
}

/// The length of the run of characters that `isPlain` accepts in `characters`, a SegmentedString's current substring.
///
/// The run starts after the current character and ends before the substring's last character, which
/// advancePastMultiple8 and advancePastMultiple16 need to remain. It is empty if the substring is too short, or after
/// a '\r', whose '\n' the preprocessor has yet to check for. Characters above 0xFF are plain. `specialCharacters` and
/// `additionalSpecialCharacters` are the characters `isPlain` rejects.
@inline(always)
private func plainTextLength<CodeUnit: PlainTextCodeUnit>(
    in characters: Span<CodeUnit>,
    _ skipNextNewLine: Bool,
    _ specialCharacters: SIMD16<UInt8>,
    or additionalSpecialCharacters: AdditionalSpecialCharacters = .none,
    while isPlain: (UInt8) -> Bool
) -> Int {
    guard characters.count > 2 && !skipNextNewLine else {
        return 0
    }
    // A run often ends at once, at the character after the current one: test it before the scan.
    if characters[1] <= 0xFF && !isPlain(UInt8(truncatingIfNeeded: characters[1])) {
        return 0
    }
    let end = characters.count - 1
    guard end > 16 else {
        var index = 1
        while index < end && (characters[index] > 0xFF || isPlain(UInt8(truncatingIfNeeded: characters[index]))) {
            index += 1
        }
        return index - 1
    }
    let firstMatches = CodeUnit.specialCharacterMatches(characters, at: 1, specialCharacters, or: additionalSpecialCharacters)
    if firstMatches != 0 {
        return firstMatches.trailingZeroBitCount / 4
    }
    if end - 17 >= 16 {
        let remainder = characters.extracting(17..<end)
        let offset =
            switch additionalSpecialCharacters {
            case .none: firstSpecialCharacterOffset(in: remainder, specialCharacters)
            case .hyphenMinus: firstSpecialCharacterOrHyphenMinusOffset(in: remainder, specialCharacters)
            case .space: firstSpecialCharacterOrSpaceOffset(in: remainder, specialCharacters)
            case .rightSquareBracket: firstSpecialCharacterOrRightSquareBracketOffset(in: remainder, specialCharacters)
            case .attributeName: firstAttributeNameSpecialCharacterOffset(in: remainder, specialCharacters)
            }
        // Cannot overflow: the offset is at most the count of `remainder`.
        return 16 &+ offset
    }
    // The last sixteen characters, overlapping the first sixteen, which have no match.
    let lastBlock = end - 16
    let lastMatches = CodeUnit.specialCharacterMatches(characters, at: lastBlock, specialCharacters, or: additionalSpecialCharacters)
    if lastMatches != 0 {
        return lastBlock - 1 + lastMatches.trailingZeroBitCount / 4
    }
    return end - 1
}

/// The offset of the first character of `characters` that the tables match, or its count if none does.
///
/// Reads sixteen characters at a time with tableMatchNibbles; `characters` has at least sixteen.
@inline(always)
private func firstMatchOffset<CodeUnit: PlainTextCodeUnit>(
    in characters: Span<CodeUnit>,
    _ specialCharacters: SIMD16<UInt8>,
    or additionalSpecialCharacters: AdditionalSpecialCharacters
) -> Int {
    @inline(always)
    func matches(at offset: Int) -> UInt64 {
        CodeUnit.specialCharacterMatches(characters, at: offset, specialCharacters, or: additionalSpecialCharacters)
    }

    let lastBlock = characters.count - 16
    var offset = 0
    while offset < lastBlock {
        let blockMatches = matches(at: offset)
        if blockMatches != 0 {
            return offset + blockMatches.trailingZeroBitCount / 4
        }
        offset += 16
    }
    // The last sixteen characters, overlapping the block before when the count is not a multiple of sixteen.
    let blockMatches = matches(at: lastBlock)
    if blockMatches != 0 {
        return lastBlock + blockMatches.trailingZeroBitCount / 4
    }
    return characters.count
}

/// firstMatchOffset with no second table.
@inline(never)
private func firstSpecialCharacterOffset<CodeUnit: PlainTextCodeUnit>(
    in characters: Span<CodeUnit>,
    _ specialCharacters: SIMD16<UInt8>
) -> Int {
    firstMatchOffset(in: characters, specialCharacters, or: .none)
}

/// firstMatchOffset with the hyphen-minus table.
@inline(never)
private func firstSpecialCharacterOrHyphenMinusOffset<CodeUnit: PlainTextCodeUnit>(
    in characters: Span<CodeUnit>,
    _ specialCharacters: SIMD16<UInt8>
) -> Int {
    firstMatchOffset(in: characters, specialCharacters, or: .hyphenMinus)
}

/// firstMatchOffset with the space table.
@inline(never)
private func firstSpecialCharacterOrSpaceOffset<CodeUnit: PlainTextCodeUnit>(
    in characters: Span<CodeUnit>,
    _ specialCharacters: SIMD16<UInt8>
) -> Int {
    firstMatchOffset(in: characters, specialCharacters, or: .space)
}

/// firstMatchOffset with the right square bracket table.
@inline(never)
private func firstSpecialCharacterOrRightSquareBracketOffset<CodeUnit: PlainTextCodeUnit>(
    in characters: Span<CodeUnit>,
    _ specialCharacters: SIMD16<UInt8>
) -> Int {
    firstMatchOffset(in: characters, specialCharacters, or: .rightSquareBracket)
}

/// firstMatchOffset with the attribute name's second table.
@inline(never)
private func firstAttributeNameSpecialCharacterOffset<CodeUnit: PlainTextCodeUnit>(
    in characters: Span<CodeUnit>,
    _ specialCharacters: SIMD16<UInt8>
) -> Int {
    firstMatchOffset(in: characters, specialCharacters, or: .attributeName)
}

/// The number of ASCII letters at the start of `characters`, the current substring of a SegmentedString, whose first
/// character is a letter; 0 if the letters reach its last character, or it is empty.
private func endTagNameLength(in characters: Span<UInt8>) -> Int {
    for index in 1..<max(characters.count, 1) where !isASCIIAlpha(UInt16(characters[index])) {
        return index
    }
    return 0
}

/// What consumeEndTagName found after the start of an end tag and a letter.
private enum EndTagNameResult {
    /// The name or the character after it is not in the current 8-bit substring; nothing was consumed.
    case notInCurrentSubstring
    /// Not an appropriate end tag: "</" and the name were buffered as characters.
    case notAppropriateEndTag
    /// An appropriate end tag, if the character after the name ends it: the name is in the temporary buffer and the
    /// buffered end tag name.
    case possibleAppropriateEndTag
}

/// What appendPlainText appends a run to.
private enum PlainTextDestination {
    case characters
    case attributeValue
    case attributeName
    case comment
    case publicIdentifier
    case systemIdentifier
}

private enum AdvancePastResult {
    case didNotMatch
    case didMatch
    case notEnoughCharacters
}

/// SegmentedString::advancePast and advancePastLettersIgnoringASCIICase.
///
/// Consumes `literal` if `source` starts with it, ignoring the case of letters if `ignoringCase` is true. The literal
/// has no '\n'.
private func advancePast<let length: Int>(
    _ literal: [length of UInt8],
    ignoringCase: Bool,
    in source: inout WebCore.SegmentedString
) -> AdvancePastResult {
    func mismatch(_ character: UInt16, _ literalCharacter: UInt8) -> Bool {
        ignoringCase ? (character | 0x20) != UInt16(literalCharacter) : character != UInt16(literalCharacter)
    }

    // Whether the current substring starts with the literal, when it is 8-bit and longer than the literal plus one
    // character.
    let matchesCurrentSubstring: Bool? = {
        let characters: Span<UInt8> = source.currentSubstringBytes8()
        guard length + 1 < characters.count else {
            return nil
        }
        for index in 0..<length where mismatch(UInt16(characters[index]), literal[index]) {
            return false
        }
        return true
    }()
    if let matchesCurrentSubstring {
        guard matchesCurrentSubstring else {
            return .didNotMatch
        }
        source.advancePastMultiple(UInt32(truncatingIfNeeded: length))
        return .didMatch
    }

    if length > Int(source.length()) {
        return .notEnoughCharacters
    }
    var consumedCharacters = InlineArray<length, UInt16>(repeating: 0)
    for index in 0..<length {
        let character = source.currentCharacter()
        if mismatch(character, literal[index]) {
            if index > 0 {
                let consumed: Span<UInt16> = consumedCharacters.span.extracting(0..<index)
                source.pushBack(consuming: WTF.String(consumed))
            }
            return .didNotMatch
        }
        source.advancePastNonNewline()
        consumedCharacters[index] = character
    }
    return .didMatch
}

// HTMLTokenizer.h gives this file access to the tokenizer's private members, inside extensions of it.
extension WebCore.HTMLTokenizer {
    fileprivate var haveBufferedCharacterToken: Bool {
        m_token.type() == .Character
    }

    fileprivate var hasBufferedEndTag: Bool {
        !m_bufferedEndTagName.isEmpty()
    }

    private func shouldSkipNullCharacters(_ state: TokenizerState) -> Bool {
        state == .data && !m_forceNullCharacterReplacement
    }

    // The three ways to move to the next state: advance past the current character, advance past it knowing it is
    // not a newline, or stay at the current character of the source after consuming characters some other way. Each
    // sets `state` and reads the next character into `character`, and returns false if the source has run out.

    @inline(always)
    private mutating func advance(
        to newState: TokenizerState,
        _ state: inout TokenizerState,
        _ character: inout UInt16,
        _ source: inout WebCore.SegmentedString
    ) -> Bool {
        state = newState
        guard m_preprocessor.advance(&source, shouldSkipNullCharacters(newState)) else {
            return false
        }
        character = m_preprocessor.nextInputCharacter()
        return true
    }

    @inline(always)
    private mutating func advancePastNonNewline(
        to newState: TokenizerState,
        _ state: inout TokenizerState,
        _ character: inout UInt16,
        _ source: inout WebCore.SegmentedString
    ) -> Bool {
        state = newState
        guard m_preprocessor.advancePastNonNewline(&source, shouldSkipNullCharacters(newState)) else {
            return false
        }
        character = m_preprocessor.nextInputCharacter()
        return true
    }

    @inline(always)
    private mutating func switchTo(
        _ newState: TokenizerState,
        _ state: inout TokenizerState,
        _ character: inout UInt16,
        _ source: inout WebCore.SegmentedString
    ) -> Bool {
        state = newState
        guard m_preprocessor.peek(&source, shouldSkipNullCharacters(newState)) else {
            return false
        }
        character = m_preprocessor.nextInputCharacter()
        return true
    }

    @inline(always)
    private mutating func bufferASCIICharacter(_ character: UInt16) {
        m_token.appendToCharacter(WTF.Latin1Character(character))
    }

    private mutating func bufferCharacter(_ character: UInt16) {
        m_token.appendToCharacter(character)
    }

    /// Appends the run of characters after the current one that plainTextLength finds to `destination`.
    ///
    /// Advances past the current character, already appended, and the run. Returns false, consuming nothing, if there
    /// is no run.
    /// If `continuesAcrossNewlines`, the state appends a '\n' as it does a plain character and stays in the same
    /// state, so a run that ends at a '\n' goes on with the '\n' and the run after it, while there is one.
    @inline(always)
    private mutating func appendPlainText(
        _ source: inout WebCore.SegmentedString,
        to destination: PlainTextDestination,
        _ specialCharacters: SIMD16<UInt8>,
        or additionalSpecialCharacters: AdditionalSpecialCharacters = .none,
        continuesAcrossNewlines: Bool = true,
        while isPlain: (UInt8) -> Bool
    ) -> Bool {
        let skipNextNewLine = m_preprocessor.skipNextNewLine()
        let is8Bit: Bool
        let length: Int
        do {
            let characters: Span<UInt8> = source.currentSubstringBytes8()
            is8Bit = !characters.isEmpty
            length = plainTextLength(in: characters, skipNextNewLine, specialCharacters, or: additionalSpecialCharacters, while: isPlain)
        }
        if is8Bit {
            guard length > 0 else {
                return false
            }
            do {
                let characters: Span<UInt8> = source.currentSubstringBytes8()
                append(characters.extracting(1..<length + 1), to: destination)
            }
            // +1 to also advance past the current character.
            source.advancePastMultiple(UInt32(truncatingIfNeeded: length + 1))
            // Each run after a '\n' starts at the '\n', so that advancePastMultiple8 starts a new line as advance
            // would. The character before the '\n' was plain, so there is no '\r' to skip a '\n' after.
            while continuesAcrossNewlines {
                var runLength = 0
                do {
                    let characters: Span<UInt8> = source.currentSubstringBytes8()
                    // plainTextLength returns 0 for fewer than three characters.
                    if !characters.isEmpty, UInt16(characters[0]) == newlineCharacter {
                        runLength = plainTextLength(
                            in: characters,
                            false,
                            specialCharacters,
                            or: additionalSpecialCharacters,
                            while: isPlain
                        )
                        if runLength > 0 {
                            append(characters.extracting(0..<runLength + 1), to: destination)
                        }
                    }
                }
                guard runLength > 0 else {
                    break
                }
                // +1 for the '\n'.
                source.advancePastMultiple(UInt32(truncatingIfNeeded: runLength + 1))
            }
            return true
        }
        let length16: Int
        do {
            let characters: Span<UInt16> = source.currentSubstringSpan16()
            length16 = plainTextLength(in: characters, skipNextNewLine, specialCharacters, or: additionalSpecialCharacters, while: isPlain)
        }
        guard length16 > 0 else {
            return false
        }
        do {
            let characters: Span<UInt16> = source.currentSubstringSpan16()
            append(characters.extracting(1..<length16 + 1), to: destination)
        }
        source.advancePastMultiple(UInt32(truncatingIfNeeded: length16 + 1))
        // As above; advancePastMultiple16 starts the new line as advance does for a 16-bit substring.
        while continuesAcrossNewlines {
            var runLength = 0
            do {
                let characters: Span<UInt16> = source.currentSubstringSpan16()
                // plainTextLength returns 0 for fewer than three characters.
                if !characters.isEmpty, characters[0] == newlineCharacter {
                    runLength = plainTextLength(in: characters, false, specialCharacters, or: additionalSpecialCharacters, while: isPlain)
                    if runLength > 0 {
                        append(characters.extracting(0..<runLength + 1), to: destination)
                    }
                }
            }
            guard runLength > 0 else {
                break
            }
            // +1 for the '\n'.
            source.advancePastMultiple(UInt32(truncatingIfNeeded: runLength + 1))
        }
        return true
    }

    /// Appends `characters` to `destination` as the state appending them one at a time would.
    @inline(always)
    private mutating func append(_ characters: Span<UInt8>, to destination: PlainTextDestination) {
        switch destination {
        case .characters:
            m_token.appendToCharacter(WTF.latin1CharactersOfBytes(characters))
        case .attributeValue:
            m_token.appendToAttributeValue(WTF.latin1CharactersOfBytes(characters))
        case .attributeName:
            for index in characters.indices {
                m_token.appendToAttributeName(toASCIILower(UInt16(characters[index])))
            }
        case .comment:
            for index in characters.indices {
                m_token.appendToComment(UInt16(characters[index]))
            }
        case .publicIdentifier:
            for index in characters.indices {
                m_token.appendToPublicIdentifier(UInt16(characters[index]))
            }
        case .systemIdentifier:
            for index in characters.indices {
                m_token.appendToSystemIdentifier(UInt16(characters[index]))
            }
        }
    }

    @inline(always)
    private mutating func append(_ characters: Span<UInt16>, to destination: PlainTextDestination) {
        switch destination {
        case .characters:
            m_token.appendToCharacter(characters)
        case .attributeValue:
            m_token.appendToAttributeValue(characters)
        case .attributeName:
            for index in characters.indices {
                m_token.appendToAttributeName(toASCIILower(characters[index]))
            }
        case .comment:
            for index in characters.indices {
                m_token.appendToComment(characters[index])
            }
        case .publicIdentifier:
            for index in characters.indices {
                m_token.appendToPublicIdentifier(characters[index])
            }
        case .systemIdentifier:
            for index in characters.indices {
                m_token.appendToSystemIdentifier(characters[index])
            }
        }
    }

    /// appendPlainText to the character token.
    @inline(always)
    private mutating func bufferPlainText(
        _ source: inout WebCore.SegmentedString,
        _ specialCharacters: SIMD16<UInt8>,
        or additionalSpecialCharacters: AdditionalSpecialCharacters = .none,
        while isPlain: (UInt8) -> Bool
    ) -> Bool {
        appendPlainText(&source, to: .characters, specialCharacters, or: additionalSpecialCharacters, while: isPlain)
    }

    /// appendPlainText to the current attribute's value.
    @inline(always)
    private mutating func appendPlainTextToAttributeValue(
        _ source: inout WebCore.SegmentedString,
        _ specialCharacters: SIMD16<UInt8>,
        or additionalSpecialCharacters: AdditionalSpecialCharacters = .none,
        continuesAcrossNewlines: Bool = true,
        while isPlain: (UInt8) -> Bool
    ) -> Bool {
        appendPlainText(
            &source,
            to: .attributeValue,
            specialCharacters,
            or: additionalSpecialCharacters,
            continuesAcrossNewlines: continuesAcrossNewlines,
            while: isPlain
        )
    }

    /// Buffers a less-than sign and a solidus.
    @inline(always)
    private mutating func bufferLessThanSignSolidus() {
        m_token.appendToCharacter(WTF.Latin1Character(lessThanSign))
        m_token.appendToCharacter(WTF.Latin1Character(solidus))
    }

    // The helpers that end a token leave setting the state to their caller, which keeps it in a local.

    private mutating func emitAndResumeInDataState(_ source: inout WebCore.SegmentedString) -> Bool {
        source.advancePastNonNewline()
        return true
    }

    /// Emits the processing instruction, whose '>' is the current character.
    private mutating func emitProcessingInstruction(_ source: inout WebCore.SegmentedString) -> Bool {
        source.advancePastNonNewline()
        return true
    }

    /// Emits the U+FFFD that replaced a '\0' as a character token of its own, after the characters already buffered.
    private mutating func emitReplacedNullCharacter(_ source: inout WebCore.SegmentedString) -> Bool {
        if haveBufferedCharacterToken {
            return true
        }
        m_token.makeReplacedNullCharacter()
        source.advancePastNonNewline()
        return true
    }

    /// Turns the processing instruction being tokenized back into the bogus comment that this input produced before
    /// processing instructions were parsed, from the target characters already collected in the token.
    private mutating func rewindToBogusCommentForProcessingInstructionTarget() {
        var target: [UInt8] = []
        do {
            let characters: Span<WTF.Latin1Character> = m_token.processingInstructionTargetCharacters()
            target.reserveCapacity(characters.count)
            for index in characters.indices {
                target.append(characters[index].value)
            }
        }
        m_token.clear()
        m_token.beginComment()
        m_token.appendToComment(CChar(questionMark))
        // The target is ASCII, so appending it a character at a time makes the same comment as appending it at once.
        for character in target {
            m_token.appendToComment(CChar(truncatingIfNeeded: character))
        }
    }

    /// Whether the processing instruction's target is "xml" or "xml-stylesheet", ignoring ASCII case.
    private func processingInstructionTargetIsXMLDeclaration() -> Bool {
        let target: Span<WTF.Latin1Character> = m_token.processingInstructionTargetCharacters()
        let xmlStylesheet: [14 of UInt8] = [0x78, 0x6D, 0x6C, 0x2D, 0x73, 0x74, 0x79, 0x6C, 0x65, 0x73, 0x68, 0x65, 0x65, 0x74]
        guard target.count == 3 || target.count == 14 else {
            return false
        }
        // As equalLettersIgnoringASCIICase, which compares each character with its 0x20 bit set.
        for index in target.indices where target[index].value | 0x20 != xmlStylesheet[index] {
            return false
        }
        return true
    }

    private mutating func emitEndOfFile(_ source: inout WebCore.SegmentedString) -> Bool {
        if haveBufferedCharacterToken {
            return true
        }
        source.advance()
        m_token.clear()
        m_token.makeEndOfFile()
        return true
    }

    /// Returns false if the source ran out before the character reference could be decided.
    private mutating func processEntity(_ source: inout WebCore.SegmentedString) -> Bool {
        let decodedEntity = consumeHTMLEntity(&source)
        if decodedEntity.notEnoughCharacters() {
            return false
        }
        if decodedEntity.failed() {
            bufferASCIICharacter(ampersand)
        } else {
            let characters: Span<UInt16> = decodedEntity.span()
            for index in characters.indices {
                bufferCharacter(characters[index])
            }
        }
        return true
    }

    private mutating func flushBufferedEndTag() {
        m_token.beginEndTag(m_bufferedEndTagName)
        m_bufferedEndTagName.clear()
        m_appropriateEndTagName.clear()
        m_temporaryBuffer.clear()
    }

    /// Returns true, leaving the end tag buffered, if a character token is to be emitted first.
    private mutating func commitToPartialEndTag(_ source: inout WebCore.SegmentedString, _ character: UInt16) -> Bool {
        appendToTemporaryBuffer(character)
        source.advance()

        if haveBufferedCharacterToken {
            // Emit the buffered character token.
            // The next call to processToken will flush the buffered end tag and continue parsing it.
            return true
        }

        flushBufferedEndTag()
        return false
    }

    private mutating func commitToCompleteEndTag(_ source: inout WebCore.SegmentedString) -> Bool {
        appendToTemporaryBuffer(greaterThanSign)
        source.advancePastNonNewline()

        if haveBufferedCharacterToken {
            // Emit the character token we already have.
            // The next call to processToken will flush the buffered end tag and emit it.
            return true
        }

        flushBufferedEndTag()
        return true
    }

    /// Emits the less-than sign, solidus and temporary buffer as characters, after a possible end tag that was not one.
    private mutating func flushTemporaryBufferAsCharacters() {
        bufferLessThanSignSolidus()
        m_token.appendToCharacter(m_temporaryBuffer)
        m_bufferedEndTagName.clear()
        m_temporaryBuffer.clear()
    }

    private mutating func appendToTemporaryBuffer(_ character: UInt16) {
        m_temporaryBuffer.append(consuming: WTF.Latin1Character(character))
    }

    private func temporaryBufferIsScript() -> Bool {
        let script: [6 of UInt8] = [0x73, 0x63, 0x72, 0x69, 0x70, 0x74]
        guard m_temporaryBuffer.size() == 6 else {
            return false
        }
        for index in 0..<6 where m_temporaryBuffer[index].value != script[index] {
            return false
        }
        return true
    }

    private mutating func appendToPossibleEndTag(_ character: UInt8) {
        m_bufferedEndTagName.append(consuming: WTF.Latin1Character(character))
    }

    private func isAppropriateEndTag() -> Bool {
        let count = m_bufferedEndTagName.size()
        guard count == m_appropriateEndTagName.size() else {
            return false
        }
        for index in 0..<count where UInt16(m_bufferedEndTagName[index].value) != m_appropriateEndTagName[index] {
            return false
        }
        return true
    }

    /// In an end tag open state, at an ASCII letter: consumes the whole tag name when it and the character after it
    /// are in the current 8-bit substring, as the end tag open and end tag name states would one letter at a time.
    /// When the character after the name is one that could end an appropriate end tag, the name goes into the
    /// temporary buffer and the buffered end tag name and the end tag name state decides; otherwise "</" and the name
    /// are buffered as characters, as that state does when the end tag is not appropriate, and the next character is
    /// reconsumed in the text state.
    @inline(always)
    private mutating func consumeEndTagName(_ source: inout WebCore.SegmentedString) -> EndTagNameResult {
        guard m_temporaryBuffer.isEmpty() && m_bufferedEndTagName.isEmpty() else {
            return .notInCurrentSubstring
        }
        let length: Int
        let next: UInt16
        do {
            let characters: Span<UInt8> = source.currentSubstringBytes8()
            length = endTagNameLength(in: characters)
            next = length > 0 ? UInt16(characters[length]) : 0
        }
        guard length > 0 else {
            return .notInCurrentSubstring
        }
        // The preprocessor reads '\r' as '\n'.
        var isAppropriate = isTokenizerWhitespace(next) || next == carriageReturn || next == solidus || next == greaterThanSign
        let result: EndTagNameResult
        do {
            let characters: Span<UInt8> = source.currentSubstringBytes8()
            // isAppropriateEndTag, for the letters compared ignoring case.
            if UInt(bitPattern: length) != m_appropriateEndTagName.size() {
                isAppropriate = false
            }
            var index = 0
            while isAppropriate && index < length {
                isAppropriate = UInt16(characters[index] | 0x20) == m_appropriateEndTagName[index]
                index += 1
            }
            if isAppropriate {
                for index in 0..<length {
                    appendToTemporaryBuffer(UInt16(characters[index]))
                    appendToPossibleEndTag(convertASCIIAlphaToLower(UInt16(characters[index])))
                }
                result = .possibleAppropriateEndTag
            } else {
                bufferLessThanSignSolidus()
                m_token.appendToCharacter(WTF.latin1CharactersOfBytes(characters.extracting(0..<length)))
                result = .notAppropriateEndTag
            }
        }
        source.advancePastMultiple(UInt32(truncatingIfNeeded: length))
        return result
    }

    /// The state machine of HTMLTokenizer::processToken.
    ///
    /// `additionalAllowedCharacter` is m_additionalAllowedCharacter. The loop reads this copy and writes both.
    @inline(always)
    fileprivate mutating func processToken(
        from source: inout WebCore.SegmentedString,
        additionalAllowedCharacter: UInt16
    ) -> Bool {
        var additionalAllowedCharacter = additionalAllowedCharacter
        // m_state indexes allCases, which lists the states in order. No case handles an m_state outside State.
        let states = TokenizerState.allCases
        guard m_state.rawValue < states.count else {
            return false
        }
        var state = states[Int(m_state.rawValue)]
        defer {
            m_state = State(rawValue: state.rawValue)
        }

        if !m_bufferedEndTagName.isEmpty() && !state.isEndTagBuffering {
            // We are back here after emitting a character token that came just before an end tag.
            // To continue parsing the end tag we need to move the buffered tag name into the token.
            flushBufferedEndTag()

            // If we are in the data state, the end tag is already complete and we should emit it
            // now, otherwise, we want to resume parsing the partial end tag.
            if state == .data {
                return true
            }
        }

        guard m_preprocessor.peek(&source, shouldSkipNullCharacters(state)) else {
            return haveBufferedCharacterToken
        }
        var character = m_preprocessor.nextInputCharacter()

        // https://html.spec.whatwg.org/#tokenization
        // Each state either returns, or sets `state` and continues: "reconsume in" keeps `character`, the
        // transitions that consume read the next one. Each transition sets a constant state, so that it can branch
        // straight to that state's case.
        while true {
            switch state {
            case .data:
                // Most characters are above '<', the largest of the special ones.
                if character <= lessThanSign {
                    if character == ampersand {
                        guard advancePastNonNewline(to: .characterReferenceInData, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                    if character == lessThanSign {
                        if haveBufferedCharacterToken {
                            return true
                        }
                        guard advancePastNonNewline(to: .tagOpen, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                    if character == endOfFileMarker {
                        return emitEndOfFile(&source)
                    }
                }
                if isReplacedNullCharacter(&source, character) {
                    return emitReplacedNullCharacter(&source)
                }
                bufferCharacter(character)
                // Optimization: scan ahead for a run of plain-text characters in the
                // current substring and buffer them all at once, avoiding the
                // per-character overhead of the main tokenizer loop.
                if bufferPlainText(
                    &source,
                    dataStateSpecialCharacters,
                    while: {
                        !isDataStateSpecialCharacter($0)
                    }
                ) {
                    guard switchTo(.data, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .data, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .characterReferenceInData:
                if !processEntity(&source) {
                    return haveBufferedCharacterToken
                }
                guard switchTo(.data, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .rcdata:
                if character == ampersand {
                    guard advancePastNonNewline(to: .characterReferenceInRCDATA, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == lessThanSign {
                    guard advancePastNonNewline(to: .rcdataLessThanSign, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                if bufferPlainText(
                    &source,
                    dataStateSpecialCharacters,
                    while: {
                        !isDataStateSpecialCharacter($0)
                    }
                ) {
                    guard switchTo(.rcdata, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .rcdata, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .characterReferenceInRCDATA:
                if !processEntity(&source) {
                    return haveBufferedCharacterToken
                }
                guard switchTo(.rcdata, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .rawtext:
                if character == lessThanSign {
                    guard advancePastNonNewline(to: .rawtextLessThanSign, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                if bufferPlainText(
                    &source,
                    rawTextSpecialCharacters,
                    while: {
                        !isRawTextSpecialCharacter($0)
                    }
                ) {
                    guard switchTo(.rawtext, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .rawtext, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .scriptData:
                if character == lessThanSign {
                    guard advancePastNonNewline(to: .scriptDataLessThanSign, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                if bufferPlainText(
                    &source,
                    rawTextSpecialCharacters,
                    while: {
                        !isRawTextSpecialCharacter($0)
                    }
                ) {
                    guard switchTo(.scriptData, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .scriptData, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .plaintext:
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                guard advance(to: .plaintext, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .tagOpen:
                if character == exclamationMark {
                    guard advancePastNonNewline(to: .markupDeclarationOpen, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == solidus {
                    guard advancePastNonNewline(to: .endTagOpen, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if isASCIIAlpha(character) {
                    let lowercaseCharacter = convertASCIIAlphaToLower(character)
                    m_token.beginStartTag(WTF.Latin1Character(lowercaseCharacter))
                    m_appropriateEndTagName.shrink(0)
                    m_appropriateEndTagName.append(consuming: UInt16(lowercaseCharacter))
                    guard advancePastNonNewline(to: .tagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == questionMark {
                    if m_options.processingInstruction {
                        guard advancePastNonNewline(to: .processingInstructionOpen, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                    // The spec consumes the current character before switching
                    // to the bogus comment state, but it's easier to implement
                    // if we reconsume the current character.
                    state = .bogusComment
                    continue
                }
                bufferASCIICharacter(lessThanSign)
                state = .data
                continue

            case .endTagOpen:
                if isASCIIAlpha(character) {
                    m_token.beginEndTag(WTF.Latin1Character(convertASCIIAlphaToLower(character)))
                    m_appropriateEndTagName.clear()
                    guard advancePastNonNewline(to: .tagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    guard advancePastNonNewline(to: .data, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    bufferLessThanSignSolidus()
                    state = .data
                    continue
                }
                state = .bogusComment
                continue

            case .tagName:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeAttributeName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == solidus {
                    guard advancePastNonNewline(to: .selfClosingStartTag, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if m_options.usePreHTML5ParserQuirks && character == lessThanSign {
                    state = .data
                    return true
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                let lowercaseCharacter = toASCIILower(character)
                m_token.appendToName(lowercaseCharacter)
                if m_token.type() == .StartTag {
                    m_appropriateEndTagName.append(consuming: lowercaseCharacter)
                }
                guard advancePastNonNewline(to: .tagName, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .rcdataLessThanSign:
                if character == solidus {
                    m_temporaryBuffer.clear()
                    guard advancePastNonNewline(to: .rcdataEndTagOpen, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferASCIICharacter(lessThanSign)
                state = .rcdata
                continue

            case .rcdataEndTagOpen:
                if isASCIIAlpha(character) {
                    switch consumeEndTagName(&source) {
                    case .notAppropriateEndTag:
                        guard switchTo(.rcdata, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .possibleAppropriateEndTag:
                        guard switchTo(.rcdataEndTagName, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .notInCurrentSubstring:
                        break
                    }
                    appendToTemporaryBuffer(character)
                    appendToPossibleEndTag(convertASCIIAlphaToLower(character))
                    guard advancePastNonNewline(to: .rcdataEndTagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferLessThanSignSolidus()
                state = .rcdata
                continue

            case .rcdataEndTagName:
                if isASCIIAlpha(character) {
                    appendToTemporaryBuffer(character)
                    appendToPossibleEndTag(convertASCIIAlphaToLower(character))
                    guard advancePastNonNewline(to: .rcdataEndTagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if isTokenizerWhitespace(character) {
                    if isAppropriateEndTag() {
                        if commitToPartialEndTag(&source, character) {
                            state = .beforeAttributeName
                            return true
                        }
                        guard switchTo(.beforeAttributeName, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                } else if character == solidus {
                    if isAppropriateEndTag() {
                        if commitToPartialEndTag(&source, solidus) {
                            state = .selfClosingStartTag
                            return true
                        }
                        guard switchTo(.selfClosingStartTag, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                } else if character == greaterThanSign {
                    if isAppropriateEndTag() {
                        state = .data
                        return commitToCompleteEndTag(&source)
                    }
                }
                flushTemporaryBufferAsCharacters()
                state = .rcdata
                continue

            case .rawtextLessThanSign:
                if character == solidus {
                    m_temporaryBuffer.clear()
                    guard advancePastNonNewline(to: .rawtextEndTagOpen, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferASCIICharacter(lessThanSign)
                state = .rawtext
                continue

            case .rawtextEndTagOpen:
                if isASCIIAlpha(character) {
                    switch consumeEndTagName(&source) {
                    case .notAppropriateEndTag:
                        guard switchTo(.rawtext, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .possibleAppropriateEndTag:
                        guard switchTo(.rawtextEndTagName, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .notInCurrentSubstring:
                        break
                    }
                    appendToTemporaryBuffer(character)
                    appendToPossibleEndTag(convertASCIIAlphaToLower(character))
                    guard advancePastNonNewline(to: .rawtextEndTagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferLessThanSignSolidus()
                state = .rawtext
                continue

            case .rawtextEndTagName:
                if isASCIIAlpha(character) {
                    appendToTemporaryBuffer(character)
                    appendToPossibleEndTag(convertASCIIAlphaToLower(character))
                    guard advancePastNonNewline(to: .rawtextEndTagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if isTokenizerWhitespace(character) {
                    if isAppropriateEndTag() {
                        if commitToPartialEndTag(&source, character) {
                            state = .beforeAttributeName
                            return true
                        }
                        guard switchTo(.beforeAttributeName, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                } else if character == solidus {
                    if isAppropriateEndTag() {
                        if commitToPartialEndTag(&source, solidus) {
                            state = .selfClosingStartTag
                            return true
                        }
                        guard switchTo(.selfClosingStartTag, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                } else if character == greaterThanSign {
                    if isAppropriateEndTag() {
                        state = .data
                        return commitToCompleteEndTag(&source)
                    }
                }
                flushTemporaryBufferAsCharacters()
                state = .rawtext
                continue

            case .scriptDataLessThanSign:
                if character == solidus {
                    m_temporaryBuffer.clear()
                    guard advancePastNonNewline(to: .scriptDataEndTagOpen, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == exclamationMark {
                    bufferASCIICharacter(lessThanSign)
                    bufferASCIICharacter(exclamationMark)
                    guard advancePastNonNewline(to: .scriptDataEscapeStart, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferASCIICharacter(lessThanSign)
                state = .scriptData
                continue

            case .scriptDataEndTagOpen:
                if isASCIIAlpha(character) {
                    switch consumeEndTagName(&source) {
                    case .notAppropriateEndTag:
                        guard switchTo(.scriptData, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .possibleAppropriateEndTag:
                        guard switchTo(.scriptDataEndTagName, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .notInCurrentSubstring:
                        break
                    }
                    appendToTemporaryBuffer(character)
                    appendToPossibleEndTag(convertASCIIAlphaToLower(character))
                    guard advancePastNonNewline(to: .scriptDataEndTagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferLessThanSignSolidus()
                state = .scriptData
                continue

            case .scriptDataEndTagName:
                if isASCIIAlpha(character) {
                    appendToTemporaryBuffer(character)
                    appendToPossibleEndTag(convertASCIIAlphaToLower(character))
                    guard advancePastNonNewline(to: .scriptDataEndTagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if isTokenizerWhitespace(character) {
                    if isAppropriateEndTag() {
                        if commitToPartialEndTag(&source, character) {
                            state = .beforeAttributeName
                            return true
                        }
                        guard switchTo(.beforeAttributeName, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                } else if character == solidus {
                    if isAppropriateEndTag() {
                        if commitToPartialEndTag(&source, solidus) {
                            state = .selfClosingStartTag
                            return true
                        }
                        guard switchTo(.selfClosingStartTag, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                } else if character == greaterThanSign {
                    if isAppropriateEndTag() {
                        state = .data
                        return commitToCompleteEndTag(&source)
                    }
                }
                flushTemporaryBufferAsCharacters()
                state = .scriptData
                continue

            case .scriptDataEscapeStart:
                if character == hyphenMinus {
                    bufferASCIICharacter(hyphenMinus)
                    guard advancePastNonNewline(to: .scriptDataEscapeStartDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                state = .scriptData
                continue

            case .scriptDataEscapeStartDash:
                if character == hyphenMinus {
                    bufferASCIICharacter(hyphenMinus)
                    guard advancePastNonNewline(to: .scriptDataEscapedDashDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                state = .scriptData
                continue

            case .scriptDataEscaped:
                if character == hyphenMinus {
                    bufferASCIICharacter(hyphenMinus)
                    guard advancePastNonNewline(to: .scriptDataEscapedDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == lessThanSign {
                    guard advancePastNonNewline(to: .scriptDataEscapedLessThanSign, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                if bufferPlainText(
                    &source,
                    rawTextSpecialCharacters,
                    or: .hyphenMinus,
                    while: {
                        !isScriptDataEscapedSpecialCharacter($0)
                    }
                ) {
                    guard switchTo(.scriptDataEscaped, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .scriptDataEscaped, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .scriptDataEscapedDash:
                if character == hyphenMinus {
                    bufferASCIICharacter(hyphenMinus)
                    guard advancePastNonNewline(to: .scriptDataEscapedDashDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == lessThanSign {
                    guard advancePastNonNewline(to: .scriptDataEscapedLessThanSign, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                guard advance(to: .scriptDataEscaped, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .scriptDataEscapedDashDash:
                if character == hyphenMinus {
                    bufferASCIICharacter(hyphenMinus)
                    guard advancePastNonNewline(to: .scriptDataEscapedDashDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == lessThanSign {
                    guard advancePastNonNewline(to: .scriptDataEscapedLessThanSign, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    bufferASCIICharacter(greaterThanSign)
                    guard advancePastNonNewline(to: .scriptData, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                guard advance(to: .scriptDataEscaped, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .scriptDataEscapedLessThanSign:
                if character == solidus {
                    m_temporaryBuffer.clear()
                    guard advancePastNonNewline(to: .scriptDataEscapedEndTagOpen, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if isASCIIAlpha(character) {
                    bufferASCIICharacter(lessThanSign)
                    bufferASCIICharacter(character)
                    m_temporaryBuffer.clear()
                    appendToTemporaryBuffer(UInt16(convertASCIIAlphaToLower(character)))
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapeStart, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferASCIICharacter(lessThanSign)
                state = .scriptDataEscaped
                continue

            case .scriptDataEscapedEndTagOpen:
                if isASCIIAlpha(character) {
                    switch consumeEndTagName(&source) {
                    case .notAppropriateEndTag:
                        guard switchTo(.scriptDataEscaped, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .possibleAppropriateEndTag:
                        guard switchTo(.scriptDataEscapedEndTagName, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .notInCurrentSubstring:
                        break
                    }
                    appendToTemporaryBuffer(character)
                    appendToPossibleEndTag(convertASCIIAlphaToLower(character))
                    guard advancePastNonNewline(to: .scriptDataEscapedEndTagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferLessThanSignSolidus()
                state = .scriptDataEscaped
                continue

            case .scriptDataEscapedEndTagName:
                if isASCIIAlpha(character) {
                    appendToTemporaryBuffer(character)
                    appendToPossibleEndTag(convertASCIIAlphaToLower(character))
                    guard advancePastNonNewline(to: .scriptDataEscapedEndTagName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if isTokenizerWhitespace(character) {
                    if isAppropriateEndTag() {
                        if commitToPartialEndTag(&source, character) {
                            state = .beforeAttributeName
                            return true
                        }
                        guard switchTo(.beforeAttributeName, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                } else if character == solidus {
                    if isAppropriateEndTag() {
                        if commitToPartialEndTag(&source, solidus) {
                            state = .selfClosingStartTag
                            return true
                        }
                        guard switchTo(.selfClosingStartTag, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                } else if character == greaterThanSign {
                    if isAppropriateEndTag() {
                        state = .data
                        return commitToCompleteEndTag(&source)
                    }
                }
                flushTemporaryBufferAsCharacters()
                state = .scriptDataEscaped
                continue

            case .scriptDataDoubleEscapeStart:
                if isTokenizerWhitespace(character) || character == solidus || character == greaterThanSign {
                    bufferASCIICharacter(character)
                    if temporaryBufferIsScript() {
                        guard advance(to: .scriptDataDoubleEscaped, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                    guard advance(to: .scriptDataEscaped, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if isASCIIAlpha(character) {
                    bufferASCIICharacter(character)
                    appendToTemporaryBuffer(UInt16(convertASCIIAlphaToLower(character)))
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapeStart, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                state = .scriptDataEscaped
                continue

            case .scriptDataDoubleEscaped:
                if character == hyphenMinus {
                    bufferASCIICharacter(hyphenMinus)
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapedDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == lessThanSign {
                    bufferASCIICharacter(lessThanSign)
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapedLessThanSign, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                if bufferPlainText(
                    &source,
                    rawTextSpecialCharacters,
                    or: .hyphenMinus,
                    while: {
                        !isScriptDataEscapedSpecialCharacter($0)
                    }
                ) {
                    guard switchTo(.scriptDataDoubleEscaped, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .scriptDataDoubleEscaped, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .scriptDataDoubleEscapedDash:
                if character == hyphenMinus {
                    bufferASCIICharacter(hyphenMinus)
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapedDashDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == lessThanSign {
                    bufferASCIICharacter(lessThanSign)
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapedLessThanSign, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                guard advance(to: .scriptDataDoubleEscaped, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .scriptDataDoubleEscapedDashDash:
                if character == hyphenMinus {
                    bufferASCIICharacter(hyphenMinus)
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapedDashDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == lessThanSign {
                    bufferASCIICharacter(lessThanSign)
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapedLessThanSign, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    bufferASCIICharacter(greaterThanSign)
                    guard advancePastNonNewline(to: .scriptData, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                bufferCharacter(character)
                guard advance(to: .scriptDataDoubleEscaped, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .scriptDataDoubleEscapedLessThanSign:
                if character == solidus {
                    bufferASCIICharacter(solidus)
                    m_temporaryBuffer.clear()
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapeEnd, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                state = .scriptDataDoubleEscaped
                continue

            case .scriptDataDoubleEscapeEnd:
                if isTokenizerWhitespace(character) || character == solidus || character == greaterThanSign {
                    bufferASCIICharacter(character)
                    if temporaryBufferIsScript() {
                        guard advance(to: .scriptDataEscaped, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    }
                    guard advance(to: .scriptDataDoubleEscaped, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if isASCIIAlpha(character) {
                    bufferASCIICharacter(character)
                    appendToTemporaryBuffer(UInt16(convertASCIIAlphaToLower(character)))
                    guard advancePastNonNewline(to: .scriptDataDoubleEscapeEnd, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                state = .scriptDataDoubleEscaped
                continue

            case .beforeAttributeName:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeAttributeName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == solidus {
                    guard advancePastNonNewline(to: .selfClosingStartTag, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if m_options.usePreHTML5ParserQuirks && character == lessThanSign {
                    state = .data
                    return true
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                m_token.beginAttribute()
                m_token.appendToAttributeName(toASCIILower(character))
                if appendPlainText(
                    &source,
                    to: .attributeName,
                    attributeNameSpecialCharacters,
                    or: .attributeName,
                    continuesAcrossNewlines: false,
                    while: { !isAttributeNameSpecialCharacter($0) }
                ) {
                    guard switchTo(.attributeName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advancePastNonNewline(to: .attributeName, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .attributeName:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .afterAttributeName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == solidus {
                    guard advancePastNonNewline(to: .selfClosingStartTag, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == equalsSign {
                    guard advancePastNonNewline(to: .beforeAttributeValue, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if m_options.usePreHTML5ParserQuirks && character == lessThanSign {
                    state = .data
                    return true
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                m_token.appendToAttributeName(toASCIILower(character))
                // A '\n' ends the name, so the run stops there.
                if appendPlainText(
                    &source,
                    to: .attributeName,
                    attributeNameSpecialCharacters,
                    or: .attributeName,
                    continuesAcrossNewlines: false,
                    while: { !isAttributeNameSpecialCharacter($0) }
                ) {
                    guard switchTo(.attributeName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advancePastNonNewline(to: .attributeName, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .afterAttributeName:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .afterAttributeName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == solidus {
                    guard advancePastNonNewline(to: .selfClosingStartTag, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == equalsSign {
                    guard advancePastNonNewline(to: .beforeAttributeValue, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if m_options.usePreHTML5ParserQuirks && character == lessThanSign {
                    state = .data
                    return true
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                m_token.beginAttribute()
                m_token.appendToAttributeName(toASCIILower(character))
                if appendPlainText(
                    &source,
                    to: .attributeName,
                    attributeNameSpecialCharacters,
                    or: .attributeName,
                    continuesAcrossNewlines: false,
                    while: { !isAttributeNameSpecialCharacter($0) }
                ) {
                    guard switchTo(.attributeName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advancePastNonNewline(to: .attributeName, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .beforeAttributeValue:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeAttributeValue, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == quotationMark {
                    guard advancePastNonNewline(to: .attributeValueDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == ampersand {
                    state = .attributeValueUnquoted
                    continue
                }
                if character == apostrophe {
                    guard advancePastNonNewline(to: .attributeValueSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                m_token.appendToAttributeValue(character)
                guard advancePastNonNewline(to: .attributeValueUnquoted, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .attributeValueDoubleQuoted:
                if character == quotationMark {
                    m_token.endAttribute()
                    guard advancePastNonNewline(to: .afterAttributeValueQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == ampersand {
                    m_additionalAllowedCharacter = quotationMark
                    additionalAllowedCharacter = quotationMark
                    guard advancePastNonNewline(to: .characterReferenceInAttributeValue, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    m_token.endAttribute()
                    state = .data
                    continue
                }
                m_token.appendToAttributeValue(character)
                if appendPlainTextToAttributeValue(
                    &source,
                    doubleQuotedAttributeValueSpecialCharacters,
                    while: {
                        !isQuotedAttributeValueSpecialCharacter($0, quote: 0x22)
                    }
                ) {
                    guard switchTo(.attributeValueDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .attributeValueDoubleQuoted, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .attributeValueSingleQuoted:
                if character == apostrophe {
                    m_token.endAttribute()
                    guard advancePastNonNewline(to: .afterAttributeValueQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == ampersand {
                    m_additionalAllowedCharacter = apostrophe
                    additionalAllowedCharacter = apostrophe
                    guard advancePastNonNewline(to: .characterReferenceInAttributeValue, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    m_token.endAttribute()
                    state = .data
                    continue
                }
                m_token.appendToAttributeValue(character)
                if appendPlainTextToAttributeValue(
                    &source,
                    singleQuotedAttributeValueSpecialCharacters,
                    while: {
                        !isQuotedAttributeValueSpecialCharacter($0, quote: 0x27)
                    }
                ) {
                    guard switchTo(.attributeValueSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .attributeValueSingleQuoted, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .attributeValueUnquoted:
                if isTokenizerWhitespace(character) {
                    m_token.endAttribute()
                    guard advance(to: .beforeAttributeName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == ampersand {
                    m_additionalAllowedCharacter = greaterThanSign
                    additionalAllowedCharacter = greaterThanSign
                    guard advancePastNonNewline(to: .characterReferenceInAttributeValue, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.endAttribute()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.endAttribute()
                    state = .data
                    continue
                }
                m_token.appendToAttributeValue(character)
                // A '\n' ends the value, so the run stops there.
                if appendPlainTextToAttributeValue(
                    &source,
                    unquotedAttributeValueSpecialCharacters,
                    or: .space,
                    continuesAcrossNewlines: false,
                    while: { !isAttributeValueUnquotedSpecialCharacter($0) }
                ) {
                    guard switchTo(.attributeValueUnquoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advancePastNonNewline(to: .attributeValueUnquoted, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .characterReferenceInAttributeValue:
                let decodedEntity = consumeHTMLEntity(&source, additionalAllowedCharacter)
                if decodedEntity.notEnoughCharacters() {
                    return haveBufferedCharacterToken
                }
                if decodedEntity.failed() {
                    m_token.appendToAttributeValue(ampersand)
                } else {
                    let characters: Span<UInt16> = decodedEntity.span()
                    for index in characters.indices {
                        m_token.appendToAttributeValue(characters[index])
                    }
                }
                // We're supposed to switch back to the attribute value state that
                // we were in when we were switched into this state. Rather than
                // keeping track of this explicitly, we observe that the previous
                // state can be determined by m_additionalAllowedCharacter.
                if additionalAllowedCharacter == quotationMark {
                    guard switchTo(.attributeValueDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if additionalAllowedCharacter == apostrophe {
                    guard switchTo(.attributeValueSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard switchTo(.attributeValueUnquoted, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .afterAttributeValueQuoted:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeAttributeName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == solidus {
                    guard advancePastNonNewline(to: .selfClosingStartTag, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if m_options.usePreHTML5ParserQuirks && character == lessThanSign {
                    state = .data
                    return true
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                state = .beforeAttributeName
                continue

            case .selfClosingStartTag:
                if character == greaterThanSign {
                    m_token.setSelfClosing()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                state = .beforeAttributeName
                continue

            case .processingInstructionOpen:
                if character == lowLine || isASCIIAlpha(character) {
                    m_token.beginProcessingInstruction()
                    state = .processingInstructionTarget
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    return emitEndOfFile(&source)
                }
                m_token.beginComment()
                m_token.appendToComment(CChar(questionMark))
                state = .continueBogusComment
                continue

            case .processingInstructionTarget:
                if character == endOfFileMarker {
                    state = .data
                    return emitEndOfFile(&source)
                }
                if character == hyphenMinus || character == lowLine || isASCIIAlphanumeric(character) {
                    m_token.appendToProcessingInstructionTarget(WTF.Latin1Character(character))
                    guard advance(to: .processingInstructionTarget, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if !(isTokenizerWhitespace(character) || character == greaterThanSign || character == questionMark) {
                    rewindToBogusCommentForProcessingInstructionTarget()
                    state = .continueBogusComment
                    continue
                }
                // `<?xml` and `<?xml-stylesheet` stay bogus comments, as they were before
                // processing instructions were parsed at all.
                if processingInstructionTargetIsXMLDeclaration() {
                    rewindToBogusCommentForProcessingInstructionTarget()
                    state = .continueBogusComment
                    continue
                }
                state = .afterProcessingInstructionTarget
                continue

            case .afterProcessingInstructionTarget:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .afterProcessingInstructionTarget, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == questionMark {
                    guard advancePastNonNewline(to: .processingInstructionQuestionMark, &state, &character, &source)
                    else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitProcessingInstruction(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    return emitEndOfFile(&source)
                }
                state = .processingInstructionData
                continue

            case .processingInstructionData:
                if character == questionMark {
                    guard advancePastNonNewline(to: .processingInstructionQuestionMark, &state, &character, &source)
                    else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitProcessingInstruction(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    return emitEndOfFile(&source)
                }
                m_token.appendToProcessingInstructionData(character)
                guard advance(to: .processingInstructionData, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .processingInstructionQuestionMark:
                if character == greaterThanSign {
                    state = .data
                    return emitProcessingInstruction(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    return emitEndOfFile(&source)
                }
                m_token.appendToProcessingInstructionData(questionMark)
                state = .processingInstructionData
                continue

            case .bogusComment:
                m_token.beginComment()
                state = .continueBogusComment
                continue

            case .continueBogusComment:
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    return true
                }
                m_token.appendToComment(character)
                if appendPlainText(
                    &source,
                    to: .comment,
                    bogusCommentSpecialCharacters,
                    while: {
                        !isBogusCommentSpecialCharacter($0)
                    }
                ) {
                    guard switchTo(.continueBogusComment, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .continueBogusComment, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .markupDeclarationOpen:
                if character == hyphenMinus {
                    switch advancePast([0x2D, 0x2D], ignoringCase: false, in: &source) {
                    case .didMatch:
                        m_token.beginComment()
                        guard switchTo(.commentStart, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .notEnoughCharacters:
                        return haveBufferedCharacterToken
                    case .didNotMatch:
                        break
                    }
                } else if (character | 0x20) == 0x64 {
                    // "doctype"
                    switch advancePast([0x64, 0x6F, 0x63, 0x74, 0x79, 0x70, 0x65], ignoringCase: true, in: &source) {
                    case .didMatch:
                        guard switchTo(.doctype, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .notEnoughCharacters:
                        return haveBufferedCharacterToken
                    case .didNotMatch:
                        break
                    }
                } else if character == leftSquareBracket && m_shouldAllowCDATA {
                    // "[CDATA["
                    switch advancePast([0x5B, 0x43, 0x44, 0x41, 0x54, 0x41, 0x5B], ignoringCase: false, in: &source) {
                    case .didMatch:
                        guard switchTo(.cdataSection, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .notEnoughCharacters:
                        return haveBufferedCharacterToken
                    case .didNotMatch:
                        break
                    }
                }
                state = .bogusComment
                continue

            case .commentStart:
                if character == hyphenMinus {
                    guard advancePastNonNewline(to: .commentStartDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    return true
                }
                m_token.appendToComment(character)
                guard advance(to: .comment, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .commentStartDash:
                if character == hyphenMinus {
                    guard advancePastNonNewline(to: .commentEnd, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    return true
                }
                m_token.appendToComment(CChar(hyphenMinus))
                m_token.appendToComment(character)
                guard advance(to: .comment, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .comment:
                if character == hyphenMinus {
                    guard advancePastNonNewline(to: .commentEndDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    return true
                }
                m_token.appendToComment(character)
                if appendPlainText(
                    &source,
                    to: .comment,
                    newlineAndNullCharacters,
                    or: .hyphenMinus,
                    while: {
                        !isCommentSpecialCharacter($0)
                    }
                ) {
                    guard switchTo(.comment, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .comment, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .commentEndDash:
                if character == hyphenMinus {
                    guard advancePastNonNewline(to: .commentEnd, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    return true
                }
                m_token.appendToComment(CChar(hyphenMinus))
                m_token.appendToComment(character)
                guard advance(to: .comment, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .commentEnd:
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == exclamationMark {
                    guard advancePastNonNewline(to: .commentEndBang, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == hyphenMinus {
                    m_token.appendToComment(CChar(hyphenMinus))
                    guard advancePastNonNewline(to: .commentEnd, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    return true
                }
                m_token.appendToComment(CChar(hyphenMinus))
                m_token.appendToComment(CChar(hyphenMinus))
                m_token.appendToComment(character)
                guard advance(to: .comment, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .commentEndBang:
                if character == hyphenMinus {
                    m_token.appendToComment(CChar(hyphenMinus))
                    m_token.appendToComment(CChar(hyphenMinus))
                    m_token.appendToComment(CChar(exclamationMark))
                    guard advancePastNonNewline(to: .commentEndDash, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    return true
                }
                m_token.appendToComment(CChar(hyphenMinus))
                m_token.appendToComment(CChar(hyphenMinus))
                m_token.appendToComment(CChar(exclamationMark))
                m_token.appendToComment(character)
                guard advance(to: .comment, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .doctype:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeDOCTYPEName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    m_token.beginDOCTYPE()
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                state = .beforeDOCTYPEName
                continue

            case .beforeDOCTYPEName:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeDOCTYPEName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.beginDOCTYPE()
                    m_token.setForceQuirks()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.beginDOCTYPE()
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.beginDOCTYPE(toASCIILower(character))
                guard advancePastNonNewline(to: .doctypeName, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .doctypeName:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .afterDOCTYPEName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.appendToName(toASCIILower(character))
                guard advancePastNonNewline(to: .doctypeName, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .afterDOCTYPEName:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .afterDOCTYPEName, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                if (character | 0x20) == 0x70 {
                    // "public"
                    switch advancePast([0x70, 0x75, 0x62, 0x6C, 0x69, 0x63], ignoringCase: true, in: &source) {
                    case .didMatch:
                        guard switchTo(.afterDOCTYPEPublicKeyword, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .notEnoughCharacters:
                        return haveBufferedCharacterToken
                    case .didNotMatch:
                        break
                    }
                } else if (character | 0x20) == 0x73 {
                    // "system"
                    switch advancePast([0x73, 0x79, 0x73, 0x74, 0x65, 0x6D], ignoringCase: true, in: &source) {
                    case .didMatch:
                        guard switchTo(.afterDOCTYPESystemKeyword, &state, &character, &source) else {
                            return haveBufferedCharacterToken
                        }
                        continue
                    case .notEnoughCharacters:
                        return haveBufferedCharacterToken
                    case .didNotMatch:
                        break
                    }
                }
                m_token.setForceQuirks()
                guard advancePastNonNewline(to: .bogusDOCTYPE, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .afterDOCTYPEPublicKeyword:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeDOCTYPEPublicIdentifier, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == quotationMark {
                    m_token.setPublicIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypePublicIdentifierDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == apostrophe {
                    m_token.setPublicIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypePublicIdentifierSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.setForceQuirks()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.setForceQuirks()
                guard advancePastNonNewline(to: .bogusDOCTYPE, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .beforeDOCTYPEPublicIdentifier:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeDOCTYPEPublicIdentifier, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == quotationMark {
                    m_token.setPublicIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypePublicIdentifierDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == apostrophe {
                    m_token.setPublicIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypePublicIdentifierSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.setForceQuirks()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.setForceQuirks()
                guard advancePastNonNewline(to: .bogusDOCTYPE, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .doctypePublicIdentifierDoubleQuoted:
                if character == quotationMark {
                    guard advancePastNonNewline(to: .afterDOCTYPEPublicIdentifier, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.setForceQuirks()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.appendToPublicIdentifier(character)
                if appendPlainText(
                    &source,
                    to: .publicIdentifier,
                    doubleQuotedDOCTYPEIdentifierSpecialCharacters,
                    while: {
                        !isDOCTYPEIdentifierSpecialCharacter($0, quote: 0x22)
                    }
                ) {
                    guard switchTo(.doctypePublicIdentifierDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .doctypePublicIdentifierDoubleQuoted, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .doctypePublicIdentifierSingleQuoted:
                if character == apostrophe {
                    guard advancePastNonNewline(to: .afterDOCTYPEPublicIdentifier, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.setForceQuirks()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.appendToPublicIdentifier(character)
                if appendPlainText(
                    &source,
                    to: .publicIdentifier,
                    singleQuotedDOCTYPEIdentifierSpecialCharacters,
                    while: {
                        !isDOCTYPEIdentifierSpecialCharacter($0, quote: 0x27)
                    }
                ) {
                    guard switchTo(.doctypePublicIdentifierSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .doctypePublicIdentifierSingleQuoted, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .afterDOCTYPEPublicIdentifier:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .betweenDOCTYPEPublicAndSystemIdentifiers, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == quotationMark {
                    m_token.setSystemIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypeSystemIdentifierDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == apostrophe {
                    m_token.setSystemIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypeSystemIdentifierSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.setForceQuirks()
                guard advancePastNonNewline(to: .bogusDOCTYPE, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .betweenDOCTYPEPublicAndSystemIdentifiers:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .betweenDOCTYPEPublicAndSystemIdentifiers, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == quotationMark {
                    m_token.setSystemIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypeSystemIdentifierDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == apostrophe {
                    m_token.setSystemIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypeSystemIdentifierSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.setForceQuirks()
                guard advancePastNonNewline(to: .bogusDOCTYPE, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .afterDOCTYPESystemKeyword:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeDOCTYPESystemIdentifier, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == quotationMark {
                    m_token.setSystemIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypeSystemIdentifierDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == apostrophe {
                    m_token.setSystemIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypeSystemIdentifierSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.setForceQuirks()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.setForceQuirks()
                guard advancePastNonNewline(to: .bogusDOCTYPE, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .beforeDOCTYPESystemIdentifier:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .beforeDOCTYPESystemIdentifier, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == quotationMark {
                    m_token.setSystemIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypeSystemIdentifierDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == apostrophe {
                    m_token.setSystemIdentifierToEmptyString()
                    guard advancePastNonNewline(to: .doctypeSystemIdentifierSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.setForceQuirks()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.setForceQuirks()
                guard advancePastNonNewline(to: .bogusDOCTYPE, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .doctypeSystemIdentifierDoubleQuoted:
                if character == quotationMark {
                    guard advancePastNonNewline(to: .afterDOCTYPESystemIdentifier, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.setForceQuirks()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.appendToSystemIdentifier(character)
                if appendPlainText(
                    &source,
                    to: .systemIdentifier,
                    doubleQuotedDOCTYPEIdentifierSpecialCharacters,
                    while: {
                        !isDOCTYPEIdentifierSpecialCharacter($0, quote: 0x22)
                    }
                ) {
                    guard switchTo(.doctypeSystemIdentifierDoubleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .doctypeSystemIdentifierDoubleQuoted, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .doctypeSystemIdentifierSingleQuoted:
                if character == apostrophe {
                    guard advancePastNonNewline(to: .afterDOCTYPESystemIdentifier, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    m_token.setForceQuirks()
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                m_token.appendToSystemIdentifier(character)
                if appendPlainText(
                    &source,
                    to: .systemIdentifier,
                    singleQuotedDOCTYPEIdentifierSpecialCharacters,
                    while: {
                        !isDOCTYPEIdentifierSpecialCharacter($0, quote: 0x27)
                    }
                ) {
                    guard switchTo(.doctypeSystemIdentifierSingleQuoted, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .doctypeSystemIdentifierSingleQuoted, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .afterDOCTYPESystemIdentifier:
                if isTokenizerWhitespace(character) {
                    guard advance(to: .afterDOCTYPESystemIdentifier, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    m_token.setForceQuirks()
                    state = .data
                    return true
                }
                guard advancePastNonNewline(to: .bogusDOCTYPE, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .bogusDOCTYPE:
                if character == greaterThanSign {
                    state = .data
                    return emitAndResumeInDataState(&source)
                }
                if character == endOfFileMarker {
                    state = .data
                    return true
                }
                guard advance(to: .bogusDOCTYPE, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .cdataSection:
                if character == rightSquareBracket {
                    guard advancePastNonNewline(to: .cdataSectionRightSquareBracket, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == endOfFileMarker {
                    state = .data
                    continue
                }
                if isReplacedNullCharacter(&source, character) {
                    return emitReplacedNullCharacter(&source)
                }
                bufferCharacter(character)
                if bufferPlainText(
                    &source,
                    newlineAndNullCharacters,
                    or: .rightSquareBracket,
                    while: {
                        !isCDATASectionSpecialCharacter($0)
                    }
                ) {
                    guard switchTo(.cdataSection, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                guard advance(to: .cdataSection, &state, &character, &source) else {
                    return haveBufferedCharacterToken
                }
                continue

            case .cdataSectionRightSquareBracket:
                if character == rightSquareBracket {
                    guard advancePastNonNewline(to: .cdataSectionDoubleRightSquareBracket, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferASCIICharacter(rightSquareBracket)
                state = .cdataSection
                continue

            case .cdataSectionDoubleRightSquareBracket:
                if character == rightSquareBracket {
                    bufferCharacter(character)
                    guard advance(to: .cdataSectionDoubleRightSquareBracket, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                if character == greaterThanSign {
                    guard advancePastNonNewline(to: .data, &state, &character, &source) else {
                        return haveBufferedCharacterToken
                    }
                    continue
                }
                bufferASCIICharacter(rightSquareBracket)
                bufferASCIICharacter(rightSquareBracket)
                state = .cdataSection
                continue
            }
        }
    }
}

#endif // USE_SWIFT_HTML_TOKENIZER
