// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2022 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include "config.h"
#include "CSSParserFastPaths.h"

#include "CSSAbsoluteColorResolver.h"
#include "CSSFunctionValue.h"
#include "CSSKeywordColor.h"
#include "CSSParserContext.h"
#include "CSSParserIdioms.h"
#include "CSSPrimitiveNumericTypes.h"
#include "CSSPrimitiveValue.h"
#include "CSSProperty.h"
#include "CSSPropertyNames.h"
#include "CSSPropertyParser.h"
#include "CSSPropertyParserConsumer+Color.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSTransformListValue.h"
#include "CSSValueList.h"
#include "CSSValuePool.h"
#include "ColorConversion.h"
#include "FloatConversion.h"
#include "HashTools.h"
#include "StylePropertyShorthand.h"
// The colour fast-path island's `@c CSSSwiftColorOutcome` numbering and the named-colour lookup
// it calls back into are declared here.
#include "CSSTokenizerSwiftTypes.h"
// The island entry point this file calls, and every other island's boundary types along with it --
// WebCoreSwift-Generated.h is module-scoped, so a translation unit that includes it must declare
// all of them. WebCoreSwiftBoundaryTypes.h says why, and is the one file an added island edits.
#include "WebCoreSwiftBoundaryTypes.h"
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringParsingBuffer.h>

namespace WebCore {

std::optional<CSS::Range> CSSParserFastPaths::lengthValueRangeForPropertiesSupportingSimpleLengths(CSSPropertyID propertyId)
{
    switch (propertyId) {
    case CSSPropertyFontSize:
    case CSSPropertyHeight:
    case CSSPropertyWidth:
    case CSSPropertyMinHeight:
    case CSSPropertyMinWidth:
    case CSSPropertyPaddingBottom:
    case CSSPropertyPaddingLeft:
    case CSSPropertyPaddingRight:
    case CSSPropertyPaddingTop:
    case CSSPropertyInlineSize:
    case CSSPropertyBlockSize:
    case CSSPropertyMinInlineSize:
    case CSSPropertyMinBlockSize:
    case CSSPropertyPaddingBlockEnd:
    case CSSPropertyPaddingBlockStart:
    case CSSPropertyPaddingInlineEnd:
    case CSSPropertyPaddingInlineStart:
    case CSSPropertyR:
    case CSSPropertyRx:
    case CSSPropertyRy:
    case CSSPropertyShapeMargin:
        return CSS::Nonnegative;
    case CSSPropertyBottom:
    case CSSPropertyCx:
    case CSSPropertyCy:
    case CSSPropertyLeft:
    case CSSPropertyInsetBlockEnd:
    case CSSPropertyInsetBlockStart:
    case CSSPropertyInsetInlineEnd:
    case CSSPropertyInsetInlineStart:
    case CSSPropertyMarginBottom:
    case CSSPropertyMarginLeft:
    case CSSPropertyMarginRight:
    case CSSPropertyMarginTop:
    case CSSPropertyRight:
    case CSSPropertyTop:
    case CSSPropertyMarginBlockEnd:
    case CSSPropertyMarginBlockStart:
    case CSSPropertyMarginInlineEnd:
    case CSSPropertyMarginInlineStart:
    case CSSPropertyX:
    case CSSPropertyY:
        return CSS::All;
    default:
        return { };
    }
}

template<typename CharacterType> static inline std::optional<double> parseCSSNumber(std::span<const CharacterType> characters)
{
    // The charactersToDouble() function allows a trailing '.' but that is not allowed in CSS number values.
    if (!characters.empty() && characters.back() == '.')
        return std::nullopt;
    // FIXME: If we don't want to skip over leading spaces, we should use parseDouble, not charactersToDouble.
    bool ok;
    auto number = charactersToDouble(characters, &ok);
    if (!ok)
        return std::nullopt;
    return number;
}

template <typename CharacterType>
static inline bool parseSimpleLength(std::span<const CharacterType> characters, CSSUnitType& unit, double& number)
{
    if (characters.size() > 2 && isASCIIAlphaCaselessEqual(characters[characters.size() - 2], 'p') && isASCIIAlphaCaselessEqual(characters[characters.size() - 1], 'x')) {
        dropLast(characters, 2);
        unit = CSSUnitType::Px;
    } else if (!characters.empty() && characters.back() == '%') {
        dropLast(characters);
        unit = CSSUnitType::Percentage;
    }

    auto parsedNumber = parseCSSNumber(characters);
    number = parsedNumber.value_or(0);
    return parsedNumber.has_value();
}

enum class RequireUnits : bool { No, Yes };

template <typename CharacterType>
static inline bool parseSimpleAngle(std::span<const CharacterType> characters, RequireUnits requireUnits, CSS::AngleUnit& unit, double& number)
{
    // "0deg" or "1rad"
    if (characters.size() >= 4) {
        if (isASCIIAlphaCaselessEqual(characters[characters.size() - 3], 'd') && isASCIIAlphaCaselessEqual(characters[characters.size() - 2], 'e') && isASCIIAlphaCaselessEqual(characters[characters.size() - 1], 'g')) {
            dropLast(characters, 3);
            unit = CSS::AngleUnit::Deg;
        } else if (isASCIIAlphaCaselessEqual(characters[characters.size() - 3], 'r') && isASCIIAlphaCaselessEqual(characters[characters.size() - 2], 'a') && isASCIIAlphaCaselessEqual(characters[characters.size() - 1], 'd')) {
            dropLast(characters, 3);
            unit = CSS::AngleUnit::Rad;
        } else if (requireUnits == RequireUnits::Yes)
            return false;
    } else {
        if (requireUnits == RequireUnits::Yes || !characters.size())
            return false;

        unit = CSS::AngleUnit::Deg;
    }

    auto parsedNumber = parseCSSNumber(characters);
    number = parsedNumber.value_or(0);
    return parsedNumber.has_value();
}

template <typename CharacterType>
static inline bool parseSimpleNumberOrPercentageDividedBy100(std::span<const CharacterType> characters, double& number)
{
    bool isPercentage = false;
    if (!characters.empty() && characters.back() == '%') {
        dropLast(characters);
        isPercentage = true;
    }

    auto parsedNumber = parseCSSNumber(characters);
    if (!parsedNumber)
        return false;

    number = *parsedNumber;
    if (std::isinf(number))
        return false;

    if (isPercentage)
        number /= 100.0;

    return true;
}

static RefPtr<CSSValue> parseSimpleLengthValue(StringView string, CSSParserMode cssParserMode, CSS::Range valueRange)
{
    ASSERT(!string.isEmpty());

    double number;
    auto unit = CSSUnitType::Number;

    if (string.is8Bit()) {
        if (!parseSimpleLength(string.span8(), unit, number))
            return nullptr;
    } else {
        if (!parseSimpleLength(string.span16(), unit, number))
            return nullptr;
    }

    if (unit == CSSUnitType::Number) {
        if (number && cssParserMode != SVGAttributeMode)
            return nullptr;
        unit = CSSUnitType::Px;
    }

    if (number < valueRange.min || number > valueRange.max)
        return nullptr;

    if (std::isinf(number))
        return nullptr;

    return CSSPrimitiveValue::create(number, unit);
}

// Returns the number of characters which form a valid double
// and are terminated by the given terminator character
template <typename CharacterType>
static size_t NODELETE checkForValidDouble(std::span<const CharacterType> string, char terminator)
{
    size_t length = string.size();
    if (length < 1)
        return 0;

    std::optional<size_t> decimalMarkOffset;
    size_t processedLength = 0;

    for (size_t i = 0; i < string.size(); ++i) {
        if (string[i] == terminator) {
            processedLength = i;
            break;
        }
        if (!isASCIIDigit(string[i])) {
            if (!decimalMarkOffset && string[i] == '.')
                decimalMarkOffset = i;
            else
                return 0;
        }
    }

    // CSS disallows a period without a subsequent digit.
    if (decimalMarkOffset && *decimalMarkOffset == processedLength - 1)
        return 0;

    return processedLength;
}

// Returns the number of characters consumed for parsing a valid double
// terminated by the given terminator character
template <typename CharacterType>
static size_t NODELETE parseDouble(std::span<const CharacterType> string, char terminator, double& value)
{
    size_t length = checkForValidDouble(string, terminator);
    if (!length)
        return 0;

    size_t position = 0;
    double localValue = 0;

    // The consumed characters here are guaranteed to be
    // ASCII digits with or without a decimal mark
    for (; position < length; ++position) {
        if (string[position] == '.')
            break;
        localValue = localValue * 10 + string[position] - '0';
    }

    if (++position == length) {
        value = localValue;
        return length;
    }

    double fraction = 0;
    double scale = 1;

    double maxScale = 1000000;
    while (position < length && scale < maxScale) {
        fraction = fraction * 10 + string[position++] - '0';
        scale *= 10;
    }

    value = localValue + fraction / scale;
    return length;
}

template <typename CharacterType>
static std::optional<uint8_t> parseColorIntOrPercentage(std::span<const CharacterType>& string, std::optional<char> consumableTerminator, CSSUnitType& expectedUnitType)
{
    auto current = string;
    double localValue = 0;
    bool negative = false;
    skipWhile<isASCIIWhitespace>(current);

    if (skipExactly(current, '-'))
        negative = true;

    if (current.empty() || !isASCIIDigit(current.front()))
        return std::nullopt;

    while (!current.empty() && isASCIIDigit(current.front())) {
        double newValue = localValue * 10 + consume(current) - '0';
        if (newValue >= 255) {
            // Clamp values at 255.
            localValue = 255;
            skipWhile<isASCIIDigit>(current);
            break;
        }
        localValue = newValue;
    }

    if (current.empty())
        return std::nullopt;

    if (expectedUnitType == CSSUnitType::Number && (current.front() == '.' || current.front() == '%'))
        return std::nullopt;

    if (current.front() == '.') {
        // We already parsed the integral part, try to parse
        // the fraction part of the percentage value.
        double percentage = 0;
        size_t numCharactersParsed = parseDouble(current, '%', percentage);
        if (!numCharactersParsed)
            return std::nullopt;
        skip(current, numCharactersParsed);
        if (current.front() != '%')
            return std::nullopt;
        localValue += percentage;
    }

    if (expectedUnitType == CSSUnitType::Percentage && current.front() != '%')
        return std::nullopt;

    if (skipExactly(current, '%')) {
        expectedUnitType = CSSUnitType::Percentage;
        localValue = localValue / 100.0 * 255.0;
        // Clamp values at 255 for percentages over 100%
        if (localValue > 255)
            localValue = 255;
    } else
        expectedUnitType = CSSUnitType::Number;

    skipWhile<isASCIIWhitespace>(current);

    if (consumableTerminator && !skipExactly(current, *consumableTerminator))
        return std::nullopt;

    string = current;

    // Clamp negative values at zero.
    ASSERT(localValue <= 255);
    return negative ? 0 : convertPrescaledSRGBAFloatToSRGBAByte(localValue);
}

template <typename CharacterType>
static inline bool NODELETE isTenthAlpha(std::span<const CharacterType> string)
{
    // "0.X"
    if (string.size() == 3 && string[0] == '0' && string[1] == '.' && isASCIIDigit(string[2]))
        return true;

    // ".X"
    if (string.size() == 2 && string[0] == '.' && isASCIIDigit(string[1]))
        return true;

    return false;
}

template <typename CharacterType>
static inline std::optional<uint8_t> parseRGBAlphaValue(std::span<const CharacterType>& string, char terminator)
{
    skipWhile<isASCIIWhitespace>(string);

    bool negative = false;

    if (skipExactly(string, '-'))
        negative = true;

    size_t length = string.size();
    if (length < 2)
        return std::nullopt;

    if (string[length - 1] != terminator || !isASCIIDigit(string[length - 2]))
        return std::nullopt;

    if (string.front() != '0' && string.front() != '1' && string.front() != '.') {
        if (checkForValidDouble(string, terminator)) {
            string = { };
            return negative ? 0 : 255;
        }
        return std::nullopt;
    }

    if (length == 2 && string.front() != '.') {
        uint8_t result = !negative && string.front() == '1' ? 255 : 0;
        string = { };
        return result;
    }

    if (isTenthAlpha(string.first(length - 1))) {
        static constexpr std::array<uint8_t, 10> tenthAlphaValues { 0, 26, 51, 77, 102, 128, 153, 179, 204, 230 };
        uint8_t result = negative ? 0 : tenthAlphaValues[string[length - 2] - '0'];
        string = { };
        return result;
    }

    double alpha = 0;
    if (!parseDouble(string, terminator, alpha))
        return std::nullopt;

    string = { };
    return negative ? 0 : convertFloatAlphaTo<uint8_t>(alpha);
}

template <typename CharacterType>
static inline bool NODELETE mightBeRGBA(std::span<const CharacterType> characters)
{
    if (characters.size() < 5)
        return false;
    return characters[4] == '('
        && isASCIIAlphaCaselessEqual(characters[0], 'r')
        && isASCIIAlphaCaselessEqual(characters[1], 'g')
        && isASCIIAlphaCaselessEqual(characters[2], 'b')
        && isASCIIAlphaCaselessEqual(characters[3], 'a');
}

template <typename CharacterType>
static inline bool NODELETE mightBeRGB(std::span<const CharacterType> characters)
{
    if (characters.size() < 4)
        return false;
    return characters[3] == '('
        && isASCIIAlphaCaselessEqual(characters[0], 'r')
        && isASCIIAlphaCaselessEqual(characters[1], 'g')
        && isASCIIAlphaCaselessEqual(characters[2], 'b');
}

template <typename CharacterType>
static inline bool NODELETE mightBeHSLA(std::span<const CharacterType> characters)
{
    if (characters.size() < 5)
        return false;
    return characters[4] == '('
        && isASCIIAlphaCaselessEqual(characters[0], 'h')
        && isASCIIAlphaCaselessEqual(characters[1], 's')
        && isASCIIAlphaCaselessEqual(characters[2], 'l')
        && isASCIIAlphaCaselessEqual(characters[3], 'a');
}

template <typename CharacterType>
static inline bool NODELETE mightBeHSL(std::span<const CharacterType> characters)
{
    if (characters.size() < 4)
        return false;
    return characters[3] == '('
        && isASCIIAlphaCaselessEqual(characters[0], 'h')
        && isASCIIAlphaCaselessEqual(characters[1], 's')
        && isASCIIAlphaCaselessEqual(characters[2], 'l');
}

// MARK: - The Swift colour fast-path island (CSSParserFastPathsSwift.swift)
//
// Everything C++ still does for the island is here, and it is deliberately little: fill a
// by-value struct, pick the entry point for the width, and turn one packed answer back into an
// `SRGBA<uint8_t>`. There is no representation to translate, because the island writes
// `PackedColor::ARGB`'s own layout, and no buffer to own, because the candidate crosses as a
// value. What is *not* here is the part that would have been: no per-character shim, no
// duplicated table, and no C++ re-deriving a dispatch the Swift side already knew statically.

// The island folds into an `InlineArray<32, UInt8>`, whose count has to be a literal. This is
// the assert that makes the two views of that buffer unable to disagree; without it a change to
// the capacity here would silently start trapping inside the island for candidates between 32
// and the new capacity, which no correctness test names.
static_assert(cssSwiftColorTextCapacity == 24, "CSSParserFastPathsSwift.swift spells this capacity as a literal, in colorTextCapacity and in InlineArray<24, UInt8>");

// The outcome numbering is declared once, in Swift, and reaches C++ through the generated
// header. These pin it, so that a reordering of the Swift enum is a build failure here rather
// than a silent reinterpretation of every scan: `Parsed` read as `NotAColor` would turn every
// colour in every stylesheet into a parse failure, and `NotAColor` read as `Declined` would
// merely double the work and pass every test.
static_assert(!static_cast<uint8_t>(CSSSwiftColorOutcomeNotAColor));
static_assert(static_cast<uint8_t>(CSSSwiftColorOutcomeParsed) == 1);
static_assert(static_cast<uint8_t>(CSSSwiftColorOutcomeDeclined) == 2);

#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
#include <atomic>
// Test-only, and compiled out otherwise so the production scan pays no load for them.
// `s_forceColorScanDecline` makes every island answer read as a decline, which is the only way
// to exercise the fall-through: phase A declines for nothing, so the path is unreachable by
// input alone and would otherwise ship untested. `s_colorScanDeclines` is how a differential
// asserts that -- a decline is invisible in an output comparison, because the C++ answer for a
// declined input is the same C++ answer the comparison already trusts.
static std::atomic<bool> s_forceColorScanDecline;
static std::atomic<unsigned> s_colorScanDeclines;

void webCoreCSSColorFastPathSetForceDecline(bool force)
{
    s_forceColorScanDecline.store(force, std::memory_order_relaxed);
}

unsigned webCoreCSSColorFastPathDeclineCount()
{
    return s_colorScanDeclines.load(std::memory_order_relaxed);
}
#endif

// Fills the struct the island's entry points take.
//
// C++'s job is to *represent* the candidate, not to judge it: `length` is the true length even
// when it exceeds the capacity, and the island decides what a longer candidate means. Zero-
// filling the tail rather than tracking how much was written is what keeps that split honest --
// every index below the capacity is defined, so the boundary carries no convention about which
// ones are readable.
//
// The zero-fill was priced rather than assumed, because it is 28 bytes on a path that costs ~30
// cycles. Removing it entirely (`text;` instead of `text { }`) moved the colour micro-benchmark
// by at most a few points and *not consistently*: +4 on the 8-bit arms and -12 on six of the
// eight 16-bit arms, i.e. removing work made it slower, which is layout noise rather than signal
// on a 20-30 cycle workload. So this lever is worth <= ~4 points and the safe spelling is free.
// Probe kept at cssprobe/probes/colorboundary/fastpaths-zerofill.bak.
template<typename CharacterType>
static CSSSwiftColorText<CharacterType> makeSwiftColorText(std::span<const CharacterType> characters)
{
    CSSSwiftColorText<CharacterType> text { };
    text.length = static_cast<uint32_t>(characters.size());
    auto visible = characters.first(characters.size() < cssSwiftColorTextCapacity ? characters.size() : cssSwiftColorTextCapacity);
    memcpySpan(std::span { text.units }.first(visible.size()), visible);
    return text;
}

// The width dispatch, as four overloads rather than a runtime flag. Each call site knows both
// its width and which scanner it wants, statically, and writing either of those into a
// parameter for the callee to switch on is the shape this port already measured a cost for.
static CSSSwiftColor scanHexColorSwift(const CSSSwiftColorText8& text) { return cssParseHexColorSwift8(text); }
static CSSSwiftColor scanHexColorSwift(const CSSSwiftColorText16& text) { return cssParseHexColorSwift16(text); }
static CSSSwiftColor scanNamedColorSwift(const CSSSwiftColorText8& text) { return cssParseNamedColorSwift8(text); }
static CSSSwiftColor scanNamedColorSwift(const CSSSwiftColorText16& text) { return cssParseNamedColorSwift16(text); }

// Whether the island refused to answer, as opposed to answering that the string is not a colour
// of this kind. The distinction is the whole point of the three-way outcome: `NotAColor` is a
// finding the C++ must not repeat, and repeating it is not merely wasted work but the thing that
// makes lost coverage unmeasurable.
//
// So an island answer resolves to a *nested* optional, which reads oddly and is exactly right:
// the outer `nullopt` means "declined, run your own scanner", and `optional { nullopt }` means
// "answered, and the answer is that this is not a colour". Both fast paths share this, because
// the only thing that differs between them is which pair of functions is named -- and a runtime
// flag choosing between them would re-derive per call a dispatch both call sites know statically.
static std::optional<std::optional<SRGBA<uint8_t>>> resolveSwiftColorScan(CSSSwiftColor result)
{
    bool declined = result.outcome == CSSSwiftColorOutcomeDeclined;
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
    declined |= s_forceColorScanDecline.load(std::memory_order_relaxed);
    if (declined)
        s_colorScanDeclines.fetch_add(1, std::memory_order_relaxed);
#endif
    if (declined)
        return std::nullopt;
    if (result.outcome == CSSSwiftColorOutcomeParsed)
        return std::optional { asSRGBA(PackedColor::ARGB { result.argb }) };
    return std::optional<SRGBA<uint8_t>> { };
}

static std::optional<SRGBA<uint8_t>> NODELETE finishParsingHexColor(uint32_t value, unsigned length)
{
    switch (length) {
    case 3: {
        // #234 converts to #223344.
        uint8_t r = (value & 0x0F00) >> 8;
        uint8_t g = (value & 0x00F0) >> 4;
        uint8_t b = (value & 0x000F);
        return SRGBA<uint8_t>(r << 4 | r, g << 4 | g, b << 4 | b);
    }
    case 4: {
        // #234a converts to #223344aa.
        uint8_t r = (value & 0xF000) >> 12;
        uint8_t g = (value & 0x0F00) >> 8;
        uint8_t b = (value & 0x00F0) >> 4;
        uint8_t a = (value & 0x000F);
        return SRGBA<uint8_t>(r << 4 | r, g << 4 | g, b << 4 | b, a << 4 | a);
    }
    case 6:
        return asSRGBA(PackedColor::ARGB { 0xFF000000 | value });
    case 8:
        return asSRGBA(PackedColor::RGBA { value });
    }
    return std::nullopt;
}

template<typename CharacterType>
static std::optional<SRGBA<uint8_t>> NODELETE parseHexColorInternal(std::span<const CharacterType> characters, CSSParserFastPaths::ColorScanner scanner)
{
    // Asked at the top rather than through a wrapper around the C++ body, because there is
    // nothing here the island's answer has to be reconciled with: it either answered, in which
    // case its answer is the answer, or it declined and the C++ below runs untouched. The named
    // path next door does keep a separate C++-only function, for the one reason that justifies
    // the extra name -- its ASSERT has to call it.
    if (scanner == CSSParserFastPaths::ColorScanner::Swift) {
        if (auto answer = resolveSwiftColorScan(scanHexColorSwift(makeSwiftColorText(characters))))
            return *answer;
    }

    if (characters.size() != 3 && characters.size() != 4 && characters.size() != 6 && characters.size() != 8)
        return std::nullopt;

    uint32_t value = 0;
    for (auto digit : characters) {
        if (!isASCIIHexDigit(digit))
            return std::nullopt;
        value <<= 4;
        value |= toASCIIHexValue(digit);
    }
    return finishParsingHexColor(value, characters.size());
}

template<typename CharacterType> static std::optional<SRGBA<uint8_t>> parseHSL(std::span<const CharacterType> characters)
{
    auto skipWhitespace = [](std::span<const CharacterType>& characters) ALWAYS_INLINE_LAMBDA {
        skipWhile<isCSSSpace>(characters);
    };

    // Find the end of the hue token (terminated by comma or whitespace).
    // A comma means legacy syntax (comma-separated), whitespace means modern (space-separated).
    size_t hueEnd = 0;
    bool isLegacy = false;
    while (hueEnd < characters.size()) {
        if (characters[hueEnd] == ',') {
            isLegacy = true;
            break;
        }
        if (isCSSSpace(characters[hueEnd]))
            break;
        ++hueEnd;
    }
    if (!hueEnd || hueEnd == characters.size())
        return std::nullopt;

    double hue;
    auto angleUnit = CSS::AngleUnit::Deg;
    if (!parseSimpleAngle(characters.first(hueEnd), RequireUnits::No, angleUnit, hue))
        return std::nullopt;

    skip(characters, hueEnd);

    // In legacy syntax, components are separated by commas.
    if (isLegacy && !skipExactly(characters, ','))
        return std::nullopt;

    auto parsePercentage = [&]() -> std::optional<double> {
        skipWhitespace(characters);

        double value = 0;
        size_t numCharactersParsed = parseDouble(characters, '%', value);
        if (!numCharactersParsed)
            return std::nullopt;

        skip(characters, numCharactersParsed);
        if (!skipExactly(characters, '%'))
            return std::nullopt;

        return value;
    };

    auto saturation = parsePercentage();
    if (!saturation)
        return std::nullopt;

    if (isLegacy && !skipExactly(characters, ','))
        return std::nullopt;

    auto lightness = parsePercentage();
    if (!lightness)
        return std::nullopt;

    skipWhitespace(characters);

    // Alpha is optional. Legacy uses comma separator, modern uses slash.
    double alpha = 1.0;
    char alphaSeparator = isLegacy ? ',' : '/';
    if (!characters.empty() && characters.front() == alphaSeparator) {
        skip(characters, 1);
        skipWhitespace(characters);

        size_t numCharactersParsed;
        if ((numCharactersParsed = parseDouble(characters, ')', alpha))) {
            skip(characters, numCharactersParsed);
        } else if ((numCharactersParsed = parseDouble(characters, '%', alpha))) {
            skip(characters, numCharactersParsed);
            if (!skipExactly(characters, '%'))
                return std::nullopt;
            alpha /= 100.0;
        } else
            return std::nullopt;

        skipWhitespace(characters);
    }

    if (characters.empty() || characters.front() != ')')
        return std::nullopt;

    auto parsedColor = StyleColorParseType<HSLFunctionModern> {
        Style::Angle<>      { narrowPrecisionToFloat(CSS::convertAngle<CSS::AngleUnit::Deg>(hue, angleUnit)) },
        Style::Percentage<> { narrowPrecisionToFloat(*saturation) },
        Style::Percentage<> { narrowPrecisionToFloat(*lightness) },
        Style::Number<>     { narrowPrecisionToFloat(alpha) }
    };
    auto typedColor = convertToTypedColor<HSLFunctionModern>(parsedColor, 1.0);
    return convertToColor<HSLFunctionModern, CSSColorFunctionForm::Absolute>(typedColor, 0).tryGetAsSRGBABytes();
}

template<typename CharacterType>
static std::optional<SRGBA<uint8_t>> parseNumericColor(std::span<const CharacterType> characters, const CSSParserContext& context, CSSParserFastPaths::ColorScanner scanner)
{
    if (characters.size() >= 4 && characters.front() == '#') {
        if (auto hexColor = parseHexColorInternal(characters.subspan(1), scanner))
            return *hexColor;
    }

    if (isQuirksModeBehavior(context.mode) && (characters.size() == 3 || characters.size() == 6)) {
        if (auto hexColor = parseHexColorInternal(characters, scanner))
            return *hexColor;
    }

    if (mightBeRGB(characters) || mightBeRGBA(characters)) {
        auto expectedUnitType = CSSUnitType::Unknown;
        auto current = mightBeRGBA(characters) ? characters.subspan(5) : characters.subspan(4);

        // Red and green will both terminate with ','.
        auto red = parseColorIntOrPercentage(current, ',', expectedUnitType);
        if (!red)
            return std::nullopt;
        auto green = parseColorIntOrPercentage(current, ',', expectedUnitType);
        if (!green)
            return std::nullopt;

        // Blue may terminate with ',' or ')', but do not consume either terminator.
        auto blue = parseColorIntOrPercentage(current, std::nullopt, expectedUnitType);
        if (!blue)
            return std::nullopt;
        if (current.empty())
            return std::nullopt;

        // Finish parsing rgb if no alpha value.
        if (current.front() == ')') {
            consume(current);
            if (!current.empty())
                return std::nullopt;
            return SRGBA<uint8_t> { *red, *green, *blue };
        }

        // Parse alpha value if present.
        if (current.front() == ',') {
            consume(current);
            auto alpha = parseRGBAlphaValue(current, ')');
            if (!alpha)
                return std::nullopt;
            if (!current.empty())
                return std::nullopt;
            return SRGBA<uint8_t> { *red, *green, *blue, *alpha };
        }

        return std::nullopt;
    }

    // hsl() and hsla() are synonyms.
    if (mightBeHSLA(characters))
        return parseHSL(characters.subspan(5));

    if (mightBeHSL(characters))
        return parseHSL(characters.subspan(4));

    return std::nullopt;
}

static std::optional<SRGBA<uint8_t>> parseNumericColor(StringView string, const CSSParserContext& context, CSSParserFastPaths::ColorScanner scanner)
{
    if (string.is8Bit())
        return parseNumericColor(string.span8(), context, scanner);
    return parseNumericColor(string.span16(), context, scanner);
}

static RefPtr<CSSValue> parseColor(StringView string, const CSSParserContext& context)
{
    ASSERT(!string.isEmpty());
    auto valueID = cssValueKeywordID(string);
    if (CSS::isColorKeyword(valueID)) {
        if (!CSSPropertyParserHelpers::isColorKeywordAllowed(valueID, context))
            return nullptr;
        return CSSKeywordValue::create(valueID);
    }
    if (auto color = parseNumericColor(string, context, CSSParserFastPaths::defaultColorScanner))
        return CSSValuePool::singleton().createColorValue(*color);
    return nullptr;
}

// The island's half of the named-colour lookup. Declared in CSSTokenizerSwiftTypes.h, where the
// reason it takes a bounded, non-escaping pointer rather than a NUL-terminated buffer is written
// down: that pair of annotations is what makes the importer hand Swift a single `Span`, so the
// island passes its folded buffer down without a marker.
//
// Both annotations are repeated here because `__counted_by` participates in the function's type:
// spelling the definition as a plain `const Latin1Character*` is a "conflicting types" error, not
// a redundancy.
CSSSwiftColor cssSwiftFindNamedColor(const Latin1Character *__counted_by(length) name __attribute__((noescape)), size_t length)
{
    auto* namedColor = findColor(byteCast<char>(name), static_cast<unsigned>(length));
    if (!namedColor)
        return CSSSwiftColor { 0, static_cast<uint8_t>(CSSSwiftColorOutcomeNotAColor) };
    return CSSSwiftColor { namedColor->ARGBValue, static_cast<uint8_t>(CSSSwiftColorOutcomeParsed) };
}

static std::optional<SRGBA<uint8_t>> finishParsingNamedColor(std::span<char> buffer)
{
    buffer.back() = '\0';
    auto namedColor = findColor(buffer.data(), buffer.size() - 1);
    if (!namedColor)
        return std::nullopt;
    return asSRGBA(PackedColor::ARGB { namedColor->ARGBValue });
}

template<typename CharacterType> static std::optional<SRGBA<uint8_t>> parseNamedColorInternalCpp(std::span<const CharacterType> characters)
{
    std::array<char, 64> buffer; // Easily big enough for the longest color name.
    if (characters.size() > buffer.size() - 1)
        return std::nullopt;
    for (size_t i = 0; i < characters.size(); ++i) {
        auto character = characters[i];
        if (!character || !isASCII(character))
            return std::nullopt;
        buffer[i] = toASCIILower(static_cast<char>(character));
    }
    return finishParsingNamedColor(std::span { buffer }.first(characters.size() + 1));
}

template<typename CharacterType> static std::optional<SRGBA<uint8_t>> parseNamedColorInternal(std::span<const CharacterType> characters, CSSParserFastPaths::ColorScanner scanner)
{
    if (scanner == CSSParserFastPaths::ColorScanner::Swift) {
        // The island answers `NotAColor` rather than declining for a candidate longer than the
        // crossing capacity, because gperf's own `MAX_WORD_LENGTH` over ColorData.gperf's 152
        // keys is 20 and the longest name is `lightgoldenrodyellow`. That is the one claim in
        // this island that rests on a generated file rather than on the code beside it, so it
        // is checked rather than argued: every debug run of every test that reaches a colour
        // compares it against the scanner it replaces, and colorcheck sweeps every length from
        // 0 to 70 in release.
        ASSERT(characters.size() <= cssSwiftColorTextCapacity || !parseNamedColorInternalCpp(characters));

        if (auto answer = resolveSwiftColorScan(scanNamedColorSwift(makeSwiftColorText(characters))))
            return *answer;
    }
    return parseNamedColorInternalCpp(characters);
}

template<typename CharacterType> static std::optional<SRGBA<uint8_t>> parseSimpleColorInternal(std::span<const CharacterType> characters, const CSSParserContext& context, CSSParserFastPaths::ColorScanner scanner)
{
    if (auto color = parseNumericColor(characters, context, scanner))
        return color;
    return parseNamedColorInternal(characters, scanner);
}

std::optional<SRGBA<uint8_t>> CSSParserFastPaths::parseSimpleColor(StringView string, const CSSParserContext& context, ColorScanner scanner)
{
    if (string.is8Bit())
        return parseSimpleColorInternal(string.span8(), context, scanner);
    return parseSimpleColorInternal(string.span16(), context, scanner);
}

std::optional<SRGBA<uint8_t>> CSSParserFastPaths::parseHexColor(StringView string, ColorScanner scanner)
{
    if (string.is8Bit())
        return parseHexColorInternal(string.span8(), scanner);
    return parseHexColorInternal(string.span16(), scanner);
}

std::optional<SRGBA<uint8_t>> CSSParserFastPaths::parseNamedColor(StringView string, ColorScanner scanner)
{
    if (string.is8Bit())
        return parseNamedColorInternal(string.span8(), scanner);
    return parseNamedColorInternal(string.span16(), scanner);
}

static bool isUniversalKeyword(StringView string)
{
    // These keywords can be used for all properties.
    return equalLettersIgnoringASCIICase(string, "initial"_s)
        || equalLettersIgnoringASCIICase(string, "inherit"_s)
        || equalLettersIgnoringASCIICase(string, "unset"_s)
        || equalLettersIgnoringASCIICase(string, "revert"_s)
        || equalLettersIgnoringASCIICase(string, "revert-layer"_s)
        || equalLettersIgnoringASCIICase(string, "revert-rule"_s);
}

static RefPtr<CSSValue> parseKeywordValue(CSSPropertyID property, StringView string, CSS::PropertyParserState& state)
{
    ASSERT(!string.isEmpty());

    if (!CSSPropertyParsing::isKeywordFastPathEligibleStyleProperty(property)) {
        // All properties, including non-keyword properties, accept the CSS-wide keywords.
        if (!isUniversalKeyword(string))
            return nullptr;

        // Leave shorthands to parse CSS-wide keywords using CSSPropertyParser.
        if (shorthandForProperty(property).length())
            return nullptr;
    }

    auto valueID = cssValueKeywordID(string);
    if (!valueID)
        return nullptr;

    if (isCSSWideKeyword(valueID))
        return CSSKeywordValue::create(valueID);

    if (CSSPropertyParsing::isKeywordValidForStyleProperty(property, valueID, state))
        return CSSKeywordValue::create(valueID);
    return nullptr;
}

template <typename CharType>
static bool parseTransformTranslateArguments(StringParsingBuffer<CharType>& buffer, unsigned expectedCount, CSSValueID transformType, CSSValueListBuilder& arguments)
{
    while (expectedCount) {
        size_t delimiter = find(buffer.span(), expectedCount == 1 ? ')' : ',');
        if (delimiter == notFound)
            return false;
        unsigned argumentLength = static_cast<unsigned>(delimiter);
        CSSUnitType unit = CSSUnitType::Number;
        double number;
        if (!parseSimpleLength(buffer.span().first(argumentLength), unit, number))
            return false;
        if (!number && unit == CSSUnitType::Number)
            unit = CSSUnitType::Px;
        if (unit == CSSUnitType::Number || (unit == CSSUnitType::Percentage && (transformType == CSSValueTranslateZ || (transformType == CSSValueTranslate3d && expectedCount == 1))))
            return false;
        arguments.append(CSSPrimitiveValue::create(number, unit));
        buffer.advanceBy(argumentLength + 1);
        --expectedCount;
    }
    return true;
}

template <typename CharType>
static RefPtr<CSSValue> parseTransformAngleArgument(StringParsingBuffer<CharType>& buffer)
{
    size_t delimiter = find(buffer.span(), ')');
    if (delimiter == notFound)
        return nullptr;

    unsigned argumentLength = static_cast<unsigned>(delimiter);
    auto angleUnit = CSS::AngleUnit::Deg;
    double number;
    if (!parseSimpleAngle(buffer.span().first(argumentLength), RequireUnits::Yes, angleUnit, number))
        return nullptr;

    buffer.advanceBy(argumentLength + 1);

    return CSSPrimitiveValue::create(number, CSS::toCSSUnitType(angleUnit));
}

template <typename CharType>
static bool parseTransformNumberArguments(StringParsingBuffer<CharType>& buffer, unsigned expectedCount, CSSValueListBuilder& arguments)
{
    while (expectedCount) {
        size_t delimiter = find(buffer.span(), expectedCount == 1 ? ')' : ',');
        if (delimiter == notFound)
            return false;
        unsigned argumentLength = static_cast<unsigned>(delimiter);
        auto number = parseCSSNumber(buffer.span().first(argumentLength));
        if (!number)
            return false;
        arguments.append(CSSPrimitiveValue::create(*number, CSSUnitType::Number));
        buffer.advanceBy(argumentLength + 1);
        --expectedCount;
    }
    return true;
}

template <typename CharType>
static RefPtr<CSSFunctionValue> parseSimpleTransformValue(StringParsingBuffer<CharType>& buffer)
{
    // Also guarantees indexes up to buffer[8] are safe to access below.
    constexpr auto shortestValidTransformStringLength = 9; // "rotate(0)"
    if (buffer.lengthRemaining() < shortestValidTransformStringLength)
        return nullptr;

    bool isTranslate = toASCIILower(buffer[0]) == 't'
        && toASCIILower(buffer[1]) == 'r'
        && toASCIILower(buffer[2]) == 'a'
        && toASCIILower(buffer[3]) == 'n'
        && toASCIILower(buffer[4]) == 's'
        && toASCIILower(buffer[5]) == 'l'
        && toASCIILower(buffer[6]) == 'a'
        && toASCIILower(buffer[7]) == 't'
        && toASCIILower(buffer[8]) == 'e';

    if (isTranslate) {
        // Also guarantees indexes up to buffer[11] are safe to access below.
        constexpr auto shortestValidTranslateStringLength = 12; // "translate(0)"
        if (buffer.lengthRemaining() < shortestValidTranslateStringLength)
            return nullptr;

        CSSValueID transformType;
        unsigned expectedArgumentCount = 1;
        unsigned argumentStart = 11;
        CharType c9 = toASCIILower(buffer[9]);
        if (c9 == 'x' && buffer[10] == '(') {
            transformType = CSSValueTranslateX;
        } else if (c9 == 'y' && buffer[10] == '(') {
            transformType = CSSValueTranslateY;
        } else if (c9 == 'z' && buffer[10] == '(') {
            transformType = CSSValueTranslateZ;
        } else if (c9 == '(') {
            transformType = CSSValueTranslate;
            expectedArgumentCount = 2;
            argumentStart = 10;
        } else if (c9 == '3' && toASCIILower(buffer[10]) == 'd' && buffer[11] == '(') {
            transformType = CSSValueTranslate3d;
            expectedArgumentCount = 3;
            argumentStart = 12;
        } else
            return nullptr;

        CSSValueListBuilder arguments;
        buffer.advanceBy(argumentStart);
        if (!parseTransformTranslateArguments(buffer, expectedArgumentCount, transformType, arguments))
            return nullptr;
        return CSSFunctionValue::create(transformType, WTF::move(arguments));
    }

    bool isMatrix3d = toASCIILower(buffer[0]) == 'm'
        && toASCIILower(buffer[1]) == 'a'
        && toASCIILower(buffer[2]) == 't'
        && toASCIILower(buffer[3]) == 'r'
        && toASCIILower(buffer[4]) == 'i'
        && toASCIILower(buffer[5]) == 'x'
        && buffer[6] == '3'
        && toASCIILower(buffer[7]) == 'd'
        && buffer[8] == '(';

    if (isMatrix3d) {
        buffer.advanceBy(9);
        CSSValueListBuilder arguments;
        if (!parseTransformNumberArguments(buffer, 16, arguments))
            return nullptr;
        return CSSFunctionValue::create(CSSValueMatrix3d, WTF::move(arguments));
    }

    bool isScale3d = toASCIILower(buffer[0]) == 's'
        && toASCIILower(buffer[1]) == 'c'
        && toASCIILower(buffer[2]) == 'a'
        && toASCIILower(buffer[3]) == 'l'
        && toASCIILower(buffer[4]) == 'e'
        && buffer[5] == '3'
        && toASCIILower(buffer[6]) == 'd'
        && buffer[7] == '(';

    if (isScale3d) {
        buffer.advanceBy(8);
        CSSValueListBuilder arguments;
        if (!parseTransformNumberArguments(buffer, 3, arguments))
            return nullptr;
        return CSSFunctionValue::create(CSSValueScale3d, WTF::move(arguments));
    }

    bool isRotate = toASCIILower(buffer[0]) == 'r'
        && toASCIILower(buffer[1]) == 'o'
        && toASCIILower(buffer[2]) == 't'
        && toASCIILower(buffer[3]) == 'a'
        && toASCIILower(buffer[4]) == 't'
        && toASCIILower(buffer[5]) == 'e';

    if (isRotate) {
        CSSValueID transformType;
        unsigned argumentStart = 7;
        CharType c6 = toASCIILower(buffer[6]);
        if (c6 == '(') {
            transformType = CSSValueRotate;
        } else if (c6 == 'z' && buffer[7] == '(') {
            transformType = CSSValueRotateZ;
            argumentStart = 8;
        } else
            return nullptr;

        buffer.advanceBy(argumentStart);
        RefPtr angle = parseTransformAngleArgument(buffer);
        if (!angle)
            return nullptr;
        return CSSFunctionValue::create(transformType, angle.releaseNonNull());
    }

    return nullptr;
}

template<typename CharacterType>
static RefPtr<CSSValue> parseSimpleTransformList(std::span<const CharacterType> characters)
{
    StringParsingBuffer<CharacterType> buffer(characters);
    CSSValueListBuilder builder;
    while (buffer.hasCharactersRemaining()) {
        while (buffer.hasCharactersRemaining() && isCSSSpace(*buffer))
            buffer.consume();
        if (buffer.atEnd())
            break;
        auto transformValue = parseSimpleTransformValue(buffer);
        if (!transformValue)
            return nullptr;
        builder.append(transformValue.releaseNonNull());
    }
    if (builder.isEmpty())
        return nullptr;
    return CSSTransformListValue::create(WTF::move(builder));
}

static RefPtr<CSSValue> parseSimpleTransform(StringView string)
{
    ASSERT(!string.isEmpty());
    if (string.is8Bit())
        return parseSimpleTransformList(string.span8());
    return parseSimpleTransformList(string.span16());
}

static RefPtr<CSSValue> parseDisplay(StringView string)
{
    ASSERT(!string.isEmpty());
    auto valueID = cssValueKeywordID(string);

    switch (valueID) {
    case CSSValueNone:
    // <display-outside>
    case CSSValueBlock:
    case CSSValueInline:
    // <display-inside> (except for CSSValueFlow since it becomes "block")
    case CSSValueFlex:
    case CSSValueFlowRoot:
    case CSSValueGrid:
    case CSSValueTable:
    // <display-internal>
    case CSSValueTableCaption:
    case CSSValueTableCell:
    case CSSValueTableColumnGroup:
    case CSSValueTableColumn:
    case CSSValueTableHeaderGroup:
    case CSSValueTableFooterGroup:
    case CSSValueTableRow:
    case CSSValueTableRowGroup:
    // <display-legacy>
    case CSSValueInlineBlock:
    case CSSValueInlineFlex:
    case CSSValueInlineGrid:
    case CSSValueInlineTable:
    // Prefixed values
    case CSSValueWebkitInlineBox:
    case CSSValueWebkitBox:
    // No layout support for the full <display-listitem> syntax, so treat it as <display-legacy>
    case CSSValueListItem:
        return CSSKeywordValue::create(valueID);
    default:
        if (isCSSWideKeyword(valueID))
            return CSSKeywordValue::create(valueID);
        return nullptr;
    }
}

static RefPtr<CSSValue> parseOpacity(StringView string)
{
    double number;

    if (string.is8Bit()) {
        if (!parseSimpleNumberOrPercentageDividedBy100(string.span8(), number))
            return nullptr;
    } else {
        if (!parseSimpleNumberOrPercentageDividedBy100(string.span16(), number))
            return nullptr;
    }

    return CSSPrimitiveValue::create(number, CSSUnitType::Number);
}

static RefPtr<CSSValue> parseColorWithAuto(StringView string, const CSSParserContext& context)
{
    ASSERT(!string.isEmpty());
    if (cssValueKeywordID(string) == CSSValueAuto)
        return CSSKeywordValue::create(CSSValueAuto);
    return parseColor(string, context);
}

RefPtr<CSSValue> CSSParserFastPaths::maybeParseValue(CSSPropertyID property, StringView string, CSS::PropertyParserState& state)
{
    // Some at-rules like @keyframes, @position-try restrict which properties
    // are allowed inside the rule. Fallback to slow path for at-rules since
    // the restriction logic is in the slow-path parser (CSSPropertyParser).
    if (state.currentRule != StyleRuleType::Style)
        return nullptr;

    switch (property) {
    case CSSPropertyDisplay:
        return parseDisplay(string);
    case CSSPropertyOpacity:
        return parseOpacity(string);
    case CSSPropertyTransform:
        return parseSimpleTransform(string);
    case CSSPropertyCaretColor:
    case CSSPropertyAccentColor:
        if (isExposed(property, &state.context.propertySettings))
            return parseColorWithAuto(string, state.context);
        break;
    default:
        break;
    }

    if (CSSProperty::isColorProperty(property)) {
        auto context = state.context;
        if (!CSSProperty::acceptsQuirkyColor(property))
            context.mode = HTMLStandardMode;
        return parseColor(string, context);
    }

    if (auto valueRange = lengthValueRangeForPropertiesSupportingSimpleLengths(property)) {
        if (auto result = parseSimpleLengthValue(string, state.context.mode, *valueRange))
            return result;
    }

    return parseKeywordValue(property, string, state);
}

} // namespace WebCore
