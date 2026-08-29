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
#include <wtf/text/StringView.h>

// Which scanner CSSTokenizer uses, chosen at compile time. Both are compiled in either way,
// since the comparison tests need both, but only one is reachable from the constructors the
// rest of WebCore calls.
//
// Off by default. Select the Swift scanner by building WebCore with
// WK_USE_SWIFT_CSS_TOKENIZER=YES (Source/WebCore/Configurations/WebCore.xcconfig).
// Tests name their scanner explicitly; webCoreCSSTokenizerDefaultScannerIsSwift() reports which
// one this build defaulted to.
#if !defined(USE_SWIFT_CSS_TOKENIZER)
#define USE_SWIFT_CSS_TOKENIZER 0
#endif

namespace WebCore {

class CSSTokenizerInputStream;
class CSSParserObserverWrapper;
class CSSParserTokenRange;

DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(CSSTokenizer);
class CSSTokenizer {
    WTF_MAKE_NONCOPYABLE(CSSTokenizer);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED_WITH_HEAP_IDENTIFIER(CSSTokenizer, CSSTokenizer);
public:
    static std::unique_ptr<CSSTokenizer> tryCreate(StringView string LIFETIME_BOUND);
    static std::unique_ptr<CSSTokenizer> tryCreate(StringView string LIFETIME_BOUND, CSSParserObserverWrapper&); // For the inspector

    // Which scanner builds the token stream. Both are compiled in; this chooses which one
    // CSSTokenizer uses.
    enum class Scanner : bool { Cpp, Swift };

    static constexpr Scanner defaultScanner =
#if USE_SWIFT_CSS_TOKENIZER
        Scanner::Swift;
#else
        Scanner::Cpp;
#endif

    WEBCORE_EXPORT explicit CSSTokenizer(StringView string LIFETIME_BOUND);
    CSSTokenizer(StringView string LIFETIME_BOUND, CSSParserObserverWrapper&); // For the inspector

    // Builds with a named scanner regardless of `defaultScanner`, so that a test can build both
    // token streams from one source and compare them.
    WEBCORE_EXPORT CSSTokenizer(StringView string LIFETIME_BOUND, Scanner);
    CSSTokenizer(StringView string LIFETIME_BOUND, CSSParserObserverWrapper&, Scanner);

    WEBCORE_EXPORT CSSParserTokenRange NODELETE tokenRange() const LIFETIME_BOUND;
    unsigned NODELETE tokenCount() const;

    static bool NODELETE isWhitespace(CSSParserTokenType);

    // Number of times the Swift scanner failed to allocate. An allocation failure already fails
    // construction directly; this is a cheap second check for tests.
    WEBCORE_EXPORT static unsigned swiftScannerFailureCountForTesting();

    // Forces the Swift scanner to fail after building a chunk, which is the only way to reach
    // the failure-reporting path: in production it is reached only on allocation failure.
    WEBCORE_EXPORT static void setForceSwiftScannerFailureForTesting(bool);

    Vector<String>&& escapedStringsForAdoption() { return WTF::move(m_stringPool); }

private:
    friend class CSSSwiftTokenSink;

    CSSTokenizer(StringView string LIFETIME_BOUND, CSSParserObserverWrapper*, bool* constructionSuccess, Scanner = defaultScanner);

    CSSParserToken nextToken();

    // Fills m_tokens by driving the Swift tokenizer (CSSTokenizerSwift.swift) and converting
    // its tokens, instead of running the C++ state machine below. It handles every input, both
    // of StringImpl's widths, every escape form and unbounded block nesting, and returns false
    // only if m_tokens could not be allocated, which fails construction the same way the C++
    // path's allocation failure does.
    bool tokenizeWithSwiftScanner(CSSParserObserverWrapper*, bool* constructionSuccess);

    char16_t NODELETE consume();
    void NODELETE reconsume(char16_t);

    StringView preprocessString(StringView);

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
    CSSParserToken nameStart(char16_t);
    CSSParserToken stringStart(char16_t);
    CSSParserToken endOfFile(char16_t);

    StringView registerString(String&&);
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
