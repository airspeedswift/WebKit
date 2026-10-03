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

// Writers for `CSSParserTokenBits`, one per token kind. The struct and the readers C++ uses are
// in CSSParserTokenBits.h.

internal import WebCore_Private.CSSTokenizerSwiftTypes

// MARK: - Parking a value offset in the pointer slot

/// Whether this input's offsets can be tagged; call once per tokenization.
///
/// A stylesheet of 2 GB or more cannot be, so tokenization fails rather than truncating.
///
/// This also keeps every parked offset below 2^32, inside Darwin's 4 GB `__PAGEZERO`, so a
/// `CSSParserToken` built from bits that missed `resolveValuePointer` faults deterministically
/// instead of reading live heap.
@inline(always)
func cssParserTokenBitsCanRepresentOffsets(_ inputLength: Int) -> Bool {
    inputLength < Int(WebCore.cssParserTokenBitsUnescapedValueTag)
}

/// The value's extent and width, and its offset parked in the pointer slot until
/// `resolveValuePointer` runs.
///
/// Writing the slot's integer alternative needs no `unsafe`.
@inline(always)
private func setParkedValue(
    _ bits: inout WebCore.CSSParserTokenBits,
    _ valueOffset: UInt32,
    _ valueLength: UInt32,
    _ valueIsUnescaped: Bool,
    _ is8Bit: Bool
) {
    bits.valueLength = valueLength
    bits.valueIs8Bit = is8Bit
    let tagged = valueIsUnescaped ? valueOffset | WebCore.cssParserTokenBitsUnescapedValueTag : valueOffset
    bits.parkedValueOffset = UInt(tagged)
}

// MARK: - The writers

@inline(always)
func makeSimpleTokenBits(_ type: UInt32, _ blockType: UInt32) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    bits.blockType = blockType
    return bits
}

@inline(always)
func makeValueTokenBits(
    _ type: UInt32,
    _ blockType: UInt32,
    _ valueOffset: UInt32,
    _ valueLength: UInt32,
    _ valueIsUnescaped: Bool,
    _ is8Bit: Bool
) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    bits.blockType = blockType
    setParkedValue(&bits, valueOffset, valueLength, valueIsUnescaped, is8Bit)
    bits.id = -1
    return bits
}

/// Zeroes the union's bytes above the delimiter, which the C++ constructor leaves unspecified;
/// nothing reads them.
@inline(always)
func makeDelimiterTokenBits(_ type: UInt32, _ character: UInt32) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    bits.delimiter = UInt16(truncatingIfNeeded: character)
    return bits
}

/// Zeroes the rest of the union, for the same reason as the delimiter factory above.
@inline(always)
func makeWhitespaceTokenBits(_ type: UInt32, _ count: UInt32) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    bits.whitespaceCount = count
    return bits
}

@inline(always)
func makeHashTokenBits(
    _ type: UInt32,
    _ isIdHashToken: Bool,
    _ valueOffset: UInt32,
    _ valueLength: UInt32,
    _ valueIsUnescaped: Bool,
    _ is8Bit: Bool
) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    setParkedValue(&bits, valueOffset, valueLength, valueIsUnescaped, is8Bit)
    bits.hashTokenType = isIdHashToken ? WebCore.HashTokenId : WebCore.HashTokenUnrestricted
    return bits
}

/// Numeric tokens keep their number unconverted so that `charactersToDouble` runs in C++ and
/// rounds as the C++ scanner does.
///
/// Until then the union holds the number's own range.
///
/// The number's range is separate from the value range because a DimensionToken's value is
/// either the number and unit merged ("10px", when they are adjacent and the number is shorter
/// than sixteen characters) or the unit alone (a long number, or an escaped unit held in a pooled
/// `String`).
///
/// `nonUnitPrefixLength` says which: zero for the bare unit, the number's length when merged.
/// `unitString()`, `operator==` and custom property serialization all depend on it, and a merged
/// value with a zero prefix length is a state `convertToDimensionWithUnit` cannot produce.
@inline(always)
func makeNumericTokenBits(
    _ type: UInt32,
    _ isNonInteger: Bool,
    _ hasPlusSign: Bool,
    _ hasMinusSign: Bool,
    _ unit: UInt32,
    _ valueOffset: UInt32,
    _ valueLength: UInt32,
    _ valueIsUnescaped: Bool,
    _ nonUnitPrefixLength: UInt32,
    _ numberOffset: UInt32,
    _ numberLength: UInt32,
    _ is8Bit: Bool
) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    bits.numericValueType = UInt32((isNonInteger ? WebCore.NumberValueType : WebCore.IntegerValueType).rawValue)
    bits.numericSign = UInt32(
        (hasMinusSign ? WebCore.MinusSign : (hasPlusSign ? WebCore.PlusSign : WebCore.NoSign)).rawValue
    )
    bits.unit = unit
    bits.nonUnitPrefixLength = nonUnitPrefixLength
    setParkedValue(&bits, valueOffset, valueLength, valueIsUnescaped, is8Bit)
    bits.pendingNumberRange.offset = numberOffset
    bits.pendingNumberRange.length = numberLength
    // The union's discriminant: `takeChunk` reads `pendingNumberRange` exactly when this is set.
    bits.hasParkedNumberRange = 1
    return bits
}
