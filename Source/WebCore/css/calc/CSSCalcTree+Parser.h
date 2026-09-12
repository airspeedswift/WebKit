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

// When the parse simplifies. Shaped like `CSSCalc::Simplifier` and `CSSCalc::Serializer`: a
// compile-time selector with a named default.
//
//   Eager     the parse simplifies node by node as it builds, through the per-operation
//             `simplify(Op&, ...)` call sites in CSSCalcTree+Parser.cpp, and returns a tree already
//             at a fixed point for the options it was parsed with. There is no terminal whole-tree
//             pass. This is the one mode a build with the C++ simplifier compiled out cannot offer,
//             and the one mode the Swift parser does not implement.
//   Terminal  the parse builds the tree and simplifies it once at the end, through
//             `copyAndSimplify(Tree)`.
//   None      the parse does not simplify at all. `Terminal` is `None` followed by one
//             `copyAndSimplify`, and is implemented that way.
//
// `None` is not a test-only mode: `consumeAnchor` builds a `ParserState` with a null
// `simplificationOptions` for the anchor-side `<percentage>` sub-parse, so an unsimplified parse is
// a configuration this file already runs in production.
//
// `defaultParseSimplification` is used as a default argument, so it is evaluated in the caller's
// translation unit. That is fine while it is a plain constant; were it ever made to depend on a
// build define, every target that calls `parseAndSimplify` would need that define or callers would
// silently select different modes.
enum class ParseSimplification : uint8_t { Eager, Terminal, None };
static constexpr ParseSimplification defaultParseSimplification = ParseSimplification::Terminal;

// MARK: Parser selection

// Which implementation parses. Shaped like `CSSCalc::Simplifier`, `CSSCalc::Serializer` and
// `CSSTokenizer::Scanner`: both implementations compiled in, the choice made at compile time, with
// C++ as the fallback for input the Swift parser does not cover.
//
// A parameter rather than a `#if` inside `parseAndSimplify`, because the validation bridge's
// reference implementation is `parseAndSimplify` itself: with a compile-time-only selector, a build
// that selected Swift would have the bridge compare the Swift parser against itself and report no
// mismatches while testing nothing.
enum class Parser : bool { Cpp, Swift };

// `defined() &&` rather than a `#if !defined / #define 0` prologue, for the same reason as
// `defaultSimplifier`: the flag is only ever defined as 1, by WK_USE_SWIFT_CSS_CALC_PARSER=YES.
//
// As above, this is a default argument evaluated in the caller's translation unit, so every target
// that calls `parseAndSimplify` must see the same value. This is a project header rather than a
// private one, so all of its includers are WebCore translation units and take the define from one
// place, WebCore.xcconfig's GCC_PREPROCESSOR_DEFINITIONS. If it ever becomes a private header, the
// parser has to be passed explicitly at every call.
static constexpr Parser defaultParser =
#if defined(USE_SWIFT_CSS_CALC_PARSER) && USE_SWIFT_CSS_CALC_PARSER
    Parser::Swift;
#else
    Parser::Cpp;
#endif

// Parses and simplifies the provided `CSSParserTokenRange` into a CSSCalc::Tree. Returns `std::nullopt` on failure.
std::optional<Tree> parseAndSimplify(CSSParserTokenRange&, CSS::PropertyParserState&, const ParserOptions&, const SimplificationOptions&, ParseSimplification = defaultParseSimplification, Parser = defaultParser);

// Parses and simplifies a bare `<calc-sum>`, one that is not wrapped in a math function.
std::optional<Tree> parseAndSimplifyCalcSum(CSSParserTokenRange&, CSS::PropertyParserState&, const ParserOptions&, const SimplificationOptions&, ParseSimplification = defaultParseSimplification);

// Returns whether the provided `CSSValueID` is one of the functions that should be parsed as a `calc()`.
bool NODELETE isCalcFunction(CSSValueID function);

} // namespace CSSCalc
} // namespace WebCore
