// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2024 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#pragma once

#include <WebCore/CSSParserToken.h>
#include <WebCore/CSSTokenizerInputStream.h>
#include <climits>
#include <wtf/SwiftBridging.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Which scanner CSSTokenizer uses, chosen at compile time. Both are compiled in
// either way — the comparison tests need both — but only one is reachable from the
// constructors the rest of WebCore calls.
//
// Off by default: the Swift scanner is validated against the C++ one and matches it
// on everything measured (notes §11i–§11m), but the two are deliberately kept side
// by side for now rather than one replacing the other. Build with
// -DUSE_SWIFT_CSS_TOKENIZER=1 to select it, which is also how to run the layout
// tests against it. If this outlives the experiment it should become a real USE()
// macro rather than a local one.
#if !defined(USE_SWIFT_CSS_TOKENIZER)
#define USE_SWIFT_CSS_TOKENIZER 0
#endif

namespace WebCore {

class CSSTokenizer;
class CSSTokenizerInputStream;
class CSSParserObserverWrapper;
class CSSParserTokenRange;

DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(CSSTokenizer);
class CSSTokenizer {
    WTF_MAKE_NONCOPYABLE(CSSTokenizer);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED_WITH_HEAP_IDENTIFIER(CSSTokenizer, CSSTokenizer);
public:
    static std::unique_ptr<CSSTokenizer> tryCreate(const String&);
    static std::unique_ptr<CSSTokenizer> tryCreate(const String&, CSSParserObserverWrapper&); // For the inspector

    // Which scanner builds the token stream. Both are compiled in; this chooses
    // which one CSSTokenizer uses, and the choice is made at compile time.
    enum class Scanner : bool { Cpp, Swift };

    static constexpr Scanner defaultScanner =
#if USE_SWIFT_CSS_TOKENIZER
        Scanner::Swift;
#else
        Scanner::Cpp;
#endif

    WEBCORE_EXPORT explicit CSSTokenizer(const String&);
    CSSTokenizer(const String&, CSSParserObserverWrapper&); // For the inspector

    // Builds with a named scanner regardless of `defaultScanner`, so a test can
    // build both token streams from one source in one process and compare them.
    // That comparison is what makes keeping two scanners side by side cheap, so it
    // has to work whichever way the compile-time choice went.
    WEBCORE_EXPORT CSSTokenizer(const String&, Scanner);
    CSSTokenizer(const String&, CSSParserObserverWrapper&, Scanner);

    WEBCORE_EXPORT CSSParserTokenRange NODELETE tokenRange() const LIFETIME_BOUND;
    unsigned NODELETE tokenCount();

    static bool NODELETE isWhitespace(CSSParserTokenType);

    // How many times the Swift scanner has declined an input and fallen back to the
    // C++ one. A test that compares the two passes trivially if the Swift scanner
    // silently declined, so tests assert on this.
    WEBCORE_EXPORT static unsigned swiftIslandDeclineCountForTesting();

    Vector<String>&& escapedStringsForAdoption() { return WTF::move(m_stringPool); }

private:
    friend class CSSSwiftTokenSink;

    CSSTokenizer(const String&, CSSParserObserverWrapper*, bool* constructionSuccess, Scanner = defaultScanner);

    CSSParserToken nextToken();

    // Swift tokenizer path (CSSTokenizerSwift.swift, notes §11). Fills m_tokens
    // by driving the Swift island and converting its POD tokens, instead of
    // running the C++ state machine below. Both of StringImpl's widths are
    // handled and the island's block stack grows, so the only decline left is
    // running out of memory, in which case the caller falls back to the C++ path.
    bool tokenizeWithSwiftIsland(CSSParserObserverWrapper*, bool* constructionSuccess);
    bool tokenizeWithSwiftIslandOrDecline(CSSParserObserverWrapper*, bool* constructionSuccess);
    bool appendTokensFromSwiftIsland(std::span<const CSSSwiftToken>, std::span<const char16_t> unescapedUnits, CSSParserObserverWrapper*, unsigned& observerOffset);
    Vector<String>& stringPool() { return m_stringPool; }

    char16_t NODELETE consume();
    void NODELETE reconsume(char16_t);

    String preprocessString(const String&);

    CSSParserToken consumeNumericToken();
    CSSParserToken consumeIdentLikeToken();
    CSSParserToken consumeNumber();
    CSSParserToken consumeStringTokenUntil(char16_t);
    CSSParserToken consumeURLToken();

    void consumeBadUrlRemnants();
    void NODELETE consumeSingleWhitespaceIfNext();
    void NODELETE consumeUntilCommentEndFound();

    bool NODELETE consumeIfNext(char16_t);
    StringView consumeName();
    char32_t consumeEscape();

    bool NODELETE nextTwoCharsAreValidEscape();
    bool NODELETE nextCharsAreNumber(char16_t);
    bool NODELETE nextCharsAreNumber();
    bool NODELETE nextCharsAreIdentifier(char16_t);
    bool NODELETE nextCharsAreIdentifier();

    CSSParserToken blockStart(CSSParserTokenType);
    CSSParserToken blockStart(CSSParserTokenType blockType, CSSParserTokenType, StringView);
    CSSParserToken blockEnd(CSSParserTokenType, CSSParserTokenType startType);

    CSSParserToken newline(char16_t);
    CSSParserToken whitespace(char16_t);
    CSSParserToken leftParenthesis(char16_t);
    CSSParserToken rightParenthesis(char16_t);
    CSSParserToken leftBracket(char16_t);
    CSSParserToken rightBracket(char16_t);
    CSSParserToken leftBrace(char16_t);
    CSSParserToken rightBrace(char16_t);
    CSSParserToken plusOrFullStop(char16_t);
    CSSParserToken comma(char16_t);
    CSSParserToken hyphenMinus(char16_t);
    CSSParserToken asterisk(char16_t);
    CSSParserToken lessThan(char16_t);
    CSSParserToken solidus(char16_t);
    CSSParserToken colon(char16_t);
    CSSParserToken semiColon(char16_t);
    CSSParserToken hash(char16_t);
    CSSParserToken circumflexAccent(char16_t);
    CSSParserToken dollarSign(char16_t);
    CSSParserToken verticalLine(char16_t);
    CSSParserToken tilde(char16_t);
    CSSParserToken commercialAt(char16_t);
    CSSParserToken reverseSolidus(char16_t);
    CSSParserToken asciiDigit(char16_t);
    CSSParserToken letterU(char16_t);
    CSSParserToken nameStart(char16_t);
    CSSParserToken stringStart(char16_t);
    CSSParserToken endOfFile(char16_t);

    StringView registerString(const String&);

    using CodePoint = CSSParserToken (CSSTokenizer::*)(char16_t);
    static const std::array<CodePoint, 128> codePoints;

    Vector<CSSParserTokenType, 8> m_blockStack;
    Vector<CSSParserToken, 32> m_tokens;
    // We only allocate strings when escapes are used.
    Vector<String> m_stringPool;
    CSSTokenizerInputStream m_input;
};


} // namespace WebCore
