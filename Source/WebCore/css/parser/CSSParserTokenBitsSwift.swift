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

// The island's writers for `CSSParserTokenBits` -- one per token kind, so a producer that knows
// the kind statically never encodes it for a consumer to decode again.
//
// THESE WERE C++, AND THE REASON THEY WERE IS FALSE. CSSParserTokenBits.h said "Swift cannot
// name a bitfield or an anonymous union member, so it does not: it calls the inline setters
// below", and `tokenBitsType` repeated it. Swift can name all of it -- the bitfields, the
// anonymous union's members, and even `pendingNumberRange`, a nested anonymous struct inside
// that union -- and it can default-construct the struct and read the bitfields back. It can
// also name `NumericValueType`, `NumericSign` and `HashTokenType`, which is what the C++ side
// was mapping booleans onto "because these enums have no static_assert bridge": they are
// declared in CSSParserTokenBits.h, which IS the island's boundary module, so naming them
// mirrors nothing. Probes, with anti-vacuity arms, at ~/src/webkit-swift-ports/bitfieldimport/.
//
// So C++ keeps exactly what C++ uses -- `resolveValuePointer`, `bitsParkedValueOffset`,
// `bitsCarryPendingNumber` and the tag -- and the writers, which only ever had Swift callers,
// live here beside the code that calls them.
//
// The struct itself stays in C++: it is `CSSParserToken`'s own storage, and the whole point is
// that one definition is compiled by both languages.

internal import WebCore_Private.CSSTokenizerSwiftTypes

// MARK: - Parking a value offset in the pointer slot

/// Whether this input's offsets can be tagged, called once per tokenization rather than once
/// per token.
///
/// A stylesheet at or above 2 GB cannot have its value offsets tagged, and the island has no
/// fallback, so it reports failure instead of truncating. Nothing real comes close; "surely
/// not" is not a bound.
///
/// And this is a **memory-safety** property rather than the representability one that sentence
/// describes, which is why it earns its keep beyond "no stylesheet is 2 GB". While Swift owns a
/// token the pointer slot holds the offset, so a `CSSParserToken` built from bits that never
/// went through `resolveValuePointer` would dereference a small integer. Darwin's `__PAGEZERO`
/// is 4 GB -- `otool -l` on this framework reports `vmsize 0x100000000` for it -- and this check
/// keeps every parked offset below 2^31 untagged and below 2^32 tagged, so every unresolved
/// offset lies strictly inside that guard page and a mis-sequenced resolve faults
/// deterministically instead of reading live heap. Drop the check and an offset could exceed
/// 4 GB, at which point it would not. Ledger R1.
@inline(always)
func cssParserTokenBitsCanRepresentOffsets(_ inputLength: Int) -> Bool {
    inputLength < Int(WebCore.cssParserTokenBitsUnescapedValueTag)
}

/// The value tail: its extent, its width, and its offset parked in the slot that will hold the
/// pointer once `resolveValuePointer` has run on the C++ side.
///
/// ZERO `unsafe` MARKERS, and getting there was the interesting part. The slot used to be
/// declared `const void*`, and under strict memory safety (SE-0458) *any* expression of type
/// `UnsafeRawPointer` is unsafe -- forming one, storing one, whether or not it is ever
/// dereferenced -- so the island could not write the field at all without a marker. Swift was
/// right to object: the declaration claimed a pointer where an integer was being stored. The
/// answer was to stop lying in the type. `CSSParserTokenBits` now declares the slot as a union
/// of `valueDataCharRaw` and `parkedValueOffset`, which is what it always was, and writing the
/// integer alternative is ordinary safe Swift. It also took two `reinterpret_cast`s out of the
/// C++ side, which were the same lie seen from the other end.
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

/// The C++ constructor this mirrors uses designated mem-initialisers, so it leaves the union's
/// bytes above the delimiter unspecified where this zeroes them through `numericValue`'s default
/// member initialiser. Behaviourally identical -- nothing may read a union member that was never
/// written -- and better defined, so it is deliberate rather than an oversight.
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
    // The imported C++ enumerations, not a mirrored numbering: they are declared in
    // CSSParserTokenBits.h, which is this island's boundary module.
    bits.numericValueType = UInt32((isNonInteger ? WebCore.NumberValueType : WebCore.IntegerValueType).rawValue)
    bits.numericSign = UInt32(
        (hasMinusSign ? WebCore.MinusSign : (hasPlusSign ? WebCore.PlusSign : WebCore.NoSign)).rawValue)
    bits.unit = unit
    bits.nonUnitPrefixLength = nonUnitPrefixLength
    setParkedValue(&bits, valueOffset, valueLength, valueIsUnescaped, is8Bit)
    bits.pendingNumberRange.offset = numberOffset
    bits.pendingNumberRange.length = numberLength
    // The union's discriminant, written together with the member it discriminates so the two
    // cannot drift. `bitsCarryPendingNumber` answers "does a token of this *type* owe a double",
    // which is a property of the type and therefore says nothing about whether this factory is
    // the one that produced the token; a numeric type reaching any other factory leaves
    // `numericValue` active and would have its double read out as an offset and a length.
    // `takeChunk` requires this flag before it touches `pendingNumberRange`, so that read is no
    // longer through a member nothing wrote. Ledger R2.
    bits.hasParkedNumberRange = 1
    return bits
}
