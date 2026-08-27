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

// Tests for the Swift CSS tokenizer island
// (Source/WebCore/css/parser/CSSTokenizerSwift.swift), notes §11.
//
// Every test builds the whole CSSParserToken stream twice from the same source —
// once with the C++ scanner and once with the Swift one — and compares the tokens
// themselves: value text, numeric values, units, hash types, block types, counts.
//
// Two things make this a real comparison rather than a tautology:
//
//  * `EXPECT_NO_DECLINES` — the Swift path falls back to the C++ path for any input
//    it cannot handle, so a comparison passes trivially if it declined and both
//    sides ran C++. The tokenizer counts declines and every test asserts the count
//    did not move.
//  * the UTF-8 tests assert which of StringImpl's representations was exercised, so
//    a case meant to test the 16-bit specialization cannot pass by staying 8-bit.

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

CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePaths(const char*, size_t);
CSSTokenizerSwiftValidationResult webCoreCSSTokenizerComparePathsUTF8(const char*, size_t);
CSSTokenizerSwiftValidationResult webCoreCSSTokenizerCompareObserverOffsets(const char*, size_t);
unsigned webCoreCSSTokenizerSwiftDeclineCount(void);

} // extern "C"

namespace TestWebKitAPI {

static const char* divergenceReason(uint32_t reason)
{
    switch (reason) {
    case 0: return "the tokens differ";
    case 1: return "the block types differ";
    case 2: return "the token counts differ";
    case 3: return "the observer's token offsets differ";
    case 4: return "the observer's end offset differs";
    case 6: return "the source was not valid UTF-8";
    default: return "unknown";
    }
}

#define EXPECT_PATHS_AGREE(css) do { \
    auto utf8 = String { css }.utf8(); \
    unsigned declinesBefore = webCoreCSSTokenizerSwiftDeclineCount(); \
    auto result = webCoreCSSTokenizerComparePaths(utf8.data(), utf8.length()); \
    EXPECT_EQ(-1, result.divergenceIndex) \
        << "diverged at token " << result.divergenceIndex << ": " << divergenceReason(result.reason) \
        << " (C++ " << result.expectedType << " vs Swift " << result.actualType << "), " \
        << result.realTokenCount << " tokens vs " << result.swiftTokenCount; \
    EXPECT_EQ(declinesBefore, webCoreCSSTokenizerSwiftDeclineCount()) \
        << "the Swift path declined this input and fell back to C++, so the comparison proved nothing"; \
} while (0)

#define EXPECT_PATHS_AGREE_UTF8(css, expectedWidth) do { \
    unsigned declinesBefore = webCoreCSSTokenizerSwiftDeclineCount(); \
    auto result = webCoreCSSTokenizerComparePathsUTF8(css, strlen(css)); \
    EXPECT_EQ(-1, result.divergenceIndex) \
        << "diverged at token " << result.divergenceIndex << ": " << divergenceReason(result.reason); \
    EXPECT_EQ(static_cast<uint32_t>(expectedWidth), result.expectedType) \
        << "expected StringImpl to choose " << expectedWidth << "-bit for this source"; \
    EXPECT_EQ(declinesBefore, webCoreCSSTokenizerSwiftDeclineCount()) \
        << "the Swift path declined this input and fell back to C++"; \
} while (0)

#define EXPECT_OBSERVER_OFFSETS_AGREE(css) do { \
    auto utf8 = String { css }.utf8(); \
    unsigned declinesBefore = webCoreCSSTokenizerSwiftDeclineCount(); \
    auto result = webCoreCSSTokenizerCompareObserverOffsets(utf8.data(), utf8.length()); \
    EXPECT_EQ(-1, result.divergenceIndex) \
        << "diverged at token " << result.divergenceIndex << ": " << divergenceReason(result.reason) \
        << " (C++ " << result.expectedType << " vs Swift " << result.actualType << ")"; \
    EXPECT_EQ(declinesBefore, webCoreCSSTokenizerSwiftDeclineCount()) \
        << "the Swift path declined this input and fell back to C++"; \
} while (0)

TEST(CSSTokenizerSwift, Rules)
{
    EXPECT_PATHS_AGREE("a { color: red }"_s);
    EXPECT_PATHS_AGREE(".cls > #id ~ [attr=\"v\"] + :hover { margin: 0 auto }"_s);
    EXPECT_PATHS_AGREE("@media (min-width: 100px) and (max-width: 50em) { .a { top: -1.5e-3px } }"_s);
    EXPECT_PATHS_AGREE(".a { .b { color: blue } &:hover { color: green } }"_s);
    EXPECT_PATHS_AGREE("a { --custom: var(--other, calc(100% - 12px)); color: var(--custom) }"_s);
}

TEST(CSSTokenizerSwift, Numbers)
{
    EXPECT_PATHS_AGREE("n { a: 1 23 4.56 -7.8e-9 +0.5 .25 1e3 1E+3 10px 50% 0 5e3px 1e 1.e3 }"_s);
    EXPECT_PATHS_AGREE("n { a: 00000000000000000001px 1.00000000000000000001px }"_s);
}

TEST(CSSTokenizerSwift, StringsAndUrls)
{
    EXPECT_PATHS_AGREE("a { content: \"double\" 'single' \"\" }"_s);
    EXPECT_PATHS_AGREE("a { background: url(plain.png) url(\"quoted.png\") url( spaced.png ) }"_s);
    EXPECT_PATHS_AGREE("a { background: url(ab\"cd) }"_s);
    EXPECT_PATHS_AGREE("a { content: \"unterminated\n }"_s);
}

TEST(CSSTokenizerSwift, Escapes)
{
    EXPECT_PATHS_AGREE("\\41 BC { color: red }"_s);
    EXPECT_PATHS_AGREE("a { background: \\75 rl(x.png) }"_s);
    EXPECT_PATHS_AGREE("a { color: #\\41 41 41 }"_s);
    EXPECT_PATHS_AGREE("a\\0 b\\110000 c\\d800 d\\ffff { top: 0 }"_s);
    EXPECT_PATHS_AGREE("a { content: \"line\\\ncontinued\" }"_s);
    EXPECT_PATHS_AGREE("a { content: \"\\1F3A8\" }"_s);
    EXPECT_PATHS_AGREE("a { background: url(\\1F3A8 .png) }"_s);
}

// The unescape buffer starts small and grows; these cross that boundary.
TEST(CSSTokenizerSwift, ManyEscapes)
{
    StringBuilder oneLongValue;
    oneLongValue.append("a { content: \""_s);
    for (unsigned i = 0; i < 400; ++i)
        oneLongValue.append("\\41 "_s);
    oneLongValue.append("\" }"_s);
    EXPECT_PATHS_AGREE(oneLongValue.toString());

    StringBuilder manyValues;
    manyValues.append("a {"_s);
    for (unsigned i = 0; i < 300; ++i)
        manyValues.append(" content: \"\\41 \\42 \";"_s);
    manyValues.append(" }"_s);
    EXPECT_PATHS_AGREE(manyValues.toString());
}

TEST(CSSTokenizerSwift, CommentsAndCDO)
{
    EXPECT_PATHS_AGREE("a /* c1 */ { /* c2 */ color: red } /* unterminated"_s);
    EXPECT_PATHS_AGREE("<!-- a { color: red } -->"_s);
    EXPECT_PATHS_AGREE("/**/ /* normal */ <!-- --> <!-x -"_s);
}

TEST(CSSTokenizerSwift, DelimitersAndMatches)
{
    EXPECT_PATHS_AGREE("a[x~=\"1\"][y|=\"2\"][z^=\"3\"][w$=\"4\"][v*=\"5\"] { top: 0 }"_s);
    EXPECT_PATHS_AGREE("a || b { top: 0 }"_s);
    EXPECT_PATHS_AGREE("a { top: ! & = > ? ` % }"_s);
    EXPECT_PATHS_AGREE("U+0-7F u+26 U\\+0"_s);
}

// The island's block stack is the caller's buffer and grows; these cross that
// boundary several times.
TEST(CSSTokenizerSwift, BlockNesting)
{
    EXPECT_PATHS_AGREE("a { b: ( c [ d "_s);
    EXPECT_PATHS_AGREE("a } ) ] { top: 0 }"_s);
    for (unsigned depth : { 40u, 200u, 1000u, 5000u }) {
        StringBuilder builder;
        builder.append("a { b: "_s);
        for (unsigned i = 0; i < depth; ++i)
            builder.append('(');
        builder.append('1');
        for (unsigned i = 0; i < depth; ++i)
            builder.append(')');
        builder.append(" }"_s);
        EXPECT_PATHS_AGREE(builder.toString());
    }
    StringBuilder unclosed;
    unclosed.append("a { b: "_s);
    for (unsigned i = 0; i < 5000; ++i)
        unclosed.append('(');
    EXPECT_PATHS_AGREE(unclosed.toString());
}

TEST(CSSTokenizerSwift, EndOfInput)
{
    for (auto* fragment : { "", " ", "   \t\n  ", "#", "@", "\"", "url(", "/*", "-", "+", "<", "\\", "1e", "u+" })
        EXPECT_PATHS_AGREE(String::fromUTF8(fragment));
}

TEST(CSSTokenizerSwift, SixteenBitInput)
{
    EXPECT_PATHS_AGREE_UTF8("a { color: red }", 8);
    EXPECT_PATHS_AGREE_UTF8(".\xe6\xa0\xb9 > #\xe8\xa6\x81\xe7\xb4\xa0 { color: red }", 16);
    EXPECT_PATHS_AGREE_UTF8(".caf\xc3\xa9 { font-family: \xc3\x89l\xc3\xa9gant }", 16);
    EXPECT_PATHS_AGREE_UTF8("a { content: \"\xe3\x81\x93\xe3\x82\x93\xe3\x81\xab\xe3\x81\xa1\xe3\x81\xaf\" }", 16);
    EXPECT_PATHS_AGREE_UTF8("a { background: url(\xe7\x94\xbb\xe5\x83\x8f.png) }", 16);
    EXPECT_PATHS_AGREE_UTF8("a { content: \"\xf0\x9f\x8e\xa8\" }", 16);
    EXPECT_PATHS_AGREE_UTF8(".\xf0\x9f\x8e\xa8x { top: 0 }", 16);
    EXPECT_PATHS_AGREE_UTF8(".\xe6\xa0\xb9\\41 BC { color: \\72 ed }", 16);
    EXPECT_PATHS_AGREE_UTF8(".\xe6\xa0\xb9 { width: calc(100% - 1.5e-3px) }", 16);
    EXPECT_PATHS_AGREE_UTF8("/* \xe6\xa0\xb9 */ a { top: 0 } /* \xf0\x9f\x8e\xa8", 16);
    EXPECT_PATHS_AGREE_UTF8("a\xc2\xa0" "b { top: 0 }", 16);
    EXPECT_PATHS_AGREE_UTF8("a { top: 0 }\xe2\x80\xa8" "b { top: 1 }", 16);
}

TEST(CSSTokenizerSwift, ObserverOffsets)
{
    EXPECT_OBSERVER_OFFSETS_AGREE("a { color: red }"_s);
    EXPECT_OBSERVER_OFFSETS_AGREE("a /* c1 */ { /* c2 */ color: red } /* trailing */"_s);
    EXPECT_OBSERVER_OFFSETS_AGREE("a { color: red } /* unterminated"_s);
    EXPECT_OBSERVER_OFFSETS_AGREE("/* lead */ a { color: red }"_s);
    EXPECT_OBSERVER_OFFSETS_AGREE("/* just a comment */"_s);
    EXPECT_OBSERVER_OFFSETS_AGREE("\\41 BC { color: \\72 ed }"_s);
    EXPECT_OBSERVER_OFFSETS_AGREE("@media (min-width: 1px) { /* c */ a { top: 0 } }"_s);
}

// A realistic body of CSS, mixing the constructs a stylesheet actually contains
// rather than exercising one at a time.
TEST(CSSTokenizerSwift, SyntheticStylesheet)
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
    auto stylesheet = builder.toString();
    EXPECT_PATHS_AGREE(stylesheet);
    EXPECT_OBSERVER_OFFSETS_AGREE(stylesheet);
}

} // namespace TestWebKitAPI
