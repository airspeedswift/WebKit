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
internal import WebCore_Private.Core.HTMLEntityParser
internal import WebCore_Private.Core.HTMLEntityTable
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

/// Consumes the character reference at the start of 8-bit `characters`, for WebVTTTokenizer.
///
/// `characters` start just after the '&'. Sets `entity` to what it decodes to, failed if it is not a character
/// reference, and returns how many characters it consumed. The source is complete: the character after the last one
/// reads as 0.
///
/// `characters` are the rest of the WebVTTTokenizer's input, a String it holds for the call. A String's characters
/// stay allocated and never change, and any byte is a valid Latin1Character.
///
/// FIXME: Take a Span once a std::span can cross safely (rdar://186723514).
@_expose(Cxx, "consumeHTMLEntity")
func consumeHTMLEntity8(
    _ characters: WebCore.HTMLFastPathLatin1Span,
    _ additionalAllowedCharacter: UInt16,
    _ entity: inout WebCore.DecodedHTMLEntity
) -> UInt {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(characters))
    return UInt(consumeHTMLEntity(characters, additionalAllowedCharacter, &entity))
}

/// Consumes the character reference that starts `characters`, as consumeHTMLEntity8 does, from 16-bit characters.
///
/// `characters` are the rest of the WebVTTTokenizer's input, a String it holds for the call. A String's characters
/// stay allocated and never change, and any 16-bit value is a valid char16_t.
///
/// FIXME: Take a Span once a std::span can cross safely (rdar://186723514).
@_expose(Cxx, "consumeHTMLEntity")
func consumeHTMLEntity16(
    _ characters: WebCore.HTMLFastPathUTF16Span,
    _ additionalAllowedCharacter: UInt16,
    _ entity: inout WebCore.DecodedHTMLEntity
) -> UInt {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    return UInt(consumeHTMLEntity(characters, additionalAllowedCharacter, &entity))
}

/// The entity named `name` followed by a ';', for the XML parser, or a failed entity if there is none.
///
/// `name` is the name libxml2 passes to the XML parser's entity lookup, without its terminating NUL. libxml2 owns it
/// and does not change it during the call, and any byte is a valid char.
///
/// FIXME: Take a Span once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
func decodeNamedHTMLEntityForXMLParser(_ name: WebCore.HTMLFastPathLatin1Span) -> WebCore.DecodedHTMLEntity {
    let name = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    let table = WebCore.HTMLEntityTable()
    // The name's characters are char, so a byte above 0x7F sign-extends to 0xFF80-0xFFFF.
    let first = name.isEmpty ? semicolon : UInt16(truncatingIfNeeded: Int8(bitPattern: name[0]))
    guard isASCIIAlpha(first) else {
        return WebCore.DecodedHTMLEntity()
    }
    let entries: Span<WebCore.HTMLEntityTableEntry> = table.entriesStartingWithCharacter(first)
    var search = HTMLEntitySearch()
    for index in name.indices {
        search.advance(UInt16(truncatingIfNeeded: Int8(bitPattern: name[index])), in: entries)
        if !search.isEntityPrefix {
            return WebCore.DecodedHTMLEntity()
        }
    }
    search.advance(semicolon, in: entries)
    if !search.isEntityPrefix {
        return WebCore.DecodedHTMLEntity()
    }
    guard let match = search.match else {
        preconditionFailure()
    }
    return makeEntity(entries[match])
}

/// Consumes the character reference at the start of `characters`.
///
/// `characters` start just after the '&'. Sets `entity` to what it decodes to, failed if it is not a character
/// reference, and returns how many characters it consumed. The source is complete: the character after the last one
/// reads as 0.
func consumeHTMLEntity<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ additionalAllowedCharacter: UInt16,
    _ entity: inout WebCore.DecodedHTMLEntity
) -> Int {
    var source = characters
    var consumed = 0
    entity = consumeHTMLEntity(&source, &consumed, additionalAllowedCharacter)
    return consumed
}

/// Consumes the character reference at the start of `characters` and writes what it decodes to into `decoded`.
///
/// `characters` start just after the '&'. Writes the 0 to 3 characters at `offset` of `decoded`, which has room for 3
/// there. Returns how many characters it read, shifted left by 2, or'ed with how many it wrote. The source is
/// complete: the character after the last one reads as 0.
func consumeHTMLEntity<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ additionalAllowedCharacter: UInt16,
    _ decoded: inout MutableSpan<UInt16>,
    at offset: Int
) -> UInt64 {
    var entity = WebCore.DecodedHTMLEntity()
    let consumed = consumeHTMLEntity(characters, additionalAllowedCharacter, &entity)
    let entityCharacters: Span<UInt16> = entity.span()
    for index in entityCharacters.indices {
        decoded[offset + index] = entityCharacters[index]
    }
    return UInt64(consumed) << 2 | UInt64(entityCharacters.count)
}

/// Consumes the character reference at the current character of `source` and returns what it decodes to.
///
/// The current character is the one after the '&'. Returns a failed entity, with nothing consumed, if it is not a
/// character reference, and one that reports notEnoughCharacters, with nothing consumed, if `source` ends before that
/// can be decided. `source` is complete only if it ends with a 0 character.
///
/// A character reference decided before the last character of the current substring is read in place. None of its
/// characters is a newline, so advancing past them all at once leaves `source` as advancing past each one does.
@inline(always)
func consumeHTMLEntity(
    _ source: inout WebCore.SegmentedString,
    _ additionalAllowedCharacter: UInt16 = 0
) -> WebCore.DecodedHTMLEntity {
    let is8Bit: Bool
    do {
        let characters: Span<UInt8> = source.currentSubstringBytes8()
        is8Bit = !characters.isEmpty
    }
    if is8Bit {
        return consumeHTMLEntityFromSubstring8(&source, additionalAllowedCharacter)
    }
    let is16Bit: Bool
    do {
        let characters: Span<UInt16> = source.currentSubstringSpan16()
        is16Bit = !characters.isEmpty
    }
    if is16Bit {
        return consumeHTMLEntityFromSubstring16(&source, additionalAllowedCharacter)
    }
    return consumeHTMLEntityFromSubstrings(&source, additionalAllowedCharacter)
}

/// consumeHTMLEntity for a source whose current substring is 8-bit.
private func consumeHTMLEntityFromSubstring8(
    _ source: inout WebCore.SegmentedString,
    _ additionalAllowedCharacter: UInt16
) -> WebCore.DecodedHTMLEntity {
    var consumed = 0
    let entity: WebCore.DecodedHTMLEntity
    do {
        // Without the substring's last character, which advancePastMultiple8 needs to remain.
        let characters: Span<UInt8> = source.currentSubstringBytes8()
        var leading = LeadingCharacters(characters.extracting(droppingLast: 1))
        entity = consumeHTMLEntity(&leading, &consumed, additionalAllowedCharacter)
    }
    if entity.notEnoughCharacters() {
        return consumeHTMLEntityFromSubstrings(&source, additionalAllowedCharacter)
    }
    if consumed > 0 {
        source.advancePastMultiple(UInt32(truncatingIfNeeded: consumed))
    }
    return entity
}

/// consumeHTMLEntity for a source whose current substring is 16-bit and has more than one character.
private func consumeHTMLEntityFromSubstring16(
    _ source: inout WebCore.SegmentedString,
    _ additionalAllowedCharacter: UInt16
) -> WebCore.DecodedHTMLEntity {
    var consumed = 0
    let entity: WebCore.DecodedHTMLEntity
    do {
        // Without the substring's last character, which advancePastMultiple16 needs to remain.
        let characters: Span<UInt16> = source.currentSubstringSpan16()
        var leading = LeadingCharacters(characters.extracting(droppingLast: 1))
        entity = consumeHTMLEntity(&leading, &consumed, additionalAllowedCharacter)
    }
    if entity.notEnoughCharacters() {
        return consumeHTMLEntityFromSubstrings(&source, additionalAllowedCharacter)
    }
    if consumed > 0 {
        source.advancePastMultiple(UInt32(truncatingIfNeeded: consumed))
    }
    return entity
}

/// consumeHTMLEntity over `source` one character at a time, pushing back what it consumed when it has to.
@inline(never)
private func consumeHTMLEntityFromSubstrings(
    _ source: inout WebCore.SegmentedString,
    _ additionalAllowedCharacter: UInt16
) -> WebCore.DecodedHTMLEntity {
    var consumed = ConsumedCharacters()
    return consumeHTMLEntity(&source, &consumed, additionalAllowedCharacter)
}

private let semicolon = UInt16(UInt8(ascii: ";"))
private let numberSign = UInt16(UInt8(ascii: "#"))
private let equalsSign = UInt16(UInt8(ascii: "="))
private let digitZero = UInt16(UInt8(ascii: "0"))
private let capitalA = UInt16(UInt8(ascii: "A"))
private let smallX = UInt16(UInt8(ascii: "x"))

private var replacementCharacter: UInt16 { WTF.Unicode.replacementCharacter }

private func isASCIIAlpha(_ character: UInt16) -> Bool {
    // Wraps on purpose: anything below 'a' becomes too large.
    (character | 0x20) &- 0x61 < 26
}

private func isASCIIDigit(_ character: UInt16) -> Bool {
    // Wraps on purpose: anything below '0' becomes too large.
    character &- digitZero < 10
}

private func isASCIIHexDigit(_ character: UInt16) -> Bool {
    // Wraps on purpose: anything below 'a' becomes too large.
    isASCIIDigit(character) || (character | 0x20) &- 0x61 < 6
}

private func isASCIIAlphanumeric(_ character: UInt16) -> Bool {
    isASCIIDigit(character) || isASCIIAlpha(character)
}

/// The value of a hex digit, as WTF's toASCIIHexValue computes it.
private func toASCIIHexValue(_ character: UInt16) -> UInt32 {
    // character is a hex digit, so neither subtraction wraps.
    character < capitalA ? UInt32(character &- digitZero) : UInt32((character &- capitalA &+ 10) & 0xF)
}

// U+0080 to U+009F as windows-1252 decodes those bytes.
private let windowsLatin1ExtensionArray: [32 of UInt16] = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, // 80-87
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, // 88-8F
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90-97
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178, // 98-9F
]

private func leadSurrogate(_ character: UInt32) -> UInt16 {
    // character is above U+FFFF and at most U+10FFFF, so the sum fits in 16 bits.
    UInt16(truncatingIfNeeded: (character >> 10) + 0xD7C0)
}

private func trailSurrogate(_ character: UInt32) -> UInt16 {
    UInt16(truncatingIfNeeded: (character & 0x3FF) | 0xDC00)
}

private func makeEntity(_ character: UInt32) -> WebCore.DecodedHTMLEntity {
    if character == 0 || character > UInt32(UCHAR_MAX_VALUE) || (character & 0xFFFF_F800) == 0xD800 {
        return WebCore.DecodedHTMLEntity(replacementCharacter)
    }
    if (character & ~0x1F) != 0x80 {
        if character <= 0xFFFF {
            return WebCore.DecodedHTMLEntity(UInt16(truncatingIfNeeded: character))
        }
        return WebCore.DecodedHTMLEntity(leadSurrogate(character), trailSurrogate(character))
    }
    return WebCore.DecodedHTMLEntity(windowsLatin1ExtensionArray.span[Int(character - 0x80)])
}

/// The value of a numeric character reference, which saturates to an overflow that later digits do not undo.
private struct NumericValue {
    var value: UInt32 = 0
    var hasOverflowed = false

    mutating func append(_ digit: UInt32, base: UInt32) {
        let (product, productOverflowed) = value.multipliedReportingOverflow(by: base)
        let (sum, sumOverflowed) = product.addingReportingOverflow(digit)
        value = sum
        hasOverflowed = hasOverflowed || productOverflowed || sumOverflowed
    }

    var entity: WebCore.DecodedHTMLEntity {
        if hasOverflowed {
            return WebCore.DecodedHTMLEntity(replacementCharacter)
        }
        return makeEntity(value)
    }
}

private func makeEntity(_ entry: WebCore.HTMLEntityTableEntry) -> WebCore.DecodedHTMLEntity {
    let first = UInt32(entry.firstCharacter)
    let second = UInt16(truncatingIfNeeded: entry.optionalSecondCharacter)
    if first <= 0xFFFF {
        let firstCodeUnit = UInt16(truncatingIfNeeded: first)
        if second == 0 {
            return WebCore.DecodedHTMLEntity(firstCodeUnit)
        }
        return WebCore.DecodedHTMLEntity(firstCodeUnit, second)
    }
    if second == 0 {
        return WebCore.DecodedHTMLEntity(leadSurrogate(first), trailSurrogate(first))
    }
    return WebCore.DecodedHTMLEntity(leadSurrogate(first), trailSurrogate(first), second)
}

/// Searches the entity table for the longest entity name that is a prefix of the characters seen so far.
///
/// It takes one character at a time. The entries are those starting with the first character, sorted by name.
private struct HTMLEntitySearch {
    private enum CompareResult {
        case before
        case prefix
        case after
    }

    private(set) var currentLength = 0
    /// The index of the longest entry that matches the characters seen.
    private(set) var match: Int?
    private(set) var isEntityPrefix = true
    // The entries that the characters seen are a prefix of, from first to last.
    private var first = 0
    private var last = 0

    @inline(always)
    private func compare(_ entry: WebCore.HTMLEntityTableEntry, _ nextCharacter: UInt16) -> CompareResult {
        let name: Span<CChar> = entry.nameCharacters()
        let entryNextCharacter: UInt16
        if currentLength >= name.count {
            if entry.nameIncludesTrailingSemicolon == 0 || currentLength > name.count {
                return .before
            }
            entryNextCharacter = semicolon
        } else {
            entryNextCharacter = UInt16(truncatingIfNeeded: name[currentLength])
        }
        if entryNextCharacter == nextCharacter {
            return .prefix
        }
        return entryNextCharacter < nextCharacter ? .before : .after
    }

    @inline(always)
    private func findFirst(_ nextCharacter: UInt16, in entries: Span<WebCore.HTMLEntityTableEntry>) -> Int {
        var front = first
        var back = last
        if front == back {
            return front
        }
        switch compare(entries[front], nextCharacter) {
        case .prefix:
            return front
        case .after:
            return back
        case .before:
            break
        }
        // 0 <= front < back < entries.count, so neither the difference nor the midpoint can overflow. The nested loops
        // make each probe a branch.
        bisect: while back &- front > 1 {
            var probe = front &+ (back &- front) / 2
            while compare(entries[probe], nextCharacter) == .before {
                front = probe
                if back &- front <= 1 {
                    break bisect
                }
                probe = front &+ (back &- front) / 2
            }
            back = probe
        }
        return back
    }

    @inline(always)
    private func findLast(_ nextCharacter: UInt16, in entries: Span<WebCore.HTMLEntityTableEntry>) -> Int {
        var front = first
        var back = last
        if front == back {
            return back
        }
        switch compare(entries[back], nextCharacter) {
        case .prefix:
            return back
        case .before:
            return front
        case .after:
            break
        }
        // 0 <= front < back < entries.count, so neither the difference nor the midpoint can overflow. The nested loops
        // make each probe a branch.
        bisect: while back &- front > 1 {
            var probe = front &+ (back &- front) / 2
            while compare(entries[probe], nextCharacter) == .after {
                back = probe
                if back &- front <= 1 {
                    break bisect
                }
                probe = front &+ (back &- front) / 2
            }
            front = probe
        }
        return front
    }

    /// Adds `nextCharacter` to the characters seen. `entries` are the table's entries starting with the first
    /// character seen.
    @inline(always)
    mutating func advance(_ nextCharacter: UInt16, in entries: Span<WebCore.HTMLEntityTableEntry>) {
        if currentLength == 0 {
            first = 0
            last = entries.count - 1
        } else {
            first = findFirst(nextCharacter, in: entries)
            last = findLast(nextCharacter, in: entries)
            if first == last && compare(entries[first], nextCharacter) != .prefix {
                isEntityPrefix = false
                return
            }
        }
        currentLength += 1
        if Int(entries[first].nameLength()) != currentLength {
            return
        }
        match = first
    }
}

/// The characters a character reference is read from. `Consumed` is what the decoder has consumed of them, kept so
/// that it can push them back.
private protocol HTMLEntitySource: ~Copyable, ~Escapable {
    associatedtype Consumed

    func isEmpty(_ consumed: borrowing Consumed) -> Bool
    func currentCharacter(_ consumed: borrowing Consumed) -> UInt16
    mutating func advance(_ consumed: inout Consumed)
    mutating func pushEverythingBack(_ consumed: inout Consumed)
    mutating func pushBackButKeep(_ keepCount: Int, _ consumed: inout Consumed)
}

/// The characters consumed from a SegmentedString.
private struct ConsumedCharacters {
    fileprivate static let inlineCapacity = 64

    fileprivate var inlineCharacters = InlineArray<64, UInt16>(repeating: 0)
    // All the consumed characters, once there are more than fit inline.
    fileprivate var characters: [UInt16] = []
    fileprivate var count = 0

    fileprivate mutating func append(_ character: UInt16) {
        if count < Self.inlineCapacity {
            inlineCharacters[count] = character
        } else {
            if characters.isEmpty {
                for index in 0..<Self.inlineCapacity {
                    characters.append(inlineCharacters[index])
                }
            }
            characters.append(character)
        }
        count += 1
    }

    /// A String of the consumed characters from `keepCount` on, which no longer count as consumed.
    fileprivate mutating func removeCharacters(from keepCount: Int) -> WTF.String {
        let string: WTF.String
        if count <= Self.inlineCapacity {
            let span: Span<UInt16> = inlineCharacters.span.extracting(keepCount..<count)
            string = WTF.String(span)
        } else {
            let span: Span<UInt16> = characters.span.extracting(keepCount..<count)
            string = WTF.String(span)
        }
        count = keepCount
        if count <= Self.inlineCapacity {
            characters.removeAll()
        } else {
            characters.removeLast(characters.count - count)
        }
        return string
    }
}

// The source the tokenizer reads from. A source that is complete ends with a 0 character.
extension WebCore.SegmentedString: HTMLEntitySource {
    fileprivate func isEmpty(_ consumed: borrowing ConsumedCharacters) -> Bool {
        isEmpty()
    }

    fileprivate func currentCharacter(_ consumed: borrowing ConsumedCharacters) -> UInt16 {
        currentCharacter()
    }

    fileprivate mutating func advance(_ consumed: inout ConsumedCharacters) {
        consumed.append(currentCharacter())
        advancePastNonNewline()
    }

    fileprivate mutating func pushEverythingBack(_ consumed: inout ConsumedCharacters) {
        pushBack(consuming: consumed.removeCharacters(from: 0))
    }

    fileprivate mutating func pushBackButKeep(_ keepCount: Int, _ consumed: inout ConsumedCharacters) {
        pushBack(consuming: consumed.removeCharacters(from: keepCount))
    }
}

// Characters that are complete: the character after the last one reads as 0, and the source is never empty.
// `Consumed` is the number of characters consumed.
extension Span: HTMLEntitySource where Element: FixedWidthInteger & UnsignedInteger {
    fileprivate func isEmpty(_ consumed: borrowing Int) -> Bool {
        false
    }

    fileprivate func currentCharacter(_ consumed: borrowing Int) -> UInt16 {
        consumed < count ? UInt16(truncatingIfNeeded: self[consumed]) : 0
    }

    fileprivate func advance(_ consumed: inout Int) {
        consumed += 1
    }

    fileprivate func pushEverythingBack(_ consumed: inout Int) {
        consumed = 0
    }

    fileprivate func pushBackButKeep(_ keepCount: Int, _ consumed: inout Int) {
        consumed = keepCount
    }
}

/// Characters that the source may continue past.
///
/// Running out of them leaves the character reference undecided. `Consumed` is the number of characters consumed.
private struct LeadingCharacters<CodeUnit: FixedWidthInteger & UnsignedInteger>: ~Escapable {
    let characters: Span<CodeUnit>

    @_lifetime(copy characters)
    init(_ characters: Span<CodeUnit>) {
        self.characters = characters
    }
}

extension LeadingCharacters: HTMLEntitySource {
    fileprivate func isEmpty(_ consumed: borrowing Int) -> Bool {
        consumed >= characters.count
    }

    fileprivate func currentCharacter(_ consumed: borrowing Int) -> UInt16 {
        consumed < characters.count ? UInt16(truncatingIfNeeded: characters[consumed]) : 0
    }

    fileprivate func advance(_ consumed: inout Int) {
        // Called only when consumed < characters.count, so this cannot overflow.
        consumed &+= 1
    }

    fileprivate func pushEverythingBack(_ consumed: inout Int) {
        consumed = 0
    }

    fileprivate func pushBackButKeep(_ keepCount: Int, _ consumed: inout Int) {
        consumed = keepCount
    }
}

private func consumeDecimalHTMLEntity<Source: HTMLEntitySource & ~Copyable & ~Escapable>(
    _ source: inout Source,
    _ consumed: inout Source.Consumed
) -> WebCore.DecodedHTMLEntity {
    var result = NumericValue()
    var character = source.currentCharacter(consumed)
    repeat {
        source.advance(&consumed)
        if source.isEmpty(consumed) {
            source.pushEverythingBack(&consumed)
            return WebCore.DecodedHTMLEntity(WebCore.DecodedHTMLEntity.ConstructNotEnoughCharacters)
        }
        // character is a digit, so this does not wrap.
        result.append(UInt32(character &- digitZero), base: 10)
        character = source.currentCharacter(consumed)
    } while isASCIIDigit(character)
    if character == semicolon {
        source.advance(&consumed)
    }
    return result.entity
}

private func consumeHexHTMLEntity<Source: HTMLEntitySource & ~Copyable & ~Escapable>(
    _ source: inout Source,
    _ consumed: inout Source.Consumed
) -> WebCore.DecodedHTMLEntity {
    var result = NumericValue()
    var character = source.currentCharacter(consumed)
    repeat {
        source.advance(&consumed)
        if source.isEmpty(consumed) {
            source.pushEverythingBack(&consumed)
            return WebCore.DecodedHTMLEntity(WebCore.DecodedHTMLEntity.ConstructNotEnoughCharacters)
        }
        result.append(toASCIIHexValue(character), base: 16)
        character = source.currentCharacter(consumed)
    } while isASCIIHexDigit(character)
    if character == semicolon {
        source.advance(&consumed)
    }
    return result.entity
}

private func consumeNamedHTMLEntity<Source: HTMLEntitySource & ~Copyable & ~Escapable>(
    _ source: inout Source,
    _ consumed: inout Source.Consumed,
    _ additionalAllowedCharacter: UInt16
) -> WebCore.DecodedHTMLEntity {
    let table = WebCore.HTMLEntityTable()
    let entries: Span<WebCore.HTMLEntityTableEntry> = table.entriesStartingWithCharacter(source.currentCharacter(consumed))
    var search = HTMLEntitySearch()
    var character: UInt16
    repeat {
        character = source.currentCharacter(consumed)
        search.advance(character, in: entries)
        if !search.isEntityPrefix {
            break
        }
        source.advance(&consumed)
    } while !source.isEmpty(consumed)
    // We can't decide on an entity because there might be a longer entity we could match if we had more data.
    if source.isEmpty(consumed) && character != semicolon {
        source.pushEverythingBack(&consumed)
        return WebCore.DecodedHTMLEntity(WebCore.DecodedHTMLEntity.ConstructNotEnoughCharacters)
    }
    guard let matchIndex = search.match else {
        source.pushEverythingBack(&consumed)
        return WebCore.DecodedHTMLEntity()
    }
    let match = entries[matchIndex]
    let nameLength = Int(match.nameLength())
    if nameLength != search.currentLength {
        // We've consumed too many characters. Walk the source back to the point at which we had consumed an actual
        // entity.
        source.pushBackButKeep(nameLength, &consumed)
        character = source.currentCharacter(consumed)
    }
    // FIXME: The use of additionalAllowedCharacter as just a boolean here is surprising.
    if match.nameIncludesTrailingSemicolon != 0 || additionalAllowedCharacter == 0
        || !(isASCIIAlphanumeric(character) || character == equalsSign)
    {
        return makeEntity(match)
    }
    source.pushEverythingBack(&consumed)
    return WebCore.DecodedHTMLEntity()
}

private func consumeHTMLEntity<Source: HTMLEntitySource & ~Copyable & ~Escapable>(
    _ source: inout Source,
    _ consumed: inout Source.Consumed,
    _ additionalAllowedCharacter: UInt16
) -> WebCore.DecodedHTMLEntity {
    if source.isEmpty(consumed) {
        return WebCore.DecodedHTMLEntity(WebCore.DecodedHTMLEntity.ConstructNotEnoughCharacters)
    }

    var character = source.currentCharacter(consumed)
    if isASCIIAlpha(character) {
        return consumeNamedHTMLEntity(&source, &consumed, additionalAllowedCharacter)
    }
    if character != numberSign {
        return WebCore.DecodedHTMLEntity()
    }

    source.advance(&consumed)
    if source.isEmpty(consumed) {
        source.pushEverythingBack(&consumed)
        return WebCore.DecodedHTMLEntity(WebCore.DecodedHTMLEntity.ConstructNotEnoughCharacters)
    }

    character = source.currentCharacter(consumed)
    if isASCIIDigit(character) {
        return consumeDecimalHTMLEntity(&source, &consumed)
    }
    if (character | 0x20) != smallX {
        source.pushEverythingBack(&consumed)
        return WebCore.DecodedHTMLEntity()
    }

    source.advance(&consumed)
    if source.isEmpty(consumed) {
        source.pushEverythingBack(&consumed)
        return WebCore.DecodedHTMLEntity(WebCore.DecodedHTMLEntity.ConstructNotEnoughCharacters)
    }

    character = source.currentCharacter(consumed)
    if isASCIIHexDigit(character) {
        return consumeHexHTMLEntity(&source, &consumed)
    }

    source.pushEverythingBack(&consumed)
    return WebCore.DecodedHTMLEntity()
}

#endif // USE_SWIFT_HTML_TOKENIZER
