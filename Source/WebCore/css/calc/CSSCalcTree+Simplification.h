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

#include "CSSCalcSymbolTable.h"
#include "CSSPrimitiveNumericRange.h"
#include "CSSToLengthConversionData.h"

namespace WebCore {

namespace CSS {
enum class Category : uint8_t;
}

namespace CSSCalc {

struct Child;
struct Tree;

struct Abs;
struct Acos;
struct Anchor;
struct AnchorSize;
struct Asin;
struct Atan2;
struct Atan;
struct CalcMix;
struct CanonicalDimension;
struct Clamp;
struct Cos;
struct Deg2Rad;
struct Exp;
struct Hypot;
struct Invert;
struct Log;
struct Max;
struct Min;
struct Mod;
struct Negate;
struct NonCanonicalDimension;
struct Number;
struct Percentage;
struct Pow;
struct Product;
struct Progress;
struct ProgressNoClamp;
struct Random;
struct Rem;
struct RoundDown;
struct RoundNearest;
struct RoundToZero;
struct RoundUp;
struct SiblingCount;
struct SiblingIndex;
struct Sign;
struct Sin;
struct Sqrt;
struct Sum;
struct Symbol;
struct Tan;

// https://drafts.csswg.org/css-values-4/#calc-simplification

struct SimplificationOptions {
    // `category` represents the context in which the simplification is taking place.
    CSS::Category category;

    // `range` represents the allowed numeric range for the calculated result.
    CSS::Range range;

    // `conversionData` contains information needed to convert length units into their canonical forms.
    std::optional<CSSToLengthConversionData> conversionData;

    // `symbolTable` contains information needed to convert unresolved symbols into Numeric values.
    CSSCalcSymbolTable symbolTable;

    // `allowZeroValueLengthRemovalFromSum` allows removal of 0 value lengths (px, em, etc.) from Sum operations.
    bool allowZeroValueLengthRemovalFromSum = false;
};


// MARK: Simplifier selection

// Which implementation simplifies the tree. Both are compiled in; this chooses which one the
// `Tree` entry point below uses, and the choice is made at compile time.
//
// Named explicitly by the validation bridge rather than taken from `defaultSimplifier`, so that a
// differential compares the two arms whatever the build was configured with, and so that an
// ignored build flag cannot masquerade as a pass. Same arrangement, and for the same reasons, as
// `CSSCalc::Serializer`, `CSSTokenizer::Scanner` and `CSSParserFastPaths::ColorScanner`.
//
// Declared above `canSimplify` rather than between it and `copyAndSimplify`, because both entries
// take it now.
enum class Simplifier : bool { Cpp, Swift };

// `defined() &&` rather than a `#if !defined / #define 0` prologue, which WebCore builds with
// -Werror,-Wundef would otherwise require: the flag is only ever defined as 1, by
// WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION=YES, and that is where the choice lives.
static constexpr Simplifier defaultSimplifier =
#if defined(USE_SWIFT_CSS_CALC_SIMPLIFICATION) && USE_SWIFT_CSS_CALC_SIMPLIFICATION
    Simplifier::Swift;
#else
    Simplifier::Cpp;
#endif

// Whether the C++ recursive `copyAndSimplify` walk is compiled in at all.
//
// ITS REACH IS MUCH SHORTER THAN THE SERIALIZATION EQUIVALENT'S, and that is a property of this
// island rather than of this slice's coverage, so it is recorded here rather than left to be
// rediscovered from a link error. Three things outside the island keep the C++ alive whatever the
// island does:
//
//  - the 42 per-operation `simplify(Op&, ...)` overloads below have a caller that is not
//    `copyAndSimplify` at all: StyleCalculationTree+Conversion.cpp:181 calls `simplify` on a
//    freshly built operation node during Style conversion;
//  - `copyAndSimplify(const Child&, ...)` is called by CSSCalcTree+Parser.cpp:1638, and it is also
//    the recursion the whole family bottoms out in, so it cannot take a Swift arm without the
//    island re-entering itself once per node;
//  - `canonicalize` has a second caller in CSSCalcTree+Evaluation.cpp:143.
//
// So this mode guards exactly one thing: the body of `copyAndSimplify(const Tree&, ...)`. Its
// value is therefore NOT a deletable count -- that count is a *dependency* zero, not a coverage one
// -- but a coverage ASSERTION: with the C++ arm gone, a decline is a stop rather than a silent
// fallback, which is the only way to make "the island never declines on the corpus" a claim the
// build enforces instead of one the differential has to notice. Giving the `Child` entry a Swift
// arm too, by splitting the exported entry from the internal recursion, is what would widen this,
// and it is the named next step.
#if defined(USE_SWIFT_CSS_CALC_SIMPLIFICATION_NO_FALLBACK) && USE_SWIFT_CSS_CALC_SIMPLIFICATION_NO_FALLBACK
#if !defined(USE_SWIFT_CSS_CALC_SIMPLIFICATION) || !USE_SWIFT_CSS_CALC_SIMPLIFICATION
// Diagnosed here rather than left to produce a link error naming `copyAndSimplify`, which is what
// removing the only other simplifier from a build that still selects one looks like.
#error "WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION_NO_FALLBACK=YES requires WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION=YES: it removes the only other simplifier."
#endif
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
// The differential names `Simplifier::Cpp` on one arm on purpose, and this mode is the removal of
// that arm. The two cannot be combined, and saying so here is cheaper than discovering it as a
// missing overload inside the bridge.
#error "WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION_NO_FALLBACK=YES is mutually exclusive with WK_ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE=YES: the differential needs the C++ arm this mode removes."
#endif
#define CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN 0
#else
#define CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN 1
#endif

// MARK: Can Simplify

// Whether simplifying the tree could change it.
//
// THE C++ THIS ARM PORTS IS VERY NEARLY VACUOUS, and that is recorded here rather than discovered
// by someone reading a green differential. `canSimplify` (CSSCalcTree+Simplification.cpp) IGNORES
// its `SimplificationOptions` entirely -- the parameter is unnamed in the definition -- and
// switches only on the ROOT alternative: `false` for `Number`, `Percentage` and
// `CanonicalDimension`, `true` for the other 38, every operator included. So it carries one bit per
// tree, it cannot be wrong about any tree whose root is an operator, and an arm-versus-arm
// agreement count over it is close to no evidence at all. simplifycheck.cpp's guard 10 prints the
// true/false split for exactly that reason, and guard 10b carries the check that has information in
// it: `canSimplify(t) == false` must imply `copyAndSimplify(t) == t`.
//
// It is ported anyway, and the reason is coverage rather than confidence: it is the second of the
// two entry points in this header that a caller outside the island reaches
// (CSSUnevaluatedCalc.cpp:61 is the only one), so leaving it C++-only would leave the island unable
// to answer a question the C++ answers. The Swift arm takes NO options, matching what the C++
// actually reads; if a future `canSimplify` starts reading them -- the NOTE at the definition says
// a more precise implementation is possible -- the Swift entry's signature has to grow with it, and
// the fact that it does not take them today is the record of that.
//
// The default argument is safe here for the same reason it is safe on `copyAndSimplify` below, and
// on the same evidence: one caller, in a WebCore TU, from a project header.
bool canSimplify(const Tree&, const SimplificationOptions&, Simplifier = defaultSimplifier);

// MARK: Copy & Simplify

// A DEFAULT ARGUMENT IS SAFE HERE, and it was checked rather than copied from
// CSSCalcTree+Serialization.h:95. `defaultSimplifier` is `static constexpr` and a default argument
// is evaluated in the CALLER's translation unit, so every caller must be built with the same value
// of the gate or the arms silently disagree -- which is exactly how ten content-extension tests
// stayed on the old arm while their WebCore was rebuilt. This header is a PROJECT header, not a
// Private one (it has no `in Headers` entry in WebCore.xcodeproj), so it cannot be included outside
// the WebCore target at all, and its five includers -- CSSUnevaluatedCalc.cpp,
// CSSCalcTree+Evaluation.cpp, CSSCalcTree+Parser.cpp, CSSNumericValue.cpp, SizesAttributeParser.cpp,
// StyleCalculationTree+Conversion.cpp and CSSTokenizerSwiftBridge.cpp -- are all WebCore TUs, which
// take the define from one place, WebCore.xcconfig's GCC_PREPROCESSOR_DEFINITIONS. If this header
// ever becomes Private, this argument stops holding and the arm has to be passed explicitly.
Tree copyAndSimplify(const Tree&, const SimplificationOptions&, Simplifier = defaultSimplifier);
// NO SWIFT ARM, deliberately: this overload is the recursion the whole `copyAndSimplify` family
// bottoms out in (CSSCalcTree+Simplification.cpp:1803), so an arm here would have the island
// re-enter itself once per node. Its one external caller, CSSCalcTree+Parser.cpp:1638, therefore
// stays on the C++ arm in this slice.
Child copyAndSimplify(const Child&, const SimplificationOptions&);

// MARK: In-place Simplify

std::optional<Child> NODELETE simplify(Number&, const SimplificationOptions&);
std::optional<Child> NODELETE simplify(Percentage&, const SimplificationOptions&);
std::optional<Child> simplify(NonCanonicalDimension&, const SimplificationOptions&);
std::optional<Child> NODELETE simplify(CanonicalDimension&, const SimplificationOptions&);
std::optional<Child> simplify(Symbol&, const SimplificationOptions&);
std::optional<Child> simplify(SiblingCount&, const SimplificationOptions&);
std::optional<Child> simplify(SiblingIndex&, const SimplificationOptions&);
std::optional<Child> simplify(Sum&, const SimplificationOptions&);
std::optional<Child> simplify(Product&, const SimplificationOptions&);
std::optional<Child> simplify(Negate&, const SimplificationOptions&);
std::optional<Child> simplify(Invert&, const SimplificationOptions&);
std::optional<Child> simplify(Deg2Rad&, const SimplificationOptions&);
std::optional<Child> simplify(Min&, const SimplificationOptions&);
std::optional<Child> simplify(Max&, const SimplificationOptions&);
std::optional<Child> simplify(Clamp&, const SimplificationOptions&);
std::optional<Child> simplify(RoundNearest&, const SimplificationOptions&);
std::optional<Child> simplify(RoundUp&, const SimplificationOptions&);
std::optional<Child> simplify(RoundDown&, const SimplificationOptions&);
std::optional<Child> simplify(RoundToZero&, const SimplificationOptions&);
std::optional<Child> simplify(Mod&, const SimplificationOptions&);
std::optional<Child> simplify(Rem&, const SimplificationOptions&);
std::optional<Child> simplify(Sin&, const SimplificationOptions&);
std::optional<Child> simplify(Cos&, const SimplificationOptions&);
std::optional<Child> simplify(Tan&, const SimplificationOptions&);
std::optional<Child> simplify(Asin&, const SimplificationOptions&);
std::optional<Child> simplify(Acos&, const SimplificationOptions&);
std::optional<Child> simplify(Atan&, const SimplificationOptions&);
std::optional<Child> simplify(Atan2&, const SimplificationOptions&);
std::optional<Child> simplify(Pow&, const SimplificationOptions&);
std::optional<Child> simplify(Sqrt&, const SimplificationOptions&);
std::optional<Child> simplify(Hypot&, const SimplificationOptions&);
std::optional<Child> simplify(Log&, const SimplificationOptions&);
std::optional<Child> simplify(Exp&, const SimplificationOptions&);
std::optional<Child> simplify(Abs&, const SimplificationOptions&);
std::optional<Child> simplify(Sign&, const SimplificationOptions&);
std::optional<Child> simplify(Random&, const SimplificationOptions&);
std::optional<Child> simplify(Progress&, const SimplificationOptions&);
std::optional<Child> simplify(ProgressNoClamp&, const SimplificationOptions&);
std::optional<Child> simplify(CalcMix&, const SimplificationOptions&);
std::optional<Child> simplify(Anchor&, const SimplificationOptions&);
std::optional<Child> simplify(AnchorSize&, const SimplificationOptions&);

// MARK: Unit Canonicalization

std::optional<CanonicalDimension> canonicalize(NonCanonicalDimension, const std::optional<CSSToLengthConversionData>&);

#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
// Test-only, reached from CSSTokenizerSwiftBridge.cpp, and compiled out otherwise. The counter and
// the switch live beside the code that declines rather than in the bridge, for the reason
// CSSCalcTree+Serialization.h:110 gives: a decline is invisible in an output comparison, because
// the C++ answer for a declined tree is the same C++ answer the comparison already trusts, so the
// count has to come from the code that declined and not from the code that asked.
void webCoreCSSCalcSimplificationSetForceDecline(bool);
unsigned webCoreCSSCalcSimplificationDeclineCount(void);
// The last walk's node count and kind mask, so a differential can assert that the island really
// descended through the tree and really reached every node kind it claims coverage of. The mask is
// 64 bits and is keyed on `CSSCalcSwiftAlternative`, i.e. on `Node`'s own 41 variant alternatives;
// `CSSCalcSwiftSimplificationResult::kindMask` says why that is a different question from the
// serialization island's 32-bit mask over 23 serialization shapes, and why only the alternative
// keying can express the decline expectation.
uint32_t webCoreCSSCalcSimplificationLastNodeCount(void);
uint64_t webCoreCSSCalcSimplificationLastKindMask(void);
// The `CSSCalcSwiftAlternative` the last walk declined ON, or 0xFF for "did not decline" and for
// "declined with no single alternative to blame". `CSSCalcSwiftSimplificationResult` says why an
// unattributed decline is treated as a failure rather than as a decline.
uint8_t webCoreCSSCalcSimplificationLastDeclineAlternative(void);
uint64_t webCoreCSSCalcSimplificationSwiftCallCount(void);
#endif

} // namespace CSSCalc
} // namespace WebCore
