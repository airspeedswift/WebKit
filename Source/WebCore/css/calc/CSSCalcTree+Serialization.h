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

// Whether the C++ serializer is compiled in: exactly when the Swift CSS implementation is not
// (WK_USE_SWIFT_CSS). There is one serializer in any build, and nothing chooses between them.
#if USE(SWIFT_CSS)
#define CSS_CALC_CPP_SERIALIZER_COMPILED_IN 0
#else
#define CSS_CALC_CPP_SERIALIZER_COMPILED_IN 1
#endif

// https://drafts.csswg.org/css-values-4/#serialize-a-math-function
void serializationForCSS(StringBuilder&, const Tree&, const SerializationOptions&);
String serializationForCSS(const Tree&, const SerializationOptions&);

#if CSS_CALC_CPP_SERIALIZER_COMPILED_IN
// These two overloads have no caller anywhere in WebCore; every production path goes through the
// `Tree` overloads above.
void serializationForCSS(StringBuilder&, const Child&, const SerializationOptions&);
String serializationForCSS(const Child&, const SerializationOptions&);
#endif

// Serializes a `<calc-sum>` as a math function argument, omitting the grouping parentheses. Same
// `Serializer` selection as the two entry points above, and for the same reason.
void serializationForCSSAsFunctionArgument(StringBuilder&, const Tree&, const SerializationOptions&);


} // namespace CSSCalc
} // namespace WebCore
