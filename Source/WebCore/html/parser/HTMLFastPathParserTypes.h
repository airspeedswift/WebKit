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

// Declarations for the HTML fragment fast path's Swift (HTMLFastPathParser.swift), which imports this header as
// WebCore_Private.HTMLFastPathParserTypes, so it includes nothing beyond the standard library and WTF.

#include <cstddef>
#include <cstdint>
#include <span>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

using HTMLFastPathLatin1Span = std::span<const Latin1Character>;
using HTMLFastPathUTF16Span = std::span<const char16_t>;

// consumeHTMLEntity on the source after a '&', writing up to 3 characters at decodedOffset of decoded. Returns
// (characters read << 2) | characters written. The source is latin1Source unless it is empty.
uint64_t consumeHTMLEntityForFastPath(HTMLFastPathLatin1Span latin1Source NOESCAPE, HTMLFastPathUTF16Span utf16Source NOESCAPE, char16_t additionalAllowedCharacter, std::span<char16_t> decoded NOESCAPE, size_t decodedOffset);

// '\n' followed by spaceCount spaces, at most 32, from NewlineThenWhitespaceStringsTable.
String newlineThenWhitespaceStringForFastPath(unsigned spaceCount);

} // namespace WebCore
