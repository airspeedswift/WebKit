/*
 * Copyright (C) 2024 Samuel Weinig <sam@webkit.org>
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "CSSPrimitiveNumericRange.h"
#include <cstdint>
#include <wtf/Forward.h>

namespace WebCore {

namespace CSS {
struct SerializationContext;
}

namespace CSSCalc {

struct Child;
struct Tree;

struct SerializationOptions {
    // `range` represents the allowed numeric range for the calculated result.
    CSS::Range range;

    // `serializationContext` is the context used for CSS serialization state.
    const CSS::SerializationContext& serializationContext;
};

// Which implementation serializes the tree. Both are compiled in; this chooses which one the
// entry points below use, and the choice is made at compile time.
//
// Named explicitly by the validation bridge rather than taken from `defaultSerializer`, so that a
// differential compares the two arms whatever the build was configured with, and so that an
// ignored build flag cannot masquerade as a pass. Same arrangement, and for the same reasons, as
// `CSSTokenizer::Scanner` and `CSSParserFastPaths::ColorScanner`.
enum class Serializer : bool { Cpp, Swift };

// `defined() &&` rather than a `#if !defined / #define 0` prologue, which WebCore builds with
// -Werror,-Wundef would otherwise require: the flag is only ever defined as 1, by
// WK_USE_SWIFT_CSS_CALC_SERIALIZATION=YES, and that is where the choice lives.
static constexpr Serializer defaultSerializer =
#if defined(USE_SWIFT_CSS_CALC_SERIALIZATION) && USE_SWIFT_CSS_CALC_SERIALIZATION
    Serializer::Swift;
#else
    Serializer::Cpp;
#endif

// https://drafts.csswg.org/css-values-4/#serialize-a-math-function
void serializationForCSS(StringBuilder&, const Tree&, const SerializationOptions&, Serializer = defaultSerializer);
String serializationForCSS(const Tree&, const SerializationOptions&, Serializer = defaultSerializer);

void serializationForCSS(StringBuilder&, const Child&, const SerializationOptions&);
String serializationForCSS(const Child&, const SerializationOptions&);

#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
// Test-only, reached from CSSTokenizerSwiftBridge.cpp. The counter and the switch live beside the
// code that declines rather than in the bridge, for the reason CSSParserFastPaths.h:79 gives: a
// decline is invisible in an output comparison, because the C++ answer for a declined tree is the
// same C++ answer the comparison already trusts, so the count has to come from the code that
// declined and not from the code that asked.
void webCoreCSSCalcSerializationSetForceDecline(bool);
unsigned webCoreCSSCalcSerializationDeclineCount(void);
// The last walk's node count and kind mask, so a differential can assert that the island really
// descended through the tree and really reached every node kind it claims coverage of.
uint32_t webCoreCSSCalcSerializationLastNodeCount(void);
uint32_t webCoreCSSCalcSerializationLastKindMask(void);
uint64_t webCoreCSSCalcSerializationSwiftCallCount(void);
#endif

} // namespace CSSCalc
} // namespace WebCore
