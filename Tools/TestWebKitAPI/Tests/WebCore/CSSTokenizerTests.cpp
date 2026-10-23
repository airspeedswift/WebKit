/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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

#include "config.h"

#include <WebCore/CSSParserToken.h>
#include <WebCore/CSSParserTokenRange.h>
#include <WebCore/CSSTokenizer.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

using namespace WebCore;

TEST(CSSTokenizerTest, TokenizeWhitespaceLikeInput)
{
    CSSTokenizer tokenizer("foo           \n\n\n bar"_s);
    auto tokenRange = tokenizer.tokenRange();
    auto tokenRangeSpan = tokenRange.span();

    ASSERT_EQ(tokenRangeSpan.size(), 7ul);
    EXPECT_EQ(CSSParserTokenType::IdentToken, tokenRangeSpan[0].type());
    EXPECT_EQ(CSSParserTokenType::NonNewlineWhitespaceToken, tokenRangeSpan[1].type());
    EXPECT_EQ(CSSParserTokenType::NewlineToken, tokenRangeSpan[2].type());
    EXPECT_EQ(CSSParserTokenType::NewlineToken, tokenRangeSpan[3].type());
    EXPECT_EQ(CSSParserTokenType::NewlineToken, tokenRangeSpan[4].type());
    EXPECT_EQ(CSSParserTokenType::NonNewlineWhitespaceToken, tokenRangeSpan[5].type());
    EXPECT_EQ(CSSParserTokenType::IdentToken, tokenRangeSpan[6].type());
}

TEST(CSSTokenizerTest, DimensionTokenEqualityIsSymmetric)
{
    CSSTokenizer plain("1px"_s);
    CSSTokenizer escaped("1\\70x"_s);
    auto plainRange = plain.tokenRange();
    auto escapedRange = escaped.tokenRange();
    auto plainSpan = plainRange.span();
    auto escapedSpan = escapedRange.span();

    ASSERT_EQ(1ul, plainSpan.size());
    ASSERT_EQ(1ul, escapedSpan.size());
    EXPECT_EQ(CSSParserTokenType::DimensionToken, plainSpan[0].type());
    EXPECT_EQ(CSSParserTokenType::DimensionToken, escapedSpan[0].type());
    EXPECT_EQ(plainSpan[0] == escapedSpan[0], escapedSpan[0] == plainSpan[0]);
    EXPECT_TRUE(plainSpan[0] == escapedSpan[0]);
}

TEST(CSSTokenizerTest, TokenizeIdentAndCommaInput)
{
    CSSTokenizer tokenizer("this, "_s);
    auto tokenRange = tokenizer.tokenRange();
    auto tokenRangeSpan = tokenRange.span();

    ASSERT_EQ((size_t)3, tokenRangeSpan.size());
    EXPECT_EQ(CSSParserTokenType::IdentToken, tokenRangeSpan[0].type());
    EXPECT_EQ(CSSParserTokenType::CommaToken, tokenRangeSpan[1].type());
    EXPECT_EQ(CSSParserTokenType::NonNewlineWhitespaceToken, tokenRangeSpan[2].type());
}

TEST(CSSTokenizerTest, TokenizeMultipleWhitespaceInput)
{
    CSSTokenizer tokenizer("          "_s);
    auto tokenRange = tokenizer.tokenRange();
    auto tokenRangeSpan = tokenRange.span();

    ASSERT_EQ((size_t)1, tokenRangeSpan.size());
    EXPECT_EQ(CSSParserTokenType::NonNewlineWhitespaceToken, tokenRangeSpan[0].type());
}

TEST(CSSTokenizerTest, TokenizeNewlineTokenOnlyInput)
{
    CSSTokenizer tokenizer("\n"_s);
    auto tokenRange = tokenizer.tokenRange();
    auto tokenRangeSpan = tokenRange.span();

    ASSERT_EQ((size_t)1, tokenRangeSpan.size());
    EXPECT_EQ(CSSParserTokenType::NewlineToken, tokenRangeSpan[0].type());
}

TEST(CSSTokenizerTest, TokenizeNewlineAndWhitespaceInput)
{
    CSSTokenizer tokenizer("\n "_s);
    auto tokenRange = tokenizer.tokenRange();
    auto tokenRangeSpan = tokenRange.span();

    ASSERT_EQ((size_t)2, tokenRangeSpan.size());
    EXPECT_EQ(CSSParserTokenType::NewlineToken, tokenRangeSpan[0].type());
    EXPECT_EQ(CSSParserTokenType::NonNewlineWhitespaceToken, tokenRangeSpan[1].type());
}

TEST(CSSTokenizerTest, TokenizeNewlineWhitespaceAndIdentInput)
{
    CSSTokenizer tokenizer("\n identifiervalue"_s);
    auto tokenRange = tokenizer.tokenRange();
    auto tokenRangeSpan = tokenRange.span();

    ASSERT_EQ((size_t)3, tokenRangeSpan.size());
    EXPECT_EQ(CSSParserTokenType::NewlineToken, tokenRangeSpan[0].type());
    EXPECT_EQ(CSSParserTokenType::NonNewlineWhitespaceToken, tokenRangeSpan[1].type());
    EXPECT_EQ(CSSParserTokenType::IdentToken, tokenRangeSpan[2].type());
}

TEST(CSSTokenizerTest, TokenizeURLWithProperInput)
{
    CSSTokenizer tokenizer("url(foo)"_s);
    auto tokenRange = tokenizer.tokenRange();
    auto tokenRangeSpan = tokenRange.span();

    ASSERT_EQ((size_t)1, tokenRangeSpan.size());
    EXPECT_EQ(CSSParserTokenType::UrlToken, tokenRangeSpan[0].type());
}

TEST(CSSTokenizerTest, TokenizeURLWithNewlineWhitespaceInput)
{
    CSSTokenizer tokenizer("url(\n   \n foo)"_s);
    auto tokenRange = tokenizer.tokenRange();
    auto tokenRangeSpan = tokenRange.span();

    ASSERT_EQ((size_t)1, tokenRangeSpan.size());
    EXPECT_EQ(CSSParserTokenType::UrlToken, tokenRangeSpan[0].type());
}

TEST(CSSTokenizerTest, TokenizeNestedBlocks)
{
    static constexpr std::array openers { '(', '[', '{' };
    static constexpr std::array closers { ')', ']', '}' };
    for (unsigned depth : { 7u, 8u, 9u, 16u, 17u, 31u, 32u, 33u, 64u, 65u }) {
        StringBuilder builder;
        for (unsigned i = 0; i < depth; ++i)
            builder.append(openers[i % 3]);
        // A closer that does not match the innermost block, then every block closed, then one closer too many.
        builder.append(closers[(depth + 1) % 3]);
        for (unsigned i = depth; i--;)
            builder.append(closers[i % 3]);
        builder.append(')');
        auto input = builder.toString();

        CSSTokenizer tokenizer(input);
        auto tokenRange = tokenizer.tokenRange();
        auto tokens = tokenRange.span();
        ASSERT_EQ(2 * depth + 2, tokens.size());
        for (unsigned i = 0; i < depth; ++i)
            EXPECT_EQ(CSSParserToken::BlockStart, tokens[i].getBlockType());
        EXPECT_EQ(CSSParserToken::NotBlock, tokens[depth].getBlockType());
        for (unsigned i = depth + 1; i <= 2 * depth; ++i)
            EXPECT_EQ(CSSParserToken::BlockEnd, tokens[i].getBlockType());
        EXPECT_EQ(CSSParserToken::NotBlock, tokens[2 * depth + 1].getBlockType());
    }
}

TEST(CSSTokenizerTest, TokenizeLongEscapedIdentifier)
{
    for (unsigned length : { 1u, 255u, 256u, 257u, 1000u }) {
        // "\61 " is an escaped 'a'.
        StringBuilder builder;
        builder.append("\\61 "_s);
        StringBuilder expected;
        expected.append('a');
        for (unsigned i = 1; i < length; ++i) {
            builder.append('a');
            expected.append('a');
        }
        builder.append(" b"_s);
        auto input = builder.toString();

        CSSTokenizer tokenizer(input);
        auto tokenRange = tokenizer.tokenRange();
        auto tokens = tokenRange.span();
        ASSERT_EQ(3u, tokens.size());
        EXPECT_EQ(CSSParserTokenType::IdentToken, tokens[0].type());
        EXPECT_EQ(expected.toString(), tokens[0].value().toString());
        EXPECT_TRUE(tokens[2].value() == "b"_s);
        auto pool = tokenizer.escapedStringsForAdoption();
        ASSERT_EQ(1u, pool.size());
        EXPECT_EQ(length, pool[0].length());
    }
}

TEST(CSSTokenizerTest, TokenizeCharactersAroundNameStarts)
{
    struct Case {
        char16_t first;
        CSSParserTokenType type;
        ASCIILiteral value;
    };
    // The characters at either end of the ASCII letters and of the underscore, each at the start of a token.
    static constexpr std::array cases {
        Case { '@', CSSParserTokenType::AtKeywordToken, "b"_s },
        Case { 'A', CSSParserTokenType::IdentToken, "Ab"_s },
        Case { 'Z', CSSParserTokenType::IdentToken, "Zb"_s },
        Case { '[', CSSParserTokenType::LeftBracketToken, nullptr },
        Case { '_', CSSParserTokenType::IdentToken, "_b"_s },
        Case { '`', CSSParserTokenType::DelimiterToken, nullptr },
        Case { 'a', CSSParserTokenType::IdentToken, "ab"_s },
        Case { 'z', CSSParserTokenType::IdentToken, "zb"_s },
        Case { '{', CSSParserTokenType::LeftBraceToken, nullptr },
        Case { 0x7F, CSSParserTokenType::DelimiterToken, nullptr },
    };
    for (bool is8Bit : { true, false }) {
        for (auto& testCase : cases) {
            std::array<char16_t, 4> characters { u' ', testCase.first, u'b', u' ' };
            auto input = is8Bit ? makeString(" "_s, static_cast<char>(testCase.first), "b "_s) : String(std::span<const char16_t> { characters });
            ASSERT_EQ(is8Bit, input.is8Bit());

            CSSTokenizer tokenizer(input);
            auto tokenRange = tokenizer.tokenRange();
            auto tokens = tokenRange.span();
            bool isName = !testCase.value.isNull();
            ASSERT_EQ(isName ? 3u : 4u, tokens.size());
            EXPECT_EQ(CSSParserTokenType::NonNewlineWhitespaceToken, tokens[0].type());
            EXPECT_EQ(testCase.type, tokens[1].type());
            if (isName)
                EXPECT_EQ(String(testCase.value), tokens[1].value().toString());
            else {
                if (testCase.type == CSSParserTokenType::DelimiterToken)
                    EXPECT_EQ(testCase.first, tokens[1].delimiter());
                EXPECT_EQ(CSSParserTokenType::IdentToken, tokens[2].type());
                EXPECT_EQ("b"_s, tokens[2].value().toString());
            }
            EXPECT_EQ(CSSParserTokenType::NonNewlineWhitespaceToken, tokens.back().type());
        }
    }
}

TEST(CSSTokenizerTest, TokenizeCommentEnds)
{
    auto tokenize = [](const String& input) {
        CSSTokenizer tokenizer(input);
        auto tokenRange = tokenizer.tokenRange();
        Vector<String> values;
        for (auto& token : tokenRange.span())
            values.append(token.value().toString());
        return values;
    };
    auto wide = [](std::span<const char16_t> characters) {
        auto string = String(characters);
        EXPECT_FALSE(string.is8Bit());
        return string;
    };
    // A comment end at each offset from the comment's start, from 0 to 17 code units before the end of the input.
    static constexpr std::array<char, 7> pattern { 'x', '*', 'y', '*', '*', 'z', '/' };
    for (bool is8Bit : { true, false }) {
        for (unsigned length = 0; length <= 40; ++length) {
            StringBuilder body;
            for (unsigned i = 0; i < length; ++i)
                body.append(pattern[i % pattern.size()]);
            if (!is8Bit)
                body.append(static_cast<char16_t>(0x2A2F));
            auto comment = body.toString();
            ASSERT_EQ(is8Bit, comment.is8Bit());
            for (unsigned after = 0; after <= 17; ++after) {
                StringBuilder input;
                input.append("/*"_s, comment, "**/"_s);
                for (unsigned i = 0; i < after; ++i)
                    input.append('b');
                auto values = tokenize(input.toString());
                ASSERT_EQ(after ? 1u : 0u, values.size());
                if (after)
                    EXPECT_EQ(after, values[0].length());
            }
            EXPECT_TRUE(tokenize(makeString("/*"_s, comment)).isEmpty());
            EXPECT_TRUE(tokenize(makeString("/*"_s, comment, "*"_s)).isEmpty());
        }
    }
    // In 16-bit input, '*' and '/' match only those code units, not U+012A, U+012F or U+2A2F.
    std::array<char16_t, 22> lookalikes { u'/', u'*', 0x012A, 0x012F, 0x2A2F, u'*', 0x012F, 0x012A, u'/' };
    for (unsigned i = 9; i < lookalikes.size(); ++i)
        lookalikes[i] = 0x2A2F;
    EXPECT_TRUE(tokenize(wide(lookalikes)).isEmpty());
    std::array<char16_t, 25> ended { };
    std::ranges::copy(lookalikes, ended.begin());
    ended[22] = u'*';
    ended[23] = u'/';
    ended[24] = u'b';
    auto values = tokenize(wide(ended));
    ASSERT_EQ(1u, values.size());
    EXPECT_EQ("b"_s, values[0]);
}

TEST(CSSTokenizerTest, TokenizeWhitespaceRuns)
{
    struct Token {
        CSSParserTokenType type;
        String text;
    };
    auto tokenize = [](const String& input) {
        CSSTokenizer tokenizer(input);
        auto tokenRange = tokenizer.tokenRange();
        Vector<Token> tokens;
        for (auto& token : tokenRange.span()) {
            StringBuilder builder;
            token.serialize(builder, nullptr, CSSParserToken::SerializationMode::CustomProperty);
            tokens.append({ token.type(), builder.toString() });
        }
        return tokens;
    };
    // Runs of spaces and tabs of each length, ending 0 to 17 code units before the end of the input. The whitespace
    // token keeps the run's length, which a custom property serializes. In 16-bit input U+0120 and U+0109 are not
    // a space or a tab.
    for (bool is8Bit : { true, false }) {
        for (unsigned length = 1; length <= 40; ++length) {
            StringBuilder run;
            for (unsigned i = 0; i < length; ++i)
                run.append(i % 3 == 2 ? '\t' : ' ');
            auto spaces = run.toString();
            for (unsigned after = 0; after <= 17; ++after) {
                StringBuilder input;
                input.append('a', spaces);
                if (is8Bit)
                    input.append('b');
                else
                    input.append(static_cast<char16_t>(after % 2 ? 0x0109 : 0x0120));
                for (unsigned i = 0; i < after; ++i)
                    input.append('c');
                auto string = input.toString();
                ASSERT_EQ(is8Bit, string.is8Bit());
                auto tokens = tokenize(string);
                ASSERT_EQ(3u, tokens.size());
                EXPECT_EQ(CSSParserTokenType::NonNewlineWhitespaceToken, tokens[1].type);
                EXPECT_EQ(length, tokens[1].text.length());
                EXPECT_EQ(CSSParserTokenType::IdentToken, tokens[2].type);
                EXPECT_EQ(after + 1, tokens[2].text.length());

                Vector<char16_t> newline;
                for (unsigned i = 0; i < length; ++i)
                    newline.append(spaces[i]);
                newline.append('\n');
                auto newlineString = is8Bit ? makeString(spaces, '\n') : String(newline.span());
                ASSERT_EQ(is8Bit, newlineString.is8Bit());
                auto newlineTokens = tokenize(newlineString);
                ASSERT_EQ(2u, newlineTokens.size());
                EXPECT_EQ(length, newlineTokens[0].text.length());
                EXPECT_EQ(CSSParserTokenType::NewlineToken, newlineTokens[1].type);
            }
        }
    }
}

TEST(CSSTokenizerTest, TokenizeIntegerValues)
{
    // Integers of 1 to 20 digits, leading zeros, signs, halfway cases above 2^53: values match charactersToDouble().
    struct Follower {
        ASCIILiteral text;
        CSSParserTokenType type;
        size_t tokenCount;
    };
    static constexpr std::array followers {
        Follower { ""_s, NumberToken, 1 }, Follower { "%"_s, PercentageToken, 1 }, Follower { "px"_s, DimensionToken, 1 },
        Follower { "e"_s, DimensionToken, 1 }, Follower { "."_s, NumberToken, 2 }, Follower { " "_s, NumberToken, 2 },
    };
    struct Sign {
        ASCIILiteral text;
        NumericSign sign;
    };
    static constexpr std::array signs { Sign { ""_s, NoSign }, Sign { "+"_s, PlusSign }, Sign { "-"_s, MinusSign } };
    static constexpr std::array largeIntegers {
        "9007199254740991"_s, "9007199254740992"_s, "9007199254740993"_s, "9007199254740994"_s,
        "9007199254740995"_s, "18014398509481985"_s, "18014398509481986"_s, "18014398509481987"_s,
        "18014398509481990"_s, "9223372036854775295"_s, "9223372036854775296"_s, "9223372036854775297"_s,
        "9223372036854775807"_s, "9223372036854775808"_s, "9223372036854776831"_s, "9223372036854776832"_s,
        "9223372036854776833"_s, "9223372036854778880"_s, "9999999999999996928"_s, "9999999999999998975"_s,
        "9999999999999998976"_s, "9999999999999998977"_s, "9999999999999999999"_s, "18446744073709551615"_s,
        "18446744073709551616"_s,
    };
    auto check = [&](bool is8Bit, const Sign& sign, const String& digits) {
        auto number = makeString(sign.text, digits);
        bool isOK = false;
        double value = charactersToDouble(number.span8(), &isOK);
        ASSERT_TRUE(isOK);
        for (auto& follower : followers) {
            auto narrow = makeString(number, follower.text);
            Vector<char16_t> wide;
            for (auto character : narrow.span8())
                wide.append(character);
            auto input = is8Bit ? narrow : String(wide.span());
            ASSERT_EQ(is8Bit, input.is8Bit());
            CSSTokenizer tokenizer(input);
            auto range = tokenizer.tokenRange();
            auto tokens = range.span();
            ASSERT_EQ(follower.tokenCount, tokens.size());
            auto& token = tokens[0];
            EXPECT_EQ(follower.type, token.type());
            EXPECT_EQ(IntegerValueType, token.numericValueType());
            EXPECT_EQ(sign.sign, token.numericSign());
            EXPECT_EQ(std::bit_cast<uint64_t>(value), std::bit_cast<uint64_t>(token.numericValue()));
            if (!value)
                EXPECT_EQ(sign.sign == MinusSign, std::signbit(token.numericValue()));
        }
    };
    for (bool is8Bit : { true, false }) {
        for (auto& sign : signs) {
            for (unsigned length = 1; length <= 20; ++length) {
                for (unsigned zeros = 0; zeros <= length; ++zeros) {
                    StringBuilder digits;
                    for (unsigned i = 0; i < length; ++i)
                        digits.append(static_cast<Latin1Character>(i < zeros ? '0' : '1' + (i * 7) % 9));
                    check(is8Bit, sign, digits.toString());
                }
            }
            for (auto integer : largeIntegers) {
                for (unsigned length : { 0u, 19u, 20u }) {
                    StringBuilder digits;
                    for (unsigned i = integer.length(); i < length; ++i)
                        digits.append('0');
                    digits.append(integer);
                    check(is8Bit, sign, digits.toString());
                }
            }
        }
    }
}

TEST(CSSTokenizerTest, TokenizeDecimalValues)
{
    // Fractions and exponents around 15 significant digits and scales of +-22: values match charactersToDouble().
    auto check = [](const String& narrow, const String& numberText, CSSParserTokenType type, size_t tokenCount) {
        bool isOK = false;
        double value = charactersToDouble(numberText.span8(), &isOK);
        ASSERT_TRUE(isOK);
        for (bool is8Bit : { true, false }) {
            Vector<char16_t> wide;
            for (auto character : narrow.span8())
                wide.append(character);
            auto input = is8Bit ? narrow : String(wide.span());
            ASSERT_EQ(is8Bit, input.is8Bit());
            CSSTokenizer tokenizer(input);
            auto range = tokenizer.tokenRange();
            auto tokens = range.span();
            ASSERT_EQ(tokenCount, tokens.size());
            auto& token = tokens[0];
            EXPECT_EQ(type, token.type());
            EXPECT_EQ(std::bit_cast<uint64_t>(value), std::bit_cast<uint64_t>(token.numericValue()));
        }
    };
    struct Follower {
        ASCIILiteral text;
        CSSParserTokenType type;
        size_t tokenCount;
    };
    static constexpr std::array followers {
        Follower { ""_s, NumberToken, 1 }, Follower { "%"_s, PercentageToken, 1 }, Follower { "px"_s, DimensionToken, 1 },
        Follower { " "_s, NumberToken, 2 },
    };
    for (auto sign : { ""_s, "+"_s, "-"_s }) {
        for (unsigned length : { 1, 14, 15, 16 }) {
            for (unsigned zeros : { 0, 1, 3 }) {
                StringBuilder digitsBuilder;
                for (unsigned i = 0; i < zeros + length; ++i)
                    digitsBuilder.append(static_cast<Latin1Character>(i < zeros ? '0' : '1' + (i * 7) % 9));
                auto digits = digitsBuilder.toString();
                unsigned digitCount = digits.length();
                Vector<int> points { -1, 0 };
                for (unsigned point : { 1u, digitCount - 1 }) {
                    if (point > 0 && point < digitCount && !points.contains(static_cast<int>(point)))
                        points.append(point);
                }
                for (int point : points) {
                    auto significand = point < 0 ? digits : makeString(digits.left(point), '.', digits.substring(point));
                    unsigned fractionLength = point < 0 ? 0 : digitCount - point;
                    Vector<String> numbers;
                    if (point >= 0)
                        numbers.append(significand);
                    for (int scale : { -23, -22, -21, -1, 0, 1, 21, 22, 23 }) {
                        int exponent = scale + static_cast<int>(fractionLength);
                        auto exponentDigits = String::number(std::abs(exponent));
                        for (auto exponentSign : { ""_s, "+"_s, "-"_s }) {
                            if ((exponent < 0) != (exponentSign.length() && exponentSign[0] == '-'))
                                continue;
                            for (unsigned width = exponentDigits.length(); width <= 4; ++width) {
                                StringBuilder padding;
                                for (unsigned i = exponentDigits.length(); i < width; ++i)
                                    padding.append('0');
                                numbers.append(makeString(significand, 'e', exponentSign, padding.toString(), exponentDigits));
                            }
                        }
                    }
                    for (auto& number : numbers) {
                        auto text = makeString(sign, number);
                        for (auto& follower : followers)
                            check(makeString(text, follower.text), text, follower.type, follower.tokenCount);
                    }
                }
            }
        }
    }
    struct Special {
        ASCIILiteral input;
        ASCIILiteral numberText;
        CSSParserTokenType type;
        size_t tokenCount;
    };
    static constexpr std::array specials {
        Special { "-0.0"_s, "-0.0"_s, NumberToken, 1 }, Special { "-.0"_s, "-.0"_s, NumberToken, 1 },
        Special { "-0.0e5"_s, "-0.0e5"_s, NumberToken, 1 }, Special { "+0.0e-0"_s, "+0.0e-0"_s, NumberToken, 1 },
        Special { "-0e0"_s, "-0e0"_s, NumberToken, 1 }, Special { "-0e-23"_s, "-0e-23"_s, NumberToken, 1 },
        Special { "1e0000"_s, "1e0000"_s, NumberToken, 1 }, Special { "1e00022"_s, "1e00022"_s, NumberToken, 1 },
        Special { "1e00023"_s, "1e00023"_s, NumberToken, 1 },
        Special { "1e0000000000000000022"_s, "1e0000000000000000022"_s, NumberToken, 1 },
        Special { "1e00000000000000000022"_s, "1e00000000000000000022"_s, NumberToken, 1 },
        Special { "1.5e0000000000000000000001"_s, "1.5e0000000000000000000001"_s, NumberToken, 1 },
        Special { "1e99999999999999999999999"_s, "1e99999999999999999999999"_s, NumberToken, 1 },
        Special { "-1e-99999999999999999999999"_s, "-1e-99999999999999999999999"_s, NumberToken, 1 },
        Special { "1e18446744073709551638"_s, "1e18446744073709551638"_s, NumberToken, 1 },
        Special { "999999999999999.5"_s, "999999999999999.5"_s, NumberToken, 1 },
        Special { "99999999999999.95"_s, "99999999999999.95"_s, NumberToken, 1 },
        Special { "0.000000000000000001"_s, "0.000000000000000001"_s, NumberToken, 1 },
        Special { "0.0000000000000000001"_s, "0.0000000000000000001"_s, NumberToken, 1 },
        Special { "000000000000000000001.5"_s, "000000000000000000001.5"_s, NumberToken, 1 },
        Special { "9007199254740993.0"_s, "9007199254740993.0"_s, NumberToken, 1 },
        Special { "123456789012345e-22"_s, "123456789012345e-22"_s, NumberToken, 1 },
        Special { "0.123456789012345e-7"_s, "0.123456789012345e-7"_s, NumberToken, 1 },
        Special { "1.e5"_s, "1"_s, NumberToken, 3 }, Special { "1."_s, "1"_s, NumberToken, 2 },
        Special { "1e"_s, "1"_s, DimensionToken, 1 }, Special { "1e+"_s, "1"_s, DimensionToken, 2 },
        Special { "1.5E-3"_s, "1.5E-3"_s, NumberToken, 1 }, Special { "1.5e3.5"_s, "1.5e3"_s, NumberToken, 2 },
    };
    for (auto& special : specials)
        check(special.input, special.numberText, special.type, special.tokenCount);
}

TEST(CSSTokenizerTest, ReplaceUnpairedSurrogates)
{
    // A name of each length up to 40 with a lone lead, a lone trail or a pair at each position: the lone surrogate
    // becomes U+FFFD and the pair stays, wherever it falls against the input's start and end.
    enum class Kind { Lead, Trail, Pair, LeadThenNull };
    for (unsigned length = 1; length <= 40; ++length) {
        for (unsigned position = 0; position < length; ++position) {
            for (auto kind : { Kind::Lead, Kind::Trail, Kind::Pair, Kind::LeadThenNull }) {
                if ((kind == Kind::Pair || kind == Kind::LeadThenNull) && position + 1 == length)
                    continue;
                Vector<char16_t> input;
                input.fill('a', length);
                auto expected = input;
                switch (kind) {
                case Kind::Lead:
                    input[position] = 0xD83D;
                    expected[position] = 0xFFFD;
                    break;
                case Kind::Trail:
                    input[position] = 0xDE00;
                    expected[position] = 0xFFFD;
                    break;
                case Kind::Pair:
                    input[position] = expected[position] = 0xD83D;
                    input[position + 1] = expected[position + 1] = 0xDE00;
                    break;
                case Kind::LeadThenNull:
                    input[position] = 0xD83D;
                    input[position + 1] = 0;
                    expected[position] = expected[position + 1] = 0xFFFD;
                    break;
                }
                String string(input.span());
                CSSTokenizer tokenizer(string);
                auto tokenRange = tokenizer.tokenRange();
                auto tokens = tokenRange.span();
                ASSERT_EQ(1u, tokens.size());
                EXPECT_EQ(IdentToken, tokens[0].type());
                EXPECT_EQ(String(expected.span()), tokens[0].value().toString());
            }
        }
    }
}

} // namespace TestWebKitAPI
