/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// Bridge for the Swift CSS tokenizer island (CSSTokenizerSwift.swift), see
// ~/Documents/webkit-swift-adoption-notes.md §11.
//
// Exposes three things to TestWebKitAPI, `extern "C"` so no header needs
// exporting:
//
//   1. the Swift island, driven over a span;
//   2. a validation entry that walks the *real* CSSTokenizer's token stream and
//      the island's side by side and reports the first divergence. This is the
//      gate that matters: the standalone probe only proves two of my own ports
//      agree with each other, which a symmetric misreading of the spec would
//      satisfy;
//   3. a benchmark entry that times the island against the real CSSTokenizer's
//      tokenization loop.

#include "config.h"

#include "CSSParserObserver.h"
#include "CSSParserObserverWrapper.h"
#include "CSSParserToken.h"
#include "CSSParserTokenRange.h"
#include "CSSTokenizer.h"
#include "CSSTokenizerInputStream.h"
#include "WebCoreSwift-Generated.h"
#include <optional>
#include <wtf/StdLibExtras.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
namespace {

// Must match CSSTokenFlag in CSSTokenizerSwift.swift.
enum SwiftTokenFlag : uint8_t {
    FlagNonInteger = 1 << 0,
    FlagPlusSign = 1 << 1,
    FlagMinusSign = 1 << 2,
    FlagHashTokenId = 1 << 3,
    FlagNeedsUnescape = 1 << 4,
};

// A do-nothing observer, so a CSSParserObserverWrapper can be constructed and the
// offsets the tokenizer feeds it compared between the two paths. The parser is
// what would normally call these; the tokenizer only supplies offsets.
class NullCSSParserObserver final : public CSSParserObserver {
public:
    void startRuleHeader(StyleRuleType, unsigned) final { }
    void endRuleHeader(unsigned) final { }
    void observeSelector(unsigned, unsigned) final { }
    void startRuleBody(unsigned) final { }
    void endRuleBody(unsigned) final { }
    void markRuleBodyContainsImplicitlyNestedProperties() final { }
    void observeProperty(unsigned, unsigned, bool, bool) final { }
    void observeComment(unsigned, unsigned) final { }
};

// The island reports comments; CSSTokenizer drops them from m_tokens. The
// validation walk therefore skips them on the Swift side.
bool isComment(const CSSSwiftToken& token)
{
    return token.type == static_cast<uint8_t>(CommentToken);
}

} // namespace
} // namespace WebCore

using namespace WebCore;

extern "C" {

struct CSSTokenizerSwiftValidationResult {
    // -1 when the streams agree; otherwise the index of the first divergence.
    int64_t divergenceIndex;
    // What diverged, for the failure message.
    uint32_t expectedType;
    uint32_t actualType;
    uint64_t realTokenCount;
    uint64_t swiftTokenCount;
    // 0 = types differ, 1 = value text differs, 2 = counts differ.
    uint32_t reason;
};

WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerSwiftValidate(const char*, size_t);
WEBCORE_EXPORT void webCoreCSSTokenizerBenchSwift(const uint8_t*, size_t, size_t*, uint64_t*);
WEBCORE_EXPORT void webCoreCSSTokenizerBenchReal(const char*, size_t, size_t*, uint64_t*);
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePaths(const char*, size_t);
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerCompareObserverOffsets(const char*, size_t);
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePathsUTF8(const char*, size_t);
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated(const char*, size_t, bool, size_t*, uint64_t*);

// Walks the real CSSTokenizer and the Swift island over the same stylesheet.
//
// Only 8-bit input is compared: the island's element type is `UInt8`, and a
// stylesheet that survives preprocessing as Latin-1 is exactly the case it
// handles. Callers pass Latin-1 text.
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerSwiftValidate(const char* text, size_t length)
{
    CSSTokenizerSwiftValidationResult result { -1, 0, 0, 0, 0, 0 };

    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    WebCore::CSSTokenizer tokenizer(source);
    auto range = tokenizer.tokenRange();

    // The island sees what the real tokenizer sees: the *preprocessed* string.
    // Reconstructing it here rather than reaching into the tokenizer keeps this
    // bridge out of CSSTokenizer's internals; preprocessing is a no-op for
    // Latin-1 input without NULs, which is what the tests feed.
    auto preprocessed = source;
    if (!preprocessed.is8Bit()) {
        result.reason = 2;
        result.divergenceIndex = 0;
        return result;
    }
    auto span = preprocessed.span8();

    size_t realCount = 0;
    for (auto probe = range; !probe.atEnd(); probe.consume())
        ++realCount;
    result.realTokenCount = realCount;

    size_t swiftIndex = 0;
    size_t compared = 0;
    for (auto cursor = range; !cursor.atEnd(); cursor.consume(), ++compared) {
        const CSSParserToken& real = cursor.peek();

        // Advance the island past any comments, which the real stream omits.
        WebCore::CSSSwiftToken mine = WebCore::cssTokenizeSwiftNth(span, swiftIndex);
        while (WebCore::isComment(mine)) {
            ++swiftIndex;
            mine = WebCore::cssTokenizeSwiftNth(span, swiftIndex);
        }

        if (static_cast<uint8_t>(real.type()) != mine.type) {
            result.divergenceIndex = static_cast<int64_t>(compared);
            result.expectedType = static_cast<uint32_t>(real.type());
            result.actualType = mine.type;
            result.reason = 0;
            result.swiftTokenCount = swiftIndex;
            return result;
        }

        // Value text, for the token kinds that carry one. Skipped when the
        // island flagged the value as needing unescaping: there the real token
        // holds the *unescaped* string from m_stringPool while the island
        // reports the raw range, by design (the island cannot allocate a
        // String). Escaped values are covered by the extent-level comparison in
        // the standalone probe instead.
        //
        // The numeric kinds need care, because CSSParserToken does not store
        // what the token grammar suggests:
        //
        //   NumberToken      value() is the number's original text.
        //   PercentageToken  likewise — convertToPercentage() only retypes.
        //   DimensionToken   convertToDimensionWithUnit() *merges* the number
        //                    and the unit into one StringView when they are
        //                    adjacent in the buffer and the number is shorter
        //                    than 16 characters, and falls back to the unit
        //                    alone otherwise.
        //
        // The island reports the number range and the unit range separately,
        // which is strictly more information; reconstruct what the real token
        // should hold and compare that.
        std::optional<std::pair<uint32_t, uint32_t>> expectedRange;
        switch (real.type()) {
        case IdentToken:
        case FunctionToken:
        case AtKeywordToken:
        case HashToken:
        case UrlToken:
        case StringToken:
            expectedRange = { { mine.valueStart, mine.valueLength } };
            break;
        case NumberToken:
        case PercentageToken:
            expectedRange = { { mine.numberStart, mine.numberLength } };
            break;
        case DimensionToken: {
            uint32_t numberLength = mine.numberLength;
            if (numberLength && numberLength < 16) {
                uint32_t end = mine.valueStart + mine.valueLength;
                expectedRange = { { mine.numberStart, end - mine.numberStart } };
            } else
                expectedRange = { { mine.valueStart, mine.valueLength } };
            break;
        }
        default:
            break;
        }
        if (expectedRange && !(mine.flags & FlagNeedsUnescape)) {
            auto mineValue = StringView { span.subspan(expectedRange->first, expectedRange->second) };
            if (real.value() != mineValue) {
                result.divergenceIndex = static_cast<int64_t>(compared);
                result.expectedType = static_cast<uint32_t>(real.type());
                result.actualType = mine.type;
                result.reason = 1;
                result.swiftTokenCount = swiftIndex;
                return result;
            }
        }

        ++swiftIndex;
    }

    // Whatever the island has left must be comments and then EOF.
    WebCore::CSSSwiftToken tail = WebCore::cssTokenizeSwiftNth(span, swiftIndex);
    while (WebCore::isComment(tail)) {
        ++swiftIndex;
        tail = WebCore::cssTokenizeSwiftNth(span, swiftIndex);
    }
    result.swiftTokenCount = swiftIndex;
    if (tail.type != static_cast<uint8_t>(EOFToken)) {
        result.divergenceIndex = static_cast<int64_t>(compared);
        result.reason = 2;
    }
    return result;
}

WEBCORE_EXPORT void webCoreCSSTokenizerBenchSwift(const uint8_t* data, size_t length, size_t* outTokens, uint64_t* outFold)
{
    auto result = WebCore::cssTokenizeSwiftSpan(unsafeMakeSpan(reinterpret_cast<const Latin1Character*>(data), length));
    *outTokens = static_cast<size_t>(result.getTokenCount());
    *outFold = result.getFold();
}

// The real tokenizer, for the same input. Not a like-for-like control — it also
// builds CSSParserTokens, a string pool and a Vector, and converts numbers to
// double — so it is an upper bound on the work the island does, not a
// same-work comparison. The same-work control lives in the standalone probe.
WEBCORE_EXPORT void webCoreCSSTokenizerBenchReal(const char* text, size_t length, size_t* outTokens, uint64_t* outFold)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    WebCore::CSSTokenizer tokenizer(source);
    auto range = tokenizer.tokenRange();
    size_t count = 0;
    uint64_t fold = 0;
    for (; !range.atEnd(); range.consume()) {
        ++count;
        fold = fold * 1000003 + static_cast<uint64_t>(range.peek().type());
    }
    *outTokens = count;
    *outFold = fold;
}

// The integration gate: builds the whole CSSParserToken stream both ways, in one
// process, and compares the tokens themselves rather than the island's POD output.
// This is what has to hold before the Swift path could ever be turned on by
// default, because it is comparing what the rest of the CSS parser will actually
// see: values, numeric values, units, hash types and block types.
//
// The whitespace run length is not compared, because CSSParserToken keeps it in a
// private union member with no accessor. The POD-level comparison in the
// standalone probe covers it.
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePaths(const char* text, size_t length)
{
    CSSTokenizerSwiftValidationResult result { -1, 0, 0, 0, 0, 0 };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    // Both tokenizers stay alive for the comparison: each token's value is a view
    // into its own tokenizer's input or string pool.
    CSSTokenizer::setUseSwiftTokenizerForTesting(false);
    WebCore::CSSTokenizer cppTokenizer(source);
    CSSTokenizer::setUseSwiftTokenizerForTesting(true);
    WebCore::CSSTokenizer swiftTokenizer(source);
    CSSTokenizer::setUseSwiftTokenizerForTesting(std::nullopt);

    auto cppRange = cppTokenizer.tokenRange();
    auto swiftRange = swiftTokenizer.tokenRange();
    result.realTokenCount = cppRange.size();
    result.swiftTokenCount = swiftRange.size();

    size_t index = 0;
    for (; !cppRange.atEnd() && !swiftRange.atEnd(); cppRange.consume(), swiftRange.consume(), ++index) {
        const CSSParserToken& expected = cppRange.peek();
        const CSSParserToken& actual = swiftRange.peek();
        if (!(expected == actual)) {
            result.divergenceIndex = static_cast<int64_t>(index);
            result.expectedType = static_cast<uint32_t>(expected.type());
            result.actualType = static_cast<uint32_t>(actual.type());
            result.reason = 0;
            return result;
        }
        if (expected.getBlockType() != actual.getBlockType()) {
            result.divergenceIndex = static_cast<int64_t>(index);
            result.expectedType = static_cast<uint32_t>(expected.getBlockType());
            result.actualType = static_cast<uint32_t>(actual.getBlockType());
            result.reason = 1;
            return result;
        }
    }
    if (cppRange.size() != swiftRange.size()) {
        result.divergenceIndex = static_cast<int64_t>(index);
        result.reason = 2;
    }
    return result;
}

// Same comparison, but the source is built from UTF-8 so that any non-ASCII text
// makes StringImpl choose its 16-bit representation. That is the only way to
// exercise the island's UInt16 specialization: a String built from Latin-1 bytes is
// always 8-bit. `expectedType` comes back as 8 or 16 so the caller can confirm
// which representation was actually tested rather than assuming.
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePathsUTF8(const char* text, size_t length)
{
    CSSTokenizerSwiftValidationResult result { -1, 0, 0, 0, 0, 0 };
    String source = String::fromUTF8(unsafeMakeSpan(byteCast<char8_t>(text), length));
    if (source.isNull()) {
        result.divergenceIndex = 0;
        result.reason = 6;
        return result;
    }

    CSSTokenizer::setUseSwiftTokenizerForTesting(false);
    WebCore::CSSTokenizer cppTokenizer(source);
    CSSTokenizer::setUseSwiftTokenizerForTesting(true);
    WebCore::CSSTokenizer swiftTokenizer(source);
    CSSTokenizer::setUseSwiftTokenizerForTesting(std::nullopt);

    auto cppRange = cppTokenizer.tokenRange();
    auto swiftRange = swiftTokenizer.tokenRange();
    result.realTokenCount = cppRange.size();
    result.swiftTokenCount = swiftRange.size();
    result.expectedType = source.is8Bit() ? 8 : 16;

    size_t index = 0;
    for (; !cppRange.atEnd() && !swiftRange.atEnd(); cppRange.consume(), swiftRange.consume(), ++index) {
        if (!(cppRange.peek() == swiftRange.peek())) {
            result.divergenceIndex = static_cast<int64_t>(index);
            result.actualType = static_cast<uint32_t>(cppRange.peek().type());
            result.reason = 0;
            return result;
        }
        if (cppRange.peek().getBlockType() != swiftRange.peek().getBlockType()) {
            result.divergenceIndex = static_cast<int64_t>(index);
            result.actualType = static_cast<uint32_t>(cppRange.peek().getBlockType());
            result.reason = 1;
            return result;
        }
    }
    if (cppRange.size() != swiftRange.size()) {
        result.divergenceIndex = static_cast<int64_t>(index);
        result.reason = 2;
    }
    return result;
}

// The inspector path: both tokenizers built with an observer wrapper attached, then
// every source offset the wrapper was fed compared. A wrapper records one offset
// per token plus one per comment, and startOffset()/endOffset() read them back, so
// walking the range position by position checks all of them.
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerCompareObserverOffsets(const char* text, size_t length)
{
    CSSTokenizerSwiftValidationResult result { -1, 0, 0, 0, 0, 0 };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    NullCSSParserObserver observer;
    auto cppWrapper = CSSParserObserverWrapper::create(observer);
    auto swiftWrapper = CSSParserObserverWrapper::create(observer);

    CSSTokenizer::setUseSwiftTokenizerForTesting(false);
    WebCore::CSSTokenizer cppTokenizer(source, cppWrapper.get());
    CSSTokenizer::setUseSwiftTokenizerForTesting(true);
    WebCore::CSSTokenizer swiftTokenizer(source, swiftWrapper.get());
    CSSTokenizer::setUseSwiftTokenizerForTesting(std::nullopt);

    auto cppRange = cppTokenizer.tokenRange();
    auto swiftRange = swiftTokenizer.tokenRange();
    result.realTokenCount = cppRange.size();
    result.swiftTokenCount = swiftRange.size();
    if (cppRange.size() != swiftRange.size()) {
        result.divergenceIndex = 0;
        result.reason = 2;
        return result;
    }

    size_t index = 0;
    for (; !cppRange.atEnd(); cppRange.consume(), swiftRange.consume(), ++index) {
        if (cppWrapper->startOffset(cppRange) != swiftWrapper->startOffset(swiftRange)) {
            result.divergenceIndex = static_cast<int64_t>(index);
            result.expectedType = cppWrapper->startOffset(cppRange);
            result.actualType = swiftWrapper->startOffset(swiftRange);
            result.reason = 3;
            return result;
        }
    }
    if (cppWrapper->endOffset(cppRange) != swiftWrapper->endOffset(swiftRange)) {
        result.divergenceIndex = static_cast<int64_t>(index);
        result.expectedType = cppWrapper->endOffset(cppRange);
        result.actualType = swiftWrapper->endOffset(swiftRange);
        result.reason = 4;
    }
    return result;
}

// Times a whole CSSTokenizer construction on one path or the other. Same work on
// both sides at last: same tokens, same string pool, same double conversions.
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated(const char* text, size_t length, bool useSwift, size_t* outTokens, uint64_t* outFold)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    CSSTokenizer::setUseSwiftTokenizerForTesting(useSwift);
    WebCore::CSSTokenizer tokenizer(source);
    CSSTokenizer::setUseSwiftTokenizerForTesting(std::nullopt);
    size_t count = 0;
    uint64_t fold = 0;
    for (auto range = tokenizer.tokenRange(); !range.atEnd(); range.consume()) {
        ++count;
        fold = fold * 1000003 + static_cast<uint64_t>(range.peek().type());
    }
    *outTokens = count;
    *outFold = fold;
}

} // extern "C"
