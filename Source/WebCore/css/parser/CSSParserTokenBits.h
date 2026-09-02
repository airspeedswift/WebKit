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

// CSSParserToken's storage, in its own header so that exactly one definition is compiled by
// both C++ and Swift. Self-contained on purpose: the island's boundary module takes this and
// nothing else, so importing it cannot walk into WebCore's umbrella.
//
// Swift cannot name a bitfield or an anonymous union member, so it does not: it calls the
// inline setters below, which are the only place the packing is written down.

#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <wtf/SwiftBridging.h>

namespace WebCore {

enum NumericSign {
    NoSign,
    PlusSign,
    MinusSign,
};

enum NumericValueType {
    IntegerValueType,
    NumberValueType,
};

enum HashTokenType {
    HashTokenId,
    HashTokenUnrestricted,
};

// CSSParserToken's storage, lifted out of the class *unchanged* so one definition can be
// compiled by both C++ and Swift. The island used to emit a different struct carrying offsets
// plus a type tag, which C++ decoded back into a typed constructor call -- a dispatch the
// producer had already made for free. Sharing the real storage lets the island write finished
// tokens instead, and that round trip is gone.
//
// Same fields, same order, same bitfield widths, so the object's layout and every accessor's
// codegen are unchanged. Lifting it out was a pure refactor and was verified as one.
// SWIFT_SAFE, and it is honest rather than a silencer: the pointer slot holds an *offset*
// for as long as Swift can see the struct -- resolveValuePointer turns it into a pointer only
// after the chunk has crossed into C++. So Swift never forms or dereferences one, and there is
// no lifetime to model either, which is why this needs no ~Escapable and sidesteps the whole
// problem that blocked handing Swift a real CSSParserToken.
struct SWIFT_SAFE CSSParserTokenBits {
    unsigned type : 6 { 0 }; // CSSParserTokenType
    unsigned blockType : 2 { 0 }; // BlockType
    unsigned numericValueType : 1 { 0 }; // NumericValueType
    unsigned numericSign : 2 { 0 }; // NumericSign
    unsigned unit : 7 { 0 }; // CSSUnitType
    unsigned nonUnitPrefixLength : 4 { 0 }; // Only for DimensionType, only needs to be long enough for UnicodeRange parsing.

    // value... is an unpacked StringView so that we can pack it
    // tightly with the rest of this object for a smaller object size.
    bool valueIs8Bit : 1 { false };
    bool isBackedByStringLiteral : 1 { false };
    // Whether the union below carries pendingNumberRange rather than one of the other members:
    // the union's active member is a *phase* of the crossing and not a function of `type`, so it
    // is discriminated here explicitly instead of being inferred. Set by makeNumericTokenBits,
    // which is the only writer of that member, and cleared by every other factory and by every
    // one of CSSParserToken's own constructors, so a numeric token that did not come from that
    // factory is distinguishable rather than being read through the wrong member. Ledger R2.
    //
    // Costs nothing: the bitfields above sum to 24 bits, so this lands in the eight free bits of
    // the same 32-bit allocation unit. CSSParserToken.h static_asserts the size, and
    // cssprobe/probes/bits-packing-probe.cpp is the standalone check that it packs.
    unsigned hasParkedNumberRange : 1 { 0 };
    unsigned valueLength { 0 };
    // The value's characters, and the slot's type depends on which side owns the token -- which
    // is why it is a union rather than a `const void*` Swift stores an integer into.
    //
    // WHILE SWIFT OWNS THE TOKEN this holds `parkedValueOffset`, an offset into the input (or,
    // tagged, into the chunk's unescape buffer); `resolveValuePointer` turns it into
    // `valueDataCharRaw` once the chunk has crossed into C++. That was true before this was a
    // union too -- what was NOT true was the declared type, which said `const void*` throughout
    // and made C++ `reinterpret_cast` an integer in and out of a pointer slot.
    //
    // Stating it as a union is what lets Swift write the offset with NO `unsafe` marker. Any
    // expression of type `UnsafeRawPointer` is unsafe under strict memory safety (SE-0458),
    // whether or not it is ever dereferenced, so with the old declaration the island could not
    // write this field at all without one -- and Swift was right to object, because the type was
    // claiming a pointer where an integer was being stored. It is the same phase-dependent
    // storage the union below models for the number range, and it gets the same treatment.
    //
    // `uintptr_t` and not `uint32_t`: the alternative has to cover the whole slot, or writing the
    // offset would leave the pointer's upper four bytes indeterminate.
    //
    // Anonymous, so every existing `valueDataCharRaw` use site in the CSS parser is untouched.
    union {
        const void* valueDataCharRaw { nullptr }; // Either Latin1Character* or char16_t*.
        uintptr_t parkedValueOffset;
    };

    union {
        char16_t delimiter;
        HashTokenType hashTokenType;
        double numericValue { 0 };
        mutable int id;
        unsigned whitespaceCount;

        // While the island still holds the token, the number's own range in the input.
        // resolveNumericValue reads it and overwrites it with numericValue -- the range is
        // dead the moment the double exists, and the double is the only thing that survives.
        // Read only when hasParkedNumberRange says it was written; see that field.
        struct { unsigned offset; unsigned length; } pendingNumberRange;
    };
};


// MARK: - What C++ still does with the bits
//
// The WRITERS ARE IN SWIFT (CSSParserTokenBitsSwift.swift), beside the code that calls them --
// they never had a C++ caller. They were here because this header claimed "Swift cannot name a
// bitfield or an anonymous union member"; it can name every part of this struct, including
// `pendingNumberRange`, and it can name `NumericValueType`/`NumericSign`/`HashTokenType`, which
// are declared below and so are in the island's boundary module rather than being mirrored.
// Probes at ~/src/webkit-swift-ports/bitfieldimport/.
//
// What is left here is what the C++ side genuinely does: read a parked offset back, ask whether
// a token still owes a double, and turn the offset into a pointer.

// Which buffer a parked value offset indexes. Set means the chunk's unescape buffer, clear
// means the input. There is no room in CSSParserTokenBits for a flag of its own -- every bit
// of it is CSSParserToken::m_bits, and adding one would change the object the whole CSS
// parser stores -- but the pointer slot holds a 32-bit offset for as long as Swift owns the
// token, so the top bit of that is free until resolveValuePointer runs.
constexpr unsigned cssParserTokenBitsUnescapedValueTag = 0x80000000u;

// The offset Swift parked in the pointer slot, tag included. Only meaningful before
// resolveValuePointer has run.
inline unsigned bitsParkedValueOffset(const CSSParserTokenBits& bits)
{
    return static_cast<unsigned>(bits.parkedValueOffset);
}

// NumberToken, PercentageToken and DimensionToken are 7, 8 and 9 in CSSParserTokenType, and
// contiguous, so "does this token still owe a double" is one unsigned range check rather than a
// switch. The enumerators cannot be named here: this header is deliberately free of
// CSSParserToken.h so the island's Clang module can take it alone. CSSParserToken.h is the one
// place that can see both, and it static_asserts these literals against the enumerators, because
// a stand-in whose value drifts from the real definition with no diagnostic is a failure this
// project has already paid for.
constexpr unsigned firstNumericCSSParserTokenType = 7; // NumberToken
constexpr unsigned lastNumericCSSParserTokenType = 9; // DimensionToken

// The *reader* half of the pendingNumberRange discipline, and only that half: it answers "does a
// token of this type still owe a double", from the type alone. CSSParserToken.h proves it against
// a three-way test over all 33 types. What it cannot answer is whether the token came from
// makeNumericTokenBits, which is the only writer of that union member -- that is what
// CSSParserTokenBits::hasParkedNumberRange is for, and takeChunk requires both to agree before it
// reads the range. Ledger R2.
inline constexpr bool bitsCarryPendingNumber(const CSSParserTokenBits& bits)
{
    return bits.type - firstNumericCSSParserTokenType <= lastNumericCSSParserTokenType - firstNumericCSSParserTokenType;
}

// The branch-free half of the boundary: an offset becomes a pointer, with no reference to
// the token's kind. Only for an offset into the *input* -- a caller that finds
// cssParserTokenBitsUnescapedValueTag set has to intern the value first and set the three
// value fields itself, because there is no input range to point at.
//
// A token that carries no value has to come out with a *null* value pointer rather than a
// pointer to the start of the input with length zero. Every constructor leaves the slot null
// for such a token, so value() is a null StringView there, and null and empty are not
// interchangeable: StringView::isNull distinguishes them, and toString turns the one into a null
// String and the other into an empty one. The comment that used to sit here claimed base + 0 was
// harmless, and it was wrong.
//
// The unresolved state of a valueless token is exactly offset zero with length zero, and no
// real value can hold it. A zero-length value only occurs inside a delimited token -- `""` or
// `url()` -- so its range always starts past the opening delimiter and its offset is never
// zero. Testing the two fields together therefore separates the cases exactly, and it is an or,
// a compare and a select rather than a branch: the resolved pointer is computed unconditionally
// on both paths.
// `characterSize` is a template parameter and not an argument, because it is a property of the
// *tokenization* and not of a token: CSSSwiftTokenSink::create decides it once, from the same
// StringImpl::is8Bit that picks which of the island's two specializations runs. Passing it as a
// value made both scalings below runtime multiplies that the compiler could not see through, since
// the value reached them through a member. Specialized, the 8-bit instantiation has no multiply at
// all and the 16-bit one folds one doubling into the shifted-register operand of a compare and the
// other into the address it already had to form. Measured at -O2 under
// _LIBCPP_HARDENING_MODE_EXTENSIVE: 16 instructions with the width as an argument, 13 at 8-bit and
// 14 at 16-bit specialized, against 13 for the *unchecked* one-argument version that shipped in
// e5183bac37fd -- so the extent bound costs two instructions rather than three and the checked
// resolve ties the unchecked one at the width that matters. Inlined into takeChunk, where the slot
// load is shared with the tag test, the per-value-token path is 13 before and 12 after at both
// widths. Revisit log R104, ledger S13.
template<unsigned characterSize>
inline void resolveValuePointer(CSSParserTokenBits& bits, std::span<const uint8_t> input)
{
    static_assert(characterSize == 1 || characterSize == 2, "the only two StringImpl widths");
    // Read through the union's integer alternative, which is the one Swift wrote. This was a
    // `reinterpret_cast` off `valueDataCharRaw` while the slot was declared a pointer.
    auto offset = bits.parkedValueOffset;
    // subspan rather than pointer arithmetic: libc++ hardening is on in this build, so this
    // is a real bounds check on a value that crossed a language boundary, which the raw form
    // would not have been.
    //
    // The **two**-argument overload, because the extent crossed the boundary too. libc++ checks
    // `offset <= size()` for subspan(offset) and additionally `count <= size() - offset` for
    // subspan(offset, count) (span:522-527), and value() is
    // `StringView { valueDataCharRaw, valueLength, valueIs8Bit }` -- a raw pointer and a trusted
    // count -- so with only the one-argument form a valueLength the island got wrong was an
    // out-of-bounds read for every later reader of that value, not a mis-parse. The code this
    // replaced, `CSSTokenizerInputStream::rangeAt`, clamped both through StringView::substring
    // and so was structurally incapable of over-reading; this restores that property without
    // restoring the silence. The pointer is identical either way. Ledger S13, revisit log R101.
    const void* resolved = input.subspan(offset * characterSize, size_t { bits.valueLength } * characterSize).data();
    bits.valueDataCharRaw = (offset | bits.valueLength) ? resolved : nullptr;
}

} // namespace WebCore
