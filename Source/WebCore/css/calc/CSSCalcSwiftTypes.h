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

// Everything CSSCalcSerializationSwift.swift may see of WebCore. It has its own Clang module in
// WebCore_Private.modulemap and must stay self-contained: including CSSCalcTree.h or CSSTokenizer.h
// here walks the importer into the PrivateHeaders umbrella.
//
// Every function declared here must stay `noexcept`, or Swift emits a termination landing pad
// around each call to it. Anything added here needs a call graph that is C++ throughout, with no
// Objective-C frame that could `@throw` past it.

#pragma once

#include <WebCore/CSSUnitType.h>
#include <WebCore/PlatformExportMacros.h>
#include <cstddef>
#include <cstdint>
#include <wtf/SwiftBridging.h>

namespace WTF {
class StringBuilder;
}

namespace WebCore {

namespace CSS {
struct SerializationContext;
}

namespace CSSCalc {

struct Child;

// The shape of a node's serialization, not its operation: several operations share a kind, and
// `CSSCalcSwiftNodeInfo::valueID` carries the name, so the operator name table stays in C++.
// `Operation` is an operation this boundary has not been taught, and falls back to the C++ path.
//
// New cases are appended, never inserted. `CSSCalcSwiftSerializationResult::kindMask` is
// `1 << rawValue`, so inserting a case would silently relabel every existing coverage count.
enum class CSSCalcSwiftNodeKind : uint8_t {
    Number,
    Percentage,
    CanonicalDimension,
    NonCanonicalDimension,
    Symbol,
    SiblingCount,
    SiblingIndex,
    Sum,
    Product,
    Negate,
    Invert,
    Operation,
    // No producer. Retained because removing it would renumber every kind below it.
    OpaqueOperation,
    // `Deg2Rad`, which has no CSS-level spelling and serializes as its child.
    Transparent,
    Function,
    // `valueID` is the rounding strategy rather than the function name.
    RoundFunction,
    ProgressNoClampFunction,
    // `clamp()` with one bound holding the keyword `none` -- the one argument in the tree that is
    // not a child node, since `forAllChildNodes` skips a `ChildOrNone` holding `none`. Without
    // these, `clamp(none, VAL, MAX)` would serialize as `clamp(VAL, MAX)`. Two kinds rather than a
    // flag, so that an exhaustive `switch` is forced to decide. The both-`none` shape has a kind
    // too, `ClampWithNoneMinimumAndMaximum` below -- appended there rather than placed here because
    // these values are bit positions in `kindMask` and inserting one would relabel every kind after
    // it.
    ClampWithNoneMinimum,
    ClampWithNoneMaximum,
    // The four operations whose arguments are not a plain list of calculation trees; see
    // `CSSCalcSwiftOperationInfo`. `childCount` counts `Child`s only, so `random()`'s
    // `<random-key>`, `calc-mix()`'s per-item weights and `anchor()`'s keyword `<anchor-side>` are
    // not in it.
    RandomFunction,
    CalcMixFunction,
    AnchorFunction,
    AnchorSizeFunction,
    // `clamp(none, VAL, none)`: both bounds hold the keyword, so `childCount` is 1 and the two
    // `none`s are arguments the walk cannot see. Simplification rewrites this shape to `VAL`
    // (`simplify(Clamp&)`), so it reaches serialization only on
    // an unsimplified tree -- which is a reachable state, not a hypothetical one. Belongs beside the
    // other two `ClampWithNone...` kinds and is here instead because the numbering is append-only.
    ClampWithNoneMinimumAndMaximum,
};

// `CSSCalcSwiftSerializationResult::kindMask` is `1 << rawValue` in a `uint32_t`, and Swift's shift
// yields 0 for a count of 32 or more rather than trapping, so a kind at or past 32 would drop out of
// every coverage count while every assertion over the mask still passed. Keyed on the last
// enumerator, so appending one more than the mask can hold is a build failure.
static_assert(static_cast<uint8_t>(CSSCalcSwiftNodeKind::ClampWithNoneMinimumAndMaximum) < 32, "kindMask is 1 << rawValue in a UInt32");

// Everything the four operation kinds need that is neither a child subtree nor text. Each field is
// meaningful only for the kinds that carry it, and the rest are inert rather than indeterminate.
struct CSSCalcSwiftOperationInfo {
    // `Anchor`: the `<anchor-side>` keyword. `AnchorSize`: the `<anchor-size>` dimension keyword.
    // `Random`: `property-scoped` or `property-index-scoped`. `CSSValueInvalid` otherwise.
    uint16_t valueID;

    // Both false means `auto`, which serializes as omitted.
    bool randomSharingIsKey;
    bool randomSharingIsFixed;
    bool randomKeyHasName;
    bool randomKeyIsElementScoped;
    bool randomKeyHasPropertyScope;

    // When false, the `<anchor-side>` is a `<percentage>` subtree occupying child 0, which is what
    // makes the fallback's index depend on this.
    bool anchorSideIsKeyword;

    bool hasElementName;
    bool hasDimension;
    // Redundant with `childCount`, and kept so that a mismatch between the two is reported as a
    // contract violation rather than writing an argument in the wrong position.
    bool hasFallback;
};

// One node, described. Each field is meaningful only for the kinds that carry it, and the rest are
// inert (`CSSValueInvalid`, `CSSUnitType::Unknown`) rather than indeterminate.
struct CSSCalcSwiftNodeInfo {
    double numericValue;
    // Counts through `ChildOrNone` and `std::optional<Child>` exactly as `forAllChildNodes` does. A
    // `ChildOrNone` holding `none` is not counted, which is why the two `ClampWithNone...` kinds
    // exist: the count stays the number of subtrees to walk and the kind says where the keyword
    // goes.
    uint32_t childCount;
    uint16_t valueID;
    // `toCSSUnit(node)` for a numeric leaf.
    uint8_t unitType;
    CSSCalcSwiftNodeKind kind;
};

// MARK: - Reading a node
//
// A `const Child&` parameter is safe to Swift where a `const Child&` return is not -- only the
// return position imports as `UnsafePointer`. That is what lets `Child` stay incomplete here.
WEBCORE_EXPORT CSSCalcSwiftNodeInfo swiftNodeInfo(const Child&) noexcept;
WEBCORE_EXPORT CSSCalcSwiftOperationInfo swiftOperationInfo(const Child&) noexcept;

// Where the serialization output goes. Number formatting must stay an upcall: Swift's
// `Double.description` is shortest-round-trip and CSS number serialization is a different
// algorithm, so a Swift reimplementation would diverge on subnormals and 17-significant-digit
// values.
//
// `SWIFT_SAFE` is an unchecked assertion that the two raw pointers below are safely encapsulated,
// and it is what keeps every Swift use of this type free of an `unsafe` marker. It holds only while
// no Swift type declares a stored property of this type: every Swift signature naming it takes it
// `inout`, and an `inout` argument cannot be captured by an escaping closure.
struct SWIFT_SAFE CSSCalcSwiftSink {
    CSSCalcSwiftSink(WTF::StringBuilder& builder LIFETIME_BOUND, const CSS::SerializationContext& context LIFETIME_BOUND) noexcept
        : m_builder(&builder)
        , m_context(&context)
    {
    }

    // One entry for every fixed spelling, selected by `CSSCalcSwiftLiteral`, so that no text crosses
    // the boundary and there is exactly one copy of every CSS literal in the program. `uint8_t`
    // rather than the imported enum type, because this header is what the generated header is
    // generated from and cannot see the Swift enum's C name.
    WEBCORE_EXPORT void appendLiteral(uint8_t literal) noexcept;

    WEBCORE_EXPORT void appendNumber(double value, uint8_t unitType) noexcept;

    // `nameLiteralForSerialization(CSSValueID)`. C++ owns the table, which is generated and must not
    // be transcribed.
    WEBCORE_EXPORT void appendValueIDName(uint16_t valueID) noexcept;

    // Arguments that are CSS values rather than calculation trees. Routing them through
    // `appendNumber` would mean deciding in Swift that they are plain doubles in a known unit, a
    // claim about types Swift cannot see.
    WEBCORE_EXPORT void appendOperationArgument(const Child&, uint8_t part, uint32_t index) noexcept;

private:
    WTF::StringBuilder* m_builder;
    const CSS::SerializationContext* m_context;
};

// What the serialization walk did. `nodeCount` and `kindMask` make a fallback to the C++
// serializer observable, which the serialized output alone cannot.
struct CSSCalcSwiftSerializationResult {
    // Bit `1 << rawValue` for each CSSCalcSwiftNodeKind the walk stood on.
    uint32_t kindMask;
    uint32_t nodeCount;
    // 0 = serialized, 1 = declined. Not a `bool`, so a third outcome is not an ABI change; the
    // numbering is pinned by static_assert against the Swift enum.
    uint8_t outcome;
};

} // namespace CSSCalc
} // namespace WebCore
