// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016 Apple Inc. All rights reserved.
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

#include <array>
#include <wtf/text/StringView.h>

namespace WebCore {

constexpr Latin1Character kEndOfFileMarker = 0;

// A contiguous 8-bit view of an already-preprocessed stylesheet. This is what
// the Swift tokenizer island takes instead of the input stream itself, because
// a token carrying offsets into this span is all CSSParserToken needs — see
// CSSTokenizerSwift.swift.
using CSSTokenizerSpan8 = std::span<const Latin1Character>;
using CSSTokenizerSpan16 = std::span<const char16_t>;

// One token as the Swift tokenizer reports it: offsets into the span above, plus
// the small amount of classification CSSParserToken needs. Everything here is
// resolved against the input by CSSTokenizer::tokenizeWithSwiftIsland.
//
// Defined in C++ rather than in Swift on purpose. WebCore compiles Swift with
// -enable-library-evolution, so a Swift struct exposed with @_expose(Cxx) is
// *resilient*: the generated C++ class wraps a heap-allocated opaque box, has no
// default constructor, and its sizeof() is not the Swift struct's size. That is
// fine for a value returned once, but it cannot be an element type of a buffer
// the two languages share. A plain C++ aggregate can, and Swift imports it
// directly.
// Deliberately no default member initializers: with them the type is not
// trivially default constructible, so WTF's Vector runs initialization over the
// whole buffer (VectorTypeOperations::initializeIfNonPOD) before Swift overwrites
// every byte of it. On a large stylesheet that is tens of megabytes of pointless
// zero stores.
struct CSSSwiftToken {
    // Extent of the token in the input.
    uint32_t start;
    uint32_t end;
    // The token's value text: an ident/at-keyword/hash/string/url name, or the
    // unit of a dimension. Normally a range of the input; a range of the chunk's
    // unescape buffer when `flags` has the unescaped bit set.
    uint32_t valueStart;
    uint32_t valueLength;
    // For numeric tokens, the number's text, which is CSSParserToken's
    // originalText and the range converted to a double.
    uint32_t numberStart;
    uint32_t numberLength;
    // Delimiter code point, or the whitespace run length.
    uint32_t extra;

    uint8_t type;
    uint8_t blockType;
    uint8_t flags;
};

// Tokenizer state carried across chunked calls into the Swift island, so the
// shared token buffer can stay small enough to sit in cache instead of streaming
// one entry per token through memory.
//
// The block stack is a fixed 64 entries. CSS nesting deeper than that sets
// `blockStackOverflowed`, and the caller falls back to the C++ tokenizer rather
// than spilling — Swift has no growable container with inline capacity, and a
// heap-allocated stack here would reintroduce the allocation this is avoiding.
struct CSSSwiftTokenizerState {
    static constexpr unsigned blockStackCapacity = 64;

    uint32_t offset;
    uint32_t blockDepth;
    std::array<uint8_t, blockStackCapacity> blockStack;
    // Code units written to the caller's unescape buffer by this chunk.
    uint32_t unescapedLength;
    bool reachedEnd;
    bool blockStackOverflowed;
    // One value needed more room than the whole unescape buffer: grow it and call
    // again. Only ever set when the chunk produced no tokens at all.
    bool needsMoreUnescapeCapacity;
};

DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(CSSTokenizerInputStream);
class CSSTokenizerInputStream {
    WTF_MAKE_NONCOPYABLE(CSSTokenizerInputStream);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED_WITH_HEAP_IDENTIFIER(CSSTokenizerInputStream, CSSTokenizerInputStream);
public:
    explicit CSSTokenizerInputStream(const String& input);

    // Gets the char in the stream. Will return (NUL) kEndOfFileMarker when at the
    // end of the stream.
    char16_t nextInputChar() const
    {
        if (m_offset >= m_stringLength)
            return kEndOfFileMarker;
        return (*m_string)[m_offset];
    }

    // Gets the char at lookaheadOffset from the current stream position. Will
    // return NUL (kEndOfFileMarker) if the stream position is at the end.
    char16_t peek(unsigned lookaheadOffset) const
    {
        if ((m_offset + lookaheadOffset) >= m_stringLength)
            return kEndOfFileMarker;
        return (*m_string)[m_offset + lookaheadOffset];
    }

    void advance(unsigned offset = 1) { m_offset += offset; }

    // Repositions the cursor. Used by the Swift tokenizer path to re-tokenize a
    // single token whose value contains escapes, with the C++ code below, rather
    // than duplicating the unescaping rules.
    void seek(size_t offset) { m_offset = offset; }

    void pushBack(char16_t cc)
    {
        --m_offset;
        ASSERT_UNUSED(cc, nextInputChar() == cc);
    }

    double getDouble(unsigned start, unsigned end) const;

    template<bool characterPredicate(char16_t)>
    unsigned skipWhilePredicate(unsigned offset)
    {
        if (m_string->is8Bit()) {
            auto characters8 = m_string->span8();
            while ((m_offset + offset) < m_stringLength && characterPredicate(characters8[m_offset + offset]))
                ++offset;
        } else {
            auto characters16 = m_string->span16();
            while ((m_offset + offset) < m_stringLength && characterPredicate(characters16[m_offset + offset]))
                ++offset;
        }
        return offset;
    }

    void advanceUntilNonWhitespace();
    void advanceUntilNewlineOrNonWhitespace();

    unsigned length() const { return m_stringLength; }
    unsigned offset() const { return std::min(m_offset, m_stringLength); }

    // The whole preprocessed input, for the Swift tokenizer path, which takes a
    // contiguous span rather than driving this stream.
    StringView currentString() const LIFETIME_BOUND { return m_string.get(); }

    StringView rangeAt(unsigned start, unsigned length) const
    {
        ASSERT(start + length <= m_stringLength);
        return StringView(m_string.get()).substring(start, length); // FIXME: Should make a constructor on StringView for this.
    }

private:
    size_t m_offset;
    const size_t m_stringLength;
    RefPtr<StringImpl> m_string;
};

} // namespace WebCore
