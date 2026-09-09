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

// WHEN the parse simplifies. Shaped exactly like `CSSCalc::Simplifier` and `CSSCalc::Serializer` --
// a compile-time selector with a named default -- so that both behaviours stay in tree and the
// differential can run either on demand.
//
//   Eager     today's production behaviour. The parse simplifies node by node as it builds, through
//             the eighteen per-operation `simplify(Op&, ...)` call sites in CSSCalcTree+Parser.cpp,
//             and returns a tree that is already at a fixed point for the options it was parsed
//             with. There is NO terminal whole-tree pass.
//   Terminal  the parse builds the tree and simplifies it ONCE at the end, through
//             `copyAndSimplify(Tree)` -- which is the entry the Swift island already serves at 0
//             declines over all 41 alternatives. This is what puts the island on the parse path.
//   None      the parse does not simplify at all. `Terminal` is exactly `None` followed by one
//             `copyAndSimplify`, and that is how it is implemented.
//
// `None` IS NOT A TEST-ONLY ENUMERATOR bolted on for the differential, although the differential is
// its first caller: `consumeAnchor` already builds a `ParserState` with a null
// `simplificationOptions` for the anchor-side `<percentage>` sub-parse (CSSCalcTree+Parser.cpp), so
// an unsimplified parse is a configuration this file already runs in production. All three
// enumerators do here what the recursion already does one level down.
//
// A NOTE FOR WHOEVER FLIPS THE DEFAULT. `defaultParseSimplification` is used as a DEFAULT ARGUMENT,
// so it is evaluated in the CALLER's translation unit. That is fine while it is a plain constant. If
// it is ever made to depend on a build define, every target that calls `parseAndSimplify` needs that
// define -- the `CombinedURLFilters::defaultBuilder` trap, which silently left ten tests on the old
// arm and would have reported a false pass.
enum class ParseSimplification : uint8_t { Eager, Terminal, None };
static constexpr ParseSimplification defaultParseSimplification = ParseSimplification::Eager;

// Parses and simplifies the provided `CSSParserTokenRange` into a CSSCalc::Tree. Returns `std::nullopt` on failure.
std::optional<Tree> parseAndSimplify(CSSParserTokenRange&, CSS::PropertyParserState&, const ParserOptions&, const SimplificationOptions&, ParseSimplification = defaultParseSimplification);

// Returns whether the provided `CSSValueID` is one of the functions that should be parsed as a `calc()`.
bool NODELETE isCalcFunction(CSSValueID function);

} // namespace CSSCalc
} // namespace WebCore
