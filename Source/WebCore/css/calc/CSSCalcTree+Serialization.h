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

// Whether the C++ serializer is compiled in at all. Off means the island is the only
// implementation, which is the measurement mode WebCore.xcconfig describes: it is how *deletable*
// is answered constructively rather than inferred from a symbol table.
//
// Spelled once, here, as a named condition rather than repeated as a two-clause `#if` at each of
// the guarded regions in CSSCalcTree+Serialization.cpp. A measurement whose boundary is written out
// four times is a measurement whose boundary can drift between them, and the count it produces is
// the thing being reported.
#if defined(USE_SWIFT_CSS_CALC_SERIALIZATION_NO_FALLBACK) && USE_SWIFT_CSS_CALC_SERIALIZATION_NO_FALLBACK
#if !defined(USE_SWIFT_CSS_CALC_SERIALIZATION) || !USE_SWIFT_CSS_CALC_SERIALIZATION
// Diagnosed here rather than left to produce a pile of link errors naming `serializeMathFunction`,
// which is what removing every serializer from a build that still selects one looks like.
#error "WK_USE_SWIFT_CSS_CALC_SERIALIZATION_NO_FALLBACK=YES requires WK_USE_SWIFT_CSS_CALC_SERIALIZATION=YES: it removes the only other serializer."
#endif
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
// The differential names `Serializer::Cpp` on one arm on purpose, and this mode is the removal of
// that arm. The two cannot be combined, and saying so here is cheaper than discovering it as a
// missing overload inside a 1,000-line bridge.
#error "WK_USE_SWIFT_CSS_CALC_SERIALIZATION_NO_FALLBACK=YES is mutually exclusive with WK_ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE=YES: the differential needs the C++ arm this mode removes."
#endif
#define CSS_CALC_CPP_SERIALIZER_COMPILED_IN 0
#else
#define CSS_CALC_CPP_SERIALIZER_COMPILED_IN 1
#endif

// https://drafts.csswg.org/css-values-4/#serialize-a-math-function
void serializationForCSS(StringBuilder&, const Tree&, const SerializationOptions&, Serializer = defaultSerializer);
String serializationForCSS(const Tree&, const SerializationOptions&, Serializer = defaultSerializer);

#if CSS_CALC_CPP_SERIALIZER_COMPILED_IN
// DEAD ON ARRIVAL, and the no-fallback measurement is what established it: these two have no caller
// anywhere in WebCore. Every production path goes through the `Tree` overloads above
// (CSSUnevaluatedCalc.cpp:284 and :293, the only two production call sites of any of these). They
// are counted as deletable for that reason rather than because the island replaced them -- nothing
// replaced them, because nothing called them.
void serializationForCSS(StringBuilder&, const Child&, const SerializationOptions&);
String serializationForCSS(const Child&, const SerializationOptions&);
#endif

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
// The kind of the last tree's ROOT, which the kind mask cannot answer: the mask says a `Negate`
// appeared somewhere, and the question S2 has to settle is whether one appears *as a root*, because
// that is the one position where the C++ drops step 4's `-1 * ` prefix. Accumulated by the
// differential over every tree it parses, so "no parse produces one" is measured rather than
// assumed.
uint32_t webCoreCSSCalcSerializationLastRootKind(void);
uint64_t webCoreCSSCalcSerializationSwiftCallCount(void);
#endif

} // namespace CSSCalc
} // namespace WebCore
