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

#include "CSSCalcSwiftTypes.h"
#include "CSSCalcSymbolsAllowed.h"
#include "CSSPrimitiveNumericRange.h"
#include "CSSPropertyParserOptions.h"
#include <optional>

namespace WebCore {

namespace CSS {
enum class Category : uint8_t;
}

namespace CSS {
struct PropertyParserState;
}

class CSSParserTokenRange;
struct CSSParserContext;

enum CSSValueID : uint16_t;

namespace CSSCalc {

struct SimplificationOptions;
struct Tree;

struct ParserOptions {
    // `category` represents the context in which the parse is taking place.
    CSS::Category category;

    // `range` represents the allowed numeric range for the calculated result.
    CSS::Range range;

    // `allowedSymbols` contains additional symbols that can be used in the calculation. These will need to be resolved before the calculation can be resolved.
    CSSCalcSymbolsAllowed allowedSymbols;

    // `propertyOptions` contains options about the specific property the calc() is intended to be used with.
    CSSPropertyParserOptions propertyOptions;
};

// Whether the C++ recursive-descent parser is compiled in: exactly when the Swift CSS
// implementation is not (WK_USE_SWIFT_CSS). There is one parser in any build.
#if USE(SWIFT_CSS)
#define CSS_CALC_CPP_PARSER_COMPILED_IN 0
#else
#define CSS_CALC_CPP_PARSER_COMPILED_IN 1
#endif

// Parses and simplifies the provided `CSSParserTokenRange` into a CSSCalc::Tree. Returns `std::nullopt` on failure.
std::optional<Tree> parseAndSimplify(CSSParserTokenRange&, CSS::PropertyParserState&, const ParserOptions&, const SimplificationOptions&);

// Parses and simplifies a bare `<calc-sum>`, one that is not wrapped in a math function.
//
// Used by `calc-size()`.
//
// Unlike `parseAndSimplify`, this consumes part of the range: `<calc-sum>` stops at the top-level
// comma in `calc-size(<calc-size-basis>, <calc-sum>)`, which the caller consumes next.
std::optional<Tree> parseAndSimplifyCalcSum(CSSParserTokenRange&, CSS::PropertyParserState&, const ParserOptions&, const SimplificationOptions&);

// Returns whether the provided `CSSValueID` is one of the functions that should be parsed as a `calc()`.
bool NODELETE isCalcFunction(CSSValueID function);

} // namespace CSSCalc
} // namespace WebCore
