/*
 * Copyright (C) 2016-2017 Apple Inc. All rights reserved.
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
#include <WebCore/ExceptionOr.h>
#include <WebCore/HTMLBodyElement.h>
#include <WebCore/HTMLDivElement.h>
#include <WebCore/HTMLDocument.h>
#include <WebCore/HTMLDocumentParserFastPath.h>
#include <WebCore/HTMLHtmlElement.h>
#include <WebCore/HTMLInputElement.h>
#include <WebCore/HTMLNames.h>
#include <WebCore/HTMLParserIdioms.h>
#include <WebCore/NodeInlines.h>
#include <WebCore/ParserContentPolicy.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/ScriptWrappableInlines.h>
#include <WebCore/Settings.h>
#include <WebCore/Text.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

using namespace WebCore;

namespace TestWebKitAPI {

static int testParseHTMLInteger(StringView input)
{
    auto optionalResult = parseHTMLInteger(input);
    EXPECT_TRUE(!!optionalResult);
    return optionalResult.value_or(0);
}

static bool parseHTMLIntegerFails(StringView input)
{
    return !parseHTMLInteger(input);
}

TEST(WebCoreHTMLParserIdioms, parseHTMLInteger)
{
    EXPECT_EQ(0, testParseHTMLInteger("0"_s));
    EXPECT_EQ(0, testParseHTMLInteger("-0"_s));
    EXPECT_EQ(0, testParseHTMLInteger("+0"_s));
    EXPECT_EQ(123, testParseHTMLInteger("123"_s));
    EXPECT_EQ(123, testParseHTMLInteger("+123"_s));
    EXPECT_EQ(-123, testParseHTMLInteger("-123"_s));
    EXPECT_EQ(123, testParseHTMLInteger("  123"_s));
    EXPECT_EQ(123, testParseHTMLInteger("123   "_s));
    EXPECT_EQ(123, testParseHTMLInteger("   123   "_s));
    EXPECT_EQ(123, testParseHTMLInteger("123abc"_s));
    EXPECT_EQ(-123, testParseHTMLInteger("-123abc"_s));
    EXPECT_EQ(123, testParseHTMLInteger("  +123"_s));
    EXPECT_EQ(-123, testParseHTMLInteger("  -123"_s));
    EXPECT_EQ(12, testParseHTMLInteger("   12 3"_s));
    EXPECT_EQ(1, testParseHTMLInteger("1.0"_s));
    EXPECT_EQ(1, testParseHTMLInteger("1."_s));
    EXPECT_EQ(1, testParseHTMLInteger("1e1"_s));

    // All HTML whitespaces.
    EXPECT_EQ(123, testParseHTMLInteger(" \t\r\n\f123"_s));

    // Boundaries.
    EXPECT_EQ(-2147483648, testParseHTMLInteger("-2147483648"_s));
    EXPECT_EQ(2147483647, testParseHTMLInteger("2147483647"_s));

    // Failure cases.
    EXPECT_TRUE(parseHTMLIntegerFails("-2147483649"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("2147483648"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("111111111111111111"_s));
    EXPECT_TRUE(parseHTMLIntegerFails(""_s));
    EXPECT_TRUE(parseHTMLIntegerFails(" "_s));
    EXPECT_TRUE(parseHTMLIntegerFails("   "_s));
    EXPECT_TRUE(parseHTMLIntegerFails("+"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("+ 123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("-"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("- 123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("a"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("-a"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("+-123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("-+123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("++123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("--123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("\v123"_s)); // '\v' is an ASCII space but not an HTML whitespace.
    EXPECT_TRUE(parseHTMLIntegerFails("a123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("+a123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("-a123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails(".1"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("infinity"_s));
}

static unsigned testParseHTMLNonNegativeInteger(StringView input)
{
    auto optionalResult = parseHTMLNonNegativeInteger(input);
    EXPECT_TRUE(!!optionalResult);
    return optionalResult.value_or(0);
}

static bool parseHTMLNonNegativeIntegerFails(StringView input)
{
    return !parseHTMLNonNegativeInteger(input);
}

TEST(WebCoreHTMLParserIdioms, parseHTMLNonNegativeInteger)
{
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("123"_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("+123"_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("  123"_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("123   "_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("   123   "_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("123abc"_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("  +123"_s));
    EXPECT_EQ(12u, testParseHTMLNonNegativeInteger("   12 3"_s));
    EXPECT_EQ(1u, testParseHTMLNonNegativeInteger("1.0"_s));
    EXPECT_EQ(1u, testParseHTMLNonNegativeInteger("1."_s));
    EXPECT_EQ(1u, testParseHTMLNonNegativeInteger("1e1"_s));

    // All HTML whitespaces.
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger(" \t\r\n\f123"_s));

    // Boundaries.
    EXPECT_EQ(0u, testParseHTMLNonNegativeInteger("+0"_s));
    EXPECT_EQ(0u, testParseHTMLNonNegativeInteger("0"_s));
    EXPECT_EQ(0u, testParseHTMLNonNegativeInteger("-0"_s));
    EXPECT_EQ(2147483647u, testParseHTMLNonNegativeInteger("2147483647"_s));

    // Failure cases.
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-1"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("2147483648"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("2147483649"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("111111111111111111"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("  -123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-123abc"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails(""_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails(" "_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("   "_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("+"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("+ 123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("- 123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("a"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-a"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("+-123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-+123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("++123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("--123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("\v123"_s)); // '\v' is an ASCII space but not an HTML whitespace.
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("a123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("+a123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-a123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails(".1"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("infinity"_s));
}

TEST(WebCoreHTMLParserIdioms, parseHTMLDimensionsList)
{
    auto empty = parseHTMLDimensionsList(""_s);
    EXPECT_TRUE(empty.isEmpty());

    auto whitespaceOnly = parseHTMLDimensionsList("   "_s);
    EXPECT_EQ(1u, whitespaceOnly.size());
    EXPECT_FLOAT_EQ(0, whitespaceOnly[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceOnly[0].unit);

    auto singleIntegralAbsolute = parseHTMLDimensionsList("15"_s);
    EXPECT_EQ(1u, singleIntegralAbsolute.size());
    EXPECT_FLOAT_EQ(15.0, singleIntegralAbsolute[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Absolute, singleIntegralAbsolute[0].unit);

    auto singleFloatingAbsolute = parseHTMLDimensionsList("15.05"_s);
    EXPECT_EQ(1u, singleFloatingAbsolute.size());
    EXPECT_FLOAT_EQ(15.05, singleFloatingAbsolute[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Absolute, singleFloatingAbsolute[0].unit);

    auto singleIntegralRelative = parseHTMLDimensionsList("15*"_s);
    EXPECT_EQ(1u, singleIntegralRelative.size());
    EXPECT_FLOAT_EQ(15.0, singleIntegralRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, singleIntegralRelative[0].unit);

    auto singleFloatingRelative = parseHTMLDimensionsList("15.05*"_s);
    EXPECT_EQ(1u, singleFloatingRelative.size());
    EXPECT_FLOAT_EQ(15.05, singleFloatingRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, singleFloatingRelative[0].unit);

    auto singleIntegralPercentage = parseHTMLDimensionsList("15%"_s);
    EXPECT_EQ(1u, singleIntegralPercentage.size());
    EXPECT_FLOAT_EQ(15.0, singleIntegralPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, singleIntegralPercentage[0].unit);

    auto singleFloatingPercentage = parseHTMLDimensionsList("15.05%"_s);
    EXPECT_EQ(1u, singleFloatingPercentage.size());
    EXPECT_FLOAT_EQ(15.05, singleFloatingPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, singleFloatingPercentage[0].unit);

    auto whitespaceBeforeIntegralRelative = parseHTMLDimensionsList("15.05  *"_s);
    EXPECT_EQ(1u, whitespaceBeforeIntegralRelative.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceBeforeIntegralRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceBeforeIntegralRelative[0].unit);

    auto whitespaceBeforeFloatingRelative = parseHTMLDimensionsList("15.05  *"_s);
    EXPECT_EQ(1u, whitespaceBeforeFloatingRelative.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceBeforeFloatingRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceBeforeFloatingRelative[0].unit);

    auto whitespaceBeforeIntegralPercentage = parseHTMLDimensionsList("15  %"_s);
    EXPECT_EQ(1u, whitespaceBeforeIntegralPercentage.size());
    EXPECT_FLOAT_EQ(15.0, whitespaceBeforeIntegralPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, whitespaceBeforeIntegralPercentage[0].unit);

    auto whitespaceBeforeFloatingPercentage = parseHTMLDimensionsList("15.05  %"_s);
    EXPECT_EQ(1u, whitespaceBeforeFloatingPercentage.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceBeforeFloatingPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, whitespaceBeforeFloatingPercentage[0].unit);

    auto whitespaceInFractionalAbsolute = parseHTMLDimensionsList("15. 0   5  "_s);
    EXPECT_EQ(1u, whitespaceInFractionalAbsolute.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceInFractionalAbsolute[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Absolute, whitespaceInFractionalAbsolute[0].unit);

    auto whitespaceInFractionalRelative = parseHTMLDimensionsList("15. 0   5  *"_s);
    EXPECT_EQ(1u, whitespaceInFractionalRelative.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceInFractionalRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceInFractionalRelative[0].unit);

    auto whitespaceInFractionalPercentage = parseHTMLDimensionsList("15. 0   5  %"_s);
    EXPECT_EQ(1u, whitespaceInFractionalPercentage.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceInFractionalPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, whitespaceInFractionalPercentage[0].unit);

    auto leadingWhitespace = parseHTMLDimensionsList("  15.05 %"_s);
    EXPECT_EQ(1u, leadingWhitespace.size());
    EXPECT_FLOAT_EQ(15.05, leadingWhitespace[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, leadingWhitespace[0].unit);

    auto trailingWhitespace = parseHTMLDimensionsList("15.05 %  "_s);
    EXPECT_EQ(1u, trailingWhitespace.size());
    EXPECT_FLOAT_EQ(15.05, trailingWhitespace[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, trailingWhitespace[0].unit);

    auto largeIntegralPart = parseHTMLDimensionsList("8589934592.05%"_s);
    EXPECT_EQ(1u, largeIntegralPart.size());
    EXPECT_FLOAT_EQ(1.0, largeIntegralPart[0].number); // Falls back to "1*"
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, largeIntegralPart[0].unit);

    auto largeFractionalPart = parseHTMLDimensionsList("1.8589934592%"_s);
    EXPECT_EQ(1u, largeFractionalPart.size());
    EXPECT_FLOAT_EQ(1.0, largeFractionalPart[0].number); // Falls back to "1*"
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, largeFractionalPart[0].unit);

    auto twoValuesNoWhitespace = parseHTMLDimensionsList("15.05%,10*"_s);
    EXPECT_EQ(2u, twoValuesNoWhitespace.size());
    EXPECT_FLOAT_EQ(15.05, twoValuesNoWhitespace[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, twoValuesNoWhitespace[0].unit);
    EXPECT_FLOAT_EQ(10.0, twoValuesNoWhitespace[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, twoValuesNoWhitespace[1].unit);

    auto twoValuesWhitespace = parseHTMLDimensionsList("   15.05%  ,  10*  "_s);
    EXPECT_EQ(2u, twoValuesWhitespace.size());
    EXPECT_FLOAT_EQ(15.05, twoValuesWhitespace[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, twoValuesWhitespace[0].unit);
    EXPECT_FLOAT_EQ(10.0, twoValuesWhitespace[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, twoValuesWhitespace[1].unit);

    auto lastCharacterComma = parseHTMLDimensionsList("15.05%, 10* ,"_s);
    EXPECT_EQ(2u, lastCharacterComma.size());
    EXPECT_FLOAT_EQ(15.05, lastCharacterComma[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, lastCharacterComma[0].unit);
    EXPECT_FLOAT_EQ(10.0, lastCharacterComma[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, lastCharacterComma[1].unit);

    auto trailingGarbage = parseHTMLDimensionsList("15.05 % adfa, 10* +]"_s);
    EXPECT_EQ(2u, trailingGarbage.size());
    EXPECT_FLOAT_EQ(15.05, trailingGarbage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, trailingGarbage[0].unit);
    EXPECT_FLOAT_EQ(10.0, trailingGarbage[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, trailingGarbage[1].unit);

    auto whitespaceBeforeDot = parseHTMLDimensionsList("15 .05 %, 10*"_s);
    EXPECT_EQ(2u, whitespaceBeforeDot.size());
    EXPECT_FLOAT_EQ(15.0, whitespaceBeforeDot[0].number); // Everything from after 15 to the comma is skipped.
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Absolute, whitespaceBeforeDot[0].unit);
    EXPECT_FLOAT_EQ(10.0, whitespaceBeforeDot[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceBeforeDot[1].unit);
}

TEST(WebCoreHTMLParser, HTMLInputElementCheckedState)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div1 = HTMLDivElement::create(document);
    auto div2 = HTMLDivElement::create(document);
    document->body()->appendChild(div1);
    document->body()->appendChild(div2);

    // Set the state for new controls, which triggers a different code path in
    // HTMLInputElement::parseAttribute.
    div1->setInnerHTML("<select form='ff'></select>"_s);
    auto documentState = document->formController().formElementsState(document.get());
    document->formController().setStateForNewFormElements(documentState);
    EXPECT_TRUE(!document->formController().formElementsState(document.get()).isEmpty());
    div2->setInnerHTML("<input checked='true'>"_s);
    auto inputElement = downcast<HTMLInputElement>(div2->firstChild());
    ASSERT_TRUE(inputElement);
    EXPECT_TRUE(inputElement->checked());
}

TEST(WebCoreHTMLParser, FastPathComplexHTMLEntityParsing)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto testFastParser = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        auto textChild = dynamicDowncast<Text>(fragment->firstChild());
        EXPECT_TRUE(textChild);
        return textChild ? textChild->data() : String();
    };

    EXPECT_EQ(testFastParser("Price: 12&cent; only"_s), String::fromUTF8("Price: 12¢ only"));
    EXPECT_EQ(testFastParser("Genius Nicer Dicer Plus | 18&nbsp&hellip;"_s), String::fromUTF8("Genius Nicer Dicer Plus | 18 …"));
    EXPECT_EQ(testFastParser("&nbsp&a"_s), String::fromUTF8(" &a"));
    EXPECT_EQ(testFastParser("&nbsp&"_s), String::fromUTF8(" &"));
    EXPECT_EQ(testFastParser("&nbsp-"_s), String::fromUTF8(" -"));
    EXPECT_EQ(testFastParser("food & water"_s), String("food & water"_s));
}

TEST(WebCoreHTMLParser, FastPathHandlesLi)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto fragment = DocumentFragment::create(document);
    bool result = tryFastParsingHTMLFragment("<div><li></li></div>"_s, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
    EXPECT_TRUE(result);
    EXPECT_EQ("DIV"_s, fragment->firstChild()->nodeName());
    EXPECT_EQ("LI"_s, fragment->firstChild()->firstChild()->nodeName());
}

TEST(WebCoreHTMLParser, FastPathFailsWithNestedLi)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto fragment = DocumentFragment::create(document);
    bool result = tryFastParsingHTMLFragment("<li><li></li></li>"_s, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
    EXPECT_FALSE(result);
}

TEST(WebCoreHTMLParser, FastPathAttributeNameWithUnderscore)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    // Underscore is valid in HTML attribute names but isValidAttributeNameChar() rejects it,
    // causing an unnecessary fallback to the slow parser.
    auto fragment = DocumentFragment::create(document);
    bool result = tryFastParsingHTMLFragment("<span data_value=\"test\"></span>"_s, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
    EXPECT_TRUE(result);
}

TEST(WebCoreHTMLParser, FastPathEscapedAttributeValues)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto testFastParserAttribute = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        if (!result)
            return String();
        auto* element = dynamicDowncast<Element>(fragment->firstChild());
        EXPECT_TRUE(element);
        return element ? element->getAttribute(HTMLNames::titleAttr) : String();
    };

    // Single entity (this works today).
    EXPECT_EQ("&"_s, testFastParserAttribute("<span title=\"&amp;\"></span>"_s));

    // Entity followed by more text — exercises the missing while loop in scanEscapedAttributeValue().
    EXPECT_EQ("&b"_s, testFastParserAttribute("<span title=\"&amp;b\"></span>"_s));

    // Text before and after an entity.
    EXPECT_EQ("a&b"_s, testFastParserAttribute("<span title=\"a&amp;b\"></span>"_s));

    // Multiple entities in a single attribute value.
    EXPECT_EQ("<&>"_s, testFastParserAttribute("<span title=\"&lt;&amp;&gt;\"></span>"_s));

    // Entity with trailing text and single-quote delimiter.
    EXPECT_EQ("a&b"_s, testFastParserAttribute("<span title='a&amp;b'></span>"_s));
}

TEST(WebCoreHTMLParser, FastPathRejectsNullInEscapedAttributeValue)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    // A \0 after an entity reaches scanEscapedAttributeValue's loop body.
    // The entity forces the SIMD fast scan to hand off to the escaped path,
    // and the \0 must be rejected there.
    auto fragment = DocumentFragment::create(document);
    bool result = tryFastParsingHTMLFragment("<span title=\"&amp;\0\"></span>"_s, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
    EXPECT_FALSE(result);
}

TEST(WebCoreHTMLParser, FastPathEntityWithoutSemicolonInAttributeValue)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto testFastParserAttribute = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        if (!result)
            return String();
        auto* element = dynamicDowncast<Element>(fragment->firstChild());
        EXPECT_TRUE(element);
        return element ? element->getAttribute(HTMLNames::titleAttr) : String();
    };

    // Per the HTML spec, named entities without a trailing semicolon followed by
    // an alphanumeric character must NOT be consumed in attribute values.
    // e.g. &ampX in an attribute should remain as literal "&ampX", not become "&X".
    EXPECT_EQ("&ampX"_s, testFastParserAttribute("<span title=\"&ampX\"></span>"_s));
    EXPECT_EQ("&ampX"_s, testFastParserAttribute("<span title='&ampX'></span>"_s));

    // Entity without semicolon followed by '=' should also not be consumed.
    EXPECT_EQ("&amp=1"_s, testFastParserAttribute("<span title=\"&amp=1\"></span>"_s));

    // Entity WITH semicolon followed by alphanumeric should still be consumed.
    EXPECT_EQ("&X"_s, testFastParserAttribute("<span title=\"&amp;X\"></span>"_s));

    // Entity without semicolon NOT followed by alphanumeric should be consumed.
    EXPECT_EQ("& "_s, testFastParserAttribute("<span title=\"&amp \"></span>"_s));

    // Named entity without semicolon (e.g. &AElig followed by alphanumeric).
    EXPECT_EQ("&AEligX"_s, testFastParserAttribute("<span title=\"&AEligX\"></span>"_s));

    // Named entity with semicolon (e.g. &AElig; followed by text).
    EXPECT_EQ(UTF8CString { u8"\xC3\x86X"_span }, testFastParserAttribute("<span title=\"&AElig;X\"></span>"_s).utf8());
}

TEST(WebCoreHTMLParser, FastPathMixedCaseAttributeNames)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    // Names of 15, 16 and 17 characters, in 8-bit and 16-bit input. The 16-bit input ends with U+0141, whose low
    // byte is 'A'.
    for (bool is8Bit : { true, false }) {
        auto attributeNames = [&](ASCIILiteral markup) -> String {
            StringBuilder builder;
            builder.append(markup);
            if (!is8Bit)
                builder.append(static_cast<char16_t>(0x0141));
            auto input = builder.toString();
            EXPECT_EQ(is8Bit, input.is8Bit());
            auto fragment = DocumentFragment::create(document);
            bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
            EXPECT_TRUE(result);
            auto* element = result ? dynamicDowncast<Element>(fragment->firstChild()) : nullptr;
            EXPECT_TRUE(element);
            if (!element || !element->hasAttributes())
                return String();
            StringBuilder names;
            for (unsigned i = 0; i < element->attributeCount(); ++i) {
                if (i)
                    names.append(' ');
                names.append(element->attributeAt(i).localName());
            }
            return names.toString();
        };

        EXPECT_EQ("abcdefghijklmno"_s, attributeNames("<div ABCDEFGHIJKLMNo=1></div>"_s));
        EXPECT_EQ("abcdefghijklmnop"_s, attributeNames("<div aBcDeFgHiJkLmNoP=1></div>"_s));
        EXPECT_EQ("abcdefghijklmnopq"_s, attributeNames("<div ABCDEFGHIJKLMNOPQ=1></div>"_s));
        EXPECT_EQ("abcdefghijklmnopq abcdefghijklmnopr"_s, attributeNames("<div ABCDEFGHIJKLMNOPQ=1 abcdefghijklmnopR=2></div>"_s));
        EXPECT_EQ("abcdefghijklmnop abcdefghijklmnopq"_s, attributeNames("<div ABCDEFGHIJKLMNOP=1 ABCDEFGHIJKLMNOPQ=2></div>"_s));
        EXPECT_EQ("abcdefghijklmnop"_s, attributeNames("<div abcdefghijklmnop=1 ABCDEFGHIJKLMNOP=2></div>"_s));
        EXPECT_EQ("abcdefghijklmno-z"_s, attributeNames("<div Abcdefghijklmno-Z=1></div>"_s));
    }
}

TEST(WebCoreHTMLParser, FastPathNewlineThenSpaces)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto firstText = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        auto* text = result ? dynamicDowncast<Text>(fragment->firstChild()) : nullptr;
        EXPECT_TRUE(text);
        return text ? text->data() : String();
    };

    // Indents of 32, 33 and 40 spaces, in 8-bit and 16-bit input. The 16-bit input has U+0141 after it.
    for (unsigned spaces : { 32u, 33u, 40u }) {
        StringBuilder indent;
        indent.append('\n');
        for (unsigned i = 0; i < spaces; ++i)
            indent.append(' ');
        auto indentString = indent.toString();
        for (bool is8Bit : { true, false }) {
            StringBuilder builder;
            builder.append(indentString, "<b>"_s);
            if (!is8Bit)
                builder.append(static_cast<char16_t>(0x0141));
            builder.append("</b>"_s);
            auto input = builder.toString();
            EXPECT_EQ(is8Bit, input.is8Bit());
            EXPECT_EQ(indentString, firstText(input));
        }
    }

    // U+0120, whose low byte is a space, after 1, 16 and 20 spaces.
    for (unsigned spaces : { 1u, 16u, 20u }) {
        StringBuilder text;
        text.append('\n');
        for (unsigned i = 0; i < spaces; ++i)
            text.append(' ');
        text.append(static_cast<char16_t>(0x0120));
        for (unsigned i = 0; i < 19; ++i)
            text.append(' ');
        auto textString = text.toString();
        EXPECT_FALSE(textString.is8Bit());
        EXPECT_EQ(textString, firstText(makeString(textString, "<b></b>"_s)));
    }
}

TEST(WebCoreHTMLParser, FastPathDeeplyNestedElements)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    // 40 nested <span>s, each followed by a <b> after its end tag, in 8-bit and 16-bit input. The 16-bit input has
    // U+0141 in the innermost text.
    for (bool is8Bit : { true, false }) {
        StringBuilder builder;
        for (unsigned i = 0; i < 40; ++i)
            builder.append("<span>"_s);
        builder.append('x');
        if (!is8Bit)
            builder.append(static_cast<char16_t>(0x0141));
        for (unsigned i = 0; i < 40; ++i)
            builder.append("</span><b></b>"_s);
        auto input = builder.toString();
        EXPECT_EQ(is8Bit, input.is8Bit());

        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        if (!result)
            continue;
        Node* node = fragment.ptr();
        for (unsigned depth = 0; depth < 40; ++depth) {
            node = node->firstChild();
            ASSERT_TRUE(node);
            EXPECT_EQ("SPAN"_s, node->nodeName());
            auto* next = node->nextSibling();
            ASSERT_TRUE(next);
            EXPECT_EQ("B"_s, next->nodeName());
            EXPECT_FALSE(next->nextSibling());
        }
        auto* text = dynamicDowncast<Text>(node->firstChild());
        ASSERT_TRUE(text);
        EXPECT_EQ(is8Bit ? 1u : 2u, text->length());
        EXPECT_FALSE(text->nextSibling());
    }
}

static String sixteenBitString(const String& string)
{
    Vector<char16_t> characters;
    for (unsigned i = 0; i < string.length(); ++i)
        characters.append(string[i]);
    return String(characters.span());
}

static String repeatedCharacter(char character, unsigned count)
{
    StringBuilder builder;
    for (unsigned i = 0; i < count; ++i)
        builder.append(character);
    return builder.toString();
}

TEST(WebCoreHTMLParser, FastPathLongEscapedText)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto parse = [&](const String& input) -> RefPtr<DocumentFragment> {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        return result ? RefPtr { fragment.ptr() } : nullptr;
    };

    // Text and attribute values that decode to 255, 256, 257 and 513 characters, with the character reference first
    // or last, in 8-bit and 16-bit input.
    for (unsigned length : { 255u, 256u, 257u, 513u }) {
        auto letters = repeatedCharacter('a', length - 1);
        for (bool referenceFirst : { true, false }) {
            auto escaped = referenceFirst ? makeString("&amp;"_s, letters) : makeString(letters, "&amp;"_s);
            auto decoded = referenceFirst ? makeString('&', letters) : makeString(letters, '&');
            for (bool is8Bit : { true, false }) {
                auto text = makeString(escaped, "<b></b>"_s);
                auto fragment = parse(is8Bit ? text : sixteenBitString(text));
                auto* textNode = fragment ? dynamicDowncast<Text>(fragment->firstChild()) : nullptr;
                EXPECT_TRUE(textNode);
                if (textNode)
                    EXPECT_EQ(decoded, textNode->data());

                auto attribute = makeString("<span title=\""_s, escaped, "\"></span>"_s);
                fragment = parse(is8Bit ? attribute : sixteenBitString(attribute));
                auto* element = fragment ? dynamicDowncast<Element>(fragment->firstChild()) : nullptr;
                EXPECT_TRUE(element);
                if (element)
                    EXPECT_EQ(decoded, element->getAttribute(HTMLNames::titleAttr));
            }
        }
    }
}

TEST(WebCoreHTMLParser, FastPathManyAttributes)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto attributes = [](const Node* node) -> String {
        auto* element = dynamicDowncast<Element>(node);
        EXPECT_TRUE(element);
        if (!element || !element->hasAttributes())
            return String();
        StringBuilder builder;
        for (unsigned i = 0; i < element->attributeCount(); ++i) {
            if (i)
                builder.append(' ');
            builder.append(element->attributeAt(i).localName(), '=', element->attributeAt(i).value());
        }
        return builder.toString();
    };

    // An element with 11 attributes, then one with 2, then one with a name that the first element has, in 8-bit and
    // 16-bit input.
    for (bool is8Bit : { true, false }) {
        auto markup = "<div a0=0 a1=1 a2=2 a3=3 a4=4 a5=5 a6=6 a7=7 a8=8 a9=9 a10=10></div><span x=1 y=2></span><b x=3 a5=4 y=5></b>"_s;
        auto input = is8Bit ? String(markup) : sixteenBitString(markup);
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        if (!result)
            continue;
        auto* first = fragment->firstChild();
        EXPECT_EQ("a0=0 a1=1 a2=2 a3=3 a4=4 a5=5 a6=6 a7=7 a8=8 a9=9 a10=10"_s, attributes(first));
        auto* second = first ? first->nextSibling() : nullptr;
        EXPECT_EQ("x=1 y=2"_s, attributes(second));
        auto* third = second ? second->nextSibling() : nullptr;
        EXPECT_EQ("x=3 a5=4 y=5"_s, attributes(third));
    }
}

TEST(WebCoreHTMLParser, FastPathAttributeValueAtWindowEnd)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto attributeValue = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        auto* element = result ? dynamicDowncast<Element>(fragment->firstChild()) : nullptr;
        EXPECT_TRUE(element);
        if (!element || !element->hasAttributes())
            return String();
        return element->attributeAt(0).value();
    };

    // Values that start 15, 16 and 17 characters after the attribute name does, quoted with either quote and
    // containing the other, in 8-bit and 16-bit input. In 16-bit input, also values containing U+0122 and U+0127,
    // whose low bytes are the quotes.
    auto wideValue = makeString('a', static_cast<char16_t>(0x0122), static_cast<char16_t>(0x0127), 'b');
    for (auto name : { "abcdefghijklm"_s, "abcdefghijklmn"_s, "abcdefghijklmno"_s }) {
        for (bool is8Bit : { true, false }) {
            auto input = [&](char quote, const String& value) {
                auto markup = makeString("<span "_s, name, '=', quote, value, quote, "></span>"_s);
                return is8Bit ? markup : sixteenBitString(markup);
            };
            EXPECT_EQ("it's"_s, attributeValue(input('"', "it's"_s)));
            EXPECT_EQ("say \"hi\" to everyone"_s, attributeValue(input('\'', "say \"hi\" to everyone"_s)));
            EXPECT_EQ(emptyString(), attributeValue(input('"', emptyString())));
            EXPECT_EQ(emptyString(), attributeValue(input('\'', emptyString())));
            if (!is8Bit) {
                EXPECT_EQ(wideValue, attributeValue(input('"', wideValue)));
                EXPECT_EQ(wideValue, attributeValue(input('\'', wideValue)));
            }
        }
    }
}

TEST(WebCoreHTMLParser, FastPathTagNameLengths)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    // The names of the fragment's top-level nodes, or "fail" if the fast path does not parse it.
    auto topLevelNames = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        if (!tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent }))
            return "fail"_s;
        StringBuilder builder;
        for (auto* child = fragment->firstChild(); child; child = child->nextSibling()) {
            if (child != fragment->firstChild())
                builder.append(' ');
            builder.append(child->nodeName());
        }
        return builder.toString();
    };

    // Start tags of 6 to 9 letters, and end tags with fewer than 8 characters after them, in 8-bit and 16-bit input.
    for (bool is8Bit : { true, false }) {
        auto names = [&](ASCIILiteral markup) {
            return topLevelNames(is8Bit ? String(markup) : sixteenBitString(markup));
        };
        EXPECT_EQ("BUTTON"_s, names("<button>x</button>"_s));
        EXPECT_EQ("BUTTON"_s, names("<BUTTON>x</BUTTON>"_s));
        EXPECT_EQ("BUTTON"_s, names("<button >x</button >"_s));
        EXPECT_EQ("STRONG #text"_s, names("<strong>x</strong>y"_s));
        EXPECT_EQ("fail"_s, names("<abcdefg>x</abcdefg>"_s));
        EXPECT_EQ("fail"_s, names("<abcdefgh>x</abcdefgh>"_s));
        EXPECT_EQ("fail"_s, names("<abcdefghi>x</abcdefghi>"_s));
        EXPECT_EQ("SPAN BR"_s, names("<span>x</span><br>"_s));
        EXPECT_EQ("B"_s, names("<b>x</b>"_s));
        EXPECT_EQ("B"_s, names("<b>x</B>"_s));
        EXPECT_EQ("fail"_s, names("<span>x</spa>"_s));
        EXPECT_EQ("fail"_s, names("<span>x</span"_s));
        EXPECT_EQ("fail"_s, names("<button>x</butto"_s));
    }

    // U+0162 and U+0142, whose low bytes are 'b' and 'B', in tag names.
    auto wide = [&](char16_t character, ASCIILiteral before, ASCIILiteral after) {
        return topLevelNames(makeString(before, character, after));
    };
    EXPECT_EQ("fail"_s, wide(0x0162, "<"_s, ">x</b>"_s));
    EXPECT_EQ("fail"_s, wide(0x0142, "<b>x</"_s, ">"_s));
    EXPECT_EQ("fail"_s, wide(0x0162, "<b>x</"_s, ">0123456789"_s));
}

TEST(WebCoreHTMLParser, FastPathTextRunLengths)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto firstText = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        auto* text = result ? dynamicDowncast<Text>(fragment->firstChild()) : nullptr;
        EXPECT_TRUE(text);
        EXPECT_TRUE(text && text->nextSibling());
        return text ? text->data() : String();
    };

    // Runs of 15, 16, 17, 31, 32 and 33 characters before a tag, in 8-bit and 16-bit input. In 16-bit input, also runs
    // containing U+0126 and U+013C, whose low bytes are '&' and '<'.
    for (unsigned length : { 15u, 16u, 17u, 31u, 32u, 33u }) {
        auto run = repeatedCharacter('t', length);
        EXPECT_EQ(run, firstText(makeString(run, "<b></b>"_s)));
        EXPECT_EQ(run, firstText(sixteenBitString(makeString(run, "<b></b>"_s))));

        StringBuilder wideRun;
        for (unsigned i = 0; i < length; ++i)
            wideRun.append(i == length / 2 ? u'\u0126' : i == length - 1 ? u'\u013C' : u't');
        auto wideRunString = wideRun.toString();
        EXPECT_EQ(wideRunString, firstText(makeString(wideRunString, "<b></b>"_s)));
    }
}

} // namespace TestWebKitAPI
