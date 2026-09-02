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

// Writers for `CSSParserTokenBits`, one per token kind; called only from Swift.
//
// C++ keeps `resolveValuePointer`, `bitsParkedValueOffset`, `bitsCarryPendingNumber` and the
// type tag. The struct itself is defined in CSSParserTokenBits.h so both languages compile the
// same layout.

internal import WebCore_Private.CSSTokenizerSwiftTypes

// MARK: - Parking a value offset in the pointer slot

/// Whether this input's offsets can be tagged; call once per tokenization, not per token.
///
/// A stylesheet at or above 2 GB cannot have its value offsets tagged, so tokenization reports
/// failure instead of truncating.
///
/// This is a memory-safety property, not just a representability check: while Swift owns a
/// token, the pointer slot holds the offset, so a `CSSParserToken` built from bits that never
/// went through `resolveValuePointer` would dereference a small integer. Darwin's `__PAGEZERO`
/// is 4 GB (`otool -l` reports `vmsize 0x100000000`), and this check keeps every parked offset
/// below 2^31 untagged and below 2^32 tagged, so an unresolved offset always lies inside that
/// guard page and a mis-sequenced resolve faults deterministically instead of reading live heap.
@inline(always)
func cssParserTokenBitsCanRepresentOffsets(_ inputLength: Int) -> Bool {
    inputLength < Int(WebCore.cssParserTokenBitsUnescapedValueTag)
}

/// The value tail: its extent, its width, and its offset parked in the slot that will hold the
/// pointer once `resolveValuePointer` has run on the C++ side.
///
/// Written with no `unsafe` markers: `CSSParserTokenBits` declares the slot as a union of
/// `valueDataCharRaw` and `parkedValueOffset`, so writing the integer alternative is ordinary
/// safe Swift. Declaring the slot as `const void*` here would require `unsafe`, since under
/// strict memory safety (SE-0458) every expression of type `UnsafeRawPointer` is unsafe to
/// form or store, whether or not it is dereferenced.
@inline(always)
private func setParkedValue(
    _ bits: inout WebCore.CSSParserTokenBits,
    _ valueOffset: UInt32, _ valueLength: UInt32, _ valueIsUnescaped: Bool, _ is8Bit: Bool
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
    _ type: UInt32, _ blockType: UInt32, _ valueOffset: UInt32, _ valueLength: UInt32,
    _ valueIsUnescaped: Bool, _ is8Bit: Bool
) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    bits.blockType = blockType
    setParkedValue(&bits, valueOffset, valueLength, valueIsUnescaped, is8Bit)
    bits.id = -1
    return bits
}

/// The C++ constructor this mirrors leaves the union's bytes above the delimiter unspecified
/// (designated mem-initialisers); this zeroes them via `numericValue`'s default member
/// initialiser instead. Behaviourally identical, since nothing may read an unwritten union
/// member, and more precisely defined.
@inline(always)
func makeDelimiterTokenBits(_ type: UInt32, _ character: UInt32) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    bits.delimiter = UInt16(truncatingIfNeeded: character)
    return bits
}

/// Zeroes the rest of the union where the C++ constructor leaves it unspecified, for the same
/// reason as the delimiter factory above.
@inline(always)
func makeWhitespaceTokenBits(_ type: UInt32, _ count: UInt32) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    bits.whitespaceCount = count
    return bits
}

@inline(always)
func makeHashTokenBits(
    _ type: UInt32, _ isIdHashToken: Bool, _ valueOffset: UInt32, _ valueLength: UInt32,
    _ valueIsUnescaped: Bool, _ is8Bit: Bool
) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    setParkedValue(&bits, valueOffset, valueLength, valueIsUnescaped, is8Bit)
    bits.hashTokenType = isIdHashToken ? WebCore.HashTokenId : WebCore.HashTokenUnrestricted
    return bits
}

/// Numeric tokens keep their double unconverted: `charactersToDouble` runs on the C++ side so
/// the rounding stays bit-identical with the C++ scanner, for free. Until that post-pass runs the
/// union carries the number's own range instead, which costs nothing because the slot the double
/// will occupy is dead until it exists.
///
/// The number's range and the value range are separate parameters because they are separate
/// things, and the first is not recoverable from the second. For a NumberToken they do coincide
/// -- `value()` is `originalText()` is the number. But a DimensionToken merges the number and the
/// unit into one view when they are physically adjacent in the input and the number is shorter
/// than sixteen characters, and after that merge `value()` is "10px" and the number's own range is
/// only recoverable if you know the merge happened. In the two cases where it did not -- a number
/// of sixteen characters or more, and an escaped unit, whose text is a pooled `String` rather than
/// a range of the input -- `value()` is the unit alone and the number is nowhere in it.
///
/// `nonUnitPrefixLength` is the field that records which of those happened: zero when the value is
/// the bare unit, the number's length when the two were merged. It is not a detail the caller may
/// leave at its default, because `unitString()` is defined as
/// `value().substring(nonUnitPrefixLength)`, `operator==` selects which comparison a
/// DimensionToken gets on whether it is zero, and custom property serialization reserializes from
/// `value()`. A merged value with a zero prefix length is a state `convertToDimensionWithUnit` can
/// never produce, and every one of those three would read it as a unit sixteen characters long.
@inline(always)
func makeNumericTokenBits(
    _ type: UInt32, _ isNonInteger: Bool, _ hasPlusSign: Bool, _ hasMinusSign: Bool,
    _ unit: UInt32, _ valueOffset: UInt32, _ valueLength: UInt32, _ valueIsUnescaped: Bool,
    _ nonUnitPrefixLength: UInt32, _ numberOffset: UInt32, _ numberLength: UInt32, _ is8Bit: Bool
) -> WebCore.CSSParserTokenBits {
    var bits = WebCore.CSSParserTokenBits()
    bits.type = type
    // Uses the imported C++ enumeration directly, not a mirrored numbering.
    bits.numericValueType = UInt32((isNonInteger ? WebCore.NumberValueType : WebCore.IntegerValueType).rawValue)
    bits.numericSign = UInt32(
        (hasMinusSign ? WebCore.MinusSign : (hasPlusSign ? WebCore.PlusSign : WebCore.NoSign)).rawValue)
    bits.unit = unit
    bits.nonUnitPrefixLength = nonUnitPrefixLength
    setParkedValue(&bits, valueOffset, valueLength, valueIsUnescaped, is8Bit)
    bits.pendingNumberRange.offset = numberOffset
    bits.pendingNumberRange.length = numberLength
    // The union's discriminant, written together with the member it discriminates so the two
    // cannot drift. `bitsCarryPendingNumber` answers "does a token of this type owe a double",
    // a property of the type, not of which factory produced it; a numeric type reaching any
    // other factory leaves `numericValue` active. `takeChunk` requires this flag before it
    // touches `pendingNumberRange`.
    bits.hasParkedNumberRange = 1
    return bits
}
