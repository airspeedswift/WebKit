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
#include <WebCore/DocumentFragment.h>
#include <WebCore/Element.h>
#include <WebCore/ElementInlines.h>
#include <WebCore/HTMLBodyElement.h>
#include <WebCore/HTMLDocument.h>
#include <WebCore/HTMLDocumentParserFastPath.h>
#include <WebCore/HTMLHtmlElement.h>
#include <WebCore/HTMLNames.h>
#include <WebCore/NodeInlines.h>
#include <WebCore/ParserContentPolicy.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/ScriptWrappableInlines.h>
#include <WebCore/Settings.h>
#include <WebCore/Text.h>
#include <cstdio>
#include <wtf/MonotonicTime.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// Throughput of WebCore's HTML fragment fast path (tryFastParsingHTMLFragment, the parser behind innerHTML), one
// TEST per kind of input. Each prints "<Name>: <ms> ms <MB/s> MB/s checksum=<hex>". The checksum covers every
// iteration's result and accepted child count, plus a full dump of the first iteration's fragment. Nothing asserts
// on time.

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
        for (unsigned i = 0; i < string.length(); ++i)
            add(string[i]);
    }
};

static void addTree(Checksum& checksum, const ContainerNode& parent)
{
    for (auto* child = parent.firstChild(); child; child = child->nextSibling()) {
        checksum.add(static_cast<uint64_t>(child->nodeType()));
        if (auto* element = dynamicDowncast<Element>(*child)) {
            checksum.add(element->localName());
            unsigned count = element->hasAttributes() ? element->attributeCount() : 0;
            checksum.add(count);
            for (unsigned i = 0; i < count; ++i) {
                checksum.add(element->attributeAt(i).name().localName());
                checksum.add(element->attributeAt(i).value());
            }
            addTree(checksum, *element);
            checksum.add('/');
        } else if (auto* text = dynamicDowncast<Text>(*child)) {
            checksum.add(text->data());
            checksum.add(text->data().is8Bit());
        }
    }
}

static unsigned childCount(const ContainerNode& parent)
{
    unsigned count = 0;
    for (auto* child = parent.firstChild(); child; child = child->nextSibling())
        ++count;
    return count;
}

static void runBenchmark(ASCIILiteral name, const String& source, const QualifiedName& contextTag, unsigned iterations)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);
    auto context = document->createElement(contextTag, false);
    body->appendChild(context);

    Checksum checksum;
    {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(source, document, fragment, context, { ParserContentPolicy::AllowScriptingContent });
        checksum.add(result);
        if (result)
            addTree(checksum, fragment);
    }

    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i) {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(source, document, fragment, context, { ParserContentPolicy::AllowScriptingContent });
        checksum.add(result);
        // A failed parse leaves no tree that callers use, so only a successful one's children are counted.
        checksum.add(result ? childCount(fragment) : 0);
    }
    double seconds = (MonotonicTime::now() - start).seconds();

    double bytes = static_cast<double>(source.length()) * (source.is8Bit() ? 1 : 2) * iterations;
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum.value));
}

// innerHTML set to a prefix, then to the prefix plus a suffix. The second set clones the nodes the first one parsed
// and parses only the suffix (CachedSetInnerHTML). The checksum covers both sets' results and the child count after
// each iteration, plus a full dump of the first iteration's tree.
static void runCachedSetInnerHTMLBenchmark(ASCIILiteral name, const String& prefix, const String& source, const QualifiedName& contextTag, unsigned iterations)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);
    auto context = document->createElement(contextTag, false);
    body->appendChild(context);
    // The elements of a document without a frame use the null custom element registry, which keeps innerHTML off the
    // fast path.
    context->clearUsesNullCustomElementRegistry();

    Checksum checksum;
    auto setPrefixThenSource = [&] {
        // Removing the children with the DOM API makes the next innerHTML set replace the cached source.
        context->removeChildren();
        checksum.add(context->setInnerHTML(String(prefix)).hasException());
        checksum.add(context->setInnerHTML(String(source)).hasException());
    };
    setPrefixThenSource();
    addTree(checksum, context);

    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i) {
        setPrefixThenSource();
        checksum.add(childCount(context));
    }
    double seconds = (MonotonicTime::now() - start).seconds();

    double bytes = static_cast<double>(prefix.length() + source.length()) * (source.is8Bit() ? 1 : 2) * iterations;
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum.value));
}

static String todoItems(unsigned count, bool wide)
{
    StringBuilder builder;
    for (unsigned i = 0; i < count; ++i) {
        builder.append("<li class=\"todo\" data-id=\""_s, i, "\"><div class=\"view\"><input class=\"toggle\" type=\"checkbox\"><label>Todo item "_s, i);
        if (wide)
            builder.append(static_cast<char16_t>(0x2713));
        builder.append("</label><button class=\"destroy\"></button></div></li>"_s);
    }
    return builder.toString();
}

static void appendAttributeElements(StringBuilder& builder, std::span<const ASCIILiteral> names, unsigned count, Generator& generator)
{
    for (unsigned i = 0; i < count; ++i) {
        builder.append("<div"_s);
        for (auto name : names) {
            builder.append(' ', name, '=');
            switch (generator.below(3)) {
            case 0:
                builder.append('"', 'v', generator.below(1000), " w\""_s);
                break;
            case 1:
                builder.append('\'', 'x', generator.below(100), '\'');
                break;
            default:
                builder.append('u', generator.below(10000));
                break;
            }
        }
        builder.append("><span>item "_s, i, "</span></div>"_s);
    }
}

static const char16_t* const wideWords[] = { u"文字", u"αλφα", u"日本語", u"καλημέρα", u"漢字" };

static String paragraphs(unsigned count, bool wide)
{
    static const ASCIILiteral words[] = { "lorem"_s, "ipsum"_s, "dolor"_s, "sit"_s, "amet"_s, "consectetur"_s, "adipiscing"_s, "elit"_s, "sed"_s, "do"_s, "eiusmod"_s, "tempor"_s };
    Generator generator(7);
    StringBuilder builder;
    for (unsigned p = 0; p < count; ++p) {
        builder.append("<p>"_s);
        unsigned length = 0;
        while (length < 500) {
            unsigned pick = generator.below(40);
            String word;
            if (!pick)
                word = String::fromLatin1("caf\xe9");
            else if (pick == 1)
                word = String::fromLatin1("na\xefve");
            else if (wide && pick < 8)
                word = String(std::span<const char16_t>(wideWords[pick % 5], std::char_traits<char16_t>::length(wideWords[pick % 5])));
            else
                word = words[generator.below(std::size(words))];
            unsigned wrap = generator.below(16);
            if (!wrap)
                builder.append("<b>"_s, word, "</b> "_s);
            else if (wrap == 1)
                builder.append("<i>"_s, word, "</i> "_s);
            else if (wrap == 2)
                builder.append("<span>"_s, word, "</span> "_s);
            else
                builder.append(word, ' ');
            length += word.length() + 1;
        }
        builder.append("</p>"_s);
    }
    return builder.toString();
}

static String entityText()
{
    static const ASCIILiteral entities[] = { "&amp;"_s, "&nbsp;"_s, "&lt;"_s, "&gt;"_s, "&#169;"_s, "&#x2014;"_s, "&nbsp"_s };
    static const ASCIILiteral words[] = { "price"_s, "tax"_s, "total"_s, "and"_s, "or"_s, "per"_s, "item"_s };
    Generator generator(11);
    StringBuilder builder;
    for (unsigned p = 0; p < 64; ++p) {
        builder.append("<p>"_s);
        for (unsigned run = 0; run < 16; ++run) {
            unsigned target = 20 + generator.below(21);
            unsigned length = 0;
            while (length < target) {
                auto word = words[generator.below(std::size(words))];
                builder.append(word, ' ');
                length += word.length() + 1;
            }
            builder.append(entities[generator.below(std::size(entities))], ' ');
        }
        builder.append("</p>"_s);
    }
    return builder.toString();
}

static String entityAttributes()
{
    Generator generator(13);
    StringBuilder builder;
    for (unsigned i = 0; i < 200; ++i) {
        auto tag = generator.below(2) ? "span"_s : "div"_s;
        builder.append('<', tag, " title=\"Fish &amp; chips &quot;"_s, i, "&quot;\r\nwith peas\" alt='Tom &amp; Jerry "_s, generator.below(100), "' data-x=\"a\r\nb &lt; c\">text "_s, i, "</"_s, tag, '>');
    }
    return builder.toString();
}

static void appendIndent(StringBuilder& builder, Generator& generator)
{
    builder.append('\n');
    unsigned spaces = 2 + generator.below(39);
    for (unsigned i = 0; i < spaces; ++i)
        builder.append(' ');
}

static void appendIndentedTree(StringBuilder& builder, Generator& generator, unsigned depth)
{
    builder.append("<div class=\"level\">"_s);
    appendIndent(builder, generator);
    builder.append("<ul>"_s);
    for (unsigned i = 0; i < 4; ++i) {
        appendIndent(builder, generator);
        builder.append("<li>"_s);
        if (depth)
            appendIndentedTree(builder, generator, depth - 1);
        else
            builder.append("leaf "_s, i);
        builder.append("</li>"_s);
    }
    appendIndent(builder, generator);
    builder.append("</ul>"_s);
    appendIndent(builder, generator);
    builder.append("</div>"_s);
}

static String indentedMarkup()
{
    Generator generator(17);
    StringBuilder builder;
    for (unsigned i = 0; i < 4; ++i) {
        appendIndentedTree(builder, generator, 3);
        appendIndent(builder, generator);
    }
    return builder.toString();
}

static String deepNesting()
{
    StringBuilder builder;
    for (unsigned r = 0; r < 8; ++r) {
        for (unsigned i = 0; i < 300; ++i)
            builder.append("<div>"_s);
        for (unsigned i = 0; i < 100; ++i)
            builder.append("<span>"_s);
        builder.append("leaf "_s, r);
        for (unsigned i = 0; i < 100; ++i)
            builder.append("</span>"_s);
        for (unsigned i = 0; i < 300; ++i)
            builder.append("</div>"_s);
    }
    return builder.toString();
}

static String selectOptions()
{
    StringBuilder builder;
    builder.append("<select>"_s);
    for (unsigned i = 0; i < 500; ++i)
        builder.append("<option value=\"v"_s, i, "\">Option "_s, i, "</option>"_s);
    builder.append("</select>"_s);
    return builder.toString();
}

static String declineEarly()
{
    StringBuilder builder;
    builder.append("<table></table>"_s);
    while (builder.length() < 20000)
        builder.append("<div class=\"row\"><span>cell</span> text</div>"_s);
    return builder.toString();
}

static String sixteenBit(const String& string)
{
    // The fast path keeps the input's width, so 16-bit inputs must start from a 16-bit string.
    if (!string.is8Bit())
        return string;
    Vector<char16_t> characters;
    for (unsigned i = 0; i < string.length(); ++i)
        characters.append(string[i]);
    return String(characters.span());
}

} // namespace

TEST(HTMLFastPathParserBench, TodoListItems)
{
    runBenchmark("TodoListItems"_s, todoItems(80, false), HTMLNames::ulTag, 38000);
}

TEST(HTMLFastPathParserBench, AttributeHeavy)
{
    static const ASCIILiteral names[] = { "id"_s, "class"_s, "title"_s, "lang"_s, "dir"_s, "role"_s, "hidden"_s, "draggable"_s, "spellcheck"_s, "translate"_s };
    Generator generator(3);
    StringBuilder builder;
    appendAttributeElements(builder, std::span { names }, 200, generator);
    runBenchmark("AttributeHeavy"_s, builder.toString(), HTMLNames::divTag, 11000);
}

TEST(HTMLFastPathParserBench, MixedCaseAttributes)
{
    static const ASCIILiteral names[] = { "Class"_s, "DATA-ID"_s, "aria-Label"_s, "x1"_s, "data_value"_s, "TabIndex"_s };
    Generator generator(5);
    StringBuilder builder;
    appendAttributeElements(builder, std::span { names }, 200, generator);
    runBenchmark("MixedCaseAttributes"_s, builder.toString(), HTMLNames::divTag, 15000);
}

TEST(HTMLFastPathParserBench, TextParagraphs)
{
    runBenchmark("TextParagraphs"_s, paragraphs(64, false), HTMLNames::divTag, 14000);
}

TEST(HTMLFastPathParserBench, EntityText)
{
    runBenchmark("EntityText"_s, entityText(), HTMLNames::divTag, 13500);
}

TEST(HTMLFastPathParserBench, EntityAttributes)
{
    runBenchmark("EntityAttributes"_s, entityAttributes(), HTMLNames::divTag, 15500);
}

TEST(HTMLFastPathParserBench, IndentedMarkup)
{
    runBenchmark("IndentedMarkup"_s, indentedMarkup(), HTMLNames::divTag, 7500);
}

TEST(HTMLFastPathParserBench, DeepNesting)
{
    runBenchmark("DeepNesting"_s, deepNesting(), HTMLNames::divTag, 7500);
}

TEST(HTMLFastPathParserBench, SelectOptions)
{
    runBenchmark("SelectOptions"_s, selectOptions(), HTMLNames::divTag, 25000);
}

TEST(HTMLFastPathParserBench, DeclineLate)
{
    runBenchmark("DeclineLate"_s, makeString("<div><ul>"_s, todoItems(80, false), "</ul></div><table></table>"_s), HTMLNames::divTag, 50000);
}

TEST(HTMLFastPathParserBench, DeclineEarly)
{
    runBenchmark("DeclineEarly"_s, declineEarly(), HTMLNames::divTag, 58000000);
}

TEST(HTMLFastPathParserBench, CachedSetInnerHTMLSuffix)
{
    runCachedSetInnerHTMLBenchmark("CachedSetInnerHTMLSuffix"_s, todoItems(20, false), todoItems(21, false), HTMLNames::ulTag, 42000);
}

TEST(HTMLFastPathParserBench, TodoListItems16)
{
    runBenchmark("TodoListItems16"_s, sixteenBit(todoItems(80, true)), HTMLNames::ulTag, 37000);
}

TEST(HTMLFastPathParserBench, TextParagraphs16)
{
    runBenchmark("TextParagraphs16"_s, sixteenBit(paragraphs(64, true)), HTMLNames::divTag, 12500);
}

} // namespace TestWebKitAPI
