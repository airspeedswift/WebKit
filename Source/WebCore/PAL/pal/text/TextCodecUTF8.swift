// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if USE_SWIFT_TEXT_CODEC_UTF8

private import CxxStdlib
public import pal.Core.text.TextCodecUTF8DecoderTypes

// The UTF-8 decoder behind TextCodecUTF8::decode. Each entry point decodes one byte sequence,
// continuing from the codec's decoding state, and returns the state at the end of the call.

private let nonCharacter: Int32 = -1
private let byteOrderMark: Int32 = 0xFEFF
private let replacementCharacter: UInt16 = 0xFFFD
private let nonASCIIBytes: UInt64 = 0x8080_8080_8080_8080

/// The held partial sequence: the bytes of an incomplete sequence at the end of a byte sequence,
/// kept for the next call. Only the first `size` bytes are part of it.
private struct PartialSequence {
    var bytes: InlineArray<4, UInt8>
    var size: Int

    init(_ state: PAL.TextCodecUTF8DecoderState) {
        bytes = [state.partialSequence0, state.partialSequence1, state.partialSequence2, state.partialSequence3]
        size = Int(state.partialSequenceSize)
    }

    /// Removes the first `count` bytes, moving the rest to the front.
    mutating func removeFirst(_ count: Int) {
        size &-= count
        for index in 0..<size {
            bytes[index] = bytes[index &+ count]
        }
    }

    /// Appends bytes from `source` at `offset` until the partial sequence has `count` bytes, or
    /// `source` ends. If it is still shorter than `count`, the missing bytes are zero, which no
    /// sequence continues with, so decoding it tells whether the bytes it has are valid. Returns
    /// whether it is still shorter.
    mutating func fill(to count: Int, from source: Span<UInt8>, _ offset: inout Int) -> Bool {
        if count > size && offset < source.count {
            let additionalBytes = min(count &- size, source.count &- offset)
            for index in 0..<additionalBytes {
                bytes[size &+ index] = source[offset &+ index]
            }
            offset &+= additionalBytes
            size &+= additionalBytes
        }
        guard count > size else {
            return false
        }
        for index in size..<count {
            bytes[index] = 0
        }
        return true
    }

    /// Holds the last bytes of `source`, from `offset`.
    mutating func hold(_ source: Span<UInt8>, from offset: Int) {
        size = source.count &- offset
        for index in 0..<size {
            bytes[index] = source[offset &+ index]
        }
    }

    func state(shouldStripByteOrderMark: Bool) -> PAL.TextCodecUTF8DecoderState {
        PAL.TextCodecUTF8DecoderState(
            partialSequence0: bytes[0],
            partialSequence1: bytes[1],
            partialSequence2: bytes[2],
            partialSequence3: bytes[3],
            partialSequenceSize: UInt8(truncatingIfNeeded: size),
            shouldStripByteOrderMark: shouldStripByteOrderMark
        )
    }
}

/// The length of the sequence that `firstByte` starts, or 0 if no sequence starts with it.
@inline(always)
private func nonASCIISequenceLength(_ firstByte: UInt8) -> Int {
    // 0xC2...0xF4 start a sequence: 0xC2...0xDF of 2 bytes, 0xE0...0xEF of 3, 0xF0...0xF4 of 4.
    guard firstByte &- 0xC2 < 0x33 else {
        return 0
    }
    return 2 &+ (firstByte >= 0xE0 ? 1 : 0) &+ (firstByte >= 0xF0 ? 1 : 0)
}

/// Whether `byte` continues a sequence: 0x80...0xBF.
@inline(always)
private func isContinuationByte(_ byte: UInt8) -> Bool {
    byte &- 0x80 < 0x40
}

/// Decodes the `length`-byte sequence at `offset` in `sequence`, which holds at least `length`
/// bytes there. If it is invalid, returns `nonCharacter` and sets `length` to the number of bytes
/// before the first byte that does not continue it.
@inline(always)
private func decodeNonASCIISequence(_ sequence: Span<UInt8>, _ offset: Int, _ length: inout Int) -> Int32 {
    let byte0 = Int32(sequence[offset])
    let byte1 = sequence[offset &+ 1]
    if length == 2 {
        guard isContinuationByte(byte1) else {
            length = 1
            return nonCharacter
        }
        return ((byte0 &<< 6) &+ Int32(byte1)) &- 0x0000_3080
    }
    let secondByteRange: ClosedRange<UInt8> =
        switch byte0 {
        case 0xE0: 0xA0...0xBF
        case 0xED: 0x80...0x9F
        case 0xF0: 0x90...0xBF
        case 0xF4: 0x80...0x8F
        default: 0x80...0xBF
        }
    guard secondByteRange.contains(byte1) else {
        length = 1
        return nonCharacter
    }
    let byte2 = sequence[offset &+ 2]
    guard isContinuationByte(byte2) else {
        length = 2
        return nonCharacter
    }
    if length == 3 {
        return ((byte0 &<< 12) &+ (Int32(byte1) &<< 6) &+ Int32(byte2)) &- 0x000E_2080
    }
    let byte3 = sequence[offset &+ 3]
    guard isContinuationByte(byte3) else {
        length = 3
        return nonCharacter
    }
    return ((byte0 &<< 18) &+ (Int32(byte1) &<< 12) &+ (Int32(byte2) &<< 6) &+ Int32(byte3)) &- 0x03C8_2080
}

/// The number of ASCII bytes at the start of `word`, a word of input bytes in memory order.
@inline(always)
private func leadingASCIICount(_ word: UInt64) -> Int {
    (word & nonASCIIBytes).trailingZeroBitCount &>> 3
}

/// The number of ASCII bytes at the start of the 16 bytes `low`, then `high`, which hold at least
/// one byte that is not ASCII.
@inline(always)
private func leadingASCIICount(_ low: UInt64, _ high: UInt64) -> Int {
    low & nonASCIIBytes != 0 ? leadingASCIICount(low) : 8 &+ leadingASCIICount(high)
}

/// The number of ASCII bytes at the start of the 16 bytes at `offset` in `bytes`, which hold at least
/// one byte that is not ASCII.
@inline(always)
private func leadingASCIICountOf16Bytes(_ bytes: RawSpan, _ offset: Int) -> Int {
    leadingASCIICount(
        bytes.load(fromByteOffset: offset, as: UInt64.self), bytes.load(fromByteOffset: offset &+ 8, as: UInt64.self))
}

/// The number of ASCII bytes at the start of the 32 bytes of `block`, which hold at least one byte
/// that is not ASCII.
@inline(always)
private func leadingASCIICountOf32Bytes(_ block: RawSpan) -> Int {
    let word0 = block.load(fromByteOffset: 0, as: UInt64.self)
    let word1 = block.load(fromByteOffset: 8, as: UInt64.self)
    if (word0 | word1) & nonASCIIBytes != 0 {
        return leadingASCIICount(word0, word1)
    }
    return 16 &+ leadingASCIICount(
        block.load(fromByteOffset: 16, as: UInt64.self), block.load(fromByteOffset: 24, as: UInt64.self))
}

/// The number of ASCII bytes at the start of the 64 bytes of `block`, which hold at least one byte
/// that is not ASCII.
@inline(always)
private func leadingASCIICountOf64Bytes(_ block: RawSpan) -> Int {
    let word0 = block.load(fromByteOffset: 0, as: UInt64.self)
    let word1 = block.load(fromByteOffset: 8, as: UInt64.self)
    if (word0 | word1) & nonASCIIBytes != 0 {
        return leadingASCIICount(word0, word1)
    }
    let word2 = block.load(fromByteOffset: 16, as: UInt64.self)
    let word3 = block.load(fromByteOffset: 24, as: UInt64.self)
    if (word2 | word3) & nonASCIIBytes != 0 {
        return 16 &+ leadingASCIICount(word2, word3)
    }
    let word4 = block.load(fromByteOffset: 32, as: UInt64.self)
    let word5 = block.load(fromByteOffset: 40, as: UInt64.self)
    if (word4 | word5) & nonASCIIBytes != 0 {
        return 32 &+ leadingASCIICount(word4, word5)
    }
    return 48 &+ leadingASCIICount(
        block.load(fromByteOffset: 48, as: UInt64.self), block.load(fromByteOffset: 56, as: UInt64.self))
}

// The block loops below store a whole block before checking it, and advance only past its valid prefix.
// Characters stored beyond that are overwritten later or are past the end of the result. A block is
// stored only when at least as many input bytes remain as it stores characters, and the destination has
// room for one character per input byte, so every store is in bounds.

/// Copies the run of ASCII bytes at `read` in `source` to `destination` at `written`, advancing
/// both past it. Returns true if the run ends at a byte that is not ASCII, false if it ends at the
/// end of `source`.
@inline(always)
private func copyASCII(
    _ source: Span<UInt8>,
    _ read: inout Int,
    _ destination: inout MutableSpan<UInt8>,
    _ written: inout Int
) -> Bool {
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    if source.count &- read >= 16 {
        // The unread input and unwritten output.
        var input = sourceBytes.extracting(droppingFirst: read)
        var output = destinationBytes._mutatingExtracting(droppingFirst: written)
        do {
            let block = input.extracting(0..<16)
            var outputBlock = output._mutatingExtracting(0..<16)
            let low = block.load(fromByteOffset: 0, as: UInt64.self)
            let high = block.load(fromByteOffset: 8, as: UInt64.self)
            outputBlock.storeBytes(of: low, toByteOffset: 0, as: UInt64.self)
            outputBlock.storeBytes(of: high, toByteOffset: 8, as: UInt64.self)
            if (low | high) & nonASCIIBytes != 0 {
                let count = leadingASCIICount(low, high)
                read &+= count
                written &+= count
                return true
            }
        }
        input = input.extracting(droppingFirst: 16)
        output = output._consumingExtracting(droppingFirst: 16)
        read &+= 16
        written &+= 16
        while input.byteCount >= 64 {
            let block = input.extracting(0..<64)
            var outputBlock = output._mutatingExtracting(0..<64)
            let block0 = block.load(fromByteOffset: 0, as: SIMD16<UInt8>.self)
            let block1 = block.load(fromByteOffset: 16, as: SIMD16<UInt8>.self)
            let block2 = block.load(fromByteOffset: 32, as: SIMD16<UInt8>.self)
            let block3 = block.load(fromByteOffset: 48, as: SIMD16<UInt8>.self)
            outputBlock.storeBytes(of: block0, toByteOffset: 0, as: SIMD16<UInt8>.self)
            outputBlock.storeBytes(of: block1, toByteOffset: 16, as: SIMD16<UInt8>.self)
            outputBlock.storeBytes(of: block2, toByteOffset: 32, as: SIMD16<UInt8>.self)
            outputBlock.storeBytes(of: block3, toByteOffset: 48, as: SIMD16<UInt8>.self)
            if (block0 | block1 | block2 | block3).max() >= 0x80 {
                let count = leadingASCIICountOf64Bytes(block)
                read &+= count
                written &+= count
                return true
            }
            input = input.extracting(droppingFirst: 64)
            output = output._consumingExtracting(droppingFirst: 64)
            read &+= 64
            written &+= 64
        }
        if input.byteCount >= 32 {
            let block = input.extracting(0..<32)
            var outputBlock = output._mutatingExtracting(0..<32)
            let block0 = block.load(fromByteOffset: 0, as: SIMD16<UInt8>.self)
            let block1 = block.load(fromByteOffset: 16, as: SIMD16<UInt8>.self)
            outputBlock.storeBytes(of: block0, toByteOffset: 0, as: SIMD16<UInt8>.self)
            outputBlock.storeBytes(of: block1, toByteOffset: 16, as: SIMD16<UInt8>.self)
            if (block0 | block1).max() >= 0x80 {
                let count = leadingASCIICountOf32Bytes(block)
                read &+= count
                written &+= count
                return true
            }
            input = input.extracting(droppingFirst: 32)
            output = output._consumingExtracting(droppingFirst: 32)
            read &+= 32
            written &+= 32
        }
        if input.byteCount >= 16 {
            let block = input.extracting(0..<16)
            var outputBlock = output._mutatingExtracting(0..<16)
            let low = block.load(fromByteOffset: 0, as: UInt64.self)
            let high = block.load(fromByteOffset: 8, as: UInt64.self)
            outputBlock.storeBytes(of: low, toByteOffset: 0, as: UInt64.self)
            outputBlock.storeBytes(of: high, toByteOffset: 8, as: UInt64.self)
            if (low | high) & nonASCIIBytes != 0 {
                let count = leadingASCIICount(low, high)
                read &+= count
                written &+= count
                return true
            }
            read &+= 16
            written &+= 16
        }
    }
    if source.count &- read >= 8 {
        let word = sourceBytes.load(fromByteOffset: read, as: UInt64.self)
        destinationBytes.storeBytes(of: word, toByteOffset: written, as: UInt64.self)
        if word & nonASCIIBytes != 0 {
            let count = leadingASCIICount(word)
            read &+= count
            written &+= count
            return true
        }
        read &+= 8
        written &+= 8
    }
    while read < source.count {
        let byte = source[read]
        if byte >= 0x80 {
            return true
        }
        destinationBytes.storeBytes(of: byte, toByteOffset: written, as: UInt8.self)
        read &+= 1
        written &+= 1
    }
    return false
}

/// Stores the 16 ASCII bytes of `block` as UTF-16 code units at `offset` in `destination`.
@inline(always)
private func storeCodeUnits(_ block: SIMD16<UInt8>, _ destination: inout MutableRawSpan, _ offset: Int) {
    let byteOffset = offset &* 2
    destination.storeBytes(
        of: SIMD8<UInt16>(truncatingIfNeeded: block.lowHalf), toByteOffset: byteOffset, as: SIMD8<UInt16>.self)
    destination.storeBytes(
        of: SIMD8<UInt16>(truncatingIfNeeded: block.highHalf), toByteOffset: byteOffset &+ 16,
        as: SIMD8<UInt16>.self)
}

/// Copies the run of ASCII bytes at `read` in `source` to `destination` at `written` as UTF-16
/// code units, advancing both past it. Returns true if the run ends at a byte that is not ASCII,
/// false if it ends at the end of `source`.
@inline(always)
private func copyASCII(
    _ source: Span<UInt8>,
    _ read: inout Int,
    _ destination: inout MutableSpan<UInt16>,
    _ written: inout Int
) -> Bool {
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    if source.count &- read >= 16 {
        let block = sourceBytes.load(fromByteOffset: read, as: SIMD16<UInt8>.self)
        storeCodeUnits(block, &destinationBytes, written)
        if block.max() >= 0x80 {
            let count = leadingASCIICountOf16Bytes(sourceBytes, read)
            read &+= count
            written &+= count
            return true
        }
        read &+= 16
        written &+= 16
        if source.count &- read >= 64 {
            // The unread input and unwritten output.
            var input = sourceBytes.extracting(droppingFirst: read)
            var output = destinationBytes._mutatingExtracting(droppingFirst: written &* 2)
            while input.byteCount >= 64 {
                let block = input.extracting(0..<64)
                var outputBlock = output._mutatingExtracting(0..<128)
                let block0 = block.load(fromByteOffset: 0, as: SIMD16<UInt8>.self)
                let block1 = block.load(fromByteOffset: 16, as: SIMD16<UInt8>.self)
                let block2 = block.load(fromByteOffset: 32, as: SIMD16<UInt8>.self)
                let block3 = block.load(fromByteOffset: 48, as: SIMD16<UInt8>.self)
                storeCodeUnits(block0, &outputBlock, 0)
                storeCodeUnits(block1, &outputBlock, 16)
                storeCodeUnits(block2, &outputBlock, 32)
                storeCodeUnits(block3, &outputBlock, 48)
                if (block0 | block1 | block2 | block3).max() >= 0x80 {
                    let count = leadingASCIICountOf64Bytes(block)
                    read &+= count
                    written &+= count
                    return true
                }
                input = input.extracting(droppingFirst: 64)
                output = output._consumingExtracting(droppingFirst: 128)
                read &+= 64
                written &+= 64
            }
        }
        if source.count &- read >= 32 {
            let first = sourceBytes.load(fromByteOffset: read, as: SIMD16<UInt8>.self)
            let second = sourceBytes.load(fromByteOffset: read &+ 16, as: SIMD16<UInt8>.self)
            storeCodeUnits(first, &destinationBytes, written)
            storeCodeUnits(second, &destinationBytes, written &+ 16)
            if (first | second).max() >= 0x80 {
                let count = leadingASCIICountOf32Bytes(sourceBytes.extracting(droppingFirst: read).extracting(0..<32))
                read &+= count
                written &+= count
                return true
            }
            read &+= 32
            written &+= 32
        }
        if source.count &- read >= 16 {
            let block = sourceBytes.load(fromByteOffset: read, as: SIMD16<UInt8>.self)
            storeCodeUnits(block, &destinationBytes, written)
            if block.max() >= 0x80 {
                let count = leadingASCIICountOf16Bytes(sourceBytes, read)
                read &+= count
                written &+= count
                return true
            }
            read &+= 16
            written &+= 16
        }
    }
    if source.count &- read >= 8 {
        let word = sourceBytes.load(fromByteOffset: read, as: UInt64.self)
        let codeUnits = SIMD8<UInt16>(truncatingIfNeeded: bitCast(word, to: SIMD8<UInt8>.self))
        destinationBytes.storeBytes(of: codeUnits, toByteOffset: written &* 2, as: SIMD8<UInt16>.self)
        if word & nonASCIIBytes != 0 {
            let count = leadingASCIICount(word)
            read &+= count
            written &+= count
            return true
        }
        read &+= 8
        written &+= 8
    }
    while read < source.count {
        let byte = source[read]
        if byte >= 0x80 {
            return true
        }
        destinationBytes.storeBytes(of: UInt16(byte), toByteOffset: written &* 2, as: UInt16.self)
        read &+= 1
        written &+= 1
    }
    return false
}

/// Takes 4 byte pairs and returns a 16-bit lane per pair that is zero if the pair is a valid 2-byte
/// sequence (0xC2...0xDF, then a continuation byte). The subtraction rejects 0xC0 and 0xC1; its borrow
/// only affects later lanes.
@inline(always)
private func invalidTwoByteSequences(_ pairs: UInt64) -> UInt64 {
    ((pairs & 0xC0E0_C0E0_C0E0_C0E0) ^ 0x80C0_80C0_80C0_80C0)
        | (((pairs & 0x001E_001E_001E_001E) &- 0x0001_0001_0001_0001) & 0x8000_8000_8000_8000)
}

/// Takes 4 byte pairs and returns a 16-bit lane per pair that is zero if the pair is a 2-byte sequence
/// of a Latin-1 character (0xC2 or 0xC3, then a continuation byte).
@inline(always)
private func invalidLatin1Sequences(_ pairs: UInt64) -> UInt64 {
    (pairs & 0xC0FE_C0FE_C0FE_C0FE) ^ 0x80C2_80C2_80C2_80C2
}

/// The number of leading 16-bit lanes that are zero in `low`, then `high`.
@inline(always)
private func leadingValidPairCount(_ low: UInt64, _ high: UInt64) -> Int {
    low != 0 ? low.trailingZeroBitCount &>> 4 : 4 &+ (high.trailingZeroBitCount &>> 4)
}

/// The number of leading zero 16-bit lanes in `invalid`.
@inline(always)
private func leadingValidCount(_ invalid: UInt64) -> Int {
    invalid.trailingZeroBitCount &>> 4
}

/// Decodes the run of valid 2-byte sequences of Latin-1 characters at `read` in `source`, 8 at a
/// time, to `destination` at `written`, advancing both past the sequences it decodes. Stops at the
/// first block that is not 8 such sequences, or when fewer than 16 bytes remain.
@inline(always)
private func decodeLatin1Sequences(
    _ source: Span<UInt8>,
    _ read: inout Int,
    _ destination: inout MutableSpan<UInt8>,
    _ written: inout Int
) {
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    // The unread input and unwritten output.
    var input = sourceBytes.extracting(droppingFirst: read)
    var output = destinationBytes._mutatingExtracting(droppingFirst: written)
    while input.byteCount >= 16 {
        let block = input.extracting(0..<16)
        var outputBlock = output._mutatingExtracting(0..<8)
        // Each lane is a first byte, then the byte after it.
        let pairs = bitCast(block.load(fromByteOffset: 0, as: SIMD16<UInt8>.self), to: SIMD8<UInt16>.self)
        let characters = SIMD8<UInt8>(truncatingIfNeeded: (pairs &<< 6) | ((pairs &>> 8) & 0x3F))
        outputBlock.storeBytes(of: characters, toByteOffset: 0, as: SIMD8<UInt8>.self)
        let low = invalidLatin1Sequences(block.load(fromByteOffset: 0, as: UInt64.self))
        let high = invalidLatin1Sequences(block.load(fromByteOffset: 8, as: UInt64.self))
        if low | high != 0 {
            let count = leadingValidPairCount(low, high)
            read &+= count &* 2
            written &+= count
            return
        }
        input = input.extracting(droppingFirst: 16)
        output = output._consumingExtracting(droppingFirst: 8)
        read &+= 16
        written &+= 8
    }
}

/// Decodes the run of valid 2-byte sequences at the start of `source`, 8 at a time, to UTF-16 code
/// units at the start of `destination`. Returns the bytes read and the code units written. Stops at
/// the first block that is not 8 valid 2-byte sequences, or when fewer than 16 bytes remain.
@inline(never)
private func decodeTwoByteSequences(
    _ source: Span<UInt8>,
    _ destination: consuming MutableSpan<UInt16>
) -> (read: Int, written: Int) {
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    var read = 0
    var written = 0
    while source.count &- read >= 16 {
        // Each lane is a first byte, then the byte after it.
        let pairs = bitCast(sourceBytes.load(fromByteOffset: read, as: SIMD16<UInt8>.self), to: SIMD8<UInt16>.self)
        let codeUnits = ((pairs & 0x1F) &<< 6) | ((pairs &>> 8) & 0x3F)
        destinationBytes.storeBytes(of: codeUnits, toByteOffset: written &* 2, as: SIMD8<UInt16>.self)
        let low = invalidTwoByteSequences(sourceBytes.load(fromByteOffset: read, as: UInt64.self))
        let high = invalidTwoByteSequences(sourceBytes.load(fromByteOffset: read &+ 8, as: UInt64.self))
        if low | high != 0 {
            let count = leadingValidPairCount(low, high)
            return (read &+ count &* 2, written &+ count)
        }
        read &+= 16
        written &+= 8
    }
    return (read, written)
}

/// For each 8-bit mask, the indices of its clear bits in ascending order, padded with 0xFF.
private let remainingLaneIndices: InlineArray<256, UInt64> = [
    0x0706_0504_0302_0100, 0xFF07_0605_0403_0201, 0xFF07_0605_0403_0200, 0xFFFF_0706_0504_0302,
    0xFF07_0605_0403_0100, 0xFFFF_0706_0504_0301, 0xFFFF_0706_0504_0300, 0xFFFF_FF07_0605_0403,
    0xFF07_0605_0402_0100, 0xFFFF_0706_0504_0201, 0xFFFF_0706_0504_0200, 0xFFFF_FF07_0605_0402,
    0xFFFF_0706_0504_0100, 0xFFFF_FF07_0605_0401, 0xFFFF_FF07_0605_0400, 0xFFFF_FFFF_0706_0504,
    0xFF07_0605_0302_0100, 0xFFFF_0706_0503_0201, 0xFFFF_0706_0503_0200, 0xFFFF_FF07_0605_0302,
    0xFFFF_0706_0503_0100, 0xFFFF_FF07_0605_0301, 0xFFFF_FF07_0605_0300, 0xFFFF_FFFF_0706_0503,
    0xFFFF_0706_0502_0100, 0xFFFF_FF07_0605_0201, 0xFFFF_FF07_0605_0200, 0xFFFF_FFFF_0706_0502,
    0xFFFF_FF07_0605_0100, 0xFFFF_FFFF_0706_0501, 0xFFFF_FFFF_0706_0500, 0xFFFF_FFFF_FF07_0605,
    0xFF07_0604_0302_0100, 0xFFFF_0706_0403_0201, 0xFFFF_0706_0403_0200, 0xFFFF_FF07_0604_0302,
    0xFFFF_0706_0403_0100, 0xFFFF_FF07_0604_0301, 0xFFFF_FF07_0604_0300, 0xFFFF_FFFF_0706_0403,
    0xFFFF_0706_0402_0100, 0xFFFF_FF07_0604_0201, 0xFFFF_FF07_0604_0200, 0xFFFF_FFFF_0706_0402,
    0xFFFF_FF07_0604_0100, 0xFFFF_FFFF_0706_0401, 0xFFFF_FFFF_0706_0400, 0xFFFF_FFFF_FF07_0604,
    0xFFFF_0706_0302_0100, 0xFFFF_FF07_0603_0201, 0xFFFF_FF07_0603_0200, 0xFFFF_FFFF_0706_0302,
    0xFFFF_FF07_0603_0100, 0xFFFF_FFFF_0706_0301, 0xFFFF_FFFF_0706_0300, 0xFFFF_FFFF_FF07_0603,
    0xFFFF_FF07_0602_0100, 0xFFFF_FFFF_0706_0201, 0xFFFF_FFFF_0706_0200, 0xFFFF_FFFF_FF07_0602,
    0xFFFF_FFFF_0706_0100, 0xFFFF_FFFF_FF07_0601, 0xFFFF_FFFF_FF07_0600, 0xFFFF_FFFF_FFFF_0706,
    0xFF07_0504_0302_0100, 0xFFFF_0705_0403_0201, 0xFFFF_0705_0403_0200, 0xFFFF_FF07_0504_0302,
    0xFFFF_0705_0403_0100, 0xFFFF_FF07_0504_0301, 0xFFFF_FF07_0504_0300, 0xFFFF_FFFF_0705_0403,
    0xFFFF_0705_0402_0100, 0xFFFF_FF07_0504_0201, 0xFFFF_FF07_0504_0200, 0xFFFF_FFFF_0705_0402,
    0xFFFF_FF07_0504_0100, 0xFFFF_FFFF_0705_0401, 0xFFFF_FFFF_0705_0400, 0xFFFF_FFFF_FF07_0504,
    0xFFFF_0705_0302_0100, 0xFFFF_FF07_0503_0201, 0xFFFF_FF07_0503_0200, 0xFFFF_FFFF_0705_0302,
    0xFFFF_FF07_0503_0100, 0xFFFF_FFFF_0705_0301, 0xFFFF_FFFF_0705_0300, 0xFFFF_FFFF_FF07_0503,
    0xFFFF_FF07_0502_0100, 0xFFFF_FFFF_0705_0201, 0xFFFF_FFFF_0705_0200, 0xFFFF_FFFF_FF07_0502,
    0xFFFF_FFFF_0705_0100, 0xFFFF_FFFF_FF07_0501, 0xFFFF_FFFF_FF07_0500, 0xFFFF_FFFF_FFFF_0705,
    0xFFFF_0704_0302_0100, 0xFFFF_FF07_0403_0201, 0xFFFF_FF07_0403_0200, 0xFFFF_FFFF_0704_0302,
    0xFFFF_FF07_0403_0100, 0xFFFF_FFFF_0704_0301, 0xFFFF_FFFF_0704_0300, 0xFFFF_FFFF_FF07_0403,
    0xFFFF_FF07_0402_0100, 0xFFFF_FFFF_0704_0201, 0xFFFF_FFFF_0704_0200, 0xFFFF_FFFF_FF07_0402,
    0xFFFF_FFFF_0704_0100, 0xFFFF_FFFF_FF07_0401, 0xFFFF_FFFF_FF07_0400, 0xFFFF_FFFF_FFFF_0704,
    0xFFFF_FF07_0302_0100, 0xFFFF_FFFF_0703_0201, 0xFFFF_FFFF_0703_0200, 0xFFFF_FFFF_FF07_0302,
    0xFFFF_FFFF_0703_0100, 0xFFFF_FFFF_FF07_0301, 0xFFFF_FFFF_FF07_0300, 0xFFFF_FFFF_FFFF_0703,
    0xFFFF_FFFF_0702_0100, 0xFFFF_FFFF_FF07_0201, 0xFFFF_FFFF_FF07_0200, 0xFFFF_FFFF_FFFF_0702,
    0xFFFF_FFFF_FF07_0100, 0xFFFF_FFFF_FFFF_0701, 0xFFFF_FFFF_FFFF_0700, 0xFFFF_FFFF_FFFF_FF07,
    0xFF06_0504_0302_0100, 0xFFFF_0605_0403_0201, 0xFFFF_0605_0403_0200, 0xFFFF_FF06_0504_0302,
    0xFFFF_0605_0403_0100, 0xFFFF_FF06_0504_0301, 0xFFFF_FF06_0504_0300, 0xFFFF_FFFF_0605_0403,
    0xFFFF_0605_0402_0100, 0xFFFF_FF06_0504_0201, 0xFFFF_FF06_0504_0200, 0xFFFF_FFFF_0605_0402,
    0xFFFF_FF06_0504_0100, 0xFFFF_FFFF_0605_0401, 0xFFFF_FFFF_0605_0400, 0xFFFF_FFFF_FF06_0504,
    0xFFFF_0605_0302_0100, 0xFFFF_FF06_0503_0201, 0xFFFF_FF06_0503_0200, 0xFFFF_FFFF_0605_0302,
    0xFFFF_FF06_0503_0100, 0xFFFF_FFFF_0605_0301, 0xFFFF_FFFF_0605_0300, 0xFFFF_FFFF_FF06_0503,
    0xFFFF_FF06_0502_0100, 0xFFFF_FFFF_0605_0201, 0xFFFF_FFFF_0605_0200, 0xFFFF_FFFF_FF06_0502,
    0xFFFF_FFFF_0605_0100, 0xFFFF_FFFF_FF06_0501, 0xFFFF_FFFF_FF06_0500, 0xFFFF_FFFF_FFFF_0605,
    0xFFFF_0604_0302_0100, 0xFFFF_FF06_0403_0201, 0xFFFF_FF06_0403_0200, 0xFFFF_FFFF_0604_0302,
    0xFFFF_FF06_0403_0100, 0xFFFF_FFFF_0604_0301, 0xFFFF_FFFF_0604_0300, 0xFFFF_FFFF_FF06_0403,
    0xFFFF_FF06_0402_0100, 0xFFFF_FFFF_0604_0201, 0xFFFF_FFFF_0604_0200, 0xFFFF_FFFF_FF06_0402,
    0xFFFF_FFFF_0604_0100, 0xFFFF_FFFF_FF06_0401, 0xFFFF_FFFF_FF06_0400, 0xFFFF_FFFF_FFFF_0604,
    0xFFFF_FF06_0302_0100, 0xFFFF_FFFF_0603_0201, 0xFFFF_FFFF_0603_0200, 0xFFFF_FFFF_FF06_0302,
    0xFFFF_FFFF_0603_0100, 0xFFFF_FFFF_FF06_0301, 0xFFFF_FFFF_FF06_0300, 0xFFFF_FFFF_FFFF_0603,
    0xFFFF_FFFF_0602_0100, 0xFFFF_FFFF_FF06_0201, 0xFFFF_FFFF_FF06_0200, 0xFFFF_FFFF_FFFF_0602,
    0xFFFF_FFFF_FF06_0100, 0xFFFF_FFFF_FFFF_0601, 0xFFFF_FFFF_FFFF_0600, 0xFFFF_FFFF_FFFF_FF06,
    0xFFFF_0504_0302_0100, 0xFFFF_FF05_0403_0201, 0xFFFF_FF05_0403_0200, 0xFFFF_FFFF_0504_0302,
    0xFFFF_FF05_0403_0100, 0xFFFF_FFFF_0504_0301, 0xFFFF_FFFF_0504_0300, 0xFFFF_FFFF_FF05_0403,
    0xFFFF_FF05_0402_0100, 0xFFFF_FFFF_0504_0201, 0xFFFF_FFFF_0504_0200, 0xFFFF_FFFF_FF05_0402,
    0xFFFF_FFFF_0504_0100, 0xFFFF_FFFF_FF05_0401, 0xFFFF_FFFF_FF05_0400, 0xFFFF_FFFF_FFFF_0504,
    0xFFFF_FF05_0302_0100, 0xFFFF_FFFF_0503_0201, 0xFFFF_FFFF_0503_0200, 0xFFFF_FFFF_FF05_0302,
    0xFFFF_FFFF_0503_0100, 0xFFFF_FFFF_FF05_0301, 0xFFFF_FFFF_FF05_0300, 0xFFFF_FFFF_FFFF_0503,
    0xFFFF_FFFF_0502_0100, 0xFFFF_FFFF_FF05_0201, 0xFFFF_FFFF_FF05_0200, 0xFFFF_FFFF_FFFF_0502,
    0xFFFF_FFFF_FF05_0100, 0xFFFF_FFFF_FFFF_0501, 0xFFFF_FFFF_FFFF_0500, 0xFFFF_FFFF_FFFF_FF05,
    0xFFFF_FF04_0302_0100, 0xFFFF_FFFF_0403_0201, 0xFFFF_FFFF_0403_0200, 0xFFFF_FFFF_FF04_0302,
    0xFFFF_FFFF_0403_0100, 0xFFFF_FFFF_FF04_0301, 0xFFFF_FFFF_FF04_0300, 0xFFFF_FFFF_FFFF_0403,
    0xFFFF_FFFF_0402_0100, 0xFFFF_FFFF_FF04_0201, 0xFFFF_FFFF_FF04_0200, 0xFFFF_FFFF_FFFF_0402,
    0xFFFF_FFFF_FF04_0100, 0xFFFF_FFFF_FFFF_0401, 0xFFFF_FFFF_FFFF_0400, 0xFFFF_FFFF_FFFF_FF04,
    0xFFFF_FFFF_0302_0100, 0xFFFF_FFFF_FF03_0201, 0xFFFF_FFFF_FF03_0200, 0xFFFF_FFFF_FFFF_0302,
    0xFFFF_FFFF_FF03_0100, 0xFFFF_FFFF_FFFF_0301, 0xFFFF_FFFF_FFFF_0300, 0xFFFF_FFFF_FFFF_FF03,
    0xFFFF_FFFF_FF02_0100, 0xFFFF_FFFF_FFFF_0201, 0xFFFF_FFFF_FFFF_0200, 0xFFFF_FFFF_FFFF_FF02,
    0xFFFF_FFFF_FFFF_0100, 0xFFFF_FFFF_FFFF_FF01, 0xFFFF_FFFF_FFFF_FF00, 0xFFFF_FFFF_FFFF_FFFF,
]

/// 0xFF in each lane whose bit 7 is set, 0 in the others.
@inline(always)
private func signMask(_ lanes: SIMD16<UInt8>) -> SIMD16<UInt8> {
    bitCast(bitCast(lanes, to: SIMD16<Int8>.self) &>> 7, to: SIMD16<UInt8>.self)
}

/// The code units whose low bytes are lanes 0-7 of `low` and whose high bytes are lanes 0-7 of `high`.
@inline(always)
private func firstCodeUnits(_ low: SIMD16<UInt8>, _ high: SIMD16<UInt8>) -> SIMD8<UInt16> {
    bitCast(
        SIMD16<UInt8>(
            low[0], high[0], low[1], high[1], low[2], high[2], low[3], high[3], low[4], high[4], low[5], high[5],
            low[6], high[6], low[7], high[7]),
        to: SIMD8<UInt16>.self)
}

/// The code units whose low bytes are lanes 8-15 of `low` and whose high bytes are lanes 8-15 of `high`.
@inline(always)
private func secondCodeUnits(_ low: SIMD16<UInt8>, _ high: SIMD16<UInt8>) -> SIMD8<UInt16> {
    bitCast(
        SIMD16<UInt8>(
            low[8], high[8], low[9], high[9], low[10], high[10], low[11], high[11], low[12], high[12], low[13],
            high[13], low[14], high[14], low[15], high[15]),
        to: SIMD8<UInt16>.self)
}

/// For 8 byte lanes that are each 0 or 0xFF, a mask with bit i set if lane i is 0xFF.
@inline(always)
private func laneMask(_ lanes: UInt64) -> UInt8 {
    UInt8(truncatingIfNeeded: ((lanes & 0x8040_2010_0804_0201) &* 0x0101_0101_0101_0101) &>> 56)
}

/// For 8 byte lanes that are each 0 or 0xFF, the number of lanes that are 0xFF.
@inline(always)
private func laneCount(_ lanes: UInt64) -> Int {
    Int(truncatingIfNeeded: ((lanes & 0x0101_0101_0101_0101) &* 0x0101_0101_0101_0101) &>> 56)
}

/// Stores the code units formed from `low` and `high` at `written`, skipping lanes where `dropped` is
/// 0xFF, and advances `written`. Each half is packed and stored as 8 code units, so units past the kept
/// ones land beyond `written`.
@inline(always)
private func storePackedCodeUnits(
    _ low: SIMD16<UInt8>,
    _ high: SIMD16<UInt8>,
    dropping dropped: SIMD16<UInt8>,
    _ destination: inout MutableRawSpan,
    _ written: inout Int
) {
    let droppedWords = bitCast(dropped, to: SIMD2<UInt64>.self)
    let firstDropped = laneMask(droppedWords[0])
    let secondDropped = laneMask(droppedWords[1])
    let index = bitCast(
        SIMD2<UInt64>(
            remainingLaneIndices[Int(firstDropped)], remainingLaneIndices[Int(secondDropped)] | 0x0808_0808_0808_0808),
        to: SIMD16<UInt8>.self)
    let lowBytes = neon_tbl(low, index)
    let highBytes = neon_tbl(high, index)
    let first = firstCodeUnits(lowBytes, highBytes)
    let second = secondCodeUnits(lowBytes, highBytes)
    let firstCount = 8 &- laneCount(droppedWords[0])
    let secondCount = 8 &- laneCount(droppedWords[1])
    destination.storeBytes(of: first, toByteOffset: written &* 2, as: SIMD8<UInt16>.self)
    destination.storeBytes(of: second, toByteOffset: (written &+ firstCount) &* 2, as: SIMD8<UInt16>.self)
    written &+= firstCount &+ secondCount
}

/// Decodes the run of valid 2-byte sequences after the first byte of `source`, 8 at a time, then
/// the run of ASCII bytes and valid 2-byte sequences after it, 16 bytes at a time, to UTF-16 code
/// units at the start of `destination`. The first byte of `source` ends a character, and is not a
/// lead byte. Returns the bytes read after it and the code units written. Stops at the first block
/// that holds any other byte, or when fewer than 16 bytes remain. A 2-byte sequence that ends after a
/// block is decoded with the next block, or, after the last block, left to the caller.
@inline(never)
private func decodeOneAndTwoByteSequences(
    _ source: Span<UInt8>,
    _ destination: consuming MutableSpan<UInt16>
) -> (read: Int, written: Int) {
    var (read, written) = decodeTwoByteSequences(
        source.extracting(droppingFirst: 1), destination._mutatingExtracting(droppingFirst: 0))
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    // The unread input, starting with the byte before the next block.
    var input = sourceBytes.extracting(droppingFirst: read)
    // 0xFF for the high 4 bits of 0xC0...0xFF.
    let leadBytes = SIMD16<UInt8>(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF)
    // Each lane is classified together with the byte before it. The last lanes of `lastBlock` and
    // `lastLeads` hold that byte for the block's first lane, and whether it is 0xC0...0xFF.
    var lastBlock = SIMD16<UInt8>(repeating: input.load(fromByteOffset: 0, as: UInt8.self))
    var lastLeads = neon_tbl(leadBytes, lastBlock &>> 4)
    while input.byteCount >= 17 {
        let view = input.extracting(0..<17)
        let block = view.load(fromByteOffset: 1, as: SIMD16<UInt8>.self)
        let previous = SIMD16<UInt8>(
            lastBlock[15], block[0], block[1], block[2], block[3], block[4], block[5], block[6], block[7], block[8],
            block[9], block[10], block[11], block[12], block[13], block[14])
        let shifted = block &<< 1
        // 0xC0...0xFF, 0x80...0xBF, and the bytes before that are 0xC0...0xFF.
        let leads = neon_tbl(leadBytes, block &>> 4)
        let continuations = signMask(block & ~shifted)
        let previousLeads = SIMD16<UInt8>(
            lastLeads[15], leads[0], leads[1], leads[2], leads[3], leads[4], leads[5], leads[6], leads[7], leads[8],
            leads[9], leads[10], leads[11], leads[12], leads[13], leads[14])
        // Bit 7 is set in each lane that is a continuation byte not after a lead byte, a byte after
        // a lead byte that is not a continuation byte, 0xE0...0xFF, 0xC0 or 0xC1.
        let invalid =
            (continuations ^ previousLeads) | (leads & (block &<< 2))
            | (leads & ((block & 0x1E) &- 1))
        if invalid.max() >= 0x80 {
            break
        }
        // The code unit of each character in the lane of its last byte, split into its low and high
        // bytes.
        let low = (block & ~(continuations & 0xC0)) | ((previous &<< 6) & continuations)
        let high = ((previous &>> 2) & 0x07) & continuations
        // Packs the lanes that end a character, those that are not lead bytes, to the front of each
        // half of the block.
        storePackedCodeUnits(low, high, dropping: leads, &destinationBytes, &written)
        lastBlock = block
        lastLeads = leads
        input = input.extracting(droppingFirst: 16)
        read &+= 16
    }
    // A lead byte in the last lane read starts a 2-byte sequence that ends after the block. It is left
    // to the caller.
    if source[read] >= 0xC0 {
        read &-= 1
    }
    return (read, written)
}

/// Decodes the run of valid sequences of 1 to 4 bytes after the first 3 bytes of `source`, 16 bytes
/// at a time, to UTF-16 code units at the start of `destination`. The first 3 bytes of `source` are
/// the last bytes of a valid sequence. Returns the bytes read after them and the code units written.
/// Stops at the first block that holds an invalid sequence, or when fewer than 16 bytes remain. A
/// sequence that ends after a block is decoded with the next block, or, after the last block, left to
/// the caller.
@inline(never)
private func decodeOneToFourByteSequences(
    _ source: Span<UInt8>,
    _ destination: consuming MutableSpan<UInt16>
) -> (read: Int, written: Int) {
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    // Tables indexed by the high or low 4 bits of a byte or of the byte before it. In each lane, the
    // three lookups ANDed have a bit set for each error the two bytes make: 0x01 a lead byte followed
    // by a lead byte or an ASCII byte, 0x02 an ASCII byte followed by a continuation byte, 0x04 an
    // overlong 3-byte sequence, 0x08 a character above U+10FFFF, 0x10 a surrogate, 0x20 an overlong
    // 2-byte sequence, 0x40 an overlong 4-byte sequence or 0xF5...0xFF followed by 0x80...0x8F, and
    // 0x80 two continuation bytes.
    let previousHighBitsErrors = SIMD16<UInt8>(
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x80, 0x80, 0x80, 0x80, 0x21, 0x01, 0x15, 0x49)
    let previousLowBitsErrors = SIMD16<UInt8>(
        0xE7, 0xA3, 0x83, 0x83, 0x8B, 0xCB, 0xCB, 0xCB, 0xCB, 0xCB, 0xCB, 0xCB, 0xCB, 0xDB, 0xCB, 0xCB)
    let highBitsErrors = SIMD16<UInt8>(
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xE6, 0xAE, 0xBA, 0xBA, 0x01, 0x01, 0x01, 0x01)
    // 0xFF for the high 4 bits of 0xE0...0xFF, and of 0xF0...0xFF.
    let threeOrFourByteLeads = SIMD16<UInt8>(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF)
    let fourByteLeads = SIMD16<UInt8>(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF)
    // 0xFF for the high 4 bits of 0xC0...0xFF.
    let leadBytes = SIMD16<UInt8>(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF)
    // The unread input, starting with the 3 bytes before the next block.
    var input = sourceBytes
    var read = 0
    var written = 0
    // Each lane is classified together with the 3 bytes before it, so a sequence that starts in the
    // previous block is decoded in the lanes of its last bytes.
    while input.byteCount >= 19 {
        let view = input.extracting(0..<19)
        // Each lane of the block, and the bytes 1, 2 and 3 before it.
        let previous3 = view.load(fromByteOffset: 0, as: SIMD16<UInt8>.self)
        let previous2 = view.load(fromByteOffset: 1, as: SIMD16<UInt8>.self)
        let previous1 = view.load(fromByteOffset: 2, as: SIMD16<UInt8>.self)
        let block = view.load(fromByteOffset: 3, as: SIMD16<UInt8>.self)
        let previous1High = previous1 &>> 4
        let previous1Low = previous1 & 0x0F
        let blockHigh = block &>> 4
        let previous2High = previous2 &>> 4
        // 0xFF in the second byte of a 3- or 4-byte sequence, the third byte of a 3- or 4-byte
        // sequence, the third byte of a 4-byte sequence, and the fourth byte of a 4-byte sequence.
        let afterThreeOrFourByteLead = neon_tbl(threeOrFourByteLeads, previous1High)
        let twoAfterThreeOrFourByteLead = neon_tbl(threeOrFourByteLeads, previous2High)
        let twoAfterFourByteLead = neon_tbl(fourByteLeads, previous2High)
        let threeAfterFourByteLead = neon_tbl(fourByteLeads, previous3 &>> 4)
        // Nonzero in each lane that is an error. A continuation byte 2 bytes after a 3- or 4-byte lead
        // byte, or 3 bytes after a 4-byte lead byte, clears the two continuation bytes bit, and any
        // other byte there sets it.
        let errors =
            neon_tbl(previousHighBitsErrors, previous1High) & neon_tbl(previousLowBitsErrors, previous1Low)
            & neon_tbl(highBitsErrors, blockHigh)
        let invalid = errors ^ ((twoAfterThreeOrFourByteLead | threeAfterFourByteLead) & 0x80)
        if invalid.max() != 0 {
            break
        }
        // The code unit of each character in the lane of its last byte, or, for a 4-byte sequence,
        // the high surrogate in the lane of its third byte and the low surrogate in the lane of its
        // fourth, split into its low and high bytes. In the lanes kept, each byte that is not ASCII is
        // a continuation byte.
        let continuations = signMask(block)
        // In each continuation byte's lane, its low 6 bits under the low 2 bits of the byte before it;
        // in the other lanes, the byte itself.
        let continuationLow = block ^ (((previous1 &<< 6) ^ 0x80) & continuations)
        // Bits 0-7 of the high surrogate for a 4-byte sequence: bits 10-17 of the character, minus
        // 0x40.
        let highSurrogateLow = ((previous1 &<< 2) | (blockHigh & 0x03)) &+ 0xC0
        let low = (continuationLow & ~twoAfterFourByteLead) | (highSurrogateLow & twoAfterFourByteLead)
        let previous1Bits = previous1 &>> 2
        let previous2Bits = previous2 &<< 4
        // Bits 8-15 of the character for a 2- or 3-byte sequence, or of the low surrogate for a 4-byte
        // sequence.
        let characterHigh =
            (previous1Bits & (continuations & 0x0F)) | (previous2Bits & twoAfterThreeOrFourByteLead)
            | (threeAfterFourByteLead & 0xDC)
        // Bits 8-15 of the high surrogate for a 4-byte sequence: 0xD8 and bits 18-19 of the character
        // minus 0x10000.
        let highSurrogateHigh = (((previous2Bits | (previous1Bits & 0x0C)) &- 4) &>> 4) | 0xD8
        let high = (characterHigh & ~twoAfterFourByteLead) | (highSurrogateHigh & twoAfterFourByteLead)
        // Packs the lanes that hold a code unit to the front of each half of the block: all but the
        // lead bytes and the second bytes of 3- and 4-byte sequences.
        let dropped = neon_tbl(leadBytes, blockHigh) | afterThreeOrFourByteLead
        storePackedCodeUnits(low, high, dropping: dropped, &destinationBytes, &written)
        input = input.extracting(droppingFirst: 16)
        read &+= 16
    }
    // A lead byte in the last lane read, 0xE0...0xFF in the lane before it, or 0xF0...0xFF in the lane
    // before that starts a sequence that ends after the block. It is left to the caller, and so is the
    // high surrogate written for a 4-byte sequence. Without a block, the first 3 bytes of `source`
    // end a sequence.
    if read != 0 {
        let lastBytes = sourceBytes.load(fromByteOffset: read &- 1, as: UInt32.self)
        if UInt8(truncatingIfNeeded: lastBytes &>> 24) >= 0xC0 {
            read &-= 1
        } else if UInt8(truncatingIfNeeded: lastBytes &>> 16) >= 0xE0 {
            read &-= 2
        } else if UInt8(truncatingIfNeeded: lastBytes &>> 8) >= 0xF0 {
            read &-= 3
            written &-= 1
        }
    }
    return (read, written)
}

/// Decodes the block of 4 3-byte sequences at `read` in `source` to UTF-16 code units in
/// `destination` at `written`, advancing both past its leading valid 3-byte sequences. Returns true
/// if all 4 are valid. `source` holds at least 16 bytes from `read` on.
@inline(always)
private func decodeThreeByteBlock(
    _ source: Span<UInt8>,
    _ read: inout Int,
    _ destination: inout MutableSpan<UInt16>,
    _ written: inout Int
) -> Bool {
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    // Spreads the first 12 bytes of a block into 4 lanes of 3 bytes, the fourth byte zero.
    let sequenceIndex = SIMD16<UInt8>(0, 1, 2, 0xFF, 3, 4, 5, 0xFF, 6, 7, 8, 0xFF, 9, 10, 11, 0xFF)
    let block = sourceBytes.load(fromByteOffset: read, as: SIMD16<UInt8>.self)
    let sequences = bitCast(neon_tbl(block, sequenceIndex), to: SIMD4<UInt32>.self)
    let characters =
        ((sequences & 0x0F) &<< 12) | ((sequences & 0x3F00) &>> 2) | ((sequences &>> 16) & 0x3F)
    // Zero for 0xE0...0xEF, then two continuation bytes, of a character in U+0800...U+FFFF
    // that is not a surrogate. These are the second bytes decodeNonASCIISequence allows.
    let invalidSequences =
        ((sequences & 0x00C0_C0F0) ^ 0x0080_80E0) | ((characters &- 0x800) & 0x8000_0000)
        | ((((characters & 0xF800) ^ 0xD800) &- 1) & 0x8000_0000)
    destinationBytes.storeBytes(
        of: SIMD4<UInt16>(truncatingIfNeeded: characters), toByteOffset: written &* 2, as: SIMD4<UInt16>.self)
    let invalid = bitCast(
        SIMD4<UInt16>(truncatingIfNeeded: invalidSequences | (invalidSequences &>> 16)), to: UInt64.self)
    if invalid != 0 {
        let count = leadingValidCount(invalid)
        read &+= count &* 3
        written &+= count
        return false
    }
    read &+= 12
    written &+= 4
    return true
}

/// Decodes the run of valid 3-byte sequences at the start of `source`, 4 at a time, to UTF-16 code
/// units at the start of `destination`. Returns the bytes read and the code units written. Stops at
/// the first block that is not 4 valid 3-byte sequences, or when fewer than 16 bytes remain.
@inline(never)
private func decodeThreeByteSequences(
    _ source: Span<UInt8>,
    _ destination: consuming MutableSpan<UInt16>
) -> (read: Int, written: Int) {
    var read = 0
    var written = 0
    while source.count &- read >= 16 {
        if !decodeThreeByteBlock(source, &read, &destination, &written) {
            break
        }
    }
    return (read, written)
}

/// Decodes the block of 4 4-byte sequences at `read` in `source` to UTF-16 surrogate pairs in
/// `destination` at `written`, advancing both past its leading valid 4-byte sequences. Returns true
/// if all 4 are valid. `source` holds at least 16 bytes from `read` on.
@inline(always)
private func decodeFourByteBlock(
    _ source: Span<UInt8>,
    _ read: inout Int,
    _ destination: inout MutableSpan<UInt16>,
    _ written: inout Int
) -> Bool {
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    let sequences = bitCast(
        sourceBytes.load(fromByteOffset: read, as: SIMD16<UInt8>.self), to: SIMD4<UInt32>.self)
    let characters =
        ((sequences & 0x07) &<< 18) | ((sequences & 0x3F00) &<< 4) | ((sequences &>> 10) & 0xFC0)
        | ((sequences &>> 24) & 0x3F)
    // Zero for 0xF0...0xF7, then three continuation bytes, of a character in
    // U+10000...U+10FFFF. The range rejects the second bytes that 0xF0 and 0xF4 do not allow,
    // and every character of 0xF5...0xF7.
    let invalidSequences =
        ((sequences & 0xC0C0_C0F8) ^ 0x8080_80F0) | ((characters &- 0x1_0000) & 0xFFF0_0000)
    let surrogatePairs = ((characters &>> 10) &+ 0xD7C0) | (((characters & 0x3FF) | 0xDC00) &<< 16)
    destinationBytes.storeBytes(
        of: bitCast(surrogatePairs, to: SIMD8<UInt16>.self), toByteOffset: written &* 2,
        as: SIMD8<UInt16>.self)
    let invalid = bitCast(
        SIMD4<UInt16>(truncatingIfNeeded: invalidSequences | (invalidSequences &>> 16)), to: UInt64.self)
    if invalid != 0 {
        let count = leadingValidCount(invalid)
        read &+= count &* 4
        written &+= count &* 2
        return false
    }
    read &+= 16
    written &+= 8
    return true
}

/// Decodes the run of valid 4-byte sequences at the start of `source`, 4 at a time, to UTF-16
/// surrogate pairs at the start of `destination`. Returns the bytes read and the code units
/// written. Stops at the first block that is not 4 valid 4-byte sequences, or when fewer than 16
/// bytes remain.
@inline(never)
private func decodeFourByteSequences(
    _ source: Span<UInt8>,
    _ destination: consuming MutableSpan<UInt16>
) -> (read: Int, written: Int) {
    var read = 0
    var written = 0
    while source.count &- read >= 16 {
        if !decodeFourByteBlock(source, &read, &destination, &written) {
            break
        }
    }
    return (read, written)
}

@inline(always)
private func isLatin1(_ character: Int32) -> Bool {
    UInt32(bitPattern: character) <= 0xFF
}

/// Writes `character` at `offset` in `destination`, as a surrogate pair if it is not in the BMP,
/// and advances `offset` past it.
@inline(always)
private func appendCharacter(_ destination: inout MutableSpan<UInt16>, _ offset: inout Int, _ character: Int32) {
    if character <= 0xFFFF {
        destination[offset] = UInt16(truncatingIfNeeded: character)
        offset &+= 1
    } else {
        destination[offset] = UInt16(truncatingIfNeeded: (character &>> 10) &+ 0xD7C0)
        destination[offset &+ 1] = UInt16(truncatingIfNeeded: (character & 0x3FF) | 0xDC00)
        offset &+= 2
    }
}

/// Decodes the held partial sequence into Latin-1 characters, completing it from `source`.
/// Returns true at the first character that is not Latin-1, or the first error.
private func handlePartialSequence(
    _ partialSequence: inout PartialSequence,
    _ destination: inout MutableSpan<UInt8>,
    _ written: inout Int,
    _ source: Span<UInt8>,
    _ read: inout Int,
    _ flush: Bool
) -> Bool {
    repeat {
        let firstByte = partialSequence.bytes[0]
        if firstByte < 0x80 {
            destination[written] = firstByte
            written &+= 1
            partialSequence.removeFirst(1)
            continue
        }
        var count = nonASCIISequenceLength(firstByte)
        if count == 0 {
            return true
        }
        let partialSequenceIsTooShort = partialSequence.fill(to: count, from: source, &read)
        let character = decodeNonASCIISequence(partialSequence.bytes.span, 0, &count)
        // If we're not at the end, and the partial sequence that we have is incomplete but
        // otherwise valid, a non-character is not an error.
        if partialSequenceIsTooShort && !flush && count == partialSequence.size {
            return false
        }
        if !isLatin1(character) {
            return true
        }
        partialSequence.size &-= count
        destination[written] = UInt8(truncatingIfNeeded: character)
        written &+= 1
    } while partialSequence.size != 0
    return false
}

/// Decodes the held partial sequence into UTF-16 code units, completing it from `source`.
private func handlePartialSequence(
    _ partialSequence: inout PartialSequence,
    _ destination: inout MutableSpan<UInt16>,
    _ written: inout Int,
    _ source: Span<UInt8>,
    _ read: inout Int,
    _ flush: Bool,
    _ stopOnError: Bool,
    _ sawError: inout Bool,
    _ shouldStripByteOrderMark: inout Bool
) {
    repeat {
        let firstByte = partialSequence.bytes[0]
        if firstByte < 0x80 {
            destination[written] = UInt16(firstByte)
            written &+= 1
            partialSequence.removeFirst(1)
            continue
        }
        var count = nonASCIISequenceLength(firstByte)
        if count == 0 {
            sawError = true
            if stopOnError {
                return
            }
            destination[written] = replacementCharacter
            written &+= 1
            partialSequence.removeFirst(1)
            continue
        }
        let partialSequenceIsTooShort = partialSequence.fill(to: count, from: source, &read)
        let character = decodeNonASCIISequence(partialSequence.bytes.span, 0, &count)
        // If we're not at the end, and the partial sequence that we have is incomplete but
        // otherwise valid, a non-character is not an error.
        if partialSequenceIsTooShort && !flush && count == partialSequence.size {
            return
        }
        if character == nonCharacter {
            sawError = true
            if stopOnError {
                return
            }
            destination[written] = replacementCharacter
            written &+= 1
            partialSequence.removeFirst(count)
            continue
        }
        partialSequence.removeFirst(count)
        let shouldStrip = shouldStripByteOrderMark
        shouldStripByteOrderMark = false
        if shouldStrip && character == byteOrderMark {
            continue
        }
        appendCharacter(&destination, &written, character)
    } while partialSequence.size != 0
}

/// Decodes `source` into Latin-1 characters in `destination`, starting from `state`.
///
/// Stops with `needsUpconvert` at the first character that is not Latin-1, at an invalid partial
/// sequence, or at an invalid sequence in `source` when not stopping on error; `bytesRead` and
/// `state` then say where the 16-bit decoder continues.
///
/// `source` is the caller's byte sequence and `destination` is the 8-bit `StringBuffer` of
/// `TextCodecUTF8::decode`. Both are owned by `TextCodecUTF8::decode` for the whole call, and they do
/// not overlap.
/// FIXME: Take `Span` and `MutableSpan` parameters once a `std::span` can be received safely
/// (rdar://186723514).
@_expose(Cxx)
public func decodeUTF8ToLatin1(
    _ state: PAL.TextCodecUTF8DecoderState,
    _ source: PAL.UTF8ByteSequence,
    _ destination: PAL.Latin1CharacterSpan,
    _ flush: Bool,
    _ stopOnError: Bool
) -> PAL.TextCodecUTF8DecodeResult {
    let bytes = unsafe Span<UInt8>(_unsafeCxxSpan: source)
    var characters = unsafe MutableSpan<UInt8>(_unsafeCxxSpan: destination)
    let sourceBytes = bytes.bytes

    var partialSequence = PartialSequence(state)
    var sawError = false
    var read = 0
    var written = 0

    func upconvert(written: Int) -> PAL.TextCodecUTF8DecodeResult {
        PAL.TextCodecUTF8DecodeResult(
            state: partialSequence.state(shouldStripByteOrderMark: state.shouldStripByteOrderMark),
            bytesRead: read,
            charactersWritten: written,
            sawError: sawError,
            needsUpconvert: true
        )
    }

    repeat {
        if partialSequence.size != 0 {
            var writtenForPartialSequence = written
            if handlePartialSequence(&partialSequence, &characters, &writtenForPartialSequence, bytes, &read, flush) {
                return upconvert(written: written)
            }
            written = writtenForPartialSequence
            if partialSequence.size != 0 {
                break
            }
        }

        while read < bytes.count {
            let byte = bytes[read]
            if byte < 0x80 {
                // Fast path for ASCII. Most UTF-8 text will be ASCII.
                if !copyASCII(bytes, &read, &characters, &written) {
                    break
                }
                continue
            }
            // Fast path for a valid 2-byte sequence of a Latin-1 character: 0xC2 or 0xC3, then a
            // continuation byte. The word holds the byte after the sequence too.
            if byte &- 0xC2 < 2 && bytes.count &- read >= 4 {
                let sequence = sourceBytes.load(fromByteOffset: read, as: UInt32.self)
                let secondByte = UInt8(truncatingIfNeeded: sequence &>> 8)
                if isContinuationByte(secondByte) {
                    characters[written] = (byte &<< 6) | (secondByte & 0x3F)
                    read &+= 2
                    written &+= 1
                    if UInt8(truncatingIfNeeded: sequence &>> 16) &- 0xC2 < 2 && bytes.count &- read >= 16 {
                        decodeLatin1Sequences(bytes, &read, &characters, &written)
                    }
                    continue
                }
            }
            var count = nonASCIISequenceLength(byte)
            let character: Int32
            if count == 0 {
                character = nonCharacter
            } else {
                if count > bytes.count &- read {
                    partialSequence.hold(bytes, from: read)
                    read = bytes.count
                    break
                }
                character = decodeNonASCIISequence(bytes, read, &count)
            }
            if character == nonCharacter {
                sawError = true
                if stopOnError {
                    break
                }
                return upconvert(written: written)
            }
            if !isLatin1(character) {
                return upconvert(written: written)
            }
            read &+= count
            characters[written] = UInt8(truncatingIfNeeded: character)
            written &+= 1
        }
    } while partialSequence.size != 0

    if flush {
        partialSequence.size = 0
    }
    let shouldStripByteOrderMark = state.shouldStripByteOrderMark && !(flush || written != 0)
    return PAL.TextCodecUTF8DecodeResult(
        state: partialSequence.state(shouldStripByteOrderMark: shouldStripByteOrderMark),
        bytesRead: read,
        charactersWritten: written,
        sawError: sawError,
        needsUpconvert: false
    )
}

/// Decodes `source` into UTF-16 code units in `destination`, after the `charactersWritten`
/// characters it already holds, starting from `state`.
///
/// `source` is the caller's byte sequence and `destination` is the 16-bit `StringBuffer` of
/// `TextCodecUTF8::decode`. Both are owned by `TextCodecUTF8::decode` for the whole call, and they do
/// not overlap.
/// FIXME: Take `Span` and `MutableSpan` parameters once a `std::span` can be received safely
/// (rdar://186723514).
@_expose(Cxx)
public func decodeUTF8ToUTF16(
    _ state: PAL.TextCodecUTF8DecoderState,
    _ source: PAL.UTF8ByteSequence,
    _ destination: PAL.UTF16CharacterSpan,
    _ charactersWritten: Int,
    _ flush: Bool,
    _ stopOnError: Bool
) -> PAL.TextCodecUTF8DecodeResult {
    let bytes = unsafe Span<UInt8>(_unsafeCxxSpan: source)
    var characters = unsafe MutableSpan<UInt16>(_unsafeCxxSpan: destination)
    let sourceBytes = bytes.bytes

    var partialSequence = PartialSequence(state)
    var shouldStripByteOrderMark = state.shouldStripByteOrderMark
    var sawError = false
    var read = 0
    var written = charactersWritten

    repeat {
        if partialSequence.size != 0 {
            handlePartialSequence(
                &partialSequence, &characters, &written, bytes, &read, flush, stopOnError, &sawError,
                &shouldStripByteOrderMark)
            if partialSequence.size != 0 {
                break
            }
        }

        while read < bytes.count {
            let byte = bytes[read]
            if byte < 0x80 {
                // Fast path for ASCII. Most UTF-8 text will be ASCII.
                if !copyASCII(bytes, &read, &characters, &written) {
                    break
                }
                continue
            }
            if byte &- 0xC2 < 0x1E {
                // Fast path for a valid 2-byte sequence: 0xC2...0xDF, then a continuation byte. The
                // word holds the byte after the sequence too.
                if bytes.count &- read >= 4 {
                    let sequence = sourceBytes.load(fromByteOffset: read, as: UInt32.self)
                    let secondByte = UInt8(truncatingIfNeeded: sequence &>> 8)
                    if isContinuationByte(secondByte) {
                        characters[written] = (UInt16(byte & 0x1F) &<< 6) | UInt16(secondByte & 0x3F)
                        read &+= 2
                        written &+= 1
                        // The run of 2-byte sequences and ASCII bytes that follows is decoded out of line,
                        // once per run, so the call is rare next to the characters decoded here.
                        if _slowPath(UInt8(truncatingIfNeeded: sequence &>> 16) &- 0xC2 < 0x1E && bytes.count &- read >= 16) {
                            // The byte before `read` is the last byte of a 2-byte sequence.
                            let (bytesRead, codeUnitsWritten) = decodeOneAndTwoByteSequences(
                                bytes.extracting(droppingFirst: read &- 1),
                                characters._mutatingExtracting(droppingFirst: written))
                            read &+= bytesRead
                            written &+= codeUnitsWritten
                        }
                        continue
                    }
                }
            } else if byte &- 0xC2 >= 0x33 {
                // A byte in 0x80...0xC1 or 0xF5...0xFF starts no sequence: it is one error, and one
                // replacement character. Runs of 0x80...0xC1 are replaced 16 at a time.
                sawError = true
                if stopOnError {
                    break
                }
                if byte < 0xC2 && bytes.count &- read >= 16 {
                    let replacementCharacters = SIMD8<UInt16>(repeating: replacementCharacter)
                    var destinationBytes = characters.mutableBytes
                    let start = read
                    repeat {
                        let block = sourceBytes.load(fromByteOffset: read, as: SIMD16<UInt8>.self)
                        if (block &- 0x80).max() >= 0x42 {
                            break
                        }
                        destinationBytes.storeBytes(
                            of: replacementCharacters, toByteOffset: written &* 2, as: SIMD8<UInt16>.self)
                        destinationBytes.storeBytes(
                            of: replacementCharacters, toByteOffset: written &* 2 &+ 16,
                            as: SIMD8<UInt16>.self)
                        read &+= 16
                        written &+= 16
                    } while bytes.count &- read >= 16
                    if read != start {
                        continue
                    }
                }
                characters[written] = replacementCharacter
                read &+= 1
                written &+= 1
                continue
            } else if byte < 0xF0 {
                // Fast path for a valid 3-byte sequence whose second byte can be any continuation
                // byte: 0xE1...0xEC or 0xEE...0xEF, then two continuation bytes. A byte order mark
                // takes the path below. The word holds the byte after the sequence too.
                if byte != 0xE0 && byte != 0xED && bytes.count &- read >= 4 {
                    let sequence = sourceBytes.load(fromByteOffset: read, as: UInt32.self)
                    let character =
                        (UInt16(byte & 0x0F) &<< 12) | (UInt16(truncatingIfNeeded: sequence &>> 2) & 0x0FC0)
                        | (UInt16(truncatingIfNeeded: sequence &>> 16) & 0x3F)
                    if sequence & 0x00C0_C000 == 0x0080_8000 && character != UInt16(byteOrderMark) {
                        characters[written] = character
                        read &+= 3
                        written &+= 1
                        // The blocks decode a byte order mark as a character, as the path below
                        // does once a character is written.
                        if UInt8(truncatingIfNeeded: sequence &>> 24) &- 0xE0 < 0x10 && bytes.count &- read >= 16
                            && decodeThreeByteBlock(bytes, &read, &characters, &written) {
                            let (bytesRead, codeUnitsWritten) = decodeThreeByteSequences(
                                bytes.extracting(droppingFirst: read),
                                characters._mutatingExtracting(droppingFirst: written))
                            read &+= bytesRead
                            written &+= codeUnitsWritten
                        } else if _slowPath(sequence >= 0xC000_0000) {
                            // The byte after the sequence is a lead byte. The 3 bytes before `read` are
                            // the last 3-byte sequence decoded.
                            let (bytesRead, codeUnitsWritten) = decodeOneToFourByteSequences(
                                bytes.extracting(droppingFirst: read &- 3),
                                characters._mutatingExtracting(droppingFirst: written))
                            read &+= bytesRead
                            written &+= codeUnitsWritten
                        }
                        continue
                    }
                }
            } else if bytes.count &- read >= 8 {
                // Fast path for a valid 4-byte sequence: 0xF0...0xF4, then three continuation bytes,
                // of a character in U+10000...U+10FFFF. The range rejects the second bytes that 0xF0
                // and 0xF4 do not allow. The word holds the byte after the sequence too.
                let sequence = sourceBytes.load(fromByteOffset: read, as: UInt64.self)
                let character =
                    (UInt32(byte & 0x07) &<< 18) | ((UInt32(truncatingIfNeeded: sequence &>> 8) & 0x3F) &<< 12)
                    | ((UInt32(truncatingIfNeeded: sequence &>> 16) & 0x3F) &<< 6)
                    | (UInt32(truncatingIfNeeded: sequence &>> 24) & 0x3F)
                if sequence & 0xC0C0_C000 == 0x8080_8000 && character &- 0x1_0000 < 0x10_0000 {
                    characters[written] = UInt16(truncatingIfNeeded: (character &>> 10) &+ 0xD7C0)
                    characters[written &+ 1] = UInt16(truncatingIfNeeded: (character & 0x3FF) | 0xDC00)
                    read &+= 4
                    written &+= 2
                    if UInt8(truncatingIfNeeded: sequence &>> 32) &- 0xF0 < 5 && bytes.count &- read >= 16
                        && decodeFourByteBlock(bytes, &read, &characters, &written) {
                        let (bytesRead, codeUnitsWritten) = decodeFourByteSequences(
                            bytes.extracting(droppingFirst: read),
                            characters._mutatingExtracting(droppingFirst: written))
                        read &+= bytesRead
                        written &+= codeUnitsWritten
                    }
                    continue
                }
            }
            var count = nonASCIISequenceLength(byte)
            let character: Int32
            if count == 0 {
                character = nonCharacter
            } else {
                if count > bytes.count &- read {
                    partialSequence.hold(bytes, from: read)
                    read = bytes.count
                    break
                }
                character = decodeNonASCIISequence(bytes, read, &count)
            }
            if character == nonCharacter {
                sawError = true
                if stopOnError {
                    break
                }
                characters[written] = replacementCharacter
                written &+= 1
                read &+= count != 0 ? count : 1
                continue
            }
            read &+= count
            if character == byteOrderMark && written == 0 && shouldStripByteOrderMark {
                shouldStripByteOrderMark = false
                continue
            }
            appendCharacter(&characters, &written, character)
        }
    } while partialSequence.size != 0

    if flush {
        partialSequence.size = 0
    }
    if flush || written != 0 {
        shouldStripByteOrderMark = false
    }
    return PAL.TextCodecUTF8DecodeResult(
        state: partialSequence.state(shouldStripByteOrderMark: shouldStripByteOrderMark),
        bytesRead: read,
        charactersWritten: written,
        sawError: sawError,
        needsUpconvert: false
    )
}

#endif
