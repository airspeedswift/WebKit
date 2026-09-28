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


// MARK: Implementation

// Whether the C++ simplifier (the recursive `copyAndSimplify` walk and the per-operation `simplify`
// overloads) is compiled in: exactly when the Swift CSS implementation is not (WK_USE_SWIFT_CSS).
// Without it, a tree the Swift simplifier hands back is a `RELEASE_ASSERT`.
//
// What stays compiled either way has a caller outside that walk: `canonicalize`, which
// CSSCalcTree+Evaluation.cpp also calls, and `percentageResolveToDimension`, which the Swift
// simplifier's options carry.
#if USE(SWIFT_CSS)
#define CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN 0
#else
#define CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN 1
#endif

// Whether the C++ `evaluateDouble` walk (CSSCalcTree+Evaluation.cpp) is compiled in; off exactly
// when the C++ simplifier is. With it off, `evaluateDouble` is the Swift evaluator, and a tree that
// evaluator refuses is a `RELEASE_ASSERT`.
//
// What stays compiled has a caller outside the walk: `resolveRandomBaseValue`.
#define CSS_CALC_CPP_EVALUATOR_COMPILED_IN CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN

// MARK: Can Simplify

// Whether simplifying the tree could change it: false for `Number`, `Percentage` and
// `CanonicalDimension`, true for the other 38. `canSimplify(t) == false` must imply
// `copyAndSimplify(t) == t`.
//
// The options are not read; the Swift implementation does not take them.
bool canSimplify(const Tree&, const SimplificationOptions&);

// MARK: Copy & Simplify

Tree copyAndSimplify(const Tree&, const SimplificationOptions&);
#if CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN
// The C++ simplifier. Declared only where it is compiled, so that a use without it is a compile
// error rather than a link error.
//
// It has no Swift implementation: it is the per-node recursion, and a Swift one would cross into
// Swift once per node. Its one external caller is the C++ parser.
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
#endif // CSS_CALC_CPP_SIMPLIFIER_COMPILED_IN

// MARK: Unit Canonicalization

std::optional<CanonicalDimension> canonicalize(NonCanonicalDimension, const std::optional<CSSToLengthConversionData>&);


} // namespace CSSCalc
} // namespace WebCore
