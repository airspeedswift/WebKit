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

// Benchmark bridge for the Swift HTML tokenizer island
// (see ~/Documents/webkit-swift-adoption-notes.md §8).
//
// Exposes two entry points with identical semantics — one implemented in Swift
// (HTMLTokenizerSwift.swift) and one in C++ using WebKit's goto-threading idiom —
// so they can be measured against each other on the same input from
// TestWebKitAPI. `extern "C"` so no header needs exporting.

#include "config.h"

#include "SegmentedString.h"
#include "WebCoreSwift-Generated.h"
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/Latin1Character.h>

namespace WebCore {
namespace {

enum CppTokenizerState {
    DataState, TagOpenState, EndTagOpenState, TagNameState,
    BeforeAttributeNameState, AttributeNameState, AfterAttributeNameState,
    BeforeAttributeValueState, AttributeValueDoubleQuotedState,
    AttributeValueSingleQuotedState, AttributeValueUnquotedState,
    AfterAttributeValueQuotedState, SelfClosingStartTagState,
};

inline bool isTokenizerWhitespaceByte(uint8_t c) { return c == ' ' || c == '\n' || c == '\t' || c == '\f'; }
inline bool isASCIIAlphaByte(uint8_t c) { return ((c | 0x20) >= 'a') && ((c | 0x20) <= 'z'); }

// C++ reference: same 13 states, same name-checksum, using the ADVANCE_TO/goto
// direct-threading idiom from MarkupTokenizerInlines.h.
void tokenizeCpp(std::span<const Latin1Character> input, size_t& tokenCount, uint64_t& checksum)
{
    tokenCount = 0;
    checksum = 0;
    if (input.empty())
        return;

    size_t i = 0;
    CppTokenizerState state = DataState;
    uint8_t character = input[0];

    // Mirrors HTMLTokenSwift: a reused name buffer, cleared per token, summed
    // when a token completes. Without this the C++ does strictly less work than
    // the Swift island and the comparison is meaningless.
    Vector<Latin1Character> name;
    name.reserveInitialCapacity(64);
    auto emit = [&] {
        ++tokenCount;
        for (auto c : name.span())
            checksum += c;
        name.shrink(0);
    };

#define ADVANCE_TO(newState) do { \
        if (++i >= input.size()) { state = newState; goto done; } \
        character = input[i]; \
        goto newState; \
    } while (false)
#define EMIT_AND_ADVANCE() do { emit(); ADVANCE_TO(DataState); } while (false)

    switch (state) {
    DataState: case DataState:
        if (character == '<')
            ADVANCE_TO(TagOpenState);
        {
            // Same plain-text fast path as the Swift island, mirroring
            // findPlainTextInDataState() in HTMLTokenizer.cpp.
            size_t runStart = i;
            while (i < input.size() && input[i] != '<')
                ++i;
            name.append(input.subspan(runStart, i - runStart));
            if (i >= input.size()) {
                state = DataState;
                goto done;
            }
            character = input[i];
            goto DataState;
        }

    TagOpenState: case TagOpenState:
        if (character == '/')
            ADVANCE_TO(EndTagOpenState);
        if (isASCIIAlphaByte(character)) {
            name.append(character | 0x20);
            ADVANCE_TO(TagNameState);
        }
        goto DataState;

    EndTagOpenState: case EndTagOpenState:
        if (isASCIIAlphaByte(character)) {
            name.append(character | 0x20);
            ADVANCE_TO(TagNameState);
        }
        goto DataState;

    TagNameState: case TagNameState:
        if (isTokenizerWhitespaceByte(character))
            ADVANCE_TO(BeforeAttributeNameState);
        if (character == '>')
            EMIT_AND_ADVANCE();
        if (character == '/')
            ADVANCE_TO(SelfClosingStartTagState);
        name.append(character | 0x20);
        ADVANCE_TO(TagNameState);

    BeforeAttributeNameState: case BeforeAttributeNameState:
        if (isTokenizerWhitespaceByte(character))
            ADVANCE_TO(BeforeAttributeNameState);
        if (character == '>')
            EMIT_AND_ADVANCE();
        ADVANCE_TO(AttributeNameState);

    AttributeNameState: case AttributeNameState:
        if (isTokenizerWhitespaceByte(character))
            ADVANCE_TO(AfterAttributeNameState);
        if (character == '=')
            ADVANCE_TO(BeforeAttributeValueState);
        if (character == '>')
            EMIT_AND_ADVANCE();
        ADVANCE_TO(AttributeNameState);

    AfterAttributeNameState: case AfterAttributeNameState:
        if (isTokenizerWhitespaceByte(character))
            ADVANCE_TO(AfterAttributeNameState);
        if (character == '=')
            ADVANCE_TO(BeforeAttributeValueState);
        if (character == '>')
            EMIT_AND_ADVANCE();
        goto AttributeNameState;

    BeforeAttributeValueState: case BeforeAttributeValueState:
        if (isTokenizerWhitespaceByte(character))
            ADVANCE_TO(BeforeAttributeValueState);
        if (character == '"')
            ADVANCE_TO(AttributeValueDoubleQuotedState);
        if (character == '\'')
            ADVANCE_TO(AttributeValueSingleQuotedState);
        goto AttributeValueUnquotedState;

    AttributeValueDoubleQuotedState: case AttributeValueDoubleQuotedState:
        if (character == '"')
            ADVANCE_TO(AfterAttributeValueQuotedState);
        ADVANCE_TO(AttributeValueDoubleQuotedState);

    AttributeValueSingleQuotedState: case AttributeValueSingleQuotedState:
        if (character == '\'')
            ADVANCE_TO(AfterAttributeValueQuotedState);
        ADVANCE_TO(AttributeValueSingleQuotedState);

    AttributeValueUnquotedState: case AttributeValueUnquotedState:
        if (isTokenizerWhitespaceByte(character))
            ADVANCE_TO(BeforeAttributeNameState);
        if (character == '>')
            EMIT_AND_ADVANCE();
        ADVANCE_TO(AttributeValueUnquotedState);

    AfterAttributeValueQuotedState: case AfterAttributeValueQuotedState:
        if (isTokenizerWhitespaceByte(character))
            ADVANCE_TO(BeforeAttributeNameState);
        if (character == '>')
            EMIT_AND_ADVANCE();
        if (character == '/')
            ADVANCE_TO(SelfClosingStartTagState);
        goto BeforeAttributeNameState;

    SelfClosingStartTagState: case SelfClosingStartTagState:
        if (character == '>')
            EMIT_AND_ADVANCE();
        goto BeforeAttributeNameState;
    }

#undef EMIT_AND_ADVANCE
#undef ADVANCE_TO

done:
    if (!name.isEmpty())
        emit();
}

} // namespace
} // namespace WebCore

extern "C" {

WEBCORE_EXPORT void webCoreTokenizeBenchSwift(const uint8_t*, size_t, size_t*, uint64_t*);
WEBCORE_EXPORT void webCoreTokenizeBenchCpp(const uint8_t*, size_t, size_t*, uint64_t*);

WEBCORE_EXPORT void webCoreTokenizeBenchSwift(const uint8_t* data, size_t length, size_t* outTokens, uint64_t* outChecksum)
{
    auto result = WebCore::htmlTokenizeSwiftSpan(unsafeMakeSpan(reinterpret_cast<const Latin1Character*>(data), length));
    *outTokens = static_cast<size_t>(result.getTokenCount());
    *outChecksum = result.getNameChecksum();
}

WEBCORE_EXPORT void webCoreTokenizeBenchCpp(const uint8_t* data, size_t length, size_t* outTokens, uint64_t* outChecksum)
{
    size_t tokens = 0;
    uint64_t checksum = 0;
    WebCore::tokenizeCpp(unsafeMakeSpan(reinterpret_cast<const Latin1Character*>(data), length), tokens, checksum);
    *outTokens = tokens;
    *outChecksum = checksum;
}

} // extern "C"
