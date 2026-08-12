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

// Validation and benchmark for the Swift CSS tokenizer island
// (Source/WebCore/css/parser/CSSTokenizerSwift.swift), notes §11.
//
// The validation compares the island against the *real* CSSTokenizer, token by
// token. The standalone probe in ~/src/webkit-swift-ports/cssprobe only shows
// that two of my own ports agree, which a symmetric misreading of the syntax
// spec would also satisfy; this is the test that rules that out.

#include "config.h"

#include "Test.h"
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

extern "C" {

struct CSSTokenizerSwiftValidationResult {
    int64_t divergenceIndex;
    uint32_t expectedType;
    uint32_t actualType;
    uint64_t realTokenCount;
    uint64_t swiftTokenCount;
    uint32_t reason;
};

CSSTokenizerSwiftValidationResult webCoreCSSTokenizerSwiftValidate(const char*, size_t);
void webCoreCSSTokenizerBenchSwift(const uint8_t*, size_t, size_t*, uint64_t*);
void webCoreCSSTokenizerBenchReal(const char*, size_t, size_t*, uint64_t*);

} // extern "C"

namespace TestWebKitAPI {

static void expectAgreement(const char* label, const String& css)
{
    auto utf8 = css.utf8();
    auto result = webCoreCSSTokenizerSwiftValidate(utf8.data(), utf8.length());
    EXPECT_EQ(result.divergenceIndex, -1)
        << label << ": diverged at token " << result.divergenceIndex
        << " (reason " << result.reason << ", real type " << result.expectedType
        << " vs swift type " << result.actualType << "), real tokens "
        << result.realTokenCount << " vs swift " << result.swiftTokenCount;
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerOnSimpleRules)
{
    expectAgreement("simple", "a { color: red }"_s);
    expectAgreement("selectors", ".cls > #id ~ [attr=\"v\"] + :hover { margin: 0 auto }"_s);
    expectAgreement("atrule", "@media (min-width: 100px) and (max-width: 50em) { .a { top: -1.5e-3px } }"_s);
    expectAgreement("nesting", ".a { .b { color: blue } &:hover { color: green } }"_s);
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerOnNumbers)
{
    expectAgreement("numbers", "n { a: 1 23 4.56 -7.8e-9 +0.5 .25 1e3 1E+3 10px 50% 0 5e3px 1e 1.e3 }"_s);
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerOnStringsAndUrls)
{
    expectAgreement("strings", "a { content: \"double\" 'single' \"\" }"_s);
    expectAgreement("urls", "a { background: url(plain.png) url(\"quoted.png\") url( spaced.png ) }"_s);
    expectAgreement("badurl", "a { background: url(ab\"cd) }"_s);
    expectAgreement("badstring", "a { content: \"unterminated\n }"_s);
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerOnEscapes)
{
    // Value text is not compared for escaped values (the island reports the raw
    // range and leaves unescaping to C++), but the token *types*, extents and
    // block structure are, which is where an escape-handling bug would show.
    expectAgreement("escaped ident", "\\41 BC { color: red }"_s);
    expectAgreement("escaped url", "a { background: \\75 rl(x.png) }"_s);
    expectAgreement("escaped hash", "a { color: #\\41 41 41 }"_s);
    expectAgreement("hex bounds", "a\\0 b\\110000 c\\d800 d\\ffff { top: 0 }"_s);
    expectAgreement("continuation", "a { content: \"line\\\ncontinued\" }"_s);
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerOnCommentsAndCDO)
{
    expectAgreement("comments", "a /* c1 */ { /* c2 */ color: red } /* unterminated"_s);
    expectAgreement("cdo", "<!-- a { color: red } -->"_s);
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerOnDelimitersAndMatches)
{
    expectAgreement("matches", "a[x~=\"1\"][y|=\"2\"][z^=\"3\"][w$=\"4\"][v*=\"5\"] { top: 0 }"_s);
    expectAgreement("column", "a || b { top: 0 }"_s);
    expectAgreement("delims", "a { top: ! & = > ? ` % }"_s);
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerOnUnbalancedBlocks)
{
    expectAgreement("unclosed", "a { b: ( c [ d "_s);
    expectAgreement("extra closers", "a } ) ] { top: 0 }"_s);
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerAtEndOfInput)
{
    for (auto* fragment : { "#", "@", "\"", "url(", "/*", "-", "+", "<", "\\", "1e", "u+" })
        expectAgreement(fragment, String::fromUTF8(fragment));
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerOnLatin1)
{
    expectAgreement("latin1", "\xE9\xFF { color: \xE9 }"_s);
}

TEST(CSSTokenizerSwift, MatchesRealTokenizerOnCustomProperties)
{
    expectAgreement("custom", "a { --custom: var(--other, calc(100% - 12px)); color: var(--custom) }"_s);
}

// A larger, more realistic body of CSS, built to exercise the same mix a real
// stylesheet does rather than one construct at a time.
TEST(CSSTokenizerSwift, MatchesRealTokenizerOnSyntheticStylesheet)
{
    StringBuilder builder;
    for (unsigned i = 0; i < 200; ++i) {
        builder.append(
            ".cls-"_s, i, " > #id-"_s, i, ":hover::before { "_s,
            "color: #a0b1c2; background: url(img-"_s, i, ".png) no-repeat; "_s,
            "margin: 0 auto -1.5px 2em; width: calc(100% - "_s, i, "px); "_s,
            "content: \"item "_s, i, "\"; transition: all .25s ease-in-out "_s, i, "ms; "_s,
            "}\n"_s);
        if (!(i % 7))
            builder.append("@media (min-width: "_s, i * 10, "px) { .r-"_s, i, " { top: 0 } }\n"_s);
        if (!(i % 11))
            builder.append("/* comment "_s, i, " */\n"_s);
    }
    expectAgreement("synthetic stylesheet", builder.toString());
}

TEST(CSSTokenizerSwift, DISABLED_Benchmark)
{
    StringBuilder builder;
    for (unsigned i = 0; i < 20000; ++i) {
        builder.append(
            ".cls-"_s, i, " > #id-"_s, i, ":hover { color: #a0b1c2; "_s,
            "margin: 0 auto -1.5px 2em; width: calc(100% - "_s, i, "px); "_s,
            "content: \"item "_s, i, "\"; }\n"_s);
    }
    auto css = builder.toString().utf8();

    size_t tokens = 0;
    uint64_t fold = 0;
    const int iterations = 15;

    Vector<double> swiftSamples;
    for (int i = 0; i < iterations; ++i) {
        MonotonicTime start = MonotonicTime::now();
        webCoreCSSTokenizerBenchSwift(byteCast<uint8_t>(css.data()), css.length(), &tokens, &fold);
        swiftSamples.append((MonotonicTime::now() - start).milliseconds());
    }
    Vector<double> realSamples;
    for (int i = 0; i < iterations; ++i) {
        MonotonicTime start = MonotonicTime::now();
        webCoreCSSTokenizerBenchReal(css.data(), css.length(), &tokens, &fold);
        realSamples.append((MonotonicTime::now() - start).milliseconds());
    }

    std::sort(swiftSamples.begin(), swiftSamples.end());
    std::sort(realSamples.begin(), realSamples.end());
    double swiftMedian = swiftSamples[swiftSamples.size() / 2];
    double realMedian = realSamples[realSamples.size() / 2];
    auto mbps = [&](double ms) { return (css.length() / (ms / 1000)) / (1024 * 1024); };
    WTFLogAlways("CSS tokenizer: swift %.2f ms (%.1f MB/s), real CSSTokenizer %.2f ms (%.1f MB/s) over %zu bytes",
        swiftMedian, mbps(swiftMedian), realMedian, mbps(realMedian), css.length());
}

} // namespace TestWebKitAPI
