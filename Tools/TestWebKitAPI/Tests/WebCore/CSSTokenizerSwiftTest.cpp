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
//  * there is no fallback. The Swift scanner finishes every input, and if it cannot
//    allocate it fails construction rather than handing the work back to C++ — so a
//    comparison can no longer pass because the island quietly stepped aside. That used to
//    need a decline counter to catch; it is now structural, and
//    IslandFailureFailsConstructionRatherThanFallingBack is what keeps it that way. The
//    counter is still asserted as a cheap second check.
//  * the UTF-8 tests assert which of StringImpl's representations was exercised, so
//    a case meant to test the 16-bit specialization cannot pass by staying 8-bit.

#include "config.h"

// These link against the bridge's extern "C" entries, so they compile only when it does.
#if ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)

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
void webCoreCSSTokenizerSetForceSwiftIslandDecline(bool);
bool webCoreCSSTokenizerTryCreateSucceeds(const char*, size_t);
bool webCoreCSSTokenizerDefaultScannerIsSwift(void);

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
    case 5: return "the numeric value, its type or its sign differs";
    case 6: return "the source was not valid UTF-8";
    case 7: return "the dimension's unit type differs";
    case 8: return "the dimension's value text differs (expected/actual are its lengths)";
    case 9: return "the dimension's non-unit prefix length differs";
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

// Raw bytes, handed to the 8-bit entry with no String round-trip. EXPECT_PATHS_AGREE
// goes through utf8(), which turns a high Latin-1 character into the two bytes of its
// UTF-8 encoding; this keeps it as the one character it is. sizeof - 1 rather than
// strlen so a case can contain an embedded NUL, which is what preprocessing replaces.
#define EXPECT_PATHS_AGREE_LATIN1(bytes) do { \
    unsigned declinesBefore = webCoreCSSTokenizerSwiftDeclineCount(); \
    auto result = webCoreCSSTokenizerComparePaths(bytes, sizeof(bytes) - 1); \
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

// A DimensionToken carries three things beyond its number: a unit type, a value view
// whose extent depends on whether convertToDimensionWithUnit could merge the number and
// the unit into one view, and the non-unit prefix length that records the merge.
// CSSParserToken::operator== compares the unit only when its own prefix length is zero;
// with a prefix it compares originalText() and stops, so before compareTokens grew its
// dimension checks a wrong unit or a wrong prefix on a merged token compared equal.
// These cases sit on both sides of the merge.
TEST(CSSTokenizerSwift, Dimensions)
{
    // Number and unit adjacent in the input, so mergeIfAdjacent joins them: value() is
    // "10px" and the non-unit prefix length is 2.
    EXPECT_PATHS_AGREE("n { a: 10px }"_s);
    // The same token with the unit written through an escape -- `\70` is 'p'. An
    // unescaped value lives in the tokenizer's string pool rather than in the input, so
    // the addresses are not adjacent, the merge cannot fire, value() is just "px" and the
    // prefix length is 0. Same unit type, different value view: exactly the pair the
    // oracle could not distinguish.
    EXPECT_PATHS_AGREE("n { a: 1\\70x }"_s);
    // The merge is capped at a 16-character number, so 15 digits merge (a prefix length of
    // 15, the largest the 4-bit field holds) and 16 do not.
    EXPECT_PATHS_AGREE("n { a: 123456789012345px 1234567890123456px }"_s);
    EXPECT_PATHS_AGREE("n { a: 1e3px 0px -1.5E-3em +2.5Q .5s 0.0e0ms }"_s);
    // Unit matching is case-insensitive (cssPrimitiveValueUnitFromTrie lowercases as it
    // walks), so these are all CSSUnitType::Px while their unit text differs -- unitType()
    // alone would not tell them apart.
    EXPECT_PATHS_AGREE("n { a: 10PX 10Px 10pX }"_s);
    // Not a CSS unit at all: unitType() is CSSUnitType::Unknown on both paths, so the unit
    // text is the only thing separating one unknown dimension from another. The second
    // reaches an unknown unit through an escape (`\7a` is 'z').
    EXPECT_PATHS_AGREE("n { a: 10zz 10q\\7a }"_s);
    // The unit is an ident, so it may begin with a dash and may carry escapes anywhere.
    EXPECT_PATHS_AGREE("n { a: 5-px 5\\-px 5p\\78 }"_s);
    // The same merge decision at 16-bit width, where mergeIfAdjacent takes its span16
    // branch.
    EXPECT_PATHS_AGREE_UTF8(".\xe6\xa0\xb9 { a: 10px 1\\70x 10zz }", 16);
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

// 8-bit non-ASCII. Every high byte is a name-start code point, and this is the width
// real stylesheets actually use, so it is the figure of merit -- but it was covered only
// out of tree, because every case in this file was either pure ASCII or went through the
// UTF-8 entry, which forces 16-bit and asserts that it did.
TEST(CSSTokenizerSwift, Latin1NonASCII)
{
    EXPECT_PATHS_AGREE_LATIN1("\xe9\xff { color: \xe9 }");
    EXPECT_PATHS_AGREE_LATIN1(".caf\xe9 { font-family: \xc9l\xe9gant }");
    EXPECT_PATHS_AGREE_LATIN1("@m\xe9""dia { .\x80\x81\x82 { top: 0 } }");
    EXPECT_PATHS_AGREE_LATIN1("a { content: \"\xe9\xff\x80\" ; background: url(\xe9.png) }");
    EXPECT_PATHS_AGREE_LATIN1("\xff""8 { a: 1\xe9 2\xff""px }");
    EXPECT_PATHS_AGREE_LATIN1("a { b: \\e9 \xe9 \\0000e9 }");
    // Preprocessing replaces a NUL with U+FFFD, which forces the string to 16 bits, so
    // this case leaves the 8-bit path -- which is exactly what makes it worth having:
    // it is the one input where the width the caller chose is not the width that runs.
    EXPECT_PATHS_AGREE_LATIN1("a { color: re\0d }");
    EXPECT_PATHS_AGREE_LATIN1("\0");
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

// There is no fallback, and this is the test that holds that line.
//
// The Swift scanner finishes every input; the only way it stops is a failed allocation of
// m_tokens. The C++ scanner reserves the same size into the same vector, so it would fail on
// the identical allocation -- which is why falling back to it was deleted rather than fixed.
// What replaced it is the report the C++ path already made for itself: tryCreate returns null.
//
// Forcing the failure is the only way to reach that, since a test cannot provoke OOM. If this
// ever fails by *succeeding*, something has reintroduced a second path.
TEST(CSSTokenizerSwift, IslandFailureFailsConstructionRatherThanFallingBack)
{
    auto css = "a { color: red } .b > #c:hover { margin: 0 auto -1.5px }"_s;
    auto tryCreate = [&] { return webCoreCSSTokenizerTryCreateSucceeds(css.characters(), css.length()); };

    EXPECT_TRUE(tryCreate()) << "the island should handle this input";

    unsigned failuresBefore = webCoreCSSTokenizerSwiftDeclineCount();
    webCoreCSSTokenizerSetForceSwiftIslandDecline(true);
    bool succeeded = tryCreate();
    unsigned failuresAfter = webCoreCSSTokenizerSwiftDeclineCount();
    webCoreCSSTokenizerSetForceSwiftIslandDecline(false);

    // Only meaningful when the island is the scanner tryCreate actually uses. With the C++
    // default the forcing flag is never read, and asserting failure would fail for the wrong
    // reason.
    if (webCoreCSSTokenizerDefaultScannerIsSwift()) {
        EXPECT_LT(failuresBefore, failuresAfter) << "the forced failure did not happen";
        EXPECT_FALSE(succeeded)
            << "the island failed but construction succeeded anyway, so something other than "
               "the island produced the token stream -- a fallback has come back";
    }

    EXPECT_TRUE(tryCreate()) << "forcing should not be sticky";
}

} // namespace TestWebKitAPI

#endif // ENABLE(CSS_TOKENIZER_SWIFT_BRIDGE)
