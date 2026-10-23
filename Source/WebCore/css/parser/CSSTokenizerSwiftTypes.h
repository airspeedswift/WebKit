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

#pragma once

#include <cstdint>
#include <span>

namespace WebCore {

// The input types of cssTokenize8(), cssTokenize16() and cssHasUnpairedSurrogate(). The scanner reads 8-bit input
// as bytes, so CSSTokenizer passes its Latin1Character span through byteCast.
using CSSTokenizerSpan8 = std::span<const unsigned char>;
using CSSTokenizerSpan16 = std::span<const char16_t>;

// The kinds of token numericToken() appends: a number, a percentage, a dimension whose unit is a range of
// the input, and a dimension whose unit is the pending pooled value.
enum CSSTokenizerNumericKind : uint8_t { CSSTokenizerNumber, CSSTokenizerPercentage, CSSTokenizerDimension, CSSTokenizerPooledDimension };

// Appends the Swift scanner's tokens to CSSTokenizer's token list, one call per token, and feeds the inspector's
// observer. Offsets and lengths index the tokenizer's input; a type is a CSSParserTokenType and a block type a
// CSSParserToken::BlockType. A value the scanner built is first pooled with poolValue(), and the next token
// takes it in place of a range when its pooled flag is set; every token drops a pooled value it did not take.
// numericToken() takes the number's value, or NaN to have the sink convert its text. A member returns false when
// the token could not be allocated. Only CSSTokenizer's constructor makes one, on its stack, and only the scan
// it calls reaches it.
class __attribute__((swift_attr("~Sendable"))) CSSTokenizerSink {
public:
    CSSTokenizerSink(const CSSTokenizerSink&) = delete;
    CSSTokenizerSink& operator=(const CSSTokenizerSink&) = delete;
    [[noreturn]] CSSTokenizerSink(CSSTokenizerSink&&);
    ~CSSTokenizerSink();

    bool hasObserver();

    bool simpleToken(uint8_t type, uint8_t blockType);
    bool whitespaceToken(uint32_t count);
    bool delimiterToken(char16_t);
    bool valueToken(uint8_t type, uint8_t blockType, bool pooled, uint32_t start, uint32_t length);
    bool hashToken(bool isIdentifier, bool pooled, uint32_t start, uint32_t length);
    bool numericToken(CSSTokenizerNumericKind, bool isInteger, uint8_t sign, uint32_t start, uint32_t length, uint32_t unitStart, uint32_t unitLength, double value);

    // Keeps a value the scanner built in the tokenizer's string pool, pending for the next token.
    void poolValue([[clang::noescape]] std::span<const char16_t> value);

    // Called only when hasObserver() is true.
    void observeToken(uint32_t start);
    void observeComment(uint32_t start, uint32_t end);

protected:
    CSSTokenizerSink() = default;
};

} // namespace WebCore
