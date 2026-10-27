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
#include "TestPlatformStrategies.h"
#include <WebCore/Comment.h>
#include <WebCore/DocumentInlines.h>
#include <WebCore/DocumentParser.h>
#include <WebCore/DocumentType.h>
#include <WebCore/Element.h>
#include <WebCore/ElementInlines.h>
#include <WebCore/HTMLDocument.h>
#include <WebCore/HTMLNames.h>
#include <WebCore/NodeInlines.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/ScriptWrappableInlines.h>
#include <WebCore/Settings.h>
#include <WebCore/Text.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// Throughput of WebCore's HTML document parser, one TEST per kind of input. Each input is a whole document,
// written to a frameless HTMLDocument between Document::open() and Document::close() in one or more chunks, as
// document.write appends it, except FragmentInTable's, which is many small fragments parsed with
// Element::setInnerHTML. By default each TEST parses its input once and checks the checksum of the resulting tree.
// With WEBKIT_RUN_BENCHMARKS=1 in the environment it then repeats the parse for about a second and prints
// "<Name>: <ms> ms <MB/s> MB/s checksum=<hex>", with the same checksum. Nothing asserts on time.

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

    void add(const String& string)
    {
        add(string.length());
        for (unsigned i = 0; i < string.length(); ++i) {
            char16_t character = string[i];
            value ^= character & 0xff;
            value *= 1099511628211ull;
            value ^= character >> 8;
            value *= 1099511628211ull;
        }
    }
};

// The input as the parser receives it: a list of chunks.
struct Input {
    Vector<String> chunks;
    size_t bytes { 0 };
};

static size_t byteLength(const String& string)
{
    return string.length() * (string.is8Bit() ? 1 : 2);
}

static Input wholeDocument(const String& document)
{
    return { { document }, byteLength(document) };
}

static Input fixedChunks(const String& document, unsigned chunkLength)
{
    Input input;
    for (unsigned offset = 0; offset < document.length(); offset += chunkLength)
        input.chunks.append(document.substring(offset, chunkLength));
    input.bytes = byteLength(document);
    return input;
}

static Input randomChunks(const String& document, unsigned minimumLength, unsigned maximumLength, uint32_t seed)
{
    Generator generator(seed);
    Input input;
    for (unsigned offset = 0; offset < document.length();) {
        unsigned length = minimumLength + generator.below(maximumLength - minimumLength + 1);
        input.chunks.append(document.substring(offset, length));
        offset += length;
    }
    input.bytes = byteLength(document);
    return input;
}

static Ref<HTMLDocument> parseDocument(const Settings& settings, const Input& input)
{
    auto document = HTMLDocument::create(nullptr, settings, aboutBlankURL());
    auto result = document->open();
    EXPECT_FALSE(result.hasException());
    for (auto& chunk : input.chunks) {
        RefPtr parser = document->parser();
        if (!parser)
            break;
        parser->appendSynchronously(RefPtr { chunk.impl() });
    }
    document->close();
    return document;
}

static void addTree(Checksum& checksum, const ContainerNode& parent)
{
    for (auto* child = parent.firstChild(); child; child = child->nextSibling()) {
        checksum.add(static_cast<uint64_t>(child->nodeType()));
        if (auto* element = dynamicDowncast<Element>(*child)) {
            checksum.add(element->namespaceURI());
            checksum.add(element->prefix());
            checksum.add(element->localName());
            unsigned count = element->hasAttributes() ? element->attributeCount() : 0;
            checksum.add(count);
            for (unsigned i = 0; i < count; ++i) {
                auto& attribute = element->attributeAt(i);
                checksum.add(attribute.name().prefix());
                checksum.add(attribute.name().localName());
                checksum.add(attribute.name().namespaceURI());
                checksum.add(attribute.value());
                checksum.add(attribute.value().string().is8Bit());
            }
            addTree(checksum, *element);
            checksum.add('/');
        } else if (auto* text = dynamicDowncast<Text>(*child)) {
            checksum.add(text->data());
            checksum.add(text->data().is8Bit());
        } else if (auto* comment = dynamicDowncast<Comment>(*child)) {
            checksum.add(comment->data());
            checksum.add(comment->data().is8Bit());
        } else if (auto* doctype = dynamicDowncast<DocumentType>(*child)) {
            checksum.add(doctype->name());
            checksum.add(doctype->publicId());
            checksum.add(doctype->systemId());
        }
    }
}

static Checksum checksumOfDocument(HTMLDocument& document)
{
    Checksum checksum;
    addTree(checksum, document);
    checksum.add(static_cast<uint64_t>(document.compatibilityMode()));
    return checksum;
}

static unsigned nodeCount(const ContainerNode& parent)
{
    unsigned count = 0;
    for (auto* child = parent.firstChild(); child; child = child->nextSibling()) {
        ++count;
        if (auto* container = dynamicDowncast<ContainerNode>(*child))
            count += nodeCount(*container);
    }
    return count;
}

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

static void runBenchmark(ASCIILiteral name, const Input& input, unsigned iterations, uint64_t expectedChecksum)
{
    ensureTestPlatformStrategiesInstalled();
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = parseDocument(settings, input);
    EXPECT_FALSE(document->parsing());
    EXPECT_FALSE(document->parser());
    auto checksum = checksumOfDocument(document);
    unsigned nodes = nodeCount(document);
    expectChecksum(checksum, expectedChecksum);

    if (!runsBenchmarks())
        return;

    unsigned mismatches = 0;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i) {
        auto iterationDocument = parseDocument(settings, input);
        if (nodeCount(iterationDocument) != nodes)
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

static const ASCIILiteral proseWords[] = { "the"_s, "parser"_s, "reads"_s, "characters"_s, "from"_s, "input"_s, "stream"_s, "and"_s,
    "builds"_s, "nodes"_s, "lorem"_s, "ipsum"_s, "dolor"_s, "sit"_s, "amet"_s, "consectetur"_s, "adipiscing"_s, "elit"_s };

static void appendProse(StringBuilder& builder, Generator& generator, unsigned length)
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
            builder.append(".\n"_s);
            appended += 2;
        } else {
            auto word = proseWords[generator.below(std::size(proseWords))];
            builder.append(word, ' ');
            appended += word.length() + 1;
        }
    }
}

static void appendWord(StringBuilder& builder, Generator& generator)
{
    builder.append(proseWords[generator.below(std::size(proseWords))]);
}

// Start tags with 5 to 10 distinct attributes, from names and values common enough to stay in the parser's caches.
static String attributeHeavy()
{
    static const ASCIILiteral tags[] = { "div"_s, "span"_s, "a"_s, "li"_s, "p"_s, "button"_s, "section"_s, "label"_s, "DIV"_s, "Span"_s };
    static const ASCIILiteral names[] = { "id"_s, "class"_s, "title"_s, "href"_s, "src"_s, "alt"_s, "name"_s, "type"_s, "value"_s, "role"_s,
        "style"_s, "dir"_s, "lang"_s, "hidden"_s, "tabindex"_s, "draggable"_s, "rel"_s, "target"_s, "width"_s, "height"_s,
        "data-id"_s, "data-x"_s, "data-index"_s, "data-state"_s, "data-testid"_s, "aria-label"_s, "aria-hidden"_s, "aria-expanded"_s,
        "aria-controls"_s, "aria-describedby"_s, "Class"_s, "ID"_s, "Title"_s, "HREF"_s, "Data-Id"_s, "ARIA-LABEL"_s, "for"_s,
        "placeholder"_s, "autocomplete"_s, "itemprop"_s };
    static const ASCIILiteral values[] = { ""_s, "x"_s, "0"_s, "1"_s, "2"_s, "-1"_s, "true"_s, "false"_s, "on"_s, "off"_s, "main"_s,
        "nav"_s, "item"_s, "item active"_s, "btn"_s, "btn btn-primary"_s, "row"_s, "col-md-6"_s, "container"_s, "header"_s,
        "footer"_s, "button"_s, "submit"_s, "text"_s, "checkbox"_s, "ltr"_s, "en"_s, "en-US"_s, "#"_s, "/"_s, "#top"_s,
        "/index.html"_s, "_blank"_s, "noopener"_s, "logo.png"_s, "icon.svg"_s, "Close"_s, "Open menu"_s, "Search"_s, "menu"_s,
        "dialog"_s, "list"_s, "listitem"_s, "link"_s, "img"_s, "display:none"_s, "color: red"_s, "100"_s, "200"_s, "48"_s,
        "auto"_s, "none"_s, "user"_s, "email"_s, "name"_s, "q"_s, "status"_s, "open"_s, "closed"_s, "selected"_s };
    Generator generator(3);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        auto tag = tags[generator.below(std::size(tags))];
        builder.append('<', tag);
        unsigned count = 5 + generator.below(6);
        unsigned used[10];
        for (unsigned i = 0; i < count; ++i) {
            unsigned pick;
            bool distinct;
            do {
                pick = generator.below(std::size(names));
                distinct = true;
                for (unsigned j = 0; j < i; ++j)
                    distinct = distinct && !equalIgnoringASCIICase(StringView { names[used[j]] }, StringView { names[pick] });
            } while (!distinct);
            used[i] = pick;
            builder.append(generator.below(8) ? " "_s : "\n  "_s, names[pick]);
            auto value = values[generator.below(std::size(values))];
            switch (generator.below(4)) {
            case 0:
                builder.append("=\""_s, value, '"');
                break;
            case 1:
                builder.append("='"_s, value, '\'');
                break;
            case 2:
                if (!value.isEmpty() && StringView { value }.find(' ') == notFound) {
                    builder.append('=', value);
                    break;
                }
                builder.append("=\""_s, value, '"');
                break;
            default:
                if (generator.below(3))
                    builder.append("=\""_s, value, '"');
                break;
            }
        }
        builder.append('>');
        appendWord(builder, generator);
        builder.append("</"_s, tag, ">\n"_s);
    }
    return builder.toString();
}

// Attribute names and values that are new on almost every tag, so they miss the parser's caches.
static String distinctAttributes()
{
    static const ASCIILiteral tags[] = { "div"_s, "span"_s, "li"_s, "p"_s };
    Generator generator(5);
    StringBuilder builder;
    unsigned counter = 0;
    while (builder.length() < 1 << 20) {
        auto tag = tags[generator.below(std::size(tags))];
        builder.append('<', tag);
        unsigned count = 2 + generator.below(5);
        for (unsigned i = 0; i < count; ++i) {
            ++counter;
            builder.append(" data-"_s, proseWords[generator.below(std::size(proseWords))], '-', counter, "=\""_s);
            builder.append(proseWords[generator.below(std::size(proseWords))], '-', counter * 7919u % 1000003u, '"');
        }
        builder.append('>');
        appendWord(builder, generator);
        builder.append("</"_s, tag, ">\n"_s);
    }
    return builder.toString();
}

static void appendPath(StringBuilder& builder, Generator& generator, unsigned minimumLength)
{
    unsigned start = builder.length();
    while (builder.length() - start < minimumLength) {
        builder.append('/');
        appendWord(builder, generator);
        if (!generator.below(3))
            builder.append('-', generator.below(100000));
    }
}

// Attribute values longer than the parser caches: URLs, style declarations and srcset lists.
static String longAttributeValues()
{
    static const ASCIILiteral hosts[] = { "https://www.example.com"_s, "https://cdn.example.net/assets"_s, "http://static.example.org"_s };
    static const ASCIILiteral properties[] = { "color"_s, "background-color"_s, "margin"_s, "padding"_s, "font-size"_s, "line-height"_s,
        "border"_s, "display"_s };
    Generator generator(7);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        switch (generator.below(4)) {
        case 0:
            builder.append("<a href=\""_s, hosts[generator.below(std::size(hosts))]);
            appendPath(builder, generator, 20 + generator.below(80));
            builder.append("?id="_s, generator.below(1000000), "&amp;ref=list\">"_s);
            appendWord(builder, generator);
            builder.append("</a>\n"_s);
            break;
        case 1: {
            builder.append("<img src=\""_s, hosts[generator.below(std::size(hosts))]);
            appendPath(builder, generator, 20 + generator.below(60));
            builder.append(".jpg\" srcset=\""_s);
            unsigned candidates = 2 + generator.below(3);
            for (unsigned i = 0; i < candidates; ++i) {
                builder.append(i ? ", "_s : ""_s, hosts[generator.below(std::size(hosts))]);
                appendPath(builder, generator, 20);
                builder.append(".jpg "_s, (i + 1) * 320, 'w');
            }
            builder.append("\">\n"_s);
            break;
        }
        case 2: {
            builder.append("<div style=\""_s);
            unsigned declarations = 3 + generator.below(4);
            for (unsigned i = 0; i < declarations; ++i)
                builder.append(properties[generator.below(std::size(properties))], ": "_s, generator.below(64), "px; "_s);
            builder.append("\">"_s);
            appendWord(builder, generator);
            builder.append("</div>\n"_s);
            break;
        }
        default:
            builder.append("<link rel=stylesheet href='"_s, hosts[generator.below(std::size(hosts))]);
            appendPath(builder, generator, 30 + generator.below(40));
            builder.append(".css?v="_s, generator.below(100000000), "'>\n"_s);
            break;
        }
    }
    return builder.toString();
}

// Many short known elements with a character or two of text each.
static String shortTags()
{
    static const ASCIILiteral inline_[] = { "b"_s, "i"_s, "em"_s, "span"_s, "a"_s, "u"_s, "s"_s, "code"_s, "small"_s, "strong"_s };
    static const ASCIILiteral text[] = { "x"_s, "y"_s, "1"_s, "ab"_s, " "_s, "z"_s, "42"_s, "."_s };
    Generator generator(11);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        switch (generator.below(3)) {
        case 0:
            builder.append("<p>"_s);
            for (unsigned i = 0; i < 16; ++i) {
                auto tag = inline_[generator.below(std::size(inline_))];
                builder.append('<', tag, '>', text[generator.below(std::size(text))], "</"_s, tag, '>');
            }
            builder.append("</p>\n"_s);
            break;
        case 1:
            builder.append("<ul>"_s);
            for (unsigned i = 0; i < 12; ++i)
                builder.append("<li>"_s, text[generator.below(std::size(text))], "</li>"_s);
            builder.append("</ul>\n"_s);
            break;
        default:
            builder.append("<table>"_s);
            for (unsigned row = 0; row < 4; ++row) {
                builder.append("<tr>"_s);
                for (unsigned cell = 0; cell < 6; ++cell)
                    builder.append("<td>"_s, text[generator.below(std::size(text))], "</td>"_s);
                builder.append("</tr>"_s);
            }
            builder.append("</table>\n"_s);
            break;
        }
    }
    return builder.toString();
}

// Custom element names and names close to known ones, all unknown to the parser.
static String unknownTags()
{
    static const ASCIILiteral prefixes[] = { "x-card"_s, "my-el-"_s, "app-root"_s, "ui-button"_s, "foo-bar-"_s, "dvi"_s, "spam"_s, "tabel"_s,
        "lii"_s, "X-Card"_s, "My-Widget"_s };
    static const ASCIILiteral names[] = { "slot"_s, "variant"_s, "class"_s, "data-id"_s, "open"_s };
    Generator generator(13);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        auto prefix = prefixes[generator.below(std::size(prefixes))];
        StringBuilder tag;
        tag.append(prefix);
        if (prefix.characters()[prefix.length() - 1] == '-')
            tag.append(generator.below(50));
        builder.append('<', tag.toString());
        unsigned count = generator.below(4);
        for (unsigned i = 0; i < count; ++i)
            builder.append(' ', names[i + generator.below(std::size(names) - i)], "=\"v"_s, generator.below(20), '"');
        builder.append('>');
        appendWord(builder, generator);
        builder.append("</"_s, tag.toString(), ">\n"_s);
    }
    return builder.toString();
}

// Start tags with one to three duplicated attributes: first, middle or last, and duplicates that differ only in case.
static String duplicateAttributes()
{
    static const ASCIILiteral names[] = { "id"_s, "class"_s, "title"_s, "href"_s, "data-x"_s, "role"_s, "lang"_s, "name"_s };
    static const ASCIILiteral upper[] = { "ID"_s, "Class"_s, "TITLE"_s, "Href"_s, "DATA-X"_s, "Role"_s, "LANG"_s, "Name"_s };
    static const ASCIILiteral tags[] = { "div"_s, "span"_s, "a"_s, "p"_s };
    Generator generator(17);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        auto tag = tags[generator.below(std::size(tags))];
        unsigned count = 3 + generator.below(4);
        unsigned picks[16];
        for (unsigned i = 0; i < count; ++i)
            picks[i] = (i * 3 + generator.below(2)) % std::size(names);
        unsigned duplicates = 1 + generator.below(3);
        for (unsigned d = 0; d < duplicates; ++d) {
            unsigned of = generator.below(count);
            switch (generator.below(3)) {
            case 0:
                picks[count++] = picks[of];
                break;
            case 1:
                for (unsigned i = count++; i > 0; --i)
                    picks[i] = picks[i - 1];
                picks[0] = picks[of + 1];
                break;
            default: {
                unsigned at = count / 2;
                for (unsigned i = count++; i > at; --i)
                    picks[i] = picks[i - 1];
                picks[at] = picks[of < at ? of : of + 1] | 0x100;
                break;
            }
            }
        }
        builder.append('<', tag);
        for (unsigned i = 0; i < count; ++i) {
            unsigned pick = picks[i] & 0xff;
            builder.append(' ', (picks[i] & 0x100) ? upper[pick] : names[pick], "=\"v"_s, generator.below(8), '"');
        }
        builder.append('>');
        appendWord(builder, generator);
        builder.append("</"_s, tag, ">\n"_s);
    }
    return builder.toString();
}

// Long text with few tags.
static String textHeavy()
{
    Generator generator(19);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        builder.append("<p>"_s);
        appendProse(builder, generator, 2048 + generator.below(6144));
        builder.append("</p>\n"_s);
    }
    return builder.toString();
}

// A doctype with identifiers, then comments of both widths, bogus comments and doctypes out of place, written in
// chunks of about 4 KB. Every fourth chunk holds characters above U+00FF, and is a 16-bit string.
static Input commentsAndDoctypeInput()
{
    static const ASCIILiteral doctypes[] = {
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\" \"http://www.w3.org/TR/html4/loose.dtd\">"_s,
        "<!doctype html>"_s, "<!DOCTYPE html SYSTEM 'about:legacy-compat'>"_s, "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\">"_s,
        "<!DOCTYPE svg>"_s, "<!DOCTYPE>"_s,
    };
    static const ASCIILiteral comments[] = {
        "<!-- a comment with some length to it, as pages have -->"_s, "<!---->"_s, "<!-- x -- y -->"_s, "<!--\n multi\n line\n-->"_s,
        "<!-- [if IE]><p>old</p><![endif] -->"_s, "<?xml version=\"1.0\"?>"_s, "<!x>"_s, "</ >"_s,
        "<!-- x --!>"_s,
    };
    static const char16_t* const wideComments[] = { u"<!-- 日本語のコメント -->", u"<!-- \u2014 em dash \u2014 -->", u"<!-- 한국어 -->" };
    Generator generator(23);
    Input input;
    StringBuilder chunk;
    unsigned total = 0;
    chunk.append(doctypes[0], "<html><head><title>t</title></head><body>\n"_s);
    while (total < 1 << 20) {
        switch (generator.below(8)) {
        case 0:
            chunk.append(doctypes[generator.below(std::size(doctypes))], '\n');
            break;
        case 1: {
            if (input.chunks.size() % 4 != 3) {
                chunk.append(comments[0], '\n');
                break;
            }
            auto* comment = wideComments[generator.below(std::size(wideComments))];
            chunk.append(std::span<const char16_t>(comment, std::char_traits<char16_t>::length(comment)), '\n');
            break;
        }
        case 2:
            chunk.append("<p>text "_s, generator.below(1000), "</p>\n"_s);
            break;
        case 3:
            chunk.append("<!-- caf"_s);
            chunk.append(static_cast<Latin1Character>(0xE9));
            chunk.append(" cr"_s);
            chunk.append(static_cast<Latin1Character>(0xE8));
            chunk.append("me -->\n"_s);
            break;
        default:
            chunk.append(comments[generator.below(std::size(comments))], '\n');
            break;
        }
        if (chunk.length() >= 4096) {
            total += chunk.length();
            auto string = chunk.toString();
            input.bytes += byteLength(string);
            input.chunks.append(WTF::move(string));
            chunk.clear();
        }
    }
    auto string = chunk.toString();
    input.bytes += byteLength(string);
    input.chunks.append(WTF::move(string));
    return input;
}

// svg and math with the attributes the parser adjusts.
static String foreignContent()
{
    Generator generator(29);
    StringBuilder builder;
    while (builder.length() < 1 << 20) {
        switch (generator.below(3)) {
        case 0:
            builder.append("<svg viewBox=\"0 0 "_s, 10 + generator.below(90), " 100\" preserveAspectRatio=\"xMidYMid meet\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">"_s);
            for (unsigned i = 0; i < 4; ++i)
                builder.append("<path d=\"M"_s, generator.below(100), ' ', generator.below(100), "L"_s, generator.below(100), ' ', generator.below(100), "Z\" stroke=\"#333\" stroke-width=\""_s, 1 + generator.below(4), "\" stroke-linecap=round fill=none/>"_s);
            builder.append("<use xlink:href=\"#icon-"_s, generator.below(40), "\" x=\"0\" y=\"0\"/><clipPath id=c"_s, generator.below(100), "><rect width=10 height=10/></clipPath>"_s);
            builder.append("<linearGradient gradientUnits=userSpaceOnUse gradientTransform=\"rotate(45)\"><stop offset=0 stop-color=red/></linearGradient>"_s);
            builder.append("<foreignObject width=10 height=10><p>x</p></foreignObject><text xml:lang=en textLength=40>t</text></svg>\n"_s);
            break;
        case 1:
            builder.append("<math display=block definitionURL=\"http://example.com/def\"><mrow><mi mathvariant=bold>x</mi><mo stretchy=false>=</mo><mfrac linethickness=2><mn>"_s, generator.below(1000), "</mn><mi mathvariant=\"double-struck\">y</mi></mfrac></mrow>"_s);
            builder.append("<annotation-xml encoding=\"text/html\"><span title=t>h</span></annotation-xml></math>\n"_s);
            break;
        default:
            builder.append("<p>between "_s, generator.below(1000), "</p>\n"_s);
            break;
        }
    }
    return builder.toString();
}

// A 16-bit document: CJK text, 16-bit attribute values and some 16-bit attribute names.
static String utf16Page()
{
    static const char16_t* const words[] = { u"日本語", u"文字列", u"解析", u"字句", u"中文", u"汉字", u"한국어", u"テキスト", u"記事" };
    static const char16_t* const names[] = { u"title", u"data-名前", u"alt", u"data-説明" };
    Generator generator(31);
    StringBuilder builder;
    auto appendWide = [&](const char16_t* string) {
        builder.append(std::span<const char16_t>(string, std::char_traits<char16_t>::length(string)));
    };
    while (builder.length() < 1 << 20) {
        builder.append("<div class=\""_s, std::span<const char16_t>(u"\u8A18\u4E8B", 2), "\" data-id=\""_s, generator.below(1000), "\"><p>"_s);
        for (unsigned i = 0; i < 48; ++i) {
            appendWide(words[generator.below(std::size(words))]);
            switch (generator.below(10)) {
            case 0:
                builder.append("<a href=\"/x?a=1&amp;b=2\" "_s);
                appendWide(names[generator.below(std::size(names))]);
                builder.append("=\""_s);
                appendWide(words[generator.below(std::size(words))]);
                builder.append("\">"_s, std::span<const char16_t>(u"リンク", 3), "</a>"_s);
                break;
            case 1:
                builder.append("<span lang=ja title='"_s);
                appendWide(words[generator.below(std::size(words))]);
                builder.append("'>"_s);
                appendWide(words[generator.below(std::size(words))]);
                builder.append("</span>"_s);
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

// BEGIN HTMLTreeBuilderBenchShapes

static const ASCIILiteral misplacedInTable[] = { "x"_s, " "_s, "\n  "_s, " y "_s, "<div>d</div>"_s, "<b>b</b>"_s, "<span>s</span>"_s,
    "<input type=hidden name=h>"_s, "<input name=t>"_s, "<form><input name=f>"_s, "<p>p"_s, "<a href=#>a</a>"_s, "<script></script>"_s,
    "<style></style>"_s };

static void appendMisnestedTable(StringBuilder& builder, Generator& generator, unsigned depth)
{
    builder.append("<table>"_s);
    if (!generator.below(4))
        builder.append("<caption>"_s, misplacedInTable[generator.below(std::size(misplacedInTable))], "</caption>"_s);
    if (!generator.below(3))
        builder.append(misplacedInTable[generator.below(std::size(misplacedInTable))]);
    bool explicitBody = generator.below(2);
    if (explicitBody)
        builder.append("<tbody>"_s);
    unsigned rows = 1 + generator.below(4);
    for (unsigned row = 0; row < rows; ++row) {
        if (!generator.below(5))
            builder.append(misplacedInTable[generator.below(std::size(misplacedInTable))]);
        builder.append("<tr>"_s);
        if (!generator.below(6))
            builder.append(misplacedInTable[generator.below(std::size(misplacedInTable))]);
        unsigned cells = 1 + generator.below(4);
        for (unsigned cell = 0; cell < cells; ++cell) {
            builder.append("<td>"_s);
            if (depth < 3 && !generator.below(10))
                appendMisnestedTable(builder, generator, depth + 1);
            else
                appendWord(builder, generator);
            if (generator.below(2))
                builder.append("</td>"_s);
        }
        if (generator.below(2))
            builder.append("</tr>"_s);
    }
    if (explicitBody && generator.below(2))
        builder.append("</tbody>"_s);
    builder.append("</table>\n"_s);
}

// Tables one to three deep with misplaced content: text, elements and forms directly in table, tbody and tr (foster
// parented), whitespace-only table text, hidden inputs, cells and rows left for the parser to close.
static String tablesAndFosterParenting()
{
    Generator generator(37);
    StringBuilder builder;
    while (builder.length() < 1 << 20)
        appendMisnestedTable(builder, generator, 1);
    return builder.toString();
}

static const ASCIILiteral formattingTags[] = { "b"_s, "i"_s, "em"_s, "strong"_s, "a"_s, "u"_s, "s"_s, "code"_s, "small"_s, "font"_s,
    "nobr"_s, "tt"_s };
static const ASCIILiteral blockTags[] = { "div"_s, "p"_s, "blockquote"_s, "section"_s, "ul"_s, "h2"_s };

// Formatting elements closed out of order, around blocks, in runs of one to twelve, repeated with the same attributes,
// and across markers.
static String misnestedFormatting()
{
    Generator generator(41);
    StringBuilder builder;
    auto formatting = [&] { return formattingTags[generator.below(std::size(formattingTags))]; };
    while (builder.length() < 1 << 20) {
        switch (generator.below(5)) {
        case 0: {
            auto outer = formatting();
            auto inner = formatting();
            builder.append('<', outer, '>', '<', inner, '>');
            appendWord(builder, generator);
            builder.append("</"_s, outer, '>');
            appendWord(builder, generator);
            builder.append("</"_s, inner, ">\n"_s);
            break;
        }
        case 1: {
            auto tag = formatting();
            auto block = blockTags[generator.below(std::size(blockTags))];
            builder.append('<', tag, "><"_s, block, '>');
            appendWord(builder, generator);
            builder.append("</"_s, tag, '>');
            appendWord(builder, generator);
            builder.append("</"_s, block, ">\n"_s);
            break;
        }
        case 2: {
            unsigned count = 1 + generator.below(12);
            Vector<ASCIILiteral> open;
            for (unsigned i = 0; i < count; ++i) {
                open.append(formatting());
                builder.append('<', open.last(), '>');
                if (generator.below(2))
                    appendWord(builder, generator);
            }
            if (generator.below(2))
                builder.append("<p>"_s);
            appendWord(builder, generator);
            while (!open.isEmpty()) {
                unsigned index = generator.below(open.size());
                builder.append("</"_s, open[index], '>');
                open.removeAt(index);
                if (!generator.below(3))
                    appendWord(builder, generator);
            }
            builder.append('\n');
            break;
        }
        case 3: {
            auto tag = formatting();
            unsigned count = 2 + generator.below(4);
            for (unsigned i = 0; i < count; ++i)
                builder.append('<', tag, generator.below(4) ? " class=x"_s : " class=y"_s, '>');
            builder.append("<p>"_s);
            appendWord(builder, generator);
            builder.append("</p><p>"_s);
            appendWord(builder, generator);
            builder.append("</p>"_s);
            for (unsigned i = 0; i < count; ++i)
                builder.append("</"_s, tag, '>');
            builder.append('\n');
            break;
        }
        default: {
            auto tag = formatting();
            if (generator.below(2)) {
                builder.append('<', tag, ">x<object><i>"_s);
                appendWord(builder, generator);
                builder.append("</object>"_s);
                appendWord(builder, generator);
                builder.append("</"_s, tag, ">\n"_s);
            } else {
                builder.append("<table><tr><td><"_s, tag, '>');
                appendWord(builder, generator);
                builder.append("</td><td>"_s);
                appendWord(builder, generator);
                builder.append("</"_s, tag, "></td></tr></table>\n"_s);
            }
            break;
        }
        }
    }
    return builder.toString();
}

// <div>s and <span>s nested 400 to 600 deep, past the parser's maximum DOM tree depth (512), then closed; every
// fourth run inside a table cell.
static String deepNesting()
{
    Generator generator(43);
    StringBuilder builder;
    Vector<bool> open;
    while (builder.length() < 1 << 20) {
        unsigned depth = 400 + generator.below(201);
        bool inTable = !generator.below(4);
        if (inTable)
            builder.append("<table><tr><td>"_s);
        open.shrink(0);
        for (unsigned i = 0; i < depth; ++i) {
            open.append(generator.below(3));
            builder.append(open.last() ? "<div>"_s : "<span>"_s);
        }
        appendWord(builder, generator);
        while (!open.isEmpty())
            builder.append(open.takeLast() ? "</div>"_s : "</span>"_s);
        builder.append(inTable ? "</td></tr></table>\n"_s : "\n"_s);
    }
    return builder.toString();
}

// Templates with table rows and cells, nested templates, templates in head and in tables, templates of column groups,
// captions and options, and declarative shadow roots.
static String templates()
{
    Generator generator(47);
    StringBuilder builder;
    builder.append("<!DOCTYPE html><head><template><meta name=t><style>p { }</style></template></head><body>\n"_s);
    while (builder.length() < 1 << 20) {
        switch (generator.below(5)) {
        case 0:
            builder.append("<template><tr><td>"_s);
            appendWord(builder, generator);
            builder.append("</td><td>"_s);
            appendWord(builder, generator);
            builder.append("</td></tr><tr><td>"_s);
            appendWord(builder, generator);
            builder.append("</td></tr></template>\n"_s);
            break;
        case 1: {
            unsigned depth = 1 + generator.below(4);
            for (unsigned i = 0; i < depth; ++i)
                builder.append("<template>"_s);
            builder.append("<div>"_s);
            appendWord(builder, generator);
            builder.append("<template><td>"_s);
            appendWord(builder, generator);
            builder.append("</td></template></div>"_s);
            for (unsigned i = 0; i < depth; ++i)
                builder.append("</template>"_s);
            builder.append('\n');
            break;
        }
        case 2:
            builder.append("<table><tbody><template><tr><td>"_s);
            appendWord(builder, generator);
            builder.append("</td></tr></template><tr><td>"_s);
            appendWord(builder, generator);
            builder.append("</td></tr></tbody></table>\n"_s);
            break;
        case 3:
            builder.append("<div><template shadowrootmode=open><slot></slot><span>"_s);
            appendWord(builder, generator);
            builder.append("</span></template><p>"_s);
            appendWord(builder, generator);
            builder.append("</p></div>\n"_s);
            break;
        default:
            builder.append("<template><col><col></template><template><caption>"_s);
            appendWord(builder, generator);
            builder.append("</caption><tbody></tbody></template><template><option>"_s);
            appendWord(builder, generator);
            builder.append("<option>"_s);
            appendWord(builder, generator);
            builder.append("</template>\n"_s);
            break;
        }
    }
    return builder.toString();
}

// The fragments FragmentInTable parses with Element::setInnerHTML: one to four rows of cells, or cells alone, each into
// a <tbody>, and every fourth into a <template>.
static Vector<String> fragmentInTableFragments()
{
    Generator generator(53);
    Vector<String> fragments;
    size_t length = 0;
    while (length < 1 << 20) {
        StringBuilder builder;
        if (!generator.below(8)) {
            unsigned cells = 1 + generator.below(4);
            for (unsigned cell = 0; cell < cells; ++cell) {
                builder.append("<td>"_s);
                appendWord(builder, generator);
            }
        } else {
            unsigned rows = 1 + generator.below(4);
            for (unsigned row = 0; row < rows; ++row) {
                builder.append(generator.below(3) ? "<tr>"_s : "<tr class=r>"_s);
                unsigned cells = 1 + generator.below(5);
                for (unsigned cell = 0; cell < cells; ++cell) {
                    builder.append("<td>"_s);
                    appendWord(builder, generator);
                    if (!generator.below(6))
                        builder.append(" <b>"_s, cell, "</b>"_s);
                    builder.append("</td>"_s);
                }
                builder.append("</tr>"_s);
            }
        }
        length += builder.length();
        fragments.append(builder.toString());
    }
    return fragments;
}

static bool fragmentInTableUsesTemplate(size_t index)
{
    return index % 4 == 3;
}

static size_t byteLengthOfFragments(const Vector<String>& fragments)
{
    size_t bytes = 0;
    for (auto& fragment : fragments)
        bytes += byteLength(fragment);
    return bytes;
}

// Parses each fragment into a new context element of the document and adds the result to the checksum. A
// <template>'s children are in its content, which is reached through its markup.
static void parseFragments(Document& document, const Vector<String>& fragments, Checksum& checksum)
{
    for (size_t index = 0; index < fragments.size(); ++index) {
        bool usesTemplate = fragmentInTableUsesTemplate(index);
        Ref context = document.createElement(usesTemplate ? HTMLNames::templateTag : HTMLNames::tbodyTag, false);
        auto result = context->setInnerHTML(String { fragments[index] });
        checksum.add(result.hasException());
        if (usesTemplate)
            checksum.add(context->innerHTML());
        else
            addTree(checksum, context);
    }
}

static Input tablesAndFosterParentingInput()
{
    return wholeDocument(tablesAndFosterParenting());
}

static Input misnestedFormattingInput()
{
    return wholeDocument(misnestedFormatting());
}

static Input deepNestingInput()
{
    return wholeDocument(deepNesting());
}

static Input templatesInput()
{
    return wholeDocument(templates());
}

// END HTMLTreeBuilderBenchShapes

// Each pass parses every fragment into a context element of a new document, so the setInnerHTML cache of an earlier
// pass is never reused.
static void runFragmentBenchmark(ASCIILiteral name, const Vector<String>& fragments, unsigned iterations, uint64_t expectedChecksum)
{
    ensureTestPlatformStrategiesInstalled();
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    Checksum checksum;
    {
        auto document = HTMLDocument::create(nullptr, settings, aboutBlankURL());
        parseFragments(document, fragments, checksum);
    }
    expectChecksum(checksum, expectedChecksum);

    if (!runsBenchmarks())
        return;

    unsigned mismatches = 0;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i) {
        Checksum iterationChecksum;
        auto document = HTMLDocument::create(nullptr, settings, aboutBlankURL());
        parseFragments(document, fragments, iterationChecksum);
        if (iterationChecksum.value != checksum.value)
            ++mismatches;
    }
    double seconds = (MonotonicTime::now() - start).seconds();
    EXPECT_EQ(mismatches, 0u);

    printResult(name, seconds, static_cast<double>(byteLengthOfFragments(fragments)) * iterations, checksum);
}

static Input specPageInput()
{
    return wholeDocument(specPage());
}

static Input specPageNetworkChunksInput()
{
    return fixedChunks(specPage(), 1460);
}

static Input documentWriteSmallChunksInput()
{
    return randomChunks(specPage(), 1, 16, 67);
}

static Input attributeHeavyInput()
{
    return wholeDocument(attributeHeavy());
}

static Input distinctAttributesInput()
{
    return wholeDocument(distinctAttributes());
}

static Input longAttributeValuesInput()
{
    return wholeDocument(longAttributeValues());
}

static Input shortTagsInput()
{
    return wholeDocument(shortTags());
}

static Input unknownTagsInput()
{
    return wholeDocument(unknownTags());
}

static Input duplicateAttributesInput()
{
    return wholeDocument(duplicateAttributes());
}

static Input textHeavyInput()
{
    return wholeDocument(textHeavy());
}

static Input foreignContentInput()
{
    return wholeDocument(foreignContent());
}

static Input utf16PageInput()
{
    return wholeDocument(utf16Page());
}

} // namespace

TEST(HTMLDocumentParserBench, SpecPage)
{
    runBenchmark("SpecPage"_s, specPageInput(), 25, 0x1f1fe1130874c671ull);
}

TEST(HTMLDocumentParserBench, SpecPageNetworkChunks)
{
    runBenchmark("SpecPageNetworkChunks"_s, specPageNetworkChunksInput(), 30, 0x1f1fe1130874c671ull);
}

TEST(HTMLDocumentParserBench, DocumentWriteSmallChunks)
{
    runBenchmark("DocumentWriteSmallChunks"_s, documentWriteSmallChunksInput(), 15, 0x1f1fe1130874c671ull);
}

TEST(HTMLDocumentParserBench, AttributeHeavy)
{
    runBenchmark("AttributeHeavy"_s, attributeHeavyInput(), 160, 0xfce6bd71b5b76391ull);
}

TEST(HTMLDocumentParserBench, DistinctAttributes)
{
    runBenchmark("DistinctAttributes"_s, distinctAttributesInput(), 180, 0x41eeef8bb2029a7full);
}

TEST(HTMLDocumentParserBench, LongAttributeValues)
{
    runBenchmark("LongAttributeValues"_s, longAttributeValuesInput(), 200, 0x5c945087bb0c41c3ull);
}

TEST(HTMLDocumentParserBench, ShortTags)
{
    runBenchmark("ShortTags"_s, shortTagsInput(), 85, 0x59df074ec53737e4ull);
}

TEST(HTMLDocumentParserBench, UnknownTags)
{
    runBenchmark("UnknownTags"_s, unknownTagsInput(), 140, 0x1ad1fac87aa0b6ffull);
}

TEST(HTMLDocumentParserBench, DuplicateAttributes)
{
    runBenchmark("DuplicateAttributes"_s, duplicateAttributesInput(), 170, 0xdeb62cde6ab936fcull);
}

TEST(HTMLDocumentParserBench, TextHeavy)
{
    runBenchmark("TextHeavy"_s, textHeavyInput(), 8000, 0x2e34c0dd86ecb741ull);
}

TEST(HTMLDocumentParserBench, CommentsAndDoctype)
{
    runBenchmark("CommentsAndDoctype"_s, commentsAndDoctypeInput(), 200, 0x9dac00ba139aeda9ull);
}

TEST(HTMLDocumentParserBench, ForeignContent)
{
    runBenchmark("ForeignContent"_s, foreignContentInput(), 130, 0x6fdf20fada8feea8ull);
}

TEST(HTMLDocumentParserBench, UTF16Page)
{
    runBenchmark("UTF16Page"_s, utf16PageInput(), 160, 0x9385da9865b6cd11ull);
}


TEST(HTMLDocumentParserBench, TablesAndFosterParenting)
{
    runBenchmark("TablesAndFosterParenting"_s, tablesAndFosterParentingInput(), 90, 0x89077298b8750b99ull);
}

TEST(HTMLDocumentParserBench, MisnestedFormatting)
{
    runBenchmark("MisnestedFormatting"_s, misnestedFormattingInput(), 70, 0x43810e5ddac3c8b7ull);
}

TEST(HTMLDocumentParserBench, DeepNesting)
{
    runBenchmark("DeepNesting"_s, deepNestingInput(), 45, 0x6b5c1ce79aceb03cull);
}

TEST(HTMLDocumentParserBench, Templates)
{
    runBenchmark("Templates"_s, templatesInput(), 120, 0x60430c153e762180ull);
}

TEST(HTMLDocumentParserBench, FragmentInTable)
{
    runFragmentBenchmark("FragmentInTable"_s, fragmentInTableFragments(), 60, 0x8227c7189a81955bull);
}

} // namespace TestWebKitAPI
