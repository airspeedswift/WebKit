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

#include "Helpers/Test.h"
#include <WebCore/HTMLParserOptions.h>
#include <WebCore/HTMLToken.h>
#include <WebCore/HTMLTokenizer.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/SegmentedString.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/AtomString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// Throughput of WebCore's HTML tokenizer (HTMLTokenizer::nextToken), one TEST per kind of input. The input is
// appended to a SegmentedString in chunks, as HTMLDocumentParser appends network data or document.write text, and
// the tokens are taken after each chunk. After each start tag the tokenizer's state is updated as
// HTMLPreloadScanner does, and CDATA sections are allowed inside svg and math. By default each TEST tokenizes its
// input once and checks the checksum of the tokens. With WEBKIT_RUN_BENCHMARKS=1 in the environment it then repeats
// that for about a second and prints "<Name>: <ms> ms <MB/s> MB/s checksum=<hex>", with the same checksum. Nothing
// asserts on time.

using namespace WebCore;

namespace TestWebKitAPI {

namespace {

class Generator {
public:
    explicit Generator(uint32_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned n)
    {
        m_state = m_state * 1664525u + 1013904223u;
        return (m_state >> 8) % n;
    }

private:
    uint32_t m_state;
};

struct Checksum {
    uint64_t value { 1469598103934665603ull };

    void add(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i) {
            value ^= (word >> (8 * i)) & 0xff;
            value *= 1099511628211ull;
        }
    }

    void add(std::span<const char16_t> characters)
    {
        add(characters.size());
        for (auto character : characters) {
            value ^= character & 0xff;
            value *= 1099511628211ull;
            value ^= character >> 8;
            value *= 1099511628211ull;
        }
    }
};

// The input as the tokenizer receives it: one or more documents, each a list of chunks.
struct Input {
    Vector<Vector<String>> documents;
    size_t bytes { 0 };
};

static Input wholeDocuments(const Vector<String>& documents)
{
    Input input;
    for (auto& document : documents) {
        input.documents.append(Vector<String> { document });
        input.bytes += document.length() * (document.is8Bit() ? 1 : 2);
    }
    return input;
}

static Input fixedChunks(const String& document, unsigned chunkLength)
{
    Input input;
    Vector<String> chunks;
    for (unsigned offset = 0; offset < document.length(); offset += chunkLength)
        chunks.append(document.substring(offset, chunkLength));
    input.documents.append(WTF::move(chunks));
    input.bytes = document.length() * (document.is8Bit() ? 1 : 2);
    return input;
}

static Input randomChunks(const Vector<String>& documents, unsigned minimumLength, unsigned maximumLength, uint32_t seed)
{
    Generator generator(seed);
    Input input;
    for (auto& document : documents) {
        Vector<String> chunks;
        for (unsigned offset = 0; offset < document.length();) {
            unsigned length = minimumLength + generator.below(maximumLength - minimumLength + 1);
            chunks.append(document.substring(offset, length));
            offset += length;
        }
        input.documents.append(WTF::move(chunks));
        input.bytes += document.length() * (document.is8Bit() ? 1 : 2);
    }
    return input;
}

static bool nameIs(const HTMLToken::DataVector& name, ASCIILiteral literal)
{
    auto characters = literal.span8();
    if (name.size() != characters.size())
        return false;
    for (size_t i = 0; i < characters.size(); ++i) {
        if (name[i] != characters[i])
            return false;
    }
    return true;
}

// The tokenizer state changes the tree builder makes between tokens: the text state a start tag selects, as
// HTMLPreloadScanner approximates it, and CDATA sections inside svg and math.
class TreeBuilderEmulation {
public:
    void didTakeToken(HTMLTokenizer& tokenizer, const HTMLToken& token)
    {
        if (token.type() == HTMLToken::Type::StartTag) {
            if ((nameIs(token.name(), "svg"_s) || nameIs(token.name(), "math"_s)) && !token.selfClosing())
                ++m_foreignContentDepth;
            tokenizer.updateStateFor(AtomString::lookUp(token.name().span()));
        } else if (token.type() == HTMLToken::Type::EndTag && m_foreignContentDepth) {
            if (nameIs(token.name(), "svg"_s) || nameIs(token.name(), "math"_s))
                --m_foreignContentDepth;
        }
        tokenizer.setShouldAllowCDATA(m_foreignContentDepth > 0);
    }

private:
    unsigned m_foreignContentDepth { 0 };
};

static const String& endOfFileMarker()
{
    static const Latin1Character marker = 0;
    static NeverDestroyed<String> string { String(std::span { &marker, 1 }) };
    return string;
}

template<typename TokenFunction>
static void tokenize(const Vector<String>& chunks, TokenFunction&& takeToken)
{
    HTMLTokenizer tokenizer;
    SegmentedString source;
    TreeBuilderEmulation treeBuilder;
    auto takeTokens = [&] {
        while (auto token = tokenizer.nextToken(source)) {
            takeToken(*token);
            treeBuilder.didTakeToken(tokenizer, *token);
        }
    };
    for (auto& chunk : chunks) {
        source.append(chunk);
        takeTokens();
    }
    source.append(endOfFileMarker());
    source.close();
    takeTokens();
}

static void addToken(Checksum& checksum, HTMLToken& token)
{
    checksum.add(static_cast<uint64_t>(token.type()));
    switch (token.type()) {
    case HTMLToken::Type::StartTag:
    case HTMLToken::Type::EndTag:
        checksum.add(token.name().span());
        checksum.add(token.selfClosing());
        checksum.add(token.attributes().size());
        for (auto& attribute : token.attributes()) {
            checksum.add(attribute.name.span());
            checksum.add(attribute.value.span());
        }
        break;
    case HTMLToken::Type::Character:
        checksum.add(token.characters().span());
        checksum.add(token.charactersIsAll8BitData());
        break;
    case HTMLToken::Type::Comment:
        checksum.add(token.comment().span());
        checksum.add(token.commentIsAll8BitData());
        break;
    case HTMLToken::Type::DOCTYPE: {
        checksum.add(token.name().span());
        auto doctype = token.releaseDoctypeData();
        checksum.add(doctype->hasPublicIdentifier);
        checksum.add(doctype->publicIdentifier.span());
        checksum.add(doctype->hasSystemIdentifier);
        checksum.add(doctype->systemIdentifier.span());
        checksum.add(doctype->forceQuirks);
        break;
    }
    case HTMLToken::Type::ProcessingInstruction:
        for (auto character : token.processingInstructionTarget())
            checksum.add(character.value);
        checksum.add(token.processingInstructionData().span());
        break;
    case HTMLToken::Type::Uninitialized:
    case HTMLToken::Type::EndOfFile:
        break;
    }
}

// What the timed passes read from each token, compared against the first pass.
struct Summary {
    uint64_t tokens { 0 };
    uint64_t characters { 0 };

    bool operator==(const Summary&) const = default;

    void add(const HTMLToken& token)
    {
        ++tokens;
        switch (token.type()) {
        case HTMLToken::Type::StartTag:
        case HTMLToken::Type::EndTag:
            characters += token.name().size();
            for (auto& attribute : token.attributes())
                characters += attribute.name.size() + attribute.value.size();
            break;
        case HTMLToken::Type::Character:
            characters += token.characters().size();
            break;
        case HTMLToken::Type::Comment:
            characters += token.comment().size();
            break;
        default:
            break;
        }
    }
};

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

static void expectChecksum(const Checksum& checksum, uint64_t expected)
{
    EXPECT_EQ(checksum.value, expected) << "checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum.value;
}

static void printResult(ASCIILiteral name, double seconds, double bytes, const Checksum& checksum)
{
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum.value));
}

static Checksum checksumOfOnePass(const Input& input, Summary& summary)
{
    Checksum checksum;
    for (auto& chunks : input.documents) {
        tokenize(chunks, [&](HTMLToken& token) {
            summary.add(token);
            addToken(checksum, token);
        });
    }
    checksum.add(summary.tokens);
    return checksum;
}

static void runBenchmark(ASCIILiteral name, const Input& input, unsigned iterations, uint64_t expectedChecksum)
{
    ProcessWarming::initializeNames();

    Summary summary;
    auto checksum = checksumOfOnePass(input, summary);
    expectChecksum(checksum, expectedChecksum);

    if (!runsBenchmarks())
        return;

    unsigned mismatches = 0;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i) {
        Summary iterationSummary;
        for (auto& chunks : input.documents)
            tokenize(chunks, [&](HTMLToken& token) { iterationSummary.add(token); });
        if (iterationSummary != summary)
            ++mismatches;
    }
    double seconds = (MonotonicTime::now() - start).seconds();
    EXPECT_EQ(mismatches, 0u);

    printResult(name, seconds, static_cast<double>(input.bytes) * iterations, checksum);
}

// The HTML specification, the input of PerformanceTests/Parser/html-parser.html.
static String specPage()
{
    String path = String::fromUTF8(__FILE__);
    for (unsigned i = 0; i < 5; ++i)
        path = FileSystem::parentPath(path);
    std::array<StringView, 4> components { "PerformanceTests"_s, "Parser"_s, "resources"_s, "html5.html"_s };
    path = FileSystem::pathByAppendingComponents(path, components);
    auto contents = FileSystem::readEntireFile(path);
    EXPECT_TRUE(contents.has_value()) << "cannot read PerformanceTests/Parser/resources/html5.html";
    if (!contents)
        return emptyString();
    return String::fromUTF8(contents->span());
}

static const ASCIILiteral proseWords[] = { "the"_s, "tokenizer"_s, "reads"_s, "characters"_s, "from"_s, "input"_s, "stream"_s, "and"_s,
    "emits"_s, "tokens"_s, "lorem"_s, "ipsum"_s, "dolor"_s, "sit"_s, "amet"_s, "consectetur"_s, "adipiscing"_s, "elit"_s };

static void appendProse(StringBuilder& builder, Generator& generator, unsigned length, ASCIILiteral newline)
{
    unsigned appended = 0;
    while (appended < length) {
        unsigned pick = generator.below(64);
        if (!pick) {
            builder.append("caf"_s);
            builder.append(static_cast<Latin1Character>(0xE9));
            builder.append(' ');
            appended += 5;
        } else if (pick == 1) {
            builder.append('.', newline);
            appended += 1 + newline.length();
        } else {
            auto word = proseWords[generator.below(std::size(proseWords))];
            builder.append(word, ' ');
            appended += word.length() + 1;
        }
    }
}

static String textRuns(ASCIILiteral newline, unsigned seed)
{
    Generator generator(seed);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        builder.append("<p>"_s);
        appendProse(builder, generator, 2048, newline);
        builder.append("</p>"_s, newline);
    }
    return builder.toString();
}

static void appendAttributeValue(StringBuilder& builder, Generator& generator, ASCIILiteral newline)
{
    switch (generator.below(3)) {
    case 0:
        builder.append('"', proseWords[generator.below(std::size(proseWords))], ' ', generator.below(1000));
        if (!generator.below(8))
            builder.append(newline, "next line"_s);
        builder.append('"');
        break;
    case 1:
        builder.append('\'', 'x', generator.below(100), " y\'"_s);
        break;
    default:
        builder.append('v', generator.below(10000));
        break;
    }
}

static String attributeHeavy(ASCIILiteral newline, unsigned seed)
{
    static const ASCIILiteral names[] = { "id"_s, "class"_s, "Title"_s, "href"_s, "data-id"_s, "DATA-VALUE"_s, "data-Item-Index"_s, "aria-label"_s,
        "role"_s, "tabindex"_s, "Style"_s, "dir"_s, "lang"_s, "hidden"_s, "draggable"_s, "data-x-y-z"_s };
    static const ASCIILiteral tags[] = { "div"_s, "span"_s, "a"_s, "li"_s, "DIV"_s, "Button"_s };
    Generator generator(seed);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        auto tag = tags[generator.below(std::size(tags))];
        builder.append('<', tag);
        unsigned count = 6 + generator.below(7);
        for (unsigned i = 0; i < count; ++i) {
            builder.append(generator.below(10) ? " "_s : newline, names[generator.below(std::size(names))]);
            if (generator.below(10)) {
                builder.append('=');
                appendAttributeValue(builder, generator, newline);
            }
        }
        builder.append(">item "_s, generator.below(1000), "</"_s, tag, '>', newline);
        if (!generator.below(4))
            builder.append("<input type=checkbox checked disabled value=\"on\" name='n"_s, generator.below(100), "'/>"_s, newline);
    }
    return builder.toString();
}

static const ASCIILiteral entityReferences[] = { "&amp;"_s, "&lt;"_s, "&gt;"_s, "&nbsp;"_s, "&quot;"_s, "&copy;"_s, "&hellip;"_s, "&mdash;"_s,
    "&CounterClockwiseContourIntegral;"_s, "&DoubleLongLeftRightArrow;"_s, "&NotNestedGreaterGreater;"_s, "&#169;"_s, "&#x2014;"_s, "&#X41;"_s,
    "&#128;"_s, "&#x9F;"_s, "&#0;"_s, "&#xD800;"_s, "&#1114112;"_s, "&#00000000065;"_s, "&nbsp"_s, "&amp"_s, "&copy2"_s, "&notin;"_s, "&notit;"_s,
    "&noti"_s, "&foo;"_s, "&#xZ;"_s, "&#;"_s, "& "_s, "&#x;"_s, "&ampx"_s };

static String entityText()
{
    Generator generator(23);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        builder.append("<p>"_s);
        for (unsigned run = 0; run < 16; ++run) {
            unsigned length = 4 + generator.below(40);
            appendProse(builder, generator, length, "\n"_s);
            builder.append(entityReferences[generator.below(std::size(entityReferences))]);
            if (generator.below(2))
                builder.append(' ');
        }
        builder.append("</p>\n"_s);
    }
    return builder.toString();
}

static String entityAttributes()
{
    // Without a semicolon, a reference followed by '=' or an alphanumeric character is not decoded in an attribute.
    static const ASCIILiteral attributeOnly[] = { "&amp=1"_s, "&copy1"_s, "&notx"_s, "&lt=&gt"_s, "&nbspx"_s, "&AMP;"_s, "&ampamp;"_s };
    Generator generator(29);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        builder.append("<a"_s);
        for (unsigned i = 0; i < 4; ++i) {
            ASCIILiteral reference = generator.below(3) ? entityReferences[generator.below(std::size(entityReferences))] : attributeOnly[generator.below(std::size(attributeOnly))];
            builder.append(" data-v"_s, i, '=');
            switch (generator.below(3)) {
            case 0:
                builder.append("\"?a=1"_s, reference, "b=2&c\""_s);
                break;
            case 1:
                builder.append("'Tom "_s, reference, " Jerry'"_s);
                break;
            default:
                builder.append('x', reference, 'y');
                break;
            }
        }
        builder.append(" href=\"/search?q=fish&amp;chips&lang=en&copy=1\">link "_s, generator.below(1000), "</a>\n"_s);
    }
    return builder.toString();
}

static String scriptAndStyle()
{
    Generator generator(31);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        switch (generator.below(5)) {
        case 0:
            builder.append("<script>var a = 1 < 2 && b > 3; if (x</y) { document.write(\"</div>\"); } // </scriptx </ script>\n"_s);
            for (unsigned i = 0; i < 8; ++i)
                builder.append("  items.push({ id: "_s, generator.below(1000), ", html: '<li class=\"x\">' + name + '</li>' });\n"_s);
            builder.append("</script>\n"_s);
            break;
        case 1:
            builder.append("<script><!-- hide from old browsers\n  var s = '<scr' + 'ipt>'; a--; b-->c; <!-- again -->\n</script>\n"_s);
            break;
        case 2:
            builder.append("<script><!--<script>document.write('</script>'); x = y--;</script> still double escaped -- -></script>\n"_s);
            break;
        case 3:
            builder.append("<style>\n"_s);
            for (unsigned i = 0; i < 8; ++i)
                builder.append("  .c"_s, generator.below(1000), " > a[href^=\"http\"]::after { content: \"</p>\"; } /* </sty </stylex */\n"_s);
            builder.append("</style>\n"_s);
            break;
        default:
            builder.append("<p>between "_s, generator.below(1000), "</p>\n"_s);
            break;
        }
    }
    return builder.toString();
}

static String rcdata()
{
    Generator generator(37);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        if (generator.below(2))
            builder.append("<title>Fish &amp; chips &lt;b&gt; "_s, generator.below(1000), " </titlex </tit </ title> &copy 2026</title>\n"_s);
        else {
            builder.append("<textarea name=t>"_s);
            for (unsigned i = 0; i < 6; ++i)
                builder.append("line "_s, i, " &#x41;&nbsp;<b>not a tag</b> </textare </textarea2> &notit;\n"_s);
            builder.append("</TextArea>\n"_s);
        }
    }
    return builder.toString();
}

static String commentsAndDoctype()
{
    static const ASCIILiteral pieces[] = {
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">"_s,
        "<!doctype html>"_s, "<!DOCTYPE html SYSTEM 'about:legacy-compat'>"_s, "<!DOCTYPE html PUBLIC>"_s, "<!DOCTYPEhtml>"_s,
        "<!DOCTYPE html PUBLIC \"x\" junk>"_s, "<!DOCTYPE html public 'a' 'b'>"_s, "<!DOCTYPE>"_s,
        "<!-->"_s, "<!--->"_s, "<!-- a -- b -->"_s, "<!-- x --!>"_s, "<!-- x -- >-->"_s, "<!---x-->"_s, "<!-- <!-- nested -->"_s,
        "<!-- a comment with some length to it, as pages have -->"_s, "<?xml version=\"1.0\"?>"_s, "<!x>"_s, "</ >"_s, "</>"_s,
        "<! >"_s, "<!-x>"_s, "<!--\n multi\n line\n-->"_s,
    };
    Generator generator(41);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        builder.append(pieces[generator.below(std::size(pieces))]);
        if (generator.below(2))
            builder.append("\n<p>text "_s, generator.below(1000), "</p>\n"_s);
    }
    return builder.toString();
}

static String foreignCDATA()
{
    Generator generator(43);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        switch (generator.below(3)) {
        case 0:
            builder.append("<svg viewBox=\"0 0 10 10\"><![CDATA[ x < y && z > w ]] ]> "_s, generator.below(1000), " ]]]><g><![CDATA[]]></g><circle r=\"4\"/></svg>\n"_s);
            break;
        case 1:
            builder.append("<math><mi>x</mi><![CDATA[a]]b]]]><mo>+</mo></math>\n"_s);
            break;
        default:
            builder.append("<p><![CDATA[a bogus comment outside foreign content]]></p>\n"_s);
            break;
        }
    }
    return builder.toString();
}

static Vector<String> malformedDocuments()
{
    static const ASCIILiteral pieces[] = { "<"_s, "</"_s, "<a"_s, "<a b"_s, "="_s, "\""_s, "'"_s, "&"_s, "&am"_s, "&#x"_s, "&#"_s, "<!--"_s,
        "--"_s, "-->"_s, "<!"_s, "<!DOCTYPE"_s, " PUBLIC "_s, " SYSTEM"_s, "<script>"_s, "</script"_s, "<title>"_s, "</title"_s, "<style>"_s,
        "<svg>"_s, "<![CDATA["_s, "]]"_s, ">"_s, "/>"_s, "<?"_s, "<!x"_s, "\r\n"_s, "\r"_s, "\n"_s, "text "_s, "&amp;"_s, "&#0;"_s, "&nbsp"_s,
        "<a b='c"_s, "<a b=\"c"_s, "<a b=c"_s, "<!--<script>"_s, "-->"_s, "]]>"_s, "\t"_s, "x"_s, "A"_s };
    Generator generator(47);
    Vector<String> documents;
    for (unsigned i = 0; i < 4096; ++i) {
        StringBuilder builder;
        unsigned count = 8 + generator.below(120);
        for (unsigned j = 0; j < count; ++j) {
            if (!generator.below(16))
                builder.append('\0');
            else
                builder.append(pieces[generator.below(std::size(pieces))]);
        }
        documents.append(builder.toString());
    }
    return documents;
}

static String utf16Page()
{
    static const char16_t* const words[] = { u"日本語", u"文字列", u"解析", u"字句", u"中文", u"汉字", u"한국어", u"テキスト", u"記事" };
    Generator generator(53);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        builder.append("<div class=\""_s, std::span<const char16_t>(u"\u8A18\u4E8B", 2), "\" data-id=\""_s, generator.below(1000), "\"><p>"_s);
        for (unsigned i = 0; i < 64; ++i) {
            auto* word = words[generator.below(std::size(words))];
            builder.append(std::span<const char16_t>(word, std::char_traits<char16_t>::length(word)));
            switch (generator.below(12)) {
            case 0:
                builder.append("<a href=\"/x?a=1&amp;b=2\">"_s, std::span<const char16_t>(u"リンク", 3), "</a>"_s);
                break;
            case 1:
                builder.append("&nbsp;"_s);
                break;
            case 2:
                builder.append(static_cast<char16_t>(0x3002));
                break;
            default:
                break;
            }
        }
        builder.append("</p></div>\n"_s);
    }
    return builder.toString();
}

static String newlines()
{
    StringBuilder builder;
    builder.append(textRuns("\r\n"_s, 59), attributeHeavy("\r\n"_s, 61), "<p>lone\rcarriage\rreturns\r\r\n</p>"_s);
    return builder.toString();
}

static Input specPageInput()
{
    return wholeDocuments({ specPage() });
}

static Input specPageNetworkChunksInput()
{
    return fixedChunks(specPage(), 1460);
}

static Input documentWriteSmallChunksInput()
{
    return randomChunks({ specPage() }, 1, 16, 67);
}

static Input textRunsInput()
{
    return wholeDocuments({ textRuns("\n"_s, 19) });
}

static Input attributeHeavyInput()
{
    return wholeDocuments({ attributeHeavy("\n"_s, 3) });
}

static Input entityTextInput()
{
    return wholeDocuments({ entityText() });
}

static Input entityAttributesInput()
{
    return wholeDocuments({ entityAttributes() });
}

static Input scriptAndStyleInput()
{
    return wholeDocuments({ scriptAndStyle() });
}

static Input rcdataInput()
{
    return wholeDocuments({ rcdata() });
}

static Input commentsAndDoctypeInput()
{
    return wholeDocuments({ commentsAndDoctype() });
}

static Input foreignCDATAInput()
{
    return wholeDocuments({ foreignCDATA() });
}

static Input malformedInput()
{
    return randomChunks(malformedDocuments(), 1, 64, 71);
}

static Input utf16PageInput()
{
    return wholeDocuments({ utf16Page() });
}

static Input newlinesInput()
{
    return wholeDocuments({ newlines() });
}

} // namespace

TEST(HTMLTokenizerBench, SpecPage)
{
    runBenchmark("SpecPage"_s, specPageInput(), 90, 0x242731acd40dcc53ull);
}

TEST(HTMLTokenizerBench, SpecPageNetworkChunks)
{
    runBenchmark("SpecPageNetworkChunks"_s, specPageNetworkChunksInput(), 90, 0x44aadfcefcf9f913ull);
}

TEST(HTMLTokenizerBench, DocumentWriteSmallChunks)
{
    runBenchmark("DocumentWriteSmallChunks"_s, documentWriteSmallChunksInput(), 45, 0x68ca14db3c7247d6ull);
}

TEST(HTMLTokenizerBench, TextRuns)
{
    runBenchmark("TextRuns"_s, textRunsInput(), 3200, 0xab8eadbc32a7f0ccull);
}

TEST(HTMLTokenizerBench, AttributeHeavy)
{
    runBenchmark("AttributeHeavy"_s, attributeHeavyInput(), 400, 0x107296f25f188053ull);
}

TEST(HTMLTokenizerBench, EntityText)
{
    runBenchmark("EntityText"_s, entityTextInput(), 520, 0x15f60f49b3394863ull);
}

TEST(HTMLTokenizerBench, EntityAttributes)
{
    runBenchmark("EntityAttributes"_s, entityAttributesInput(), 260, 0x7994fd5176fbc39aull);
}

TEST(HTMLTokenizerBench, ScriptAndStyle)
{
    runBenchmark("ScriptAndStyle"_s, scriptAndStyleInput(), 600, 0x53bd7abc8f0c09e1ull);
}

TEST(HTMLTokenizerBench, RCDATA)
{
    runBenchmark("RCDATA"_s, rcdataInput(), 330, 0x9bdb0320552f22a7ull);
}

TEST(HTMLTokenizerBench, CommentsAndDoctype)
{
    runBenchmark("CommentsAndDoctype"_s, commentsAndDoctypeInput(), 440, 0x0699fa288093369aull);
}

TEST(HTMLTokenizerBench, ForeignCDATA)
{
    runBenchmark("ForeignCDATA"_s, foreignCDATAInput(), 530, 0x5f08db18908beb5full);
}

TEST(HTMLTokenizerBench, Malformed)
{
    runBenchmark("Malformed"_s, malformedInput(), 250, 0x31bc374ca25bb701ull);
}

TEST(HTMLTokenizerBench, UTF16Page)
{
    runBenchmark("UTF16Page"_s, utf16PageInput(), 330, 0xeae35cbecae6b9c9ull);
}

TEST(HTMLTokenizerBench, Newlines)
{
    runBenchmark("Newlines"_s, newlinesInput(), 360, 0xdb56581bf5912585ull);
}

} // namespace TestWebKitAPI
