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
// Exposes three things to TestWebKitAPI and the standalone harnesses, `extern "C"`
// so no header needs exporting:
//
//   1. comparison entries that build the whole CSSParserToken stream both ways in
//      one process and compare the tokens themselves — at either character width,
//      and with an observer wrapper attached. This is the gate that matters: the
//      standalone probe only proves two of my own ports agree with each other,
//      which a symmetric misreading of the spec would satisfy;
//   2. benchmark entries that time a whole CSSTokenizer construction on one
//      scanner or the other, at either width;
//   3. diagnostics: the decline counter, the forced-decline switch for the
//      failure-reporting path, and the compile-time scanner choice.
//
// Every entry here is WEBCORE_EXPORT and this file is in WebCore's own sources with
// no `#if` guard, so it ships inside WebCore.framework: its size is interop cost,
// not test overhead. Two families of entry were deleted for that reason, both
// strictly dominated. A `webCoreCSSTokenizerSwiftValidate` walked the island's POD
// output beside a real CSSParserTokenRange, but skipped escaped values entirely and
// hand-reimplemented CSSParserToken::convertToDimensionWithUnit's merge rule, where
// webCoreCSSTokenizerComparePaths below compares real CSSParserTokens including
// their numeric fields and block types. A `webCoreCSSTokenizerBenchSwift` /
// `...BenchReal` pair timed the island's scan against a control its own comment
// admitted was "not a like-for-like control", where
// webCoreCSSTokenizerBenchIntegrated does the same work on both sides.

#include "config.h"

// Off unless ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE=1. Everything below is WEBCORE_EXPORT and
// exists only to validate the island against the C++ scanner and to measure it, so it has no
// business in a shipping WebCore.framework -- which is where it was going, since this file is
// in WebCore's own sources build phase with no guard at all. Switch it on with
// WK_ENABLE_CSS_TOKENIZER_SWIFT_BRIDGE=YES, which appends the define for both WebCore and
// TestWebKitAPI; the flag has to reach both, because TestWebKitAPI links these symbols.
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)

#include "CSSParserObserver.h"
#include "CSSParserObserverWrapper.h"
#include "CSSParserToken.h"
#include "CSSParserTokenRange.h"
#include "CSSTokenizer.h"
#include "CSSTokenizerSwiftTypes.h"
// Same suppression, and the same FIXME, as CSSTokenizer.cpp: the generated header's
// `SWIFT_ENUM` hands C++ an Objective-C-only non-defining fixed-underlying-type enum
// declaration for each `@c` enum, which -Werror makes fatal. Filings register §26.
IGNORE_CLANG_WARNINGS_BEGIN("elaborated-enum-base")
#include "WebCoreSwift-Generated.h"
IGNORE_CLANG_WARNINGS_END
#include <optional>
#include <wtf/StdLibExtras.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
namespace {

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
    // What diverged, decoded by divergenceReason() in CSSTokenizerSwiftTest.cpp and by
    // the copies in cssprobe's csscheck.cpp and cssfuzz.cpp: 0 = the tokens compare
    // unequal, 1 = block types, 2 = token counts, 3 = an observer token offset,
    // 4 = the observer's end offset, 5 = a numeric field, 6 = the source was not valid
    // UTF-8, 7 = a dimension's unit type, 8 = a dimension's value text, 9 = a
    // dimension's non-unit prefix length. Add a case to all three when adding a code.
    uint32_t reason;
};

WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePaths(const char*, size_t);
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerCompareObserverOffsets(const char*, size_t);
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePathsUTF8(const char*, size_t);
WEBCORE_EXPORT unsigned webCoreCSSTokenizerSwiftDeclineCount(void);
WEBCORE_EXPORT void webCoreCSSTokenizerSetForceSwiftIslandDecline(bool);
WEBCORE_EXPORT bool webCoreCSSTokenizerTryCreateSucceeds(const char*, size_t);
WEBCORE_EXPORT bool webCoreCSSTokenizerDefaultScannerIsSwift(void);
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated(const char*, size_t, bool, size_t*, uint64_t*);
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated16(const char*, size_t, bool, size_t*, uint64_t*, bool*);

// The integration gate: builds the whole CSSParserToken stream both ways, in one
// process, and compares the tokens themselves rather than the island's POD output.
// This is what has to hold before the Swift path could ever be turned on by
// default, because it is comparing what the rest of the CSS parser will actually
// see: values, numeric values, units, hash types and block types.
//
// One token's worth of that comparison, shared by the 8-bit and the UTF-8 entry below
// so that the two cannot drift apart. Returns nothing when the tokens agree.
//
// operator== covers more than it looks: the whitespace run length is compared, via
// `case NonNewlineWhitespaceToken` in CSSParserToken.cpp. What it does not cover is
// the numeric fields of NumberToken and PercentageToken -- for those it compares
// originalText() and stops -- and, for a DimensionToken, anything but originalText()
// whenever the *left* operand has a non-unit prefix. Both holes are filled below:
// after this function returns nullopt, every field a DimensionToken carries has been
// compared, m_nonUnitPrefixLength included, and none of it needed a new accessor.
struct TokenDivergence {
    uint32_t reason;
    uint32_t expected;
    uint32_t actual;
};

static std::optional<TokenDivergence> compareTokens(const CSSParserToken& expected, const CSSParserToken& actual)
{
    if (!(expected == actual))
        return TokenDivergence { 0, static_cast<uint32_t>(expected.type()), static_cast<uint32_t>(actual.type()) };
    if (expected.getBlockType() != actual.getBlockType())
        return TokenDivergence { 1, static_cast<uint32_t>(expected.getBlockType()), static_cast<uint32_t>(actual.getBlockType()) };

    // The island's nonInteger, plusSign and minusSign flags become numericValueType and
    // numericSign, and for NumberToken and PercentageToken nothing above compares them:
    // a wrong flag would pass every test here while breaking <integer> validation and
    // nth-child(An+B) sign handling.
    //
    // Compared as bit patterns rather than as doubles, so that +0 and -0 are
    // distinguished -- that is exactly the difference a sign flag makes, and == would
    // hide it. Both paths run the same charactersToDouble over the same range, so
    // anything but an identical pattern is a real divergence.
    if (expected.type() == NumberToken || expected.type() == PercentageToken || expected.type() == DimensionToken) {
        bool agrees = std::bit_cast<uint64_t>(expected.numericValue()) == std::bit_cast<uint64_t>(actual.numericValue())
            && expected.numericValueType() == actual.numericValueType();
        // numericSign() asserts on NumberToken: it is the only type <an+b> reads it for.
        if (agrees && expected.type() == NumberToken)
            agrees = expected.numericSign() == actual.numericSign();
        if (!agrees)
            return TokenDivergence { 5, static_cast<uint32_t>(expected.numericValueType()), static_cast<uint32_t>(actual.numericValueType()) };
    }

    // A DimensionToken's unit. operator== takes its `m_nonUnitPrefixLength == 0` branch
    // off *this* -- the C++ token here -- and only that branch compares unitString();
    // with a prefix it falls through to `originalText() == other.originalText()`, so a
    // wrong m_unit or a wrong prefix length on such a token compared equal. That is not
    // hypothetical: it is the field a proposed change to this island would have
    // corrupted with every test still passing.
    //
    // value() is what catches convertToDimensionWithUnit's merge rule. The number text and
    // the unit text are joined into one view only when mergeIfAdjacent finds them
    // physically adjacent (`std::to_address(a.end()) == std::to_address(b.begin())`) and
    // the number is shorter than 16 characters, so `10px` from the input has value()
    // "10px", while `1\70x` -- the same unit written with an escape, which makes the unit
    // text a pooled String rather than a range of the input -- has value() "px". Which of
    // those happened is a property of where the island put the value, is invisible to the
    // numeric fields, and decides how a custom property reserializes.
    //
    // m_nonUnitPrefixLength has no accessor and does not need one: unitString() is
    // defined as value().substring(m_nonUnitPrefixLength), so with value() and
    // unitString() both equal the prefix length is equal too, being the difference of
    // their lengths. Comparing the two public views pins the private bit-field exactly,
    // which is why the check below adds no friend and no test-only getter.
    //
    // What remains uncompared is not specific to dimensions: StringView equality is
    // textual, so a value whose text matches but whose backing StringImpl chose the other
    // character width still compares equal, here and in operator== for every
    // value-carrying token.
    if (expected.type() == DimensionToken) {
        if (expected.unitType() != actual.unitType())
            return TokenDivergence { 7, static_cast<uint32_t>(expected.unitType()), static_cast<uint32_t>(actual.unitType()) };
        if (expected.value() != actual.value())
            return TokenDivergence { 8, expected.value().length(), actual.value().length() };
        // value() agreed, so this is exactly a m_nonUnitPrefixLength divergence.
        if (expected.unitString() != actual.unitString())
            return TokenDivergence { 9, expected.value().length() - expected.unitString().length(), actual.value().length() - actual.unitString().length() };
    }
    return std::nullopt;
}

// The integration gate: builds the whole CSSParserToken stream both ways, in one
// process, and compares the tokens themselves rather than the island's POD output.
// This is what has to hold before the Swift path could ever be turned on by
// default, because it is comparing what the rest of the CSS parser will actually
// see: values, numeric values, units, hash types and block types.
WEBCORE_EXPORT CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePaths(const char* text, size_t length)
{
    CSSTokenizerSwiftValidationResult result { -1, 0, 0, 0, 0, 0 };
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };

    // Both tokenizers stay alive for the comparison: each token's value is a view
    // into its own tokenizer's input or string pool.
    WebCore::CSSTokenizer cppTokenizer(source, CSSTokenizer::Scanner::Cpp);
    WebCore::CSSTokenizer swiftTokenizer(source, CSSTokenizer::Scanner::Swift);

    auto cppRange = cppTokenizer.tokenRange();
    auto swiftRange = swiftTokenizer.tokenRange();
    result.realTokenCount = cppRange.size();
    result.swiftTokenCount = swiftRange.size();

    size_t index = 0;
    for (; !cppRange.atEnd() && !swiftRange.atEnd(); cppRange.consume(), swiftRange.consume(), ++index) {
        if (auto divergence = compareTokens(cppRange.peek(), swiftRange.peek())) {
            result.divergenceIndex = static_cast<int64_t>(index);
            result.expectedType = divergence->expected;
            result.actualType = divergence->actual;
            result.reason = divergence->reason;
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

    WebCore::CSSTokenizer cppTokenizer(source, CSSTokenizer::Scanner::Cpp);
    WebCore::CSSTokenizer swiftTokenizer(source, CSSTokenizer::Scanner::Swift);

    auto cppRange = cppTokenizer.tokenRange();
    auto swiftRange = swiftTokenizer.tokenRange();
    result.realTokenCount = cppRange.size();
    result.swiftTokenCount = swiftRange.size();
    result.expectedType = source.is8Bit() ? 8 : 16;

    size_t index = 0;
    for (; !cppRange.atEnd() && !swiftRange.atEnd(); cppRange.consume(), swiftRange.consume(), ++index) {
        if (auto divergence = compareTokens(cppRange.peek(), swiftRange.peek())) {
            result.divergenceIndex = static_cast<int64_t>(index);
            // expectedType stays the character width the caller asserts on, so only the
            // actual value is reported here.
            result.actualType = divergence->actual;
            result.reason = divergence->reason;
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

    WebCore::CSSTokenizer cppTokenizer(source, cppWrapper.get(), CSSTokenizer::Scanner::Cpp);
    WebCore::CSSTokenizer swiftTokenizer(source, swiftWrapper.get(), CSSTokenizer::Scanner::Swift);

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

WEBCORE_EXPORT unsigned webCoreCSSTokenizerSwiftDeclineCount(void)
{
    return CSSTokenizer::swiftIslandDeclineCountForTesting();
}

// Makes the Swift scanner fail every input, after it has built a chunk, so the
// failure-reporting path is reachable from a test. See
// CSSTokenizer::setForceSwiftIslandDeclineForTesting.
WEBCORE_EXPORT void webCoreCSSTokenizerSetForceSwiftIslandDecline(bool force)
{
    CSSTokenizer::setForceSwiftIslandDeclineForTesting(force);
}

// Whether tryCreate succeeded. There is no fallback: when the island cannot allocate,
// construction fails, and this is how a test observes that rather than inferring it.
WEBCORE_EXPORT bool webCoreCSSTokenizerTryCreateSucceeds(const char* text, size_t length)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    return !!CSSTokenizer::tryCreate(source);
}

// Reports the compile-time choice, so a test can confirm that
// -DUSE_SWIFT_CSS_TOKENIZER=1 actually selects the Swift scanner rather than being
// silently ignored.
WEBCORE_EXPORT bool webCoreCSSTokenizerDefaultScannerIsSwift(void)
{
    return CSSTokenizer::defaultScanner == CSSTokenizer::Scanner::Swift;
}

// Times a whole CSSTokenizer construction on one path or the other. Same work on
// both sides at last: same tokens, same string pool, same double conversions.
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated(const char* text, size_t length, bool useSwift, size_t* outTokens, uint64_t* outFold)
{
    String source { unsafeMakeSpan(byteCast<Latin1Character>(text), length) };
    WebCore::CSSTokenizer tokenizer(source, useSwift ? CSSTokenizer::Scanner::Swift : CSSTokenizer::Scanner::Cpp);
    size_t count = 0;
    uint64_t fold = 0;
    for (auto range = tokenizer.tokenRange(); !range.atEnd(); range.consume()) {
        ++count;
        fold = fold * 1000003 + static_cast<uint64_t>(range.peek().type());
    }
    *outTokens = count;
    *outFold = fold;
}

// The same timing at 16-bit width. Every other bench entry builds its String from Latin-1
// bytes, so all three were 8-bit-only and the island's UInt16 specialization -- a separate
// body of generated code, reached by every stylesheet containing a character above U+00FF
// -- had never been timed at all, only checked for correctness.
//
// The source is upconverted rather than decoded: each input byte becomes one UTF-16 code
// unit, so the token stream is identical to the 8-bit entry's on the same input and the two
// widths are directly comparable on one corpus. Decoding UTF-8 instead would change the
// characters and therefore the tokens, which is right for a correctness oracle
// (comparePathsUTF8 does exactly that) and wrong for a throughput comparison.
// `outIs16Bit` reports what StringImpl actually chose, so a caller cannot assume a width it
// did not get -- a 16-bit measurement that quietly ran 8-bit would be the same invisible
// failure as a decline.
WEBCORE_EXPORT void webCoreCSSTokenizerBenchIntegrated16(const char* text, size_t length, bool useSwift, size_t* outTokens, uint64_t* outFold, bool* outIs16Bit)
{
    auto bytes = unsafeMakeSpan(byteCast<Latin1Character>(text), length);
    StringBuilder builder;
    builder.reserveCapacity(length + 4);
    for (auto byte : bytes)
        builder.append(static_cast<char16_t>(byte));
    // A run of pure Latin-1 would collapse back to 8-bit on toString(), so force the
    // 16-bit representation with a character that cannot be represented in 8 bits, in a
    // comment where it costs one token and no interned string. Appended as an explicit
    // char16_t rather than in a literal: a non-ASCII character in a WebKit string literal
    // breaks assertions builds.
    builder.append("/*"_s);
    builder.append(static_cast<char16_t>(0x2028));
    builder.append("*/"_s);
    String source = builder.toString();

    WebCore::CSSTokenizer tokenizer(source, useSwift ? CSSTokenizer::Scanner::Swift : CSSTokenizer::Scanner::Cpp);
    size_t count = 0;
    uint64_t fold = 0;
    for (auto range = tokenizer.tokenRange(); !range.atEnd(); range.consume()) {
        ++count;
        fold = fold * 1000003 + static_cast<uint64_t>(range.peek().type());
    }
    *outTokens = count;
    *outFold = fold;
    *outIs16Bit = !source.is8Bit();
}

} // extern "C"

#endif // ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
