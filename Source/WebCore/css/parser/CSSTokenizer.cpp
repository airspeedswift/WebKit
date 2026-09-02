// Copyright 2015 The Chromium Authors. All rights reserved.
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

#include "config.h"
#include "CSSTokenizer.h"

#include "CSSParserIdioms.h"
#include "CSSParserObserverWrapper.h"
#include "CSSParserTokenRange.h"
#include "CSSTokenizerInputStream.h"
#include "CSSTokenizerSwiftTypes.h"
// The Swift entry points this file calls. WebCoreSwift-Generated.h is module-scoped, so a
// translation unit that includes it must declare every Swift subsystem's boundary types;
// WebCoreSwiftBoundaryTypes.h is where those declarations go.
#include "WebCoreSwiftBoundaryTypes.h"
#include <atomic>
#include <wtf/NeverDestroyed.h>
#include <wtf/dtoa.h>
#include <wtf/text/CodePointIterator.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/unicode/CharacterNames.h>

namespace WebCore {
DEFINE_ALLOCATOR_WITH_HEAP_IDENTIFIER(CSSTokenizer);

// https://drafts.csswg.org/css-syntax/#input-preprocessing
StringView CSSTokenizer::preprocessString(StringView string)
{
    // We don't replace '\r' and '\f' with '\n' as the specification suggests, instead
    // we treat them all the same in the isCSSNewline() function from CSSParserIdioms.h.

    auto preprocessSpan8 = [&](auto characters) -> StringView {
        // Latin-1 strings only need to replace any null characters.

        size_t indexOfNullCharacter = WTF::find(characters, '\0');
        if (indexOfNullCharacter == notFound)
            return string;

        return registerString(String { StringImpl::createByReplacingInCharacters(characters, '\0', replacementCharacter, indexOfNullCharacter) });
    };

    auto preprocessSpan16 = [&](auto characters) -> StringView {
        // UTF-16 string need to replace any null characters and any unpaired surrogates.

        bool hasUnpairedSurrogate = [&] {
            for (WTF::CodePointIterator<char16_t> iterator(characters); !iterator.atEnd(); ++iterator) {
                if (U_IS_SURROGATE(*iterator))
                    return true;
            }
            return false;
        }();

        if (!hasUnpairedSurrogate) {
            // When there are no unpaired surrogates, we can treat this just like the Latin-1 case.

            size_t indexOfNullCharacter = WTF::find(characters, '\0');
            if (indexOfNullCharacter == notFound)
                return string;

            return registerString(String { StringImpl::createByReplacingInCharacters(characters, '\0', replacementCharacter, indexOfNullCharacter) });
        } else {
            StringBuilder result;
            result.reserveCapacity(string.length());
            for (WTF::CodePointIterator<char16_t> iterator(characters); !iterator.atEnd(); ++iterator) {
                auto codePoint = *iterator;
                if (!codePoint || U_IS_SURROGATE(codePoint))
                    result.append(replacementCharacter);
                else
                    result.append(codePoint);
            }
            return registerString(result.toString());
        }
    };

    if (string.is8Bit())
        return preprocessSpan8(string.span8());
    return preprocessSpan16(string.span16());
}

std::unique_ptr<CSSTokenizer> CSSTokenizer::tryCreate(StringView string)
{
    bool success = true;
    // We can't use makeUnique here because it does not have access to this private constructor.
    auto tokenizer = std::unique_ptr<CSSTokenizer>(new CSSTokenizer(string, nullptr, &success));
    if (!success) [[unlikely]]
        return nullptr;
    return tokenizer;
}

std::unique_ptr<CSSTokenizer> CSSTokenizer::tryCreate(StringView string, CSSParserObserverWrapper& wrapper)
{
    bool success = true;
    // We can't use makeUnique here because it does not have access to this private constructor.
    auto tokenizer = std::unique_ptr<CSSTokenizer>(new CSSTokenizer(string, &wrapper, &success));
    if (!success) [[unlikely]]
        return nullptr;
    return tokenizer;
}

CSSTokenizer::CSSTokenizer(StringView string)
    : CSSTokenizer(string, nullptr, nullptr)
{
}

CSSTokenizer::CSSTokenizer(StringView string, CSSParserObserverWrapper& wrapper)
    : CSSTokenizer(string, &wrapper, nullptr)
{
}

CSSTokenizer::CSSTokenizer(StringView string, Scanner scanner)
    : CSSTokenizer(string, nullptr, nullptr, scanner)
{
}

CSSTokenizer::CSSTokenizer(StringView string, CSSParserObserverWrapper& wrapper, Scanner scanner)
    : CSSTokenizer(string, &wrapper, nullptr, scanner)
{
}

CSSTokenizer::CSSTokenizer(StringView string, CSSParserObserverWrapper* wrapper, bool* constructionSuccessPtr, Scanner scanner)
    : m_input(preprocessString(string))
{
    if (constructionSuccessPtr)
        *constructionSuccessPtr = true;

    // An empty sheet still has to finalise the observer wrapper, exactly as any other input
    // that yields no tokens does: endOffset() computes
    // m_tokenOffsets[range.end() - m_firstParserToken], so returning early would leave it
    // indexing by an unset m_firstParserToken. Non-empty zero-token inputs such as "/* c */"
    // or " " reach the loop below and fall out of it.
    if (string.isEmpty()) {
        if (wrapper) {
            wrapper->addToken(0);
            wrapper->finalizeConstruction(m_tokens.begin());
        }
        return;
    }

    // The Swift scanner, when selected. It handles every input: all 33 token types, both of
    // StringImpl's widths, every escape form, unbounded block nesting. The only way it returns
    // false is a failed allocation of m_tokens, either the reservation or a per-token append,
    // and the C++ scanner below reserves the same size into the same vector, so it would fail
    // on the identical allocation. This therefore reports the failure the way the C++ path
    // reports its own rather than re-running the tokenization.
    if (scanner == Scanner::Swift) {
        if (!tokenizeWithSwiftScanner(wrapper, constructionSuccessPtr)) [[unlikely]] {
            // Same policy as the C++ path below: crash if the caller did not ask to be told.
            RELEASE_ASSERT(constructionSuccessPtr);
            *constructionSuccessPtr = false;
        }
        return;
    }

    // To avoid resizing we err on the side of reserving too much space.
    // Most strings we tokenize have about 3.5 to 5 characters per token.
    if (!m_tokens.tryReserveInitialCapacity(string.length() / 3)) [[unlikely]] {
        // When constructionSuccessPtr is null, our policy is to crash on failure.
        RELEASE_ASSERT(constructionSuccessPtr);
        *constructionSuccessPtr = false;
        return;
    }

    unsigned offset = 0;
    while (true) {
        CSSParserToken token = nextToken();
        if (token.type() == EOFToken)
            break;
        if (token.type() == CommentToken) {
            if (wrapper)
                wrapper->addComment(offset, m_input.offset(), m_tokens.size());
        } else {
            if (!m_tokens.tryAppend(token)) [[unlikely]] {
                // When constructionSuccessPtr is null, our policy is to crash on failure.
                RELEASE_ASSERT(constructionSuccessPtr);
                *constructionSuccessPtr = false;
                return;
            }
            if (wrapper)
                wrapper->addToken(offset);
        }
        offset = m_input.offset();
    }

    if (wrapper) {
        wrapper->addToken(offset);
        wrapper->finalizeConstruction(m_tokens.begin());
    }
}

CSSParserTokenRange CSSTokenizer::tokenRange() const LIFETIME_BOUND
{
    return m_tokens;
}

// MARK: - Swift tokenizer path
//
// See CSSTokenizerSwift.swift. Swift decides token types, extents and block structure; the code
// below materialises that into CSSParserTokens: StringViews over the input, double conversion,
// and the escaped-value string pool.

// BlockType is mirrored as CSSBlockTypeSwift rather than imported, because it is nested inside
// CSSParserToken, and importing it would move 304 use sites for the sake of three asserts.
// CSSParserTokenType itself is imported from CSSParserTokenBits.h and needs no mirror.
static_assert(static_cast<uint8_t>(CSSParserToken::NotBlock) == CSSBlockTypeSwiftNotBlock);
static_assert(static_cast<uint8_t>(CSSParserToken::BlockStart) == CSSBlockTypeSwiftBlockStart);
static_assert(static_cast<uint8_t>(CSSParserToken::BlockEnd) == CSSBlockTypeSwiftBlockEnd);

// A dimension's unit is resolved by the CSS unit-type trie, over the real CSSUnitType, imported
// from CSSUnitType.h through the boundary module, so there is no mirrored numbering to assert
// here.

// The observer record is the one boundary struct still restated on both sides; Swift imports
// CSSParserTokenBits itself, so nothing here can disagree with C++ about a token's layout.
// Twelve bytes and trivially copyable, because production tokenization has no observer and
// writes none of them.
static_assert(sizeof(CSSSwiftObserverRecord) == 12);
static_assert(alignof(CSSSwiftObserverRecord) == 4);
static_assert(std::is_trivially_copyable_v<CSSSwiftObserverRecord>);

// Counts allocation failures during Swift tokenization. A failure makes construction fail
// outright, through RELEASE_ASSERT for the direct constructor and a null return for tryCreate,
// so correctness does not depend on this counter; the test harnesses assert on it as a cheap
// second check.
static std::atomic<unsigned> s_swiftScannerFailureCount;

unsigned CSSTokenizer::swiftScannerFailureCountForTesting()
{
    return s_swiftScannerFailureCount.load(std::memory_order_relaxed);
}

// Test-only. This path fails only when an allocation does, which a test cannot provoke, so this
// is the only way to reach the failure-reporting path. Read once per chunk, after the chunk has
// been appended, so nothing lands in the hot loop.
static std::atomic<bool> s_forceSwiftScannerFailureForTesting;

void CSSTokenizer::setForceSwiftScannerFailureForTesting(bool force)
{
    s_forceSwiftScannerFailureForTesting.store(force, std::memory_order_relaxed);
}

bool CSSTokenizer::tokenizeWithSwiftScanner(CSSParserObserverWrapper* wrapper, bool* constructionSuccessPtr)
{
    auto string = m_input.currentString();

    // Same reservation the C++ path uses.
    if (!m_tokens.tryReserveInitialCapacity(string.length() / 3)) [[unlikely]] {
        s_swiftScannerFailureCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    // Swift owns its buffers and hands each chunk to this sink, so there is nothing to
    // allocate, size, grow or retry here. Both of StringImpl's representations are handled, by
    // two specializations of one Swift implementation; the C++ scanner below instead reads every
    // character through StringImpl::operator[], paying an is8Bit() branch per character.
    Ref sink = adoptRef(*CSSSwiftTokenSink::create(*this, wrapper));
    bool tokenized = string.is8Bit()
        ? cssTokenizeSwiftAll8(string.span8(), sink.ptr())
        : cssTokenizeSwiftAll16(string.span16(), sink.ptr());
    if (!tokenized) [[unlikely]] {
        s_swiftScannerFailureCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    if (constructionSuccessPtr)
        *constructionSuccessPtr = true;
    return true;
}

CSSSwiftTokenSink* CSSSwiftTokenSink::create(CSSTokenizer& tokenizer, CSSParserObserverWrapper* wrapper)
{
    // The width is decided once here, not per chunk and not per token: it is the same branch
    // tokenizeWithSwiftScanner takes to pick which of the two specializations to run. The bytes
    // stay valid because m_input holds a RefPtr<StringImpl> for the whole tokenization, which is
    // the lifetime the Swift entry points document.
    auto string = tokenizer.m_input.currentString();
    if (string.is8Bit())
        return new CSSSwiftTokenSink(tokenizer, wrapper, asBytes(string.span8()), 1);
    return new CSSSwiftTokenSink(tokenizer, wrapper, asBytes(string.span16()), 2);
}

// The annotations have to be repeated on the definition: an unannotated definition is a
// different type in C++, with a different mangled name.
//
// unsafeMakeSpan, and not std::span's two-argument constructor, even though __counted_by has
// declared each pointer's extent: clang rejects that spelling under
// -Wunsafe-buffer-usage-in-container, which WebCore builds as an error, without consulting the
// annotation. unsafeMakeSpan is the sanctioned spelling, and the annotations are what make the
// bound true rather than merely asserted.

void CSSSwiftTokenSink::finish()
{
    if (m_wrapper) {
        m_wrapper->addToken(m_observerOffset);
        m_wrapper->finalizeConstruction(m_tokenizer.m_tokens.begin());
    }
}

// Materialises one chunk of Swift's finished tokens, and feeds the inspector's observer wrapper
// the same offsets the C++ loop would have.
//
// There is no dispatch on a token's kind here: every construction site on the Swift side already
// knows its kind statically. What is left is the work Swift cannot do: an offset becomes a
// pointer, an escaped value becomes a pooled String, and charactersToDouble runs where it always
// ran, so that double rounding matches the C++ scanner's bit for bit.
bool CSSSwiftTokenSink::takeChunk(
    const CSSParserTokenBits *__counted_by(tokenCount) tokens __attribute__((noescape)), size_t tokenCount,
    const char16_t *__counted_by(unitCount) unescapedUnits __attribute__((noescape)), size_t unitCount,
    const CSSSwiftObserverRecord *__counted_by(recordCount) records __attribute__((noescape)), size_t recordCount)
{
    auto tokenBits = unsafeMakeSpan(tokens, tokenCount);
    auto unescaped = unsafeMakeSpan(unescapedUnits, unitCount);
    auto observerRecords = unsafeMakeSpan(records, recordCount);
    auto& parserTokens = m_tokenizer.m_tokens;
    // The input's length in code units, which is what the parked number range below is bounded
    // against.
    unsigned inputLength = m_tokenizer.m_input.length();

    // Where this chunk's first token lands, which is what addComment's `tokensBefore` counts.
    // Read before anything is appended, because the observer walk below runs afterwards.
    unsigned firstTokenIndex = parserTokens.size();

    // The input's width, read once for the whole chunk rather than once per token: it is fixed
    // for the tokenization, so the resolve below is specialized on it and neither of the two
    // scalings a value offset needs survives as a multiply. Read from the sink and not from a
    // token's own valueIs8Bit, which would make the scale factor of a bounds check a number
    // Swift supplied, and a check must not take its dimensions from the thing it is checking.
    bool inputIs8Bit = m_characterSize == 1;

    for (auto bits : tokenBits) {
        auto parkedOffset = bitsParkedValueOffset(bits);
        if (parkedOffset & cssParserTokenBitsUnescapedValueTag) [[unlikely]] {
            // A value Swift unescaped: its range indexes the unescape buffer rather than the
            // input, and it has to become a real String in m_stringPool. create8BitIfPossible to
            // match what the C++ path's StringBuilder produces, so that the two paths agree on
            // the string's representation as well as on its contents. Necessarily inside this
            // call: the unescape buffer is per chunk, and Swift clears it on return.
            auto units = unescaped.subspan(parkedOffset & ~cssParserTokenBitsUnescapedValueTag, bits.valueLength);
            auto value = m_tokenizer.registerString(String { StringImpl::create8BitIfPossible(units) });
            bits.valueLength = value.length();
            bits.valueIs8Bit = value.is8Bit();
            bits.valueDataCharRaw = value.rawCharacters();
        } else if (inputIs8Bit)
            resolveValuePointer<1>(bits, m_inputBytes);
        else
            resolveValuePointer<2>(bits, m_inputBytes);

        if (bitsCarryPendingNumber(bits)) {
            // The number's own range is parked in the union instead of a double, because after
            // a dimension's number and unit have been merged into one view the number is not
            // recoverable from value(). Both the discriminant and the range are checked before
            // the read: bitsCarryPendingNumber is a function of the token's type, so on its own
            // it cannot tell a token makeNumericTokenBits produced from one whose numeric type
            // came from another factory, whose numericValue would then be read out as an offset
            // and a length. The range itself is bounded against the input the way every other
            // offset crossing this boundary is, since rangeAt's own check is an ASSERT that is
            // compiled out and StringView::substring merely clamps, which would turn a bad range
            // into a silently wrong number rather than a caught one.
            if (!bits.hasParkedNumberRange) [[unlikely]]
                return false;
            auto range = bits.pendingNumberRange;
            if (range.length > inputLength || range.offset > inputLength - range.length) [[unlikely]]
                return false;
            auto numberText = m_tokenizer.m_input.rangeAt(range.offset, range.length);
            bool isResultOK = false;
            double numericValue = numberText.is8Bit()
                ? charactersToDouble(numberText.span8(), &isResultOK)
                : charactersToDouble(numberText.span16(), &isResultOK);
            bits.numericValue = isResultOK ? numericValue : 0;
            // The range is gone once the double exists, so the discriminant has to say so.
            bits.hasParkedNumberRange = 0;
        }

        // No reservation here beyond the one tokenizeWithSwiftScanner already made:
        // Vector::reserveCapacity reserves exactly what it is asked for, so a per-chunk
        // `size() + tokenCount` would reallocate every 1024 tokens on any input denser than the
        // three-characters-per-token estimate, whereas tryAppend's own growth is geometric.
        //
        // tryAppend of a temporary rather than tryConstructAndAppend(bits), because the
        // bits-taking constructor is private to this class: Vector constructs in place, so the
        // access check for tryConstructAndAppend is made inside Vector and friendship would have
        // to name Vector.
        if (!parserTokens.tryAppend(CSSParserToken { bits })) [[unlikely]]
            return false;
    }

    // The observer walk. Empty unless wantsObserverRecords() said otherwise, so production
    // tokenization does not reach it. addToken and addComment append to two separate vectors and
    // need not interleave, but m_tokenOffsets has to be in strict token order and
    // m_commentOffsets ascending by tokensBefore, which source order gives for free.
    if (auto* wrapper = m_wrapper) {
        // The tokens and the observer records are two parallel buffers, appended in lockstep by
        // Swift, one record per token plus one per comment, in source order, and nothing about
        // either buffer's shape enforces that. A desync hands addToken and addComment the offsets
        // belonging to a different token, producing silently wrong source ranges in Web
        // Inspector, so the relation is checked before the walk rather than asserted: an ASSERT
        // is compiled out of exactly the builds where this would matter.
        size_t recordedTokens = 0;
        for (auto& record : observerRecords) {
            if (!record.isComment)
                ++recordedTokens;
        }
        if (recordedTokens != tokenCount) [[unlikely]]
            return false;

        unsigned tokenIndex = firstTokenIndex;
        for (auto& record : observerRecords) {
            if (record.isComment)
                wrapper->addComment(record.start, record.end, tokenIndex);
            else {
                wrapper->addToken(record.start);
                ++tokenIndex;
            }
            m_observerOffset = record.end;
        }
    } else if (recordCount) [[unlikely]] {
        // wantsObserverRecords() is m_wrapper, and Swift asks once per tokenization, so records
        // arriving without a wrapper mean it ignored the answer.
        return false;
    }

    return !s_forceSwiftScannerFailureForTesting.load(std::memory_order_relaxed);
}

unsigned CSSTokenizer::tokenCount() const
{
    return m_tokens.size();
}

bool CSSTokenizer::isWhitespace(CSSParserTokenType type)
{
    return type == NonNewlineWhitespaceToken || type == NewlineToken;
}

CSSParserToken CSSTokenizer::newline(char16_t)
{
    return CSSParserToken(NewlineToken);
}

// http://dev.w3.org/csswg/css-syntax/#check-if-two-code-points-are-a-valid-escape
static bool NODELETE twoCharsAreValidEscape(char16_t first, char16_t second)
{
    return first == '\\' && !isCSSNewline(second);
}

void CSSTokenizer::reconsume(char16_t c)
{
    m_input.pushBack(c);
}

char16_t CSSTokenizer::consume()
{
    char16_t current = m_input.nextInputChar();
    m_input.advance();
    return current;
}

CSSParserToken CSSTokenizer::whitespace(char16_t)
{
    auto startOffset = m_input.offset();
    m_input.advanceUntilNewlineOrNonWhitespace();
    auto whitespaceCount = 1 + (m_input.offset() - startOffset);
    return CSSParserToken(whitespaceCount);
}

CSSParserToken CSSTokenizer::blockStart(CSSParserTokenType type)
{
    m_blockStack.append(type);
    return CSSParserToken(type, CSSParserToken::BlockStart);
}

CSSParserToken CSSTokenizer::blockStart(CSSParserTokenType blockType, CSSParserTokenType type, StringView name)
{
    m_blockStack.append(blockType);
    return CSSParserToken(type, name, CSSParserToken::BlockStart);
}

CSSParserToken CSSTokenizer::blockEnd(CSSParserTokenType type, CSSParserTokenType startType)
{
    if (!m_blockStack.isEmpty() && m_blockStack.last() == startType) {
        m_blockStack.removeLast();
        return CSSParserToken(type, CSSParserToken::BlockEnd);
    }
    return CSSParserToken(type);
}

CSSParserToken CSSTokenizer::leftParenthesis(char16_t)
{
    return blockStart(LeftParenthesisToken);
}

CSSParserToken CSSTokenizer::rightParenthesis(char16_t)
{
    return blockEnd(RightParenthesisToken, LeftParenthesisToken);
}

CSSParserToken CSSTokenizer::leftBracket(char16_t)
{
    return blockStart(LeftBracketToken);
}

CSSParserToken CSSTokenizer::rightBracket(char16_t)
{
    return blockEnd(RightBracketToken, LeftBracketToken);
}

CSSParserToken CSSTokenizer::leftBrace(char16_t)
{
    return blockStart(LeftBraceToken);
}

CSSParserToken CSSTokenizer::rightBrace(char16_t)
{
    return blockEnd(RightBraceToken, LeftBraceToken);
}

CSSParserToken CSSTokenizer::plusOrFullStop(char16_t cc)
{
    if (nextCharsAreNumber(cc)) {
        reconsume(cc);
        return consumeNumericToken();
    }
    return CSSParserToken(DelimiterToken, cc);
}

CSSParserToken CSSTokenizer::asterisk(char16_t cc)
{
    ASSERT_UNUSED(cc, cc == '*');
    if (consumeIfNext('='))
        return CSSParserToken(SubstringMatchToken);
    return CSSParserToken(DelimiterToken, '*');
}

CSSParserToken CSSTokenizer::lessThan(char16_t cc)
{
    ASSERT_UNUSED(cc, cc == '<');
    if (m_input.peek(0) == '!' && m_input.peek(1) == '-' && m_input.peek(2) == '-') {
        m_input.advance(3);
        return CSSParserToken(CDOToken);
    }
    return CSSParserToken(DelimiterToken, '<');
}

CSSParserToken CSSTokenizer::comma(char16_t)
{
    return CSSParserToken(CommaToken);
}

CSSParserToken CSSTokenizer::hyphenMinus(char16_t cc)
{
    if (nextCharsAreNumber(cc)) {
        reconsume(cc);
        return consumeNumericToken();
    }
    if (m_input.peek(0) == '-' && m_input.peek(1) == '>') {
        m_input.advance(2);
        return CSSParserToken(CDCToken);
    }
    if (nextCharsAreIdentifier(cc)) {
        reconsume(cc);
        return consumeIdentLikeToken();
    }
    return CSSParserToken(DelimiterToken, cc);
}

CSSParserToken CSSTokenizer::solidus(char16_t cc)
{
    if (consumeIfNext('*')) {
        // These get ignored, but we need a value to return.
        consumeUntilCommentEndFound();
        return CSSParserToken(CommentToken);
    }

    return CSSParserToken(DelimiterToken, cc);
}

CSSParserToken CSSTokenizer::colon(char16_t)
{
    return CSSParserToken(ColonToken);
}

CSSParserToken CSSTokenizer::semiColon(char16_t)
{
    return CSSParserToken(SemicolonToken);
}

CSSParserToken CSSTokenizer::hash(char16_t cc)
{
    char16_t nextChar = m_input.peek(0);
    if (isNameCodePoint(nextChar) || twoCharsAreValidEscape(nextChar, m_input.peek(1))) {
        HashTokenType type = nextCharsAreIdentifier() ? HashTokenId : HashTokenUnrestricted;
        return CSSParserToken(type, consumeName());
    }

    return CSSParserToken(DelimiterToken, cc);
}

CSSParserToken CSSTokenizer::circumflexAccent(char16_t cc)
{
    ASSERT_UNUSED(cc, cc == '^');
    if (consumeIfNext('='))
        return CSSParserToken(PrefixMatchToken);
    return CSSParserToken(DelimiterToken, '^');
}

CSSParserToken CSSTokenizer::dollarSign(char16_t cc)
{
    ASSERT_UNUSED(cc, cc == '$');
    if (consumeIfNext('='))
        return CSSParserToken(SuffixMatchToken);
    return CSSParserToken(DelimiterToken, '$');
}

CSSParserToken CSSTokenizer::verticalLine(char16_t cc)
{
    ASSERT_UNUSED(cc, cc == '|');
    if (consumeIfNext('='))
        return CSSParserToken(DashMatchToken);
    if (consumeIfNext('|'))
        return CSSParserToken(ColumnToken);
    return CSSParserToken(DelimiterToken, '|');
}

CSSParserToken CSSTokenizer::tilde(char16_t cc)
{
    ASSERT_UNUSED(cc, cc == '~');
    if (consumeIfNext('='))
        return CSSParserToken(IncludeMatchToken);
    return CSSParserToken(DelimiterToken, '~');
}

CSSParserToken CSSTokenizer::commercialAt(char16_t cc)
{
    ASSERT_UNUSED(cc, cc == '@');
    if (nextCharsAreIdentifier())
        return CSSParserToken(AtKeywordToken, consumeName());
    return CSSParserToken(DelimiterToken, '@');
}

CSSParserToken CSSTokenizer::reverseSolidus(char16_t cc)
{
    if (twoCharsAreValidEscape(cc, m_input.peek(0))) {
        reconsume(cc);
        return consumeIdentLikeToken();
    }
    return CSSParserToken(DelimiterToken, cc);
}

CSSParserToken CSSTokenizer::asciiDigit(char16_t cc)
{
    reconsume(cc);
    return consumeNumericToken();
}

CSSParserToken CSSTokenizer::nameStart(char16_t cc)
{
    reconsume(cc);
    return consumeIdentLikeToken();
}

CSSParserToken CSSTokenizer::stringStart(char16_t cc)
{
    return consumeStringTokenUntil(cc);
}

CSSParserToken CSSTokenizer::endOfFile(char16_t)
{
    return CSSParserToken(EOFToken);
}

const std::array<CSSTokenizer::CodePoint, 128> CSSTokenizer::codePoints {
    &CSSTokenizer::endOfFile,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    &CSSTokenizer::whitespace,
    &CSSTokenizer::newline, // '\n'
    0,
    &CSSTokenizer::newline, // '\f'
    &CSSTokenizer::newline, // '\r'
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    &CSSTokenizer::whitespace,
    0,
    &CSSTokenizer::stringStart,
    &CSSTokenizer::hash,
    &CSSTokenizer::dollarSign,
    0,
    0,
    &CSSTokenizer::stringStart,
    &CSSTokenizer::leftParenthesis,
    &CSSTokenizer::rightParenthesis,
    &CSSTokenizer::asterisk,
    &CSSTokenizer::plusOrFullStop,
    &CSSTokenizer::comma,
    &CSSTokenizer::hyphenMinus,
    &CSSTokenizer::plusOrFullStop,
    &CSSTokenizer::solidus,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::asciiDigit,
    &CSSTokenizer::colon,
    &CSSTokenizer::semiColon,
    &CSSTokenizer::lessThan,
    0,
    0,
    0,
    &CSSTokenizer::commercialAt,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::leftBracket,
    &CSSTokenizer::reverseSolidus,
    &CSSTokenizer::rightBracket,
    &CSSTokenizer::circumflexAccent,
    &CSSTokenizer::nameStart,
    0,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::nameStart,
    &CSSTokenizer::leftBrace,
    &CSSTokenizer::verticalLine,
    &CSSTokenizer::rightBrace,
    &CSSTokenizer::tilde,
    0,
};
#if !ASSERT_WITH_SECURITY_IMPLICATION_DISABLED
const unsigned codePointsNumber = 128;
#endif

CSSParserToken CSSTokenizer::nextToken()
{
    // Unlike the HTMLTokenizer, the CSS Syntax spec is written
    // as a stateless, (fixed-size) look-ahead tokenizer.
    // We could move to the stateful model and instead create
    // states for all the "next 3 codepoints are X" cases.
    // State-machine tokenizers are easier to write to handle
    // incremental tokenization of partial sources.
    // However, for now we follow the spec exactly.
    char16_t cc = consume();
    CodePoint codePointFunc = 0;

    if (isASCII(cc)) {
        ASSERT_WITH_SECURITY_IMPLICATION(cc < codePointsNumber);
        codePointFunc = codePoints[cc];
    } else
        codePointFunc = &CSSTokenizer::nameStart;

    if (codePointFunc)
        return ((this)->*(codePointFunc))(cc);
    return CSSParserToken(DelimiterToken, cc);
}

// This method merges the following spec sections for efficiency
// http://www.w3.org/TR/css3-syntax/#consume-a-number
// http://www.w3.org/TR/css3-syntax/#convert-a-string-to-a-number
CSSParserToken CSSTokenizer::consumeNumber()
{
    ASSERT(nextCharsAreNumber());

    auto startOffset = m_input.offset();

    NumericValueType type = IntegerValueType;
    NumericSign sign = NoSign;
    unsigned numberLength = 0;

    char16_t next = m_input.peek(0);
    if (next == '+') {
        ++numberLength;
        sign = PlusSign;
    } else if (next == '-') {
        ++numberLength;
        sign = MinusSign;
    }

    numberLength = m_input.skipWhilePredicate<isASCIIDigit>(numberLength);
    next = m_input.peek(numberLength);
    if (next == '.' && isASCIIDigit(m_input.peek(numberLength + 1))) {
        type = NumberValueType;
        numberLength = m_input.skipWhilePredicate<isASCIIDigit>(numberLength + 2);
        next = m_input.peek(numberLength);
    }

    if (next == 'E' || next == 'e') {
        next = m_input.peek(numberLength + 1);
        if (isASCIIDigit(next)) {
            type = NumberValueType;
            numberLength = m_input.skipWhilePredicate<isASCIIDigit>(numberLength + 1);
        } else if ((next == '+' || next == '-') && isASCIIDigit(m_input.peek(numberLength + 2))) {
            type = NumberValueType;
            numberLength = m_input.skipWhilePredicate<isASCIIDigit>(numberLength + 3);
        }
    }

    double value = m_input.getDouble(0, numberLength);
    m_input.advance(numberLength);

    return CSSParserToken(value, type, sign, m_input.rangeAt(startOffset, m_input.offset() - startOffset));
}

// http://www.w3.org/TR/css3-syntax/#consume-a-numeric-token
CSSParserToken CSSTokenizer::consumeNumericToken()
{
    CSSParserToken token = consumeNumber();
    if (nextCharsAreIdentifier())
        token.convertToDimensionWithUnit(consumeName());
    else if (consumeIfNext('%'))
        token.convertToPercentage();
    return token;
}

// http://dev.w3.org/csswg/css-syntax/#consume-ident-like-token
CSSParserToken CSSTokenizer::consumeIdentLikeToken()
{
    StringView name = consumeName();
    if (consumeIfNext('(')) {
        if (equalLettersIgnoringASCIICase(name, "url"_s)) {
            // The spec is slightly different so as to avoid dropping whitespace
            // tokens, but they wouldn't be used and this is easier.
            m_input.advanceUntilNonWhitespace();
            char16_t next = m_input.peek(0);
            if (next != '"' && next != '\'')
                return consumeURLToken();
        }
        return blockStart(LeftParenthesisToken, FunctionToken, name);
    }
    return CSSParserToken(IdentToken, name);
}

// http://dev.w3.org/csswg/css-syntax/#consume-a-string-token
CSSParserToken CSSTokenizer::consumeStringTokenUntil(char16_t endingCodePoint)
{
    // Strings without escapes get handled without allocations
    for (unsigned size = 0; ; size++) {
        char16_t cc = m_input.peek(size);
        if (cc == endingCodePoint) {
            unsigned startOffset = m_input.offset();
            m_input.advance(size + 1);
            return CSSParserToken(StringToken, m_input.rangeAt(startOffset, size));
        }
        if (isCSSNewline(cc)) {
            m_input.advance(size);
            return CSSParserToken(BadStringToken);
        }
        if (cc == kEndOfFileMarker || cc == '\\')
            break;
    }

    StringBuilder output;
    while (true) {
        char16_t cc = consume();
        if (cc == endingCodePoint || cc == kEndOfFileMarker)
            return CSSParserToken(StringToken, registerString(output.toString()));
        if (isCSSNewline(cc)) {
            reconsume(cc);
            return CSSParserToken(BadStringToken);
        }
        if (cc == '\\') {
            if (m_input.nextInputChar() == kEndOfFileMarker)
                continue;
            if (isCSSNewline(m_input.peek(0)))
                consumeSingleWhitespaceIfNext(); // This handles \r\n for us
            else
                output.append(consumeEscape());
        } else
            output.append(cc);
    }
}

// http://dev.w3.org/csswg/css-syntax/#non-printable-code-point
static bool NODELETE isNonPrintableCodePoint(char16_t cc)
{
    return cc <= '\x8' || cc == '\xb' || (cc >= '\xe' && cc <= '\x1f') || cc == '\x7f';
}

// http://dev.w3.org/csswg/css-syntax/#consume-url-token
CSSParserToken CSSTokenizer::consumeURLToken()
{
    m_input.advanceUntilNonWhitespace();

    // URL tokens without escapes get handled without allocations
    for (unsigned size = 0; ; size++) {
        char16_t cc = m_input.peek(size);
        if (cc == ')') {
            unsigned startOffset = m_input.offset();
            m_input.advance(size + 1);
            return CSSParserToken(UrlToken, m_input.rangeAt(startOffset, size));
        }
        if (cc <= ' ' || cc == '\\' || cc == '"' || cc == '\'' || cc == '(' || cc == '\x7f')
            break;
    }

    StringBuilder result;
    while (true) {
        char16_t cc = consume();
        if (cc == ')' || cc == kEndOfFileMarker)
            return CSSParserToken(UrlToken, registerString(result.toString()));

        if (isASCIIWhitespace(cc)) {
            m_input.advanceUntilNonWhitespace();
            if (consumeIfNext(')') || m_input.nextInputChar() == kEndOfFileMarker)
                return CSSParserToken(UrlToken, registerString(result.toString()));
            break;
        }

        if (cc == '"' || cc == '\'' || cc == '(' || isNonPrintableCodePoint(cc))
            break;

        if (cc == '\\') {
            if (twoCharsAreValidEscape(cc, m_input.peek(0))) {
                result.append(consumeEscape());
                continue;
            }
            break;
        }

        result.append(cc);
    }

    consumeBadUrlRemnants();
    return CSSParserToken(BadUrlToken);
}

// http://dev.w3.org/csswg/css-syntax/#consume-the-remnants-of-a-bad-url
void CSSTokenizer::consumeBadUrlRemnants()
{
    while (true) {
        char16_t cc = consume();
        if (cc == ')' || cc == kEndOfFileMarker)
            return;
        if (twoCharsAreValidEscape(cc, m_input.peek(0)))
            consumeEscape();
    }
}

void CSSTokenizer::consumeSingleWhitespaceIfNext()
{
    // We check for \r\n and ASCII whitespace since we don't do preprocessing
    char16_t next = m_input.peek(0);
    if (next == '\r' && m_input.peek(1) == '\n')
        m_input.advance(2);
    else if (isASCIIWhitespace(next))
        m_input.advance();
}

void CSSTokenizer::consumeUntilCommentEndFound()
{
    char16_t c = consume();
    while (true) {
        if (c == kEndOfFileMarker)
            return;
        if (c != '*') {
            c = consume();
            continue;
        }
        c = consume();
        if (c == '/')
            return;
    }
}

bool CSSTokenizer::consumeIfNext(char16_t character)
{
    // Since we're not doing replacement we can't tell the difference from
    // a NUL in the middle and the kEndOfFileMarker, so character must not be
    // NUL.
    ASSERT(character);
    if (m_input.peek(0) == character) {
        m_input.advance();
        return true;
    }
    return false;
}

// http://www.w3.org/TR/css3-syntax/#consume-a-name
StringView CSSTokenizer::consumeName()
{
    // Names without escapes get handled without allocations
    for (unsigned size = 0; ; ++size) {
        char16_t cc = m_input.peek(size);
        if (isNameCodePoint(cc))
            continue;
        // peek will return NUL when we hit the end of the
        // input. In that case we want to still use the rangeAt() fast path
        // below.
        if (cc == kEndOfFileMarker && m_input.offset() + size < m_input.length())
            break;
        if (cc == '\\')
            break;
        unsigned startOffset = m_input.offset();
        m_input.advance(size);
        return m_input.rangeAt(startOffset, size);
    }

    StringBuilder result;
    while (true) {
        char16_t cc = consume();
        if (isNameCodePoint(cc)) {
            result.append(cc);
            continue;
        }
        if (twoCharsAreValidEscape(cc, m_input.peek(0))) {
            result.append(consumeEscape());
            continue;
        }
        reconsume(cc);
        return registerString(result.toString());
    }
}

// http://dev.w3.org/csswg/css-syntax/#consume-an-escaped-code-point
char32_t CSSTokenizer::consumeEscape()
{
    char16_t cc = consume();
    ASSERT(!isCSSNewline(cc));
    if (isASCIIHexDigit(cc)) {
        uint32_t codePoint = toASCIIHexValue(cc);
        unsigned consumedHexDigits = 1;
        while (consumedHexDigits < 6 && isASCIIHexDigit(m_input.peek(0))) {
            cc = consume();
            codePoint = codePoint * 16 + toASCIIHexValue(cc);
            consumedHexDigits++;
        }
        consumeSingleWhitespaceIfNext();
        if (!codePoint || U_IS_SURROGATE(codePoint) || codePoint > UCHAR_MAX_VALUE)
            return replacementCharacter;
        return codePoint;
    }

    if (cc == kEndOfFileMarker)
        return replacementCharacter;
    return cc;
}

bool CSSTokenizer::nextTwoCharsAreValidEscape()
{
    return twoCharsAreValidEscape(m_input.peek(0), m_input.peek(1));
}

// http://www.w3.org/TR/css3-syntax/#starts-with-a-number
bool CSSTokenizer::nextCharsAreNumber(char16_t first)
{
    char16_t second = m_input.peek(0);
    if (isASCIIDigit(first))
        return true;
    if (first == '+' || first == '-')
        return ((isASCIIDigit(second)) || (second == '.' && isASCIIDigit(m_input.peek(1))));
    if (first =='.')
        return (isASCIIDigit(second));
    return false;
}

bool CSSTokenizer::nextCharsAreNumber()
{
    char16_t first = consume();
    bool areNumber = nextCharsAreNumber(first);
    reconsume(first);
    return areNumber;
}

// http://dev.w3.org/csswg/css-syntax/#would-start-an-identifier
bool CSSTokenizer::nextCharsAreIdentifier(char16_t first)
{
    char16_t second = m_input.peek(0);
    if (isNameStartCodePoint(first) || twoCharsAreValidEscape(first, second))
        return true;

    if (first == '-')
        return isNameStartCodePoint(second) || second == '-' || nextTwoCharsAreValidEscape();

    return false;
}

bool CSSTokenizer::nextCharsAreIdentifier()
{
    char16_t first = consume();
    bool areIdentifier = nextCharsAreIdentifier(first);
    reconsume(first);
    return areIdentifier;
}

StringView CSSTokenizer::registerString(String&& string)
{
    m_stringPool.append(WTF::move(string));
    return m_stringPool.last();
}

StringView CSSTokenizer::registerString(const String& string)
{
    m_stringPool.append(string);
    return string;
}

} // namespace WebCore
