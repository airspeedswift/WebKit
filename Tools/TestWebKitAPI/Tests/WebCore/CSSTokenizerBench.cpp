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

#include "config.h"

#include <WebCore/CSSParserToken.h>
#include <WebCore/CSSParserTokenRange.h>
#include <WebCore/CSSTokenizer.h>
#include <algorithm>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <wtf/FileSystem.h>
#include <wtf/HexNumber.h>
#include <wtf/MonotonicTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Each test tokenizes its inputs once and checks a checksum of the tokens. With WEBKIT_RUN_BENCHMARKS set, it
// then tokenizes them a fixed number of times and prints the time taken.

namespace TestWebKitAPI {

using namespace WebCore;

namespace CSSTokenizerBenchmark {

static constexpr unsigned generatedLength = 1 << 20;

class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned bound)
    {
        m_state = m_state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<unsigned>(m_state >> 33) % bound;
    }

    bool percent(unsigned chance) { return below(100) < chance; }

    template<typename T, size_t size>
    const T& pick(const T (&values)[size]) { return values[below(size)]; }

private:
    uint64_t m_state;
};

static String sourceRoot()
{
    StringView file = StringView::fromLatin1(__FILE__);
    auto end = file.find("/Tools/TestWebKitAPI/"_s);
    if (end == notFound)
        return { };
    return file.left(end).toString();
}

static String readSourceFile(ASCIILiteral relativePath)
{
    auto contents = FileSystem::readEntireFile(makeString(sourceRoot(), '/', relativePath));
    if (!contents)
        return { };
    return String(byteCast<Latin1Character>(contents->span()));
}

static String make16Bit(const String& string)
{
    Vector<char16_t> characters;
    characters.reserveInitialCapacity(string.length());
    for (unsigned i = 0; i < string.length(); ++i)
        characters.append(string[i]);
    return String(characters.span());
}

static Vector<String> bootstrapMinInputs()
{
    return { readSourceFile("PerformanceTests/Speedometer2.1/resources/flightjs-example-app/components/bootstrap/css/bootstrap.min.css"_s) };
}

static Vector<String> bootstrapInputs()
{
    return { readSourceFile("PerformanceTests/Speedometer2.1/resources/flightjs-example-app/components/bootstrap/css/bootstrap.css"_s) };
}

static Vector<String> userAgentSheetInputs()
{
    return { readSourceFile("Source/WebCore/css/html.css"_s) };
}

static String inspectorSheets()
{
    auto directory = makeString(sourceRoot(), "/Source/WebInspectorUI/UserInterface/Views"_s);
    auto names = FileSystem::listDirectory(directory);
    std::ranges::sort(names, codePointCompareLessThan);
    StringBuilder builder;
    for (auto& name : names) {
        if (!name.endsWith(".css"_s))
            continue;
        auto contents = FileSystem::readEntireFile(FileSystem::pathByAppendingComponent(directory, name));
        if (contents)
            builder.append(String(byteCast<Latin1Character>(contents->span())));
    }
    return builder.toString();
}

static Vector<String> inspectorSheetsInputs()
{
    return { inspectorSheets() };
}

static Vector<String> wideInputs()
{
    return { make16Bit(inspectorSheets()) };
}

static Vector<String> propertyValuesInputs()
{
    static constexpr ASCIILiteral values[] = {
        "10px"_s, "0"_s, "auto"_s, "none"_s, "100%"_s, "1.5em"_s, "-2px"_s, "inherit"_s,
        "rgb(1 2 3 / 50%)"_s, "rgba(0,0,0,.1)"_s, "#ccc"_s, "#a0b1c2"_s, "red"_s, "transparent"_s,
        "calc(100% - 2em)"_s, "calc(1px + 2 * var(--gap))"_s, "min(10vw, 200px)"_s, "clamp(1rem, 2.5vw, 2rem)"_s,
        "1px solid #ccc"_s, "0 0 0 1px rgba(0,0,0,.1)"_s, "0 auto"_s, "10px 20px 30px 40px"_s,
        "url(a.png)"_s, "url(\"images/background.png\") no-repeat center"_s, "\"Helvetica Neue\", sans-serif"_s,
        "-apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto"_s, "bold 12px/1.5 Menlo, monospace"_s,
        "opacity .25s ease-in-out"_s, "all 150ms cubic-bezier(0.4, 0, 0.2, 1)"_s, "translate(-50%, -50%) rotate(45deg)"_s,
        "matrix(1, 0, 0, 1, 0, 0)"_s, "scale(1.05)"_s, "linear-gradient(to bottom, #fff 0%, #eee 100%)"_s,
        "repeat(auto-fill, minmax(120px, 1fr))"_s, "1 1 auto"_s, "flex-start"_s, "space-between"_s,
        "var(--text-color)"_s, "var(--x, 4px)"_s, "env(safe-area-inset-left)"_s, "attr(data-label)"_s,
        "counter(item) \". \""_s, "\"\\201C\""_s, "1000"_s, "0.5"_s, "1e3"_s, "-webkit-box"_s, "block"_s,
        "inline-block"_s, "pointer"_s, "hidden"_s, "ellipsis"_s, "nowrap"_s, "break-word"_s,
        "300ms"_s, "2s"_s, "90deg"_s, "0.25turn"_s, "2dppx"_s, "16px"_s, "!important"_s, "italic small-caps"_s,
        "blur(4px) brightness(120%)"_s, "drop-shadow(0 1px 2px rgb(0 0 0 / .2))"_s,
    };
    Vector<String> inputs;
    for (unsigned i = 0; i < 20000; ++i)
        inputs.append(values[i % std::size(values)]);
    return inputs;
}

static void appendName(StringBuilder& builder, Random& random, unsigned length)
{
    static constexpr char start[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_";
    static constexpr char rest[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";
    for (unsigned i = 0; i < length; ++i) {
        if (random.percent(5))
            builder.append(static_cast<Latin1Character>(0xC0 + random.below(0x40)));
        else if (!i)
            builder.append(start[random.below(sizeof(start) - 1)]);
        else
            builder.append(rest[random.below(sizeof(rest) - 1)]);
    }
}

static Vector<String> identifiersInputs()
{
    static constexpr ASCIILiteral separators[] = { ", "_s, " "_s, ":"_s };
    Random random(1);
    StringBuilder builder;
    while (builder.length() < generatedLength) {
        appendName(builder, random, 1 + random.below(40));
        builder.append(random.pick(separators));
    }
    return { builder.toString() };
}

static Vector<String> whitespaceInputs()
{
    static constexpr ASCIILiteral newlines[] = { "\n"_s, "\r\n"_s, "\f"_s };
    Random random(2);
    StringBuilder builder;
    while (builder.length() < generatedLength) {
        appendName(builder, random, 1 + random.below(8));
        if (random.percent(25)) {
            builder.append(random.pick(newlines));
            continue;
        }
        unsigned run = 1 + random.below(64);
        for (unsigned i = 0; i < run; ++i)
            builder.append(random.percent(80) ? ' ' : '\t');
    }
    return { builder.toString() };
}

static Vector<String> punctuationInputs()
{
    static constexpr ASCIILiteral pieces[] = {
        "("_s, ")"_s, "["_s, "]"_s, "{"_s, "}"_s, ","_s, ":"_s, ";"_s, "!"_s, "*"_s, ">"_s, "+"_s, "~"_s, "="_s,
        "("_s, ")"_s, "["_s, "]"_s, "{"_s, "}"_s, ","_s, ":"_s, ";"_s, "!"_s, "*"_s, ">"_s, "+"_s, "~"_s, "="_s,
        "^="_s, "$="_s, "*="_s, "|="_s, "~="_s, "||"_s, "<!--"_s, "-->"_s,
    };
    Random random(3);
    StringBuilder builder;
    Vector<char, 16> closers;
    while (builder.length() < generatedLength) {
        auto piece = random.pick(pieces);
        char opener = piece.length() == 1 ? piece[0] : 0;
        if ((opener == '(' || opener == '[' || opener == '{') && closers.size() >= 12)
            piece = ","_s;
        else if (opener == '(' || opener == '[' || opener == '{')
            closers.append(opener == '(' ? ')' : opener == '[' ? ']' : '}');
        else if ((opener == ')' || opener == ']' || opener == '}') && !closers.isEmpty() && random.percent(90)) {
            builder.append(closers.takeLast());
            continue;
        }
        builder.append(piece);
    }
    return { builder.toString() };
}

static constexpr ASCIILiteral unitSpellings[] = {
    "q"_s, "s"_s, "x"_s, "ch"_s, "cm"_s, "em"_s, "ex"_s, "fr"_s, "hz"_s, "ic"_s, "in"_s, "lh"_s, "mm"_s, "ms"_s,
    "pc"_s, "pt"_s, "px"_s, "vb"_s, "vh"_s, "vi"_s, "vw"_s, "cap"_s, "cqb"_s, "cqh"_s, "cqi"_s, "cqw"_s, "deg"_s,
    "dpi"_s, "dvb"_s, "dvh"_s, "dvi"_s, "dvw"_s, "lvb"_s, "lvh"_s, "lvi"_s, "lvw"_s, "khz"_s, "rad"_s, "rch"_s,
    "rem"_s, "rex"_s, "ric"_s, "rlh"_s, "svb"_s, "svh"_s, "svi"_s, "svw"_s, "dpcm"_s, "dppx"_s, "grad"_s,
    "rcap"_s, "turn"_s, "vmax"_s, "vmin"_s, "__qem"_s, "cqmax"_s, "cqmin"_s, "dvmax"_s, "dvmin"_s, "lvmax"_s,
    "lvmin"_s, "svmax"_s, "svmin"_s, "zz"_s, "pxx"_s,
};

static void appendDigits(StringBuilder& builder, Random& random, unsigned count)
{
    for (unsigned i = 0; i < count; ++i)
        builder.append(static_cast<char>('0' + random.below(10)));
}

static Vector<String> numbersInputs()
{
    static constexpr ASCIILiteral signs[] = { ""_s, ""_s, "+"_s, "-"_s };
    static constexpr ASCIILiteral exponents[] = { "e"_s, "E"_s, "e+"_s, "e-"_s, "E-"_s };
    Random random(4);
    StringBuilder builder;
    while (builder.length() < generatedLength) {
        builder.append(random.pick(signs));
        switch (random.below(6)) {
        case 0:
            appendDigits(builder, random, 1 + random.below(4));
            break;
        case 1:
            appendDigits(builder, random, 1 + random.below(3));
            builder.append('.');
            appendDigits(builder, random, 1 + random.below(4));
            break;
        case 2:
            builder.append('.');
            appendDigits(builder, random, 1 + random.below(3));
            break;
        case 3:
            appendDigits(builder, random, 1 + random.below(2));
            builder.append(random.pick(exponents));
            appendDigits(builder, random, 1 + random.below(2));
            break;
        case 4:
            appendDigits(builder, random, 16 + random.below(5));
            break;
        default:
            appendDigits(builder, random, 1 + random.below(3));
            break;
        }
        switch (random.below(4)) {
        case 0:
            break;
        case 1:
            builder.append('%');
            break;
        default: {
            auto unit = random.pick(unitSpellings);
            if (random.percent(10))
                builder.append(StringView { unit }.convertToASCIIUppercase());
            else
                builder.append(unit);
            break;
        }
        }
        builder.append(random.percent(70) ? " "_s : ", "_s);
    }
    return { builder.toString() };
}

static Vector<String> stringsInputs()
{
    static constexpr char contents[] = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 .,;:!?/()[]{}#@*";
    Random random(5);
    StringBuilder builder;
    while (builder.length() < generatedLength) {
        char quote = random.percent(50) ? '"' : '\'';
        builder.append(quote);
        unsigned length = random.below(201);
        bool escaped = random.percent(10);
        for (unsigned i = 0; i < length; ++i) {
            if (escaped && i == length / 2)
                builder.append(random.percent(50) ? "\\41 "_s : "\\\""_s);
            builder.append(contents[random.below(sizeof(contents) - 1)]);
        }
        if (random.percent(2))
            builder.append('\n');
        else
            builder.append(quote);
        builder.append(", "_s);
    }
    return { builder.toString() };
}

static Vector<String> escapesInputs()
{
    static constexpr ASCIILiteral escapes[] = {
        "\\41"_s, "\\41 "_s, "\\041\t"_s, "\\0041\r\n"_s, "\\00041\n"_s, "\\000041 "_s, "\\e9"_s, "\\4E00 "_s,
        "\\1F600 "_s, "\\10FFFF "_s, "\\0 "_s, "\\D800 "_s, "\\DFFF "_s, "\\110000 "_s, "\\FFFFFF "_s, "\\g"_s,
        "\\-"_s, "\\ "_s, "\\\\"_s, "\\\""_s, "\\("_s, "\\)"_s,
    };
    static constexpr ASCIILiteral starts[] = { ""_s, "\""_s, "url("_s, "#"_s, "@"_s, "1"_s };
    Random random(6);
    StringBuilder builder;
    while (builder.length() < generatedLength) {
        unsigned context = random.below(std::size(starts));
        builder.append(starts[context]);
        appendName(builder, random, 1 + random.below(6));
        unsigned count = 1 + random.below(3);
        for (unsigned i = 0; i < count; ++i) {
            builder.append(random.pick(escapes));
            appendName(builder, random, random.below(4));
        }
        if (context == 1)
            builder.append('"');
        else if (context == 2)
            builder.append(')');
        builder.append(' ');
    }
    return { builder.toString() };
}

static Vector<String> urlsInputs()
{
    static constexpr ASCIILiteral forms[] = {
        "url(images/a.png)"_s, "url(  spaced.png  )"_s, "url(\"quoted.png\")"_s, "url('single.png')"_s,
        "url(\\61 .png)"_s, "url(a\\)b.png)"_s, "url(a b)"_s, "url(a\"b)"_s, "u\\72l(x.png)"_s,
        "URL(upper.png)"_s, "url()"_s, "url(  )"_s, "url(  \"spaced-quote.png\"  )"_s, "url(a(b)"_s,
        "url(https://example.com/path/to/a/long/resource-name.svg#fragment)"_s,
    };
    Random random(7);
    StringBuilder builder;
    while (builder.length() < generatedLength) {
        builder.append(random.pick(forms));
        builder.append(random.percent(50) ? " "_s : ", "_s);
    }
    return { builder.toString() };
}

static Vector<String> commentsInputs()
{
    static constexpr char contents[] = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJ 0123456789 ***/ *\n";
    static constexpr ASCIILiteral between[] = { "a"_s, "1px"_s, ";"_s, "{"_s, "}"_s, " "_s, "#id"_s };
    Random random(8);
    StringBuilder builder;
    while (builder.length() < generatedLength) {
        builder.append("/*"_s);
        unsigned length = random.below(501);
        for (unsigned i = 0; i < length; ++i) {
            char c = contents[random.below(sizeof(contents) - 1)];
            if (c == '/' && builder[builder.length() - 1] == '*')
                c = '-';
            builder.append(c);
        }
        builder.append("*/"_s);
        builder.append(random.pick(between));
    }
    return { builder.toString() };
}

static Vector<String> nestedBlocksInputs()
{
    static constexpr ASCIILiteral openers[] = { "("_s, "["_s, "{"_s, "f("_s, "calc("_s };
    static constexpr char closers[] = ")]}";
    Random random(9);
    StringBuilder builder;
    while (builder.length() < generatedLength) {
        unsigned depth = 1 + random.below(64);
        Vector<char, 64> expected;
        for (unsigned i = 0; i < depth; ++i) {
            auto opener = random.pick(openers);
            builder.append(opener);
            expected.append(opener[opener.length() - 1] == '[' ? ']' : opener[opener.length() - 1] == '{' ? '}' : ')');
            if (random.percent(30))
                builder.append("a "_s);
        }
        while (!expected.isEmpty()) {
            if (random.percent(10))
                builder.append(closers[random.below(3)]);
            else
                builder.append(expected.takeLast());
        }
        builder.append(' ');
    }
    return { builder.toString() };
}

static void appendHex(StringBuilder& builder, unsigned value)
{
    builder.append(hex(value, Lowercase));
}

static Vector<String> unicodeRangeInputs()
{
    Random random(10);
    StringBuilder builder;
    while (builder.length() < generatedLength) {
        builder.append("@font-face{font-family:f;src:url(f.woff2);unicode-range:U+0-7F,U+0100-024F,U+4??,u+1e00-1eff"_s);
        unsigned count = 1 + random.below(8);
        for (unsigned i = 0; i < count; ++i) {
            builder.append(random.percent(50) ? ",U+"_s : ", u+"_s);
            unsigned first = random.below(0x10000);
            appendHex(builder, first);
            switch (random.below(3)) {
            case 0:
                builder.append('-');
                appendHex(builder, first + random.below(0x1000));
                break;
            case 1:
                builder.append("??"_s);
                break;
            default:
                break;
            }
        }
        builder.append("}\n"_s);
    }
    return { builder.toString() };
}

static Vector<String> customPropertiesInputs()
{
    static constexpr ASCIILiteral pieces[] = {
        "var(--x, "_s, "calc("_s, "1px"_s, " + "_s, "  "_s, "\t"_s, "    "_s, "rgb(1 2 3 / 50%)"_s, "var(--y)"_s,
        "solid"_s, "#fff"_s, ", "_s, "2em"_s,
    };
    Random random(11);
    StringBuilder builder;
    builder.append(":root{"_s);
    while (builder.length() < generatedLength) {
        builder.append("--"_s);
        appendName(builder, random, 1 + random.below(16));
        builder.append(": "_s);
        unsigned depth = 0;
        unsigned count = 4 + random.below(24);
        for (unsigned i = 0; i < count; ++i) {
            auto piece = random.pick(pieces);
            builder.append(piece);
            depth += std::ranges::count(piece.span(), '(');
        }
        for (; depth; --depth)
            builder.append(')');
        builder.append(";\n"_s);
    }
    builder.append('}');
    return { builder.toString() };
}

static Vector<String> preprocessedInputs()
{
    auto sheet = bootstrapInputs()[0];
    StringBuilder withNulls;
    StringBuilder withSurrogates;
    for (unsigned i = 0; i < sheet.length(); ++i) {
        if (i && !(i % 1024) && sheet[i] != '\n') {
            withNulls.append('\0');
            withSurrogates.append(static_cast<char16_t>(i % 2048 ? 0xD800 + i % 0x400 : 0xDC00 + i % 0x400));
        }
        withNulls.append(sheet[i]);
        withSurrogates.append(sheet[i]);
    }
    withSurrogates.append(static_cast<char16_t>(0x4E00));
    return { withNulls.toString(), withSurrogates.toString() };
}

static Vector<String> malformedInputs()
{
    static constexpr ASCIILiteral pieces[] = {
        "\"unterminated string\n"_s, "'unterminated"_s, "/* unterminated comment"_s, "url(unterminated"_s,
        "url(bad url)"_s, "url(bad\"url)"_s, "url(bad\\"_s, "{ a: ( b [ c"_s, "} ) ]"_s, "\\"_s, "\\\n"_s,
        "\\110000"_s, "\\D800"_s, "#"_s, "@"_s, "1e"_s, "1e+"_s, "-"_s, "<!-"_s, "--"_s, "u+"_s, "a"_s, " "_s, ";"_s,
        "1."_s, "+."_s, ".x"_s, "\x01"_s, "\x07"_s, "\x0B"_s, "\x1F"_s, "\x7F"_s, "`"_s, "%"_s, "&"_s, "\r"_s,
    };
    Random random(12);
    Vector<String> inputs;
    unsigned total = 0;
    while (total < generatedLength) {
        StringBuilder builder;
        unsigned count = 4 + random.below(400);
        for (unsigned i = 0; i < count; ++i)
            builder.append(random.pick(pieces));
        total += builder.length();
        inputs.append(builder.toString());
    }
    return inputs;
}

static uint64_t mix(uint64_t hash, uint64_t value)
{
    return (hash ^ value) * 0x100000001b3ULL;
}

static uint64_t mix(uint64_t hash, StringView string)
{
    if (string.isNull())
        return mix(hash, 1ULL << 40);
    hash = mix(hash, string.length() | static_cast<uint64_t>(string.is8Bit()) << 32);
    for (auto character : string.codeUnits())
        hash = mix(hash, character);
    return hash;
}

static uint64_t mix(uint64_t hash, const CSSParserToken& token)
{
    hash = mix(hash, token.type() | token.getBlockType() << 8 | static_cast<unsigned>(token.unitType()) << 16);
    hash = mix(hash, token.value());
    switch (token.type()) {
    case DelimiterToken:
        return mix(hash, token.delimiter());
    case HashToken:
        return mix(hash, token.getHashTokenType());
    case DimensionToken:
        hash = mix(hash, token.unitString().length());
        [[fallthrough]];
    case NumberToken:
    case PercentageToken:
        hash = mix(hash, std::bit_cast<uint64_t>(token.numericValue()));
        return mix(hash, token.numericSign() | token.numericValueType() << 8);
    case NonNewlineWhitespaceToken: {
        StringBuilder builder;
        token.serialize(builder, nullptr, CSSParserToken::SerializationMode::CustomProperty);
        return mix(hash, builder.length());
    }
    default:
        return hash;
    }
}

static uint64_t checksum(const Vector<String>& inputs)
{
    uint64_t hash = 0xcbf29ce484222325ULL;
    for (auto& input : inputs) {
        CSSTokenizer tokenizer(input);
        auto range = tokenizer.tokenRange();
        auto tokens = range.span();
        hash = mix(hash, tokens.size());
        for (auto& token : tokens)
            hash = mix(hash, token);
        auto strings = tokenizer.escapedStringsForAdoption();
        hash = mix(hash, strings.size());
        for (auto& string : strings)
            hash = mix(hash, StringView { string });
    }
    return hash;
}

static void run(ASCIILiteral name, const Vector<String>& inputs, uint64_t expectedChecksum, unsigned passes)
{
    size_t length = 0;
    for (auto& input : inputs)
        length += input.length();
    ASSERT_GT(length, 0u);

    auto result = checksum(inputs);
    EXPECT_EQ(expectedChecksum, result);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    size_t tokens = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& input : inputs) {
            CSSTokenizer tokenizer(input);
            tokens += tokenizer.tokenRange().size();
        }
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_GT(tokens, 0u);
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, elapsed.milliseconds(),
        static_cast<double>(length) * passes / elapsed.microseconds(), static_cast<unsigned long long>(result));
}

} // namespace CSSTokenizerBenchmark

using namespace CSSTokenizerBenchmark;

TEST(CSSTokenizerBench, BootstrapMin) { run("BootstrapMin"_s, bootstrapMinInputs(), 0x322bf4eda5ac2fd6ULL, 5500); }
TEST(CSSTokenizerBench, Bootstrap) { run("Bootstrap"_s, bootstrapInputs(), 0x7b2fedefd13cc83bULL, 8900); }
TEST(CSSTokenizerBench, UserAgentSheet) { run("UserAgentSheet"_s, userAgentSheetInputs(), 0x70ba752db2623b74ULL, 16000); }
TEST(CSSTokenizerBench, InspectorSheets) { run("InspectorSheets"_s, inspectorSheetsInputs(), 0x09600caf111bbb4cULL, 1100); }
TEST(CSSTokenizerBench, PropertyValues) { run("PropertyValues"_s, propertyValuesInputs(), 0x3b53d4b732a1f347ULL, 1400); }
TEST(CSSTokenizerBench, Identifiers) { run("Identifiers"_s, identifiersInputs(), 0x4587899f2ebca715ULL, 780); }
TEST(CSSTokenizerBench, Whitespace) { run("Whitespace"_s, whitespaceInputs(), 0x730d16e899a84736ULL, 1100); }
TEST(CSSTokenizerBench, Punctuation) { run("Punctuation"_s, punctuationInputs(), 0xcec015d64e3ec974ULL, 150); }
TEST(CSSTokenizerBench, Numbers) { run("Numbers"_s, numbersInputs(), 0x57ca47e55f0bc2bdULL, 230); }
TEST(CSSTokenizerBench, Strings) { run("Strings"_s, stringsInputs(), 0x657268c1284b36acULL, 1400); }
TEST(CSSTokenizerBench, Escapes) { run("Escapes"_s, escapesInputs(), 0xb16d6609238ca7d0ULL, 220); }
TEST(CSSTokenizerBench, Urls) { run("Urls"_s, urlsInputs(), 0xb8109b4c04e514a5ULL, 520); }
TEST(CSSTokenizerBench, Comments) { run("Comments"_s, commentsInputs(), 0xb9815cdffc1d082eULL, 1400); }
TEST(CSSTokenizerBench, NestedBlocks) { run("NestedBlocks"_s, nestedBlocksInputs(), 0x3b992da0c22011c5ULL, 200); }
TEST(CSSTokenizerBench, UnicodeRange) { run("UnicodeRange"_s, unicodeRangeInputs(), 0x542b7f452db4a390ULL, 370); }
TEST(CSSTokenizerBench, CustomProperties) { run("CustomProperties"_s, customPropertiesInputs(), 0xd5d27f4cf8c2d5b6ULL, 260); }
TEST(CSSTokenizerBench, Wide) { run("Wide"_s, wideInputs(), 0xc052e4db111bbb4cULL, 710); }
TEST(CSSTokenizerBench, Preprocessed) { run("Preprocessed"_s, preprocessedInputs(), 0xf4aba83e147800c6ULL, 2300); }
TEST(CSSTokenizerBench, Malformed) { run("Malformed"_s, malformedInputs(), 0xb03b86e960700f68ULL, 850); }

} // namespace TestWebKitAPI
