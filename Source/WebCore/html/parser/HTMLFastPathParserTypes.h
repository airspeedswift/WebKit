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

// Types shared by the HTML fragment fast path's C++ (HTMLDocumentParserFastPath.cpp) and its Swift scanner
// (HTMLFastPathParser.swift). Swift imports this header as WebCore_Private.HTMLFastPathParserTypes, so it includes
// nothing beyond the standard library and WTF's Latin1Character.

#include <cstddef>
#include <cstdint>
#include <span>
#include <wtf/text/Latin1Character.h>

namespace WebCore {

using HTMLFastPathLatin1Span = std::span<const Latin1Character>;
using HTMLFastPathUTF16Span = std::span<const char16_t>;
using HTMLFastPathOpSpan = std::span<uint32_t>;
using HTMLFastPathDecodedSpan = std::span<char16_t>;

// The tags of FOR_EACH_SUPPORTED_TAG, in its order.
enum class HTMLFastPathTag : uint8_t { A, B, Body, Br, Button, Div, Footer, I, Input, Li, Label, Option, Ol, P, Select, Span, Strong, Ul, Unsupported };

// An op's first word is even for a Text, and otherwise has the op in its low 4 bits.
// Text: [length << 1], offset | decoded << 31, the offset being into the decoded characters when decoded is set.
//     Both fit in 31 bits, since an input is at most String::MaxLength (2^31 - 1) code units.
// Whitespace: [Whitespace | spaceCount << 4], '\n' then 0 to 32 spaces, NewlineThenWhitespaceStringsTable's string.
// Element: [Element | tag << 4 | isVoid << 9 | hasDuplicateAttribute << 10], then per attribute: name offset
//     | isDuplicate << 31, name length | folded << 31, value offset, value length | decoded << 31, then
//     HTMLFastPathOpWord::EndOfAttributes, which no name offset can equal. An attribute is a duplicate when its
//     lowercased name equals an earlier one's on the same element.
// End: [End], closing the innermost open container element.
//
// An input of n code units produces at most 2n op words and at most n decoded characters.
enum class HTMLFastPathOp : uint8_t { Text = 0, Element = 1, End = 3, Whitespace = 5 };

enum class HTMLFastPathOpWord : uint32_t { EndOfAttributes = 0xffffffff };

// Consumes the character reference that starts the source, just after its '&', with consumeHTMLEntity, and writes the
// 0 to 3 characters it decodes to at the start of `decoded`, which has room for 3, followed by zeros up to 3. The
// source is `latin1Source` unless that is empty, and then `utf16Source`. Returns how many characters it read, shifted
// left by 2, or'ed with how many it decoded.
uint64_t consumeHTMLEntityForFastPath(HTMLFastPathLatin1Span latin1Source [[clang::noescape]], HTMLFastPathUTF16Span utf16Source [[clang::noescape]], char16_t additionalAllowedCharacter, HTMLFastPathDecodedSpan decoded [[clang::noescape]]);

} // namespace WebCore
