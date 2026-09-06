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
// `Tree` entry point below uses, decided at compile time.
//
// Named explicitly by the validation bridge rather than taken from `defaultSimplifier`, so tests
// can compare both arms regardless of build configuration, and an ignored build flag cannot
// masquerade as a pass. Same arrangement as `CSSCalc::Serializer`, `CSSTokenizer::Scanner` and
// `CSSParserFastPaths::ColorScanner`.
//
// Declared above `canSimplify` rather than between it and `copyAndSimplify`, since both take it.
enum class Simplifier : bool { Cpp, Swift };

// `defined() &&` rather than a `#if !defined / #define 0` prologue, which -Werror,-Wundef
// builds would otherwise require: the flag is only ever defined as 1, by
// WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION=YES.
static constexpr Simplifier defaultSimplifier =
#if defined(USE_SWIFT_CSS_CALC_SIMPLIFICATION) && USE_SWIFT_CSS_CALC_SIMPLIFICATION
    Simplifier::Swift;
#else
    Simplifier::Cpp;
#endif

// Whether the C++ recursive `copyAndSimplify` walk is compiled in at all.
//
// Its reach is shorter than it might look: three things outside this keep the C++ path reachable
// no matter what:
//
//  - the 42 per-operation `simplify(Op&, ...)` overloads below have a caller that is not
//    `copyAndSimplify` at all: StyleCalculationTree+Conversion.cpp:181 calls `simplify` on a
//    freshly built operation node during Style conversion;
//  - `copyAndSimplify(const Child&, ...)` is called by CSSCalcTree+Parser.cpp:1638, and it is also
//    the recursion the whole family bottoms out in, so it cannot take a Swift arm without Swift
//    re-entering itself once per node;
//  - `canonicalize` has a second caller in CSSCalcTree+Evaluation.cpp:143.
//
// So this mode guards exactly one thing: the body of `copyAndSimplify(const Tree&, ...)`. With
// the C++ arm compiled out, a decline becomes a build-enforced stop rather than a silent
// fallback.
#if defined(USE_SWIFT_CSS_CALC_SIMPLIFICATION_NO_FALLBACK) && USE_SWIFT_CSS_CALC_SIMPLIFICATION_NO_FALLBACK
#if !defined(USE_SWIFT_CSS_CALC_SIMPLIFICATION) || !USE_SWIFT_CSS_CALC_SIMPLIFICATION
// Diagnosed here rather than left to produce a link error naming `copyAndSimplify`, which is what
// removing the only other simplifier from a build that still selects one looks like.
#error "WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION_NO_FALLBACK=YES requires WK_USE_SWIFT_CSS_CALC_SIMPLIFICATION=YES: it removes the only other simplifier."
#endif
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
// The validation bridge names `Simplifier::Cpp` on one arm on purpose, and this mode removes
// that arm. The two cannot be combined; saying so here is cheaper than discovering it as a
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
// The C++ this ports is very nearly vacuous: `canSimplify` (CSSCalcTree+Simplification.cpp)
// ignores its `SimplificationOptions` entirely and switches only on the root alternative --
// false for `Number`, `Percentage` and `CanonicalDimension`, true for the other 38, every
// operator included. It carries one bit per tree and cannot be wrong about any tree whose root
// is an operator, so an arm-versus-arm agreement count over it is close to no evidence at all:
// `canSimplify(t) == false` must imply `copyAndSimplify(t) == t`, and that is the check with real
// information in it.
//
// Ported anyway for coverage: it is the second of the two entry points in this header reached
// from outside (CSSUnevaluatedCalc.cpp:61 is the only external caller), so leaving it C++-only
// would leave Swift unable to answer a question the C++ answers. The Swift arm takes no options,
// matching what the C++ actually reads; a future `canSimplify` that starts reading them -- the
// NOTE at the definition says a more precise implementation is possible -- would need the Swift
// signature to grow with it.
//
// The default argument is safe here for the same reason as `copyAndSimplify` below: one caller,
// in a WebCore TU, from a project header.
bool canSimplify(const Tree&, const SimplificationOptions&, Simplifier = defaultSimplifier);

// MARK: Copy & Simplify

// A default argument is safe here, checked rather than assumed from
// CSSCalcTree+Serialization.h:95. `defaultSimplifier` is `static constexpr` and a default
// argument is evaluated in the caller's translation unit, so every caller must be built with the
// same value of the gate or the arms silently disagree -- the same hazard that let some
// content-extension tests stay on the old arm after a partial rebuild. This header is a project
// header, not a Private one (no `in Headers` entry in WebCore.xcodeproj), so it cannot be
// included outside the WebCore target, and its includers -- CSSUnevaluatedCalc.cpp,
// CSSCalcTree+Evaluation.cpp, CSSCalcTree+Parser.cpp, CSSNumericValue.cpp,
// SizesAttributeParser.cpp, StyleCalculationTree+Conversion.cpp and CSSTokenizerSwiftBridge.cpp
// -- are all WebCore TUs, which take the define from one place, WebCore.xcconfig's
// GCC_PREPROCESSOR_DEFINITIONS. If this header ever becomes Private, this argument stops holding
// and the arm has to be passed explicitly.
Tree copyAndSimplify(const Tree&, const SimplificationOptions&, Simplifier = defaultSimplifier);
// No Swift arm, deliberately: this overload is the recursion the whole `copyAndSimplify` family
// bottoms out in (CSSCalcTree+Simplification.cpp:1803), so an arm here would re-enter Swift once
// per node. Its one external caller, CSSCalcTree+Parser.cpp:1638, stays on the C++ arm.
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
// Test-only, reached from CSSTokenizerSwiftBridge.cpp, compiled out otherwise. The counter and
// the switch live beside the code that declines rather than in the bridge: a decline is invisible
// in an output comparison, since the C++ answer for a declined tree is the same C++ answer
// already trusted, so the count has to come from the code that declined, not from the code that
// asked.
void webCoreCSSCalcSimplificationSetForceDecline(bool);
unsigned webCoreCSSCalcSimplificationDeclineCount(void);
// The last walk's node count and kind mask, so a test can assert that the walk really descended
// through the tree and reached every node kind it claims coverage of. The mask is 64 bits, keyed
// on `CSSCalcSwiftAlternative` (`Node`'s own 41 variant alternatives);
// `CSSCalcSwiftSimplificationResult::kindMask` says why that differs from the serialization
// mask, which is 32 bits over 23 serialization shapes.
uint32_t webCoreCSSCalcSimplificationLastNodeCount(void);
uint64_t webCoreCSSCalcSimplificationLastKindMask(void);
// The `CSSCalcSwiftAlternative` the last walk declined on, or 0xFF for "did not decline" and for
// "declined with no single alternative to blame". `CSSCalcSwiftSimplificationResult` says why an
// unattributed decline is treated as a failure rather than as a decline.
uint8_t webCoreCSSCalcSimplificationLastDeclineAlternative(void);
uint64_t webCoreCSSCalcSimplificationSwiftCallCount(void);
// Per-primitive timing, so the island's FIXED per-whole-tree cost can be split between the read
// crossing and the construction upcalls. `which` selects the case; each is paired with the C++
// arm's equivalent for the same output. See the definition for the case list.
uint64_t webCoreCSSCalcSimplificationPrimitiveBench(uint32_t which, uint32_t iterations);
#endif

} // namespace CSSCalc
} // namespace WebCore
