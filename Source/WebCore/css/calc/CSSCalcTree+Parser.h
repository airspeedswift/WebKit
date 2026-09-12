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
//   Eager     the behaviour that shipped until this file's default moved to `Terminal`. The parse
//             simplifies node by node as it builds, through the eighteen per-operation
//             `simplify(Op&, ...)` call sites in CSSCalcTree+Parser.cpp, and returns a tree that is
//             already at a fixed point for the options it was parsed with. There is NO terminal
//             whole-tree pass. Retained because the differential compares the two arms, and because
//             it is the only arm a `CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN` build can offer.
//   Terminal  TODAY'S PRODUCTION BEHAVIOUR. The parse builds the tree and simplifies it ONCE at the
//             end, through `copyAndSimplify(Tree)` -- which is the entry the Swift island already
//             serves at 0 declines over all 41 alternatives. This is what puts the island on the
//             parse path: with `WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION=YES` the island now sees every
//             `calc()` in every stylesheet, which it never did while the default was `Eager`.
//   None      the parse does not simplify at all. `Terminal` is exactly `None` followed by one
//             `copyAndSimplify`, and that is how it is implemented.
//
// `None` IS NOT A TEST-ONLY ENUMERATOR bolted on for the differential, although the differential is
// its first caller: `consumeAnchor` already builds a `ParserState` with a null
// `simplificationOptions` for the anchor-side `<percentage>` sub-parse (CSSCalcTree+Parser.cpp), so
// an unsimplified parse is a configuration this file already runs in production. All three
// enumerators do here what the recursion already does one level down.
//
// A NOTE FOR WHOEVER CHANGES THE DEFAULT. `defaultParseSimplification` is used as a DEFAULT
// ARGUMENT, so it is evaluated in the CALLER's translation unit. That is fine while it is a plain
// constant. If it is ever made to depend on a build define, every target that calls
// `parseAndSimplify` needs that define -- the `CombinedURLFilters::defaultBuilder` trap, which
// silently left ten tests on the old arm and would have reported a false pass.
//
// THE CHECK THAT SETTLES IT COSTS ONE COMMAND, and it is worth writing down because a warning in a
// header is not a warning that fires. `parseAndSimplify` is not inline, so every caller emits the
// selector as an immediate at the call site; `Terminal` is 1 and `Eager` is 0:
//
//   objdump -d --macho --no-show-raw-insn WebCore.framework/WebCore \
//     | grep -B 14 'bl.*CSSCalc16parseAndSimplify' | grep 'w4, #'
//
// It must print `mov w4, #0x1` for each of the three callers that take the default --
// `SizesAttributeParser::parse`, `CSSNumericValue::parse` and `CSS::UnevaluatedCalcBase::parseBase`
// -- and nothing for `parseCalcExpressionAtCategory`, which passes the mode in a register because
// the differential selects it per call.
enum class ParseSimplification : uint8_t { Eager, Terminal, None };
static constexpr ParseSimplification defaultParseSimplification = ParseSimplification::Terminal;

// MARK: Parser selection

// WHICH implementation parses. Shaped exactly like `CSSCalc::Simplifier`, `CSSCalc::Serializer`
// and `CSSTokenizer::Scanner`: both arms compiled in, the choice made at compile time, C++ kept as
// the fallback because keeping it is the schedule and because the Swift grammar declines what it
// does not cover.
//
// A PARAMETER, not just a `#if` inside `parseAndSimplify`, and that is load-bearing rather than
// symmetric. The validation bridge's reference arm IS `parseAndSimplify`; with a compile-time-only
// gate, a build that selected Swift would make the differential compare the Swift grammar against
// itself and report 0 mismatches over 2,061 cases while measuring nothing. Naming the arm is what
// stops an ignored -- or an honoured -- build flag from masquerading as a pass.
enum class Parser : bool { Cpp, Swift };

// `defined() &&` rather than a `#if !defined / #define 0` prologue, for the reason
// `defaultSimplifier` gives: the flag is only ever defined as 1, by WK_USE_SWIFT_CSS_CALC_PARSER=YES.
//
// THE DEFAULT-ARGUMENT HAZARD IS REAL HERE AND IS CHECKED, NOT ASSUMED. The note above says a
// `static constexpr` used as a default argument is evaluated in the CALLER's translation unit, so
// every target that calls `parseAndSimplify` must be built with the same value or the arms silently
// disagree -- `CombinedURLFilters::defaultBuilder`, which left ten content-extension tests on the
// old arm and would have reported a false pass. This header is a PROJECT header, not a Private one
// (no `in Headers` entry in WebCore.xcodeproj), so it cannot be included outside the WebCore target,
// and its six includers -- CSSUnevaluatedCalc.cpp, CSSPropertyParserConsumer+Background.cpp,
// SizesAttributeParser.cpp, CSSNumericValue.cpp, CSSTokenizerSwiftBridge.cpp and this file's own
// .cpp -- are all WebCore TUs, which take the define from one place, WebCore.xcconfig's
// GCC_PREPROCESSOR_DEFINITIONS. If this header ever becomes Private, that argument stops holding
// and the arm has to be passed explicitly at every call.
static constexpr Parser defaultParser =
#if defined(USE_SWIFT_CSS_CALC_PARSER) && USE_SWIFT_CSS_CALC_PARSER
    Parser::Swift;
#else
    Parser::Cpp;
#endif

// Parses and simplifies the provided `CSSParserTokenRange` into a CSSCalc::Tree. Returns `std::nullopt` on failure.
std::optional<Tree> parseAndSimplify(CSSParserTokenRange&, CSS::PropertyParserState&, const ParserOptions&, const SimplificationOptions&, ParseSimplification = defaultParseSimplification, Parser = defaultParser);

// Returns whether the provided `CSSValueID` is one of the functions that should be parsed as a `calc()`.
bool NODELETE isCalcFunction(CSSValueID function);

} // namespace CSSCalc
} // namespace WebCore
