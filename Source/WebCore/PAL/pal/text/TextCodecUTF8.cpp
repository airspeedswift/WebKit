/*
 * Copyright (C) 2004-2020 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "TextCodecUTF8.h"

#include "TextCodecASCIIFastPath.h"
#include <pal/text/TextCodecUTF8SwiftTypes.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/CString.h>
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringBuffer.h>
#include <wtf/text/WTFString.h>
#include <wtf/unicode/CharacterNames.h>

// Off by default. Select it by building PAL with WK_USE_SWIFT_TEXT_CODEC_UTF8=YES
// (Source/WebCore/PAL/Configurations/PAL.xcconfig).
#if !defined(USE_SWIFT_TEXT_CODEC_UTF8)
#define USE_SWIFT_TEXT_CODEC_UTF8 0
#endif

#if USE_SWIFT_TEXT_CODEC_UTF8
// The Swift entry point this file calls, plus every other PAL Swift boundary's types along with
// it -- PALSwift-Generated.h is module-scoped, so a translation unit that includes it must
// declare all of them. PALSwiftBoundaryTypes.h says why, and is the file a new Swift boundary
// edits.
#include "PALSwiftBoundaryTypes.h"
#endif


namespace PAL {

WTF_MAKE_TZONE_ALLOCATED_IMPL(TextCodecUTF8);

using namespace WTF::Unicode;

const int nonCharacter = -1;

TextCodecUTF8SwiftCounters& textCodecUTF8SwiftCounters()
{
    static NeverDestroyed<TextCodecUTF8SwiftCounters> counters;
    return counters.get();
}

void TextCodecUTF8::registerEncodingNames(EncodingNameRegistrar registrar)
{
    // From https://encoding.spec.whatwg.org.
    registrar("UTF-8"_s, "UTF-8"_s);
    registrar("utf8"_s, "UTF-8"_s);
    registrar("unicode-1-1-utf-8"_s, "UTF-8"_s);

    // Additional aliases that originally were present in the encoding
    // table in WebKit on Macintosh, and subsequently added by
    // TextCodecICU. Perhaps we can prove some are not used on the web
    // and remove them.
    registrar("unicode11utf8"_s, "UTF-8"_s);
    registrar("unicode20utf8"_s, "UTF-8"_s);
    registrar("x-unicode20utf8"_s, "UTF-8"_s);
}

std::unique_ptr<TextCodecUTF8> TextCodecUTF8::codec()
{
    return makeUnique<TextCodecUTF8>();
}

void TextCodecUTF8::registerCodecs(TextCodecRegistrar registrar)
{
    registrar("UTF-8"_s, [] {
        return codec();
    });
}

static inline uint8_t NODELETE nonASCIISequenceLength(uint8_t firstByte)
{
    static constexpr std::array<uint8_t, 256> lengths {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    };
    return lengths[firstByte];
}

static inline int NODELETE decodeNonASCIISequence(std::span<const uint8_t> sequence, uint8_t& length)
{
    ASSERT(!isASCII(sequence[0]));
    if (length == 2) {
        ASSERT(sequence[0] >= 0xC2);
        ASSERT(sequence[0] <= 0xDF);
        if (sequence[1] < 0x80 || sequence[1] > 0xBF) {
            length = 1;
            return nonCharacter;
        }
        return ((sequence[0] << 6) + sequence[1]) - 0x00003080;
    }
    if (length == 3) {
        ASSERT(sequence[0] >= 0xE0);
        ASSERT(sequence[0] <= 0xEF);
        switch (sequence[0]) {
        case 0xE0:
            if (sequence[1] < 0xA0 || sequence[1] > 0xBF) {
                length = 1;
                return nonCharacter;
            }
            break;
        case 0xED:
            if (sequence[1] < 0x80 || sequence[1] > 0x9F) {
                length = 1;
                return nonCharacter;
            }
            break;
        default:
            if (sequence[1] < 0x80 || sequence[1] > 0xBF) {
                length = 1;
                return nonCharacter;
            }
        }
        if (sequence[2] < 0x80 || sequence[2] > 0xBF) {
            length = 2;
            return nonCharacter;
        }
        return ((sequence[0] << 12) + (sequence[1] << 6) + sequence[2]) - 0x000E2080;
    }
    ASSERT(length == 4);
    ASSERT(sequence[0] >= 0xF0);
    ASSERT(sequence[0] <= 0xF4);
    switch (sequence[0]) {
    case 0xF0:
        if (sequence[1] < 0x90 || sequence[1] > 0xBF) {
            length = 1;
            return nonCharacter;
        }
        break;
    case 0xF4:
        if (sequence[1] < 0x80 || sequence[1] > 0x8F) {
            length = 1;
            return nonCharacter;
        }
        break;
    default:
        if (sequence[1] < 0x80 || sequence[1] > 0xBF) {
            length = 1;
            return nonCharacter;
        }
    }
    if (sequence[2] < 0x80 || sequence[2] > 0xBF) {
        length = 2;
        return nonCharacter;
    }
    if (sequence[3] < 0x80 || sequence[3] > 0xBF) {
        length = 3;
        return nonCharacter;
    }
    return ((sequence[0] << 18) + (sequence[1] << 12) + (sequence[2] << 6) + sequence[3]) - 0x03C82080;
}

static inline std::span<char16_t> NODELETE appendCharacter(std::span<char16_t> destination, int character)
{
    ASSERT(character != nonCharacter);
    ASSERT(!U_IS_SURROGATE(character));
    if (U_IS_BMP(character))
        consume(destination) = character;
    else {
        destination[0] = U16_LEAD(character);
        destination[1] = U16_TRAIL(character);
        skip(destination, 2);
    }
    return destination;
}

void TextCodecUTF8::consumePartialSequenceByte()
{
    --m_partialSequenceSize;
    memmoveSpan(std::span { m_partialSequence }, std::span { m_partialSequence }.subspan(1, m_partialSequenceSize));
}

bool TextCodecUTF8::handlePartialSequence(std::span<Latin1Character>& destination, std::span<const uint8_t>& source, bool flush)
{
    ASSERT(m_partialSequenceSize);
    do {
        if (isASCII(m_partialSequence[0])) {
            consume(destination) = m_partialSequence[0];
            consumePartialSequenceByte();
            continue;
        }
        auto count = nonASCIISequenceLength(m_partialSequence[0]);
        if (!count)
            return true;

        // Copy from `source` until we have `count` bytes.
        if (count > m_partialSequenceSize && !source.empty()) {
            size_t additionalBytes = std::min<size_t>(count - m_partialSequenceSize, source.size());
            memcpySpan(std::span { m_partialSequence }.subspan(m_partialSequenceSize), consumeSpan(source, additionalBytes));
            m_partialSequenceSize += additionalBytes;
        }

        // If we still don't have `count` bytes, fill the rest with zeros (any
        // other lead byte would do), so we can run `decodeNonASCIISequence` to
        // tell if the chunk that we have is valid. These bytes are not part of
        // the partial sequence, so don't increment `m_partialSequenceSize`.
        bool partialSequenceIsTooShort = false;
        if (count > m_partialSequenceSize) {
            partialSequenceIsTooShort = true;
            zeroSpan(std::span { m_partialSequence }.subspan(m_partialSequenceSize, count - m_partialSequenceSize));
        }

        int character = decodeNonASCIISequence(std::span { m_partialSequence }, count);
        if (partialSequenceIsTooShort) {
            ASSERT(character == nonCharacter);
            ASSERT(count <= m_partialSequenceSize);
            // If we're not at the end, and the partial sequence that we have is
            // incomplete but otherwise valid, a non-character is not an error.
            if (!flush && count == m_partialSequenceSize)
                return false;
        }

        if (!isLatin1(character))
            return true;

        m_partialSequenceSize -= count;
        consume(destination) = character;
    } while (m_partialSequenceSize);

    return false;
}

void TextCodecUTF8::handlePartialSequence(std::span<char16_t>& destination, std::span<const uint8_t>& source, bool flush, bool stopOnError, bool& sawError)
{
    ASSERT(m_partialSequenceSize);
    do {
        if (isASCII(m_partialSequence[0])) {
            consume(destination) = m_partialSequence[0];
            consumePartialSequenceByte();
            continue;
        }
        auto count = nonASCIISequenceLength(m_partialSequence[0]);
        if (!count) {
            sawError = true;
            if (stopOnError)
                return;
            consume(destination) = replacementCharacter;
            consumePartialSequenceByte();
            continue;
        }

        // Copy from `source` until we have `count` bytes.
        if (count > m_partialSequenceSize && !source.empty()) {
            size_t additionalBytes = std::min<size_t>(count - m_partialSequenceSize, source.size());
            memcpySpan(std::span { m_partialSequence }.subspan(m_partialSequenceSize), consumeSpan(source, additionalBytes));
            m_partialSequenceSize += additionalBytes;
        }

        // If we still don't have `count` bytes, fill the rest with zeros (any
        // other lead byte would do), so we can run `decodeNonASCIISequence` to
        // tell if the chunk that we have is valid. These bytes are not part of
        // the partial sequence, so don't increment `m_partialSequenceSize`.
        bool partialSequenceIsTooShort = false;
        if (count > m_partialSequenceSize) {
            partialSequenceIsTooShort = true;
            zeroSpan(std::span { m_partialSequence }.subspan(m_partialSequenceSize, count - m_partialSequenceSize));
        }

        int character = decodeNonASCIISequence(std::span { m_partialSequence }, count);
        if (partialSequenceIsTooShort) {
            ASSERT(character == nonCharacter);
            ASSERT(count <= m_partialSequenceSize);
            // If we're not at the end, and the partial sequence that we have is
            // incomplete but otherwise valid, a non-character is not an error.
            if (!flush && count == m_partialSequenceSize)
                return;
        }

        if (character == nonCharacter) {
            sawError = true;
            if (stopOnError)
                return;
            consume(destination) = replacementCharacter;
            m_partialSequenceSize -= count;
            memmoveSpan(std::span { m_partialSequence }, std::span { m_partialSequence }.subspan(count, m_partialSequenceSize));
            continue;
        }

        m_partialSequenceSize -= count;
        memmoveSpan(std::span { m_partialSequence }, std::span { m_partialSequence }.subspan(count, m_partialSequenceSize));
        if (std::exchange(m_shouldStripByteOrderMark, false) && character == byteOrderMark)
            continue;
        destination = appendCharacter(destination, character);
    } while (m_partialSequenceSize);
}

String TextCodecUTF8::decode(std::span<const uint8_t> bytes, bool flush, bool stopOnError, bool& sawError)
{
    // Each input byte might turn into a character.
    // That includes all bytes in the partial-sequence buffer because
    // each byte in an invalid sequence will turn into a replacement character.
    size_t bufferSize = m_partialSequenceSize + bytes.size();
    if (bufferSize > std::numeric_limits<unsigned>::max()) {
        sawError = true;
        return { };
    }
    StringBuffer<Latin1Character> buffer(bufferSize);

    auto source = bytes;
    auto* alignedEnd = WTF::alignToMachineWord(std::to_address(source.end()));
    auto destination = buffer.span();

#if USE_SWIFT_TEXT_CODEC_UTF8
    // The narrow Swift arm, which decodes into the 8-bit `buffer` directly. It covers input
    // whose every character fits in Latin-1 and returns `needsWide = true` at the first
    // character it cannot: an ill-formed sequence (unless `stopOnError`), a well-formed
    // character above U+00FF, or a park that resolves to either of those.
    //
    // Both preconditions are the arm's, not the loop's. A pending byte order mark is the one
    // character whose handling depends on where it lands. Empty input is excluded because
    // neither arm has characters to decode -- `flush` with no bytes ends any stream.
    if (!source.empty() && !m_shouldStripByteOrderMark) {
        uint32_t partialSequence = 0;
        for (int i = 0; i < m_partialSequenceSize; ++i)
            partialSequence |= static_cast<uint32_t>(m_partialSequence[i]) << (8 * i);

        auto narrowResult = pal::textCodecUTF8DecodeNarrow(
            source, destination,
            partialSequence, static_cast<uint8_t>(m_partialSequenceSize),
            flush, stopOnError);

        if (narrowResult.answered) {
            textCodecUTF8SwiftCounters().answered.fetch_add(1, std::memory_order_relaxed);
            if (narrowResult.sawError)
                sawError = true;
            skip(source, narrowResult.consumedBytes);

            // Write the park back before any early return.
            RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(static_cast<size_t>(narrowResult.partialSequenceSize) <= m_partialSequence.size());
            m_partialSequenceSize = narrowResult.partialSequenceSize;
            for (int i = 0; i < m_partialSequenceSize; ++i)
                m_partialSequence[i] = static_cast<uint8_t>(narrowResult.partialSequence >> (8 * i));

            if (narrowResult.stoppedOnError) {
                ASSERT(stopOnError);
                ASSERT(narrowResult.sawError);
                source = { };
                skip(destination, narrowResult.producedCharacters);
                // Fall through to the 8-bit tail to handle flush/shrink.
                goto swiftNarrowDone;
            } else if (!narrowResult.needsWide) {
                // Pure Latin-1 decode: the arm consumed the whole input.
                ASSERT(source.empty());
                skip(destination, narrowResult.producedCharacters);
                // Fall through to the 8-bit tail below.
                goto swiftNarrowDone;
            } else {
                // The arm met a character above U+00FF. Allocate a 16-bit buffer, widen the
                // already-decoded narrow prefix into it, and call the wide arm for the rest.
                StringBuffer<char16_t> buffer16(bufferSize);
                auto destination16 = buffer16.span();
                size_t narrowProduced = narrowResult.producedCharacters;
                auto converted8 = buffer.span().first(narrowProduced);
                for (size_t i = 0; i < narrowProduced; ++i)
                    destination16[i] = converted8[i];

                // Repack the park from the narrow result (already written back above).
                uint32_t widePartialSequence = 0;
                for (int i = 0; i < m_partialSequenceSize; ++i)
                    widePartialSequence |= static_cast<uint32_t>(m_partialSequence[i]) << (8 * i);

                auto wideResult = pal::textCodecUTF8DecodeWide(
                    source,
                    destination16.subspan(narrowProduced),
                    widePartialSequence, static_cast<uint8_t>(m_partialSequenceSize),
                    flush, stopOnError);

                // The wide arm has no decline paths.
                RELEASE_ASSERT(wideResult.answered);
                if (wideResult.sawError)
                    sawError = true;
                if (wideResult.stoppedOnError) {
                    ASSERT(stopOnError);
                    source = { };
                } else
                    ASSERT(source.empty());

                RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(static_cast<size_t>(wideResult.partialSequenceSize) <= m_partialSequence.size());
                m_partialSequenceSize = wideResult.partialSequenceSize;
                for (int i = 0; i < m_partialSequenceSize; ++i)
                    m_partialSequence[i] = static_cast<uint8_t>(wideResult.partialSequence >> (8 * i));

                size_t totalProduced = narrowProduced + wideResult.producedCharacters;
                RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(totalProduced <= buffer16.length());
                buffer16.shrink(static_cast<unsigned>(totalProduced));
                if (buffer16.length() > String::MaxLength) {
                    sawError = true;
                    return { };
                }
                if (flush)
                    m_partialSequenceSize = 0;
                if (flush || buffer16.length())
                    m_shouldStripByteOrderMark = false;
                return String::adopt(WTF::move(buffer16));
            }
        } else
            textCodecUTF8SwiftCounters().declined.fetch_add(1, std::memory_order_relaxed);
    }
    swiftNarrowDone:;
#endif

    do {
        if (m_partialSequenceSize) {
            // Explicitly copy destination and source pointers to avoid taking pointers to the
            // local variables, which may harm code generation by disabling some optimizations
            // in some compilers.
            auto destinationForHandlePartialSequence = destination;
            if (handlePartialSequence(destinationForHandlePartialSequence, source, flush)) {
                goto upConvertTo16Bit;
            }
            destination = destinationForHandlePartialSequence;
            if (m_partialSequenceSize)
                break;
        }

        while (!source.empty()) {
            if (isASCII(source[0])) {
                // Fast path for ASCII. Most UTF-8 text will be ASCII.
                if (WTF::isAlignedToMachineWord(source.data())) {
                    while (source.data() < alignedEnd) {
                        auto chunk = reinterpretCastSpanStartTo<const WTF::MachineWord>(source);
                        if (!WTF::containsOnlyASCII<Latin1Character>(chunk))
                            break;
                        copyASCIIMachineWord(destination, source);
                        skip(source, sizeof(WTF::MachineWord));
                        skip(destination, sizeof(WTF::MachineWord));
                    }
                    if (source.empty())
                        break;
                    if (!isASCII(source[0]))
                        continue;
                }
                consume(destination) = consume(source);
                continue;
            }
            auto count = nonASCIISequenceLength(source[0]);
            int character;
            if (!count)
                character = nonCharacter;
            else {
                if (count > source.size()) {
                    RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(source.size() < m_partialSequence.size());
                    ASSERT(!m_partialSequenceSize);
                    m_partialSequenceSize = source.size();
                    memcpySpan(std::span { m_partialSequence }, source.first(m_partialSequenceSize));
                    source = { };
                    break;
                }
                character = decodeNonASCIISequence(source, count);
            }
            if (character == nonCharacter) {
                sawError = true;
                if (stopOnError)
                    break;

                goto upConvertTo16Bit;
            }
            if (!isLatin1(character))
                goto upConvertTo16Bit;

            skip(source, count);
            consume(destination) = character;
        }
    } while (m_partialSequenceSize);

    buffer.shrink(destination.data() - buffer.characters());
    if (flush)
        m_partialSequenceSize = 0;
    if (flush || buffer.length())
        m_shouldStripByteOrderMark = false;
    if (buffer.length() > String::MaxLength) {
        sawError = true;
        return { };
    }
    return String::adopt(WTF::move(buffer));

upConvertTo16Bit:
    StringBuffer<char16_t> buffer16(bufferSize);

    auto destination16 = buffer16.span();

    // Copy the already converted characters
    auto converted8 = buffer.span();
    size_t charactersToCopy = destination.data() - buffer.characters();
    for (size_t i = 0; i < charactersToCopy; ++i)
        destination16[i] = converted8[i];
    skip(destination16, charactersToCopy);

    do {
        if (m_partialSequenceSize) {
            // Explicitly copy destination and source pointers to avoid taking pointers to the
            // local variables, which may harm code generation by disabling some optimizations
            // in some compilers.
            auto destinationForHandlePartialSequence = destination16;
            handlePartialSequence(destinationForHandlePartialSequence, source, flush, stopOnError, sawError);
            destination16 = destinationForHandlePartialSequence;
            if (m_partialSequenceSize)
                break;
        }

        while (!source.empty()) {
            if (isASCII(source[0])) {
                // Fast path for ASCII. Most UTF-8 text will be ASCII.
                if (WTF::isAlignedToMachineWord(source.data())) {
                    while (source.data() < alignedEnd) {
                        auto chunk = reinterpretCastSpanStartTo<const WTF::MachineWord>(source);
                        if (!WTF::containsOnlyASCII<Latin1Character>(chunk))
                            break;
                        copyASCIIMachineWord(destination16, source);
                        skip(source, sizeof(WTF::MachineWord));
                        skip(destination16, sizeof(WTF::MachineWord));
                    }
                    if (source.empty())
                        break;
                    if (!isASCII(source[0]))
                        continue;
                }
                consume(destination16) = consume(source);
                continue;
            }
            auto count = nonASCIISequenceLength(source[0]);
            int character;
            if (!count)
                character = nonCharacter;
            else {
                if (count > source.size()) {
                    RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(source.size() < m_partialSequence.size());
                    ASSERT(!m_partialSequenceSize);
                    m_partialSequenceSize = source.size();
                    memcpySpan(std::span { m_partialSequence }, source.first(m_partialSequenceSize));
                    source = { };
                    break;
                }
                character = decodeNonASCIISequence(source, count);
            }
            if (character == nonCharacter) {
                sawError = true;
                if (stopOnError)
                    break;
                consume(destination16) = replacementCharacter;
                skip(source, count ? count : 1);
                continue;
            }
            skip(source, count);
            if (character == byteOrderMark && destination16.data() == buffer16.characters() && std::exchange(m_shouldStripByteOrderMark, false))
                continue;
            destination16 = appendCharacter(destination16, character);
        }
    } while (m_partialSequenceSize);

    buffer16.shrink(destination16.data() - buffer16.characters());
    if (flush)
        m_partialSequenceSize = 0;
    if (flush || buffer16.length())
        m_shouldStripByteOrderMark = false;
    if (buffer16.length() > String::MaxLength) {
        sawError = true;
        return { };
    }
    return String::adopt(WTF::move(buffer16));
}

Vector<uint8_t> TextCodecUTF8::encodeUTF8(StringView string)
{
    // The buffer size is string.length() * maxBytesPerUnit, where maxBytesPerUnit is the
    // worst-case UTF-8 bytes per input code unit.
    // - 8-bit (Latin1) strings: max 2 UTF-8 bytes per character (for 0x80-0xFF).
    // - 16-bit strings: max 3 UTF-8 bytes per code unit (BMP characters use 1 code unit
    //   and up to 3 bytes; non-BMP use 2 code units and 4 bytes, i.e. only 2 per unit).
    size_t maxBytesPerUnit = string.is8Bit() ? 2 : 3;
    Vector<uint8_t> bytes(WTF::checkedProduct<size_t>(string.length(), maxBytesPerUnit));
    size_t bytesWritten = 0;
    for (auto character : string.codePoints())
        U8_APPEND_UNSAFE(bytes, bytesWritten, character);
    bytes.shrink(bytesWritten);
    return bytes;
}

Vector<uint8_t> TextCodecUTF8::encode(StringView string, UnencodableHandling) const
{
    return encodeUTF8(string);
}

} // namespace PAL
