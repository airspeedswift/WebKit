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

// The Swift implementation of `TextCodecUTF8::decode`, replacing the C++ decode loops when PAL is
// built with USE_SWIFT_TEXT_CODEC_UTF8. `textCodecUTF8DecodeNarrow` fills the 8-bit buffer and stops
// with `needsWide` at the first character Latin-1 cannot hold; `textCodecUTF8DecodeWide` resumes from
// that result into the 16-bit buffer.
//
// The output width under `stopOnError` follows the C++ exactly: the 8-bit main loop's `stopOnError`
// exit keeps the 8-bit buffer, but an ill-formed partial sequence upconverts even under
// `stopOnError`.

#if USE_SWIFT_TEXT_CODEC_UTF8

public import pal.Core.text.TextCodecUTF8SwiftTypes

private let highBitsOfEachByte: UInt64 = 0x8080_8080_8080_8080

private let replacementCharacter: UInt16 = 0xFFFD

private let byteOrderMark: UInt32 = 0xFEFF
private let byteOrderMarkBytes: (UInt8, UInt8, UInt8) = (0xEF, 0xBB, 0xBF)

// Compares rather than a table like `nonASCIISequenceLength`: a global `let` table costs a
// one-time-initialization check on every access.
@inline(always)
private func sequenceLength(_ firstByte: UInt8) -> Int {
    if firstByte < 0xC2 { return 0 }
    if firstByte < 0xE0 { return 2 }
    if firstByte < 0xF0 { return 3 }
    if firstByte < 0xF5 { return 4 }
    return 0
}

@inline(always)
private func isValidSecondByte(_ firstByte: UInt8, _ secondByte: UInt8) -> Bool {
    switch firstByte {
    case 0xE0: return secondByte >= 0xA0 && secondByte <= 0xBF
    case 0xED: return secondByte >= 0x80 && secondByte <= 0x9F
    case 0xF0: return secondByte >= 0x90 && secondByte <= 0xBF
    case 0xF4: return secondByte >= 0x80 && secondByte <= 0x8F
    default: return secondByte >= 0x80 && secondByte <= 0xBF
    }
}

// `isValidSecondByte` for a known sequence length, so that each length's path in `decodeWideChunk` tests only
// its own leads' limits.
@inline(always)
private func isValidSecondByteOfThree(_ firstByte: UInt8, _ secondByte: UInt8) -> Bool {
    if firstByte == 0xE0 { return secondByte >= 0xA0 && secondByte <= 0xBF }
    if firstByte == 0xED { return secondByte >= 0x80 && secondByte <= 0x9F }
    return isContinuationByte(secondByte)
}

@inline(always)
private func isValidSecondByteOfFour(_ firstByte: UInt8, _ secondByte: UInt8) -> Bool {
    if firstByte == 0xF0 { return secondByte >= 0x90 && secondByte <= 0xBF }
    if firstByte == 0xF4 { return secondByte >= 0x80 && secondByte <= 0x8F }
    return isContinuationByte(secondByte)
}

@inline(always)
private func isContinuationByte(_ byte: UInt8) -> Bool {
    byte >= 0x80 && byte <= 0xBF
}

@inline(always)
private func twoByteScalar(_ b0: UInt8, _ b1: UInt8) -> UInt32 {
    (UInt32(b0) << 6) &+ UInt32(b1) &- 0x3080
}

@inline(always)
private func threeByteScalar(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> UInt32 {
    (UInt32(b0) << 12) &+ (UInt32(b1) << 6) &+ UInt32(b2) &- 0xE2080
}

@inline(always)
private func fourByteScalar(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
    (UInt32(b0) << 18) &+ (UInt32(b1) << 12) &+ (UInt32(b2) << 6) &+ UInt32(b3) &- 0x3C82080
}

// A held partial sequence is packed byte `i` at bit `8 * i`, so shifting drops consumed bytes.
@inline(always)
private func packPartialSequence(_ source: Span<UInt8>, from start: Int, count: Int) -> UInt32 {
    var packed: UInt32 = 0
    for offset in 0..<count {
        packed |= UInt32(source[start + offset]) &<< (8 &* offset)
    }
    return packed
}

@inline(always)
private func partialSequenceByte(_ packed: UInt32, _ index: Int) -> UInt8 {
    UInt8(truncatingIfNeeded: packed &>> (8 &* index))
}

@inline(always)
private func packPartialSequence(_ held: PAL.TextCodecUTF8SwiftPartialSequence, count: Int) -> UInt32 {
    var packed: UInt32 = 0
    for offset in 0..<count {
        packed |= UInt32(held[offset]) &<< (8 &* offset)
    }
    return packed
}

@inline(always)
private func unpackPartialSequence(_ packed: UInt32, count: Int) -> PAL.TextCodecUTF8SwiftPartialSequence {
    var held = PAL.TextCodecUTF8SwiftPartialSequence()
    for offset in 0..<count {
        held[offset] = partialSequenceByte(packed, offset)
    }
    return held
}

@inline(always)
private func extendPartialSequence(
    _ packed: inout UInt32,
    size: inout Int,
    toLength length: Int,
    from source: Span<UInt8>,
    at index: inout Int
) {
    while size < length && index < source.count {
        packed |= UInt32(source[index]) &<< (8 &* size)
        size += 1
        index += 1
    }
}

@inline(always)
private func appendSurrogatePair(_ scalar: UInt32, to output: inout MutableSpan<UInt16>, at produced: Int) -> Int {
    output[produced] = UInt16(truncatingIfNeeded: (scalar &>> 10) &+ 0xD7C0)
    output[produced + 1] = UInt16(truncatingIfNeeded: (scalar & 0x3FF) &+ 0xDC00)
    return 2
}

@inline(always)
private func appendScalar(_ scalar: UInt32, to output: inout MutableSpan<UInt16>, at produced: Int) -> Int {
    guard scalar > 0xFFFF else {
        output[produced] = UInt16(truncatingIfNeeded: scalar)
        return 1
    }
    return appendSurrogatePair(scalar, to: &output, at: produced)
}

// `decodeNonASCIISequence` over a packed partial sequence. On `nil`, `subpart` is the number of
// bytes to skip. Bytes above the held size are zero, which is not a continuation byte, so an
// incomplete sequence answers `nil`.
@inline(always)
private func decodePartialSequence(_ packed: UInt32, _ length: Int) -> (character: UInt32?, subpart: Int) {
    let b0 = partialSequenceByte(packed, 0)
    let b1 = partialSequenceByte(packed, 1)
    if !isValidSecondByte(b0, b1) { return (nil, 1) }
    if length == 2 { return (twoByteScalar(b0, b1), 2) }
    let b2 = partialSequenceByte(packed, 2)
    if !isContinuationByte(b2) { return (nil, 2) }
    if length == 3 { return (threeByteScalar(b0, b1, b2), 3) }
    let b3 = partialSequenceByte(packed, 3)
    if !isContinuationByte(b3) { return (nil, 3) }
    return (fourByteScalar(b0, b1, b2, b3), 4)
}

private enum NarrowPartialSequenceOutcome {
    case latin1(character: UInt8, consumed: Int)
    case waiting(partialSequence: UInt32, size: Int, consumed: Int)
    // Nothing is emitted, as the C++ discards anything its 8-bit overload wrote before returning true.
    case needsWide(partialSequence: UInt32, size: Int, consumed: Int)
}

// The 8-bit `handlePartialSequence`. It needs no loop because a held sequence never starts with an
// ASCII byte and never outruns its lead's length, which the two preconditions check.
//
// Inlining it moves the 8-bit word loop in `textCodecUTF8DecodeNarrow` across a cache line, costing
// 5% on ASCII input.
@inline(never)
private func handlePartialSequenceNarrow(
    _ source: Span<UInt8>,
    from start: Int,
    partialSequence: UInt32,
    size partialSequenceSize: Int,
    flush: Bool
) -> NarrowPartialSequenceOutcome {
    let firstByte = partialSequenceByte(partialSequence, 0)
    precondition(firstByte >= 0x80, "a held UTF-8 partial sequence cannot begin with an ASCII byte")
    let length = sequenceLength(firstByte)
    // Not recorded as an error here; the 16-bit half records it.
    if length == 0 { return .needsWide(partialSequence: partialSequence, size: partialSequenceSize, consumed: start) }

    var packed = partialSequence
    var size = partialSequenceSize
    var index = start
    extendPartialSequence(&packed, size: &size, toLength: length, from: source, at: &index)

    let tooShort = length > size
    let (character, subpart) = decodePartialSequence(packed, length)
    if tooShort && !flush && subpart == size {
        return .waiting(partialSequence: packed, size: size, consumed: index)
    }
    // An ill-formed sequence upconverts too, as `isLatin1(nonCharacter)` is false in the C++.
    guard let character, character <= 0xFF else {
        return .needsWide(partialSequence: packed, size: size, consumed: index)
    }
    precondition(size == length, "a held UTF-8 partial sequence cannot outrun its lead byte's sequence")
    return .latin1(character: UInt8(truncatingIfNeeded: character), consumed: index)
}

private enum WidePartialSequenceOutcome {
    case decoded(consumed: Int)
    case waiting(partialSequence: UInt32, size: Int, consumed: Int)
    case stopped(partialSequence: UInt32, size: Int, consumed: Int)
}

// The 16-bit `handlePartialSequence`. As in the C++, the byte order mark rule here does not depend
// on position: the first character decoded spends the flag, wherever it lands.
private func handlePartialSequenceWide(
    _ source: Span<UInt8>,
    from start: Int,
    partialSequence: UInt32,
    size partialSequenceSize: Int,
    flush: Bool,
    stopOnError: Bool,
    into output: inout MutableSpan<UInt16>,
    units: inout Int,
    sawError: inout Bool,
    shouldStripByteOrderMark: inout Bool
) -> WidePartialSequenceOutcome {
    var packed = partialSequence
    var size = partialSequenceSize
    var index = start
    repeat {
        precondition(units < output.count, "UTF-8 wide partial sequence ran out of destination")

        let firstByte = partialSequenceByte(packed, 0)
        if firstByte < 0x80 {
            output[units] = UInt16(truncatingIfNeeded: firstByte)
            units += 1
            packed = packed &>> 8
            size -= 1
            continue
        }

        let length = sequenceLength(firstByte)
        if length == 0 {
            sawError = true
            if stopOnError { return .stopped(partialSequence: packed, size: size, consumed: index) }
            output[units] = replacementCharacter
            units += 1
            packed = packed &>> 8
            size -= 1
            continue
        }

        extendPartialSequence(&packed, size: &size, toLength: length, from: source, at: &index)

        let tooShort = length > size
        let (character, subpart) = decodePartialSequence(packed, length)
        if tooShort && !flush && subpart == size {
            return .waiting(partialSequence: packed, size: size, consumed: index)
        }

        guard let character else {
            sawError = true
            if stopOnError { return .stopped(partialSequence: packed, size: size, consumed: index) }
            output[units] = replacementCharacter
            units += 1
            packed = packed &>> (8 &* subpart)
            size -= subpart
            continue
        }

        packed = packed &>> (8 &* length)
        size -= length
        if shouldStripByteOrderMark {
            shouldStripByteOrderMark = false
            if character == byteOrderMark { continue }
        }
        units += appendScalar(character, to: &output, at: units)
    } while size != 0

    return .decoded(consumed: index)
}

// The kernels report an ill-formed sequence rather than handling it, keeping `stopOnError` and
// `sawError` out of the per-character loop. Carrying them costs 16% on four-byte input.
private enum ChunkOutcome {
    case complete(consumed: Int, produced: Int)
    // The truncated bytes are unexamined and not counted in `consumed`.
    case truncated(consumed: Int, produced: Int, partial: Int)
    case needsWide(consumed: Int, produced: Int)
    case illFormed(consumed: Int, produced: Int)
}

// Splits 16 bytes into the 8 bytes at even offsets and the 8 at odd offsets. Written lane by lane
// with literal indices, which every target lowers to one or two shuffles (uzp1/uzp2, pshufb or
// pack); the vector-subscript spelling becomes a lane loop.
@inline(always)
private func deinterleave(_ v: SIMD16<UInt8>) -> (even: SIMD8<UInt8>, odd: SIMD8<UInt8>) {
    (SIMD8(v[0], v[2], v[4], v[6], v[8], v[10], v[12], v[14]),
     SIMD8(v[1], v[3], v[5], v[7], v[9], v[11], v[13], v[15]))
}

// Zero in every lane where `leads` is in `0xC2 ..< 0xC2 + leadCount` and `continuations` is a
// continuation byte, and at least `leadCount` in any other: a bad continuation byte sets bit 6 or
// 7, which no in-range lead offset has. So one maximum tests sixteen bytes.
@inline(always)
private func twoByteBlockIsWellFormed(_ leads: SIMD8<UInt8>, _ continuations: SIMD8<UInt8>, leadCount: UInt8) -> Bool {
    ((leads &- 0xC2) | ((continuations & 0xC0) ^ 0x80)).max() < leadCount
}

// Decodes 16-byte blocks that are exactly eight two-byte sequences, from `index`, and returns how
// many bytes it consumed (twice the characters it produced); it can return 0. `run` bounds both
// views, as in `widenASCIIRun`, so the loop carries one bound. The callers try it only when the
// next character is two-byte too, and keep it out of line so the per-character loops do not pay
// for its registers.
@inline(never)
private func decodeTwoByteBlocksNarrow(
    _ sourceBytes: RawSpan,
    from index: Int,
    count run: Int,
    into output: inout MutableSpan<UInt8>,
    at produced: Int
) -> Int {
    let sourceRun = sourceBytes.extracting(index..<(index &+ run))
    var outputBytes = output.mutableBytes
    var outputRun = outputBytes.extracting(produced..<(produced &+ (run &>> 1)))
    var offset = 0
    while offset &+ 16 <= run {
        let (leads, continuations) = deinterleave(sourceRun.load(fromByteOffset: offset, as: SIMD16<UInt8>.self))
        // Only C2 and C3 lead Latin-1 characters.
        if !twoByteBlockIsWellFormed(leads, continuations, leadCount: 2) { break }
        outputRun.storeBytes(of: (leads &<< 6) | (continuations & 0x3F), toByteOffset: offset &>> 1, as: SIMD8<UInt8>.self)
        offset &+= 16
    }
    return offset
}


// MARK: - Uniform block runs (wide)
//
// Built only from operations that lower well on every target: loads, shifts, bitwise operations,
// widening, lane-literal picks from loaded vectors and max reductions. SIMDMask comparisons are
// avoided (they lower to a per-lane loop through the stack): a lane mask is the sign bit of a byte
// spread by an arithmetic shift. Blocks of mixed lengths are left to the per-character loop: a
// portable compaction (there is no portable dynamic shuffle) lowered to more instructions than
// that loop spends on them.

// 0xFF in each lane whose bit 7 is set, else 0.
@inline(always)
private func signMask(_ x: SIMD16<UInt8>) -> SIMD16<UInt8> {
    SIMD16<UInt8>(truncatingIfNeeded: SIMD16<Int8>(truncatingIfNeeded: x) &>> 7)
}

// 0xFF in each lane that is zero, else 0.
@inline(always)
private func zeroMask(_ x: SIMD16<UInt8>) -> SIMD16<UInt8> { ~signMask(x | (0 &- x)) }

@inline(always)
private func continuationMask(_ x: SIMD16<UInt8>) -> SIMD16<UInt8> { signMask(x & ~(x &<< 1)) }
// 11xxxxxx, 111xxxxx and 1111xxxx.
@inline(always)
private func leadMask(_ x: SIMD16<UInt8>) -> SIMD16<UInt8> { signMask(x & (x &<< 1)) }
@inline(always)
private func lead34Mask(_ x: SIMD16<UInt8>) -> SIMD16<UInt8> { signMask(x & (x &<< 1) & (x &<< 2)) }
@inline(always)
private func widen(_ x: SIMD8<UInt8>) -> SIMD8<UInt16> { SIMD8<UInt16>(truncatingIfNeeded: x) }

// The continuation-byte lanes of a block of six three-byte or eight two-byte characters. Globals,
// not literals, so the optimizer cannot see their lanes (see `decodeMixedBlocksWide`).
private let threeByteContinuationPattern = SIMD16<UInt8>(0, 0xFF, 0xFF, 0, 0xFF, 0xFF, 0, 0xFF, 0xFF, 0, 0xFF, 0xFF, 0, 0xFF, 0xFF, 0)
private let twoByteContinuationPattern = SIMD16<UInt8>(0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF)

// Decodes runs of 18-byte blocks that are six three-byte characters (dense CJK) and 16-byte
// blocks that are eight two-byte characters, from `index`, and returns the bytes consumed and code
// units produced. It stops at the first block that is neither, and near the end of `run`, leaving
// the rest to the per-character loop. `run` bounds both views as in `widenASCIIRun`.
@inline(never)
private func decodeUniformBlocksWide(
    _ sourceBytes: RawSpan,
    from index: Int,
    count run: Int,
    into output: inout MutableSpan<UInt16>,
    at produced: Int
) -> (consumed: Int, produced: Int) {
    let sourceRun = sourceBytes.extracting(index..<(index &+ run))
    var outputBytes = output.mutableBytes
    var outputRun = outputBytes.extracting((produced &* 2)..<((produced &+ run) &* 2))
    // Read once per call from globals: as literals, LLVM specializes each lane of an operation
    // with them (their lanes differ) and then computes the lanes in scalar code.
    let threeByteContinuations = threeByteContinuationPattern
    let twoByteContinuations = twoByteContinuationPattern
    var offset = 0
    var units = 0
    while true {
        let start = offset
        // Six three-byte characters, leads at 0, 3, ..., 15: the continuation bytes are where those
        // leads put them (0/0xFF lanes compared by subtraction), the leads are E0-EF and every lead
        // has its continuation bytes (the last one's follow the block), and the second bytes after
        // E0 and ED are in range. Each block reads 18 bytes, through the +2 load.
        while offset &+ 18 <= run {
            let v = sourceRun.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            let n1 = sourceRun.load(fromByteOffset: offset &+ 1, as: SIMD16<UInt8>.self)
            let n2 = sourceRun.load(fromByteOffset: offset &+ 2, as: SIMD16<UInt8>.self)
            let continuation = continuationMask(v)
            let secondHigh = signMask(n1 &<< 2)
            let three = (continuation &- threeByteContinuations) | (((v ^ 0xE0) & 0xF0) & ~continuation)
                | (leadMask(v) & ~continuationMask(n1)) | (lead34Mask(v) & ~continuationMask(n2))
                | (zeroMask(v ^ 0xE0) & ~secondHigh) | (zeroMask(v ^ 0xED) & secondHigh)
            if three.max() != 0 { break }
            // Lanes 6 and 7 are padding, stored past the units and overwritten: real lanes, since a
            // literal lane makes LLVM compute the others in scalar code.
            let l = widen(SIMD8(v[0], v[3], v[6], v[9], v[12], v[15], v[1], v[2]))
            let c1 = widen(SIMD8(n1[0], n1[3], n1[6], n1[9], n1[12], n1[15], n1[1], n1[2]))
            let c2 = widen(SIMD8(n2[0], n2[3], n2[6], n2[9], n2[12], n2[15], n2[1], n2[2]))
            outputRun.storeBytes(of: ((l & 0x0F) &<< 12) | ((c1 & 0x3F) &<< 6) | (c2 & 0x3F), toByteOffset: units &* 2, as: SIMD8<UInt16>.self)
            units &+= 6
            offset &+= 18
        }
        // Eight two-byte characters: C2-DF at the even lanes, continuation bytes at the odd.
        while offset &+ 16 <= run {
            let v = sourceRun.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            let continuation = continuationMask(v)
            let two = (continuation &- twoByteContinuations) | ((((v ^ 0xC0) & 0xE0) | zeroMask(v & 0x1E)) & ~continuation)
            if two.max() != 0 { break }
            let (leads, continuations) = deinterleave(v)
            outputRun.storeBytes(of: (widen(leads & 0x1F) &<< 6) | widen(continuations & 0x3F), toByteOffset: units &* 2, as: SIMD8<UInt16>.self)
            units &+= 8
            offset &+= 16
        }
        if offset == start { break }
    }
    return (offset, units)
}

// Out of line so that its tests are not hoisted into `decodeChunk`'s per-character path, which costs
// 12.5% on Latin-1 input. It runs at most once per call.
@inline(never)
private func classifyWideLead(
    _ source: Span<UInt8>,
    at index: Int,
    produced: Int
) -> ChunkOutcome {
    let firstByte = source[index]
    let length = sequenceLength(firstByte)
    let illFormed = ChunkOutcome.illFormed(consumed: index, produced: produced)
    if !isValidSecondByte(firstByte, source[index + 1]) { return illFormed }
    if length >= 3 && !isContinuationByte(source[index + 2]) { return illFormed }
    if length == 4 && !isContinuationByte(source[index + 3]) { return illFormed }
    return .needsWide(consumed: index, produced: produced)
}

private func decodeChunk(
    _ source: Span<UInt8>,
    from start: Int,
    into output: inout MutableSpan<UInt8>,
    startingAt startProduced: Int
) -> ChunkOutcome {
    let sourceBytes = source.bytes
    var index = start
    var produced = startProduced
    let end = source.count
    // Each character is one output byte for at least one input byte, so this is the only capacity check.
    let limit = min(end, index + output.count - startProduced)

    while index < limit {
        // Copied before the word loop rather than re-read by it, which is 4-7% faster on mixed input.
        let firstByte = source[index]
        if firstByte < 0x80 {
            output[produced] = firstByte
            produced += 1
            index += 1

            // Unaligned loads, so unlike the C++ this needs no scalar run to realign.
            //
            // The loop runs over two views with the same byte count, so one bound covers the load and
            // the store and the per-word checks fold into the loop condition. Indexing `sourceBytes`
            // and `outputBytes` directly costs two more branches per word. The output view fits
            // because every step so far consumed at least as many bytes as it produced, so
            // `produced + (limit - index) <= startProduced + (limit - start) <= output.count`.
            do {
                let run = limit &- index
                let sourceRun = sourceBytes.extracting(index..<limit)
                var outputBytes = output.mutableBytes
                var outputRun = outputBytes.extracting(produced..<(produced &+ run))
                // Wrapping adds, because `offset + 8 <= run` bounds them.
                //
                // The word is stored before it is tested. On a break, the ASCII bytes ahead of the
                // first non-ASCII byte are then already in place and the loop steps past just those.
                // Without this, each of those up-to-7 bytes goes around the outer loop one at a time
                // and re-enters this block. The bytes stored past `offset` are overwritten, because
                // output is written in order from `produced`.
                var offset = 0
                // 32 bytes per iteration while the run is ASCII; the word loop below finds the first
                // non-ASCII byte of the block that ends this, and finishes the tail.
                while offset &+ 32 <= run {
                    let low = sourceRun.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
                    let high = sourceRun.load(fromByteOffset: offset &+ 16, as: SIMD16<UInt8>.self)
                    if (low | high).max() >= 0x80 { break }
                    outputRun.storeBytes(of: low, toByteOffset: offset, as: SIMD16<UInt8>.self)
                    outputRun.storeBytes(of: high, toByteOffset: offset &+ 16, as: SIMD16<UInt8>.self)
                    offset &+= 32
                }
                while offset &+ 8 <= run {
                    let word = sourceRun.load(fromByteOffset: offset, as: UInt64.self)
                    outputRun.storeBytes(of: word, toByteOffset: offset, as: UInt64.self)
                    let nonASCII = UInt64(littleEndian: word) & highBitsOfEachByte
                    if nonASCII != 0 {
                        offset &+= nonASCII.trailingZeroBitCount &>> 3
                        break
                    }
                    offset &+= 8
                }
                index &+= offset
                produced &+= offset
            }
            continue
        }

        let length = sequenceLength(firstByte)
        if length == 0 { return .illFormed(consumed: index, produced: produced) }

        if index + length > end {
            return .truncated(consumed: index, produced: produced, partial: end - index)
        }

        // Only 0xC2 and 0xC3 lead non-ASCII Latin-1 characters. Anything else is validated before
        // widening, since under `stopOnError` an ill-formed sequence leaves the string 8-bit.
        if firstByte > 0xC3 { return classifyWideLead(source, at: index, produced: produced) }

        let secondByte = source[index + 1]
        if !isContinuationByte(secondByte) { return .illFormed(consumed: index, produced: produced) }

        output[produced] = UInt8(truncatingIfNeeded: twoByteScalar(firstByte, secondByte))
        produced += 1
        index += 2

        // A second two-byte character in a row: decode eight per block while the input is exactly
        // that. Tested after the first, so an isolated one pays only the test of the byte the loop
        // reads next anyway.
        if end &- index >= 16 && source[index] & 0xE0 == 0xC0 {
            let blocks = decodeTwoByteBlocksNarrow(
                sourceBytes, from: index, count: min(end &- index, (output.count &- produced) &* 2),
                into: &output, at: produced)
            index &+= blocks
            produced &+= blocks &>> 1
        }
    }

    return .complete(consumed: index, produced: produced)
}

// Widens the ASCII run at `index` into `output` at `produced`, a word at a time, and returns how many
// bytes it consumed (and code units it produced). It stops at the first non-ASCII byte or when fewer
// than 8 units remain, and it can return 0.
//
// It takes two views of `run` units each, so one bound covers the load and both stores. Each word is
// stored before it is tested, so a break steps past exactly the ASCII prefix. The lanes widened from
// bytes past it are overwritten, because output is written in order from `produced`.
//
// Not inlined: inline, the views' setup costs `decodeWideChunk` a register, and its per-character
// loop then pays an extra address computation and a rematerialized constant on every multi-byte
// character, 7% on input with no ASCII.
@inline(never)
private func widenASCIIRun(
    _ sourceBytes: RawSpan,
    from index: Int,
    count run: Int,
    into output: inout MutableSpan<UInt16>,
    at produced: Int
) -> Int {
    let sourceRun = sourceBytes.extracting(index..<(index &+ run))
    var outputBytes = output.mutableBytes
    var outputRun = outputBytes.extracting((produced &* 2)..<((produced &+ run) &* 2))
    var offset = 0
    while offset &+ 32 <= run {
        let low = sourceRun.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
        let high = sourceRun.load(fromByteOffset: offset &+ 16, as: SIMD16<UInt8>.self)
        if (low | high).max() >= 0x80 { break }
        let base = offset &* 2
        outputRun.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: low.lowHalf), toByteOffset: base, as: SIMD8<UInt16>.self)
        outputRun.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: low.highHalf), toByteOffset: base &+ 16, as: SIMD8<UInt16>.self)
        outputRun.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: high.lowHalf), toByteOffset: base &+ 32, as: SIMD8<UInt16>.self)
        outputRun.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: high.highHalf), toByteOffset: base &+ 48, as: SIMD8<UInt16>.self)
        offset &+= 32
    }
    while offset &+ 8 <= run {
        // Lane `i` is byte `i` whatever the byte order, and the widened lanes are stored as native
        // UInt16, which is what `output` holds.
        let bytes = sourceRun.load(fromByteOffset: offset, as: SIMD8<UInt8>.self)
        outputRun.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: bytes), toByteOffset: offset &* 2, as: SIMD8<UInt16>.self)
        let nonASCII = UInt64(littleEndian: sourceRun.load(fromByteOffset: offset, as: UInt64.self)) & highBitsOfEachByte
        if nonASCII != 0 {
            return offset &+ (nonASCII.trailingZeroBitCount &>> 3)
        }
        offset &+= 8
    }
    return offset
}

// Writes U+FFFD at `produced`, which the caller's loop condition keeps below `output.count`.
@inline(always)
private func replace(at produced: Int, in output: inout MutableSpan<UInt16>, sawError: inout Bool) -> Int {
    output[produced] = replacementCharacter
    sawError = true
    return produced + 1
}

// Unless `stopOnError`, ill-formed input is replaced in the loop, as in the C++, so input dense with
// errors pays no call per error.
private func decodeWideChunk(
    _ source: Span<UInt8>,
    from start: Int,
    into output: inout MutableSpan<UInt16>,
    startingAt startProduced: Int,
    stopOnError: Bool,
    sawError: inout Bool
) -> ChunkOutcome {
    let sourceBytes = source.bytes
    var index = start
    var produced = startProduced
    let end = source.count
    let capacity = output.count
    // `decodeUniformBlocksWide` is not tried again before `uniformRetry` after a call that decoded
    // nothing, and the distance doubles with each such call, so text of mixed lengths (Cyrillic words
    // between ASCII spaces) almost never pays for it. A call that decodes something resets it.
    var uniformRetry = 0
    var uniformBackoff = 64

    // One slot per character, not two: the destination has a slot per input byte and no character
    // produces more code units than it consumes bytes, so the surrogate pair always has room.
    while index < end && produced < capacity {
        // Re-read by the word loop rather than copied first, which is 17-20% faster on long ASCII runs.
        var firstByte = source[index]
        if firstByte < 0x80 {
            // Widened in registers: per-element subscripts leave sixteen bounds checks the optimizer
            // does not remove.
            let widened = widenASCIIRun(
                sourceBytes, from: index, count: min(end &- index, capacity &- produced),
                into: &output, at: produced)
            index &+= widened
            produced &+= widened
            if index >= end || produced >= capacity { break }

            firstByte = source[index]
            if firstByte < 0x80 {
                output[produced] = UInt16(truncatingIfNeeded: firstByte)
                produced += 1
                index += 1
                continue
            }
        }

        // Positive, since `index < end`. A length tested against it needs no overflow check, and the
        // offsets below it, which that test bounds, can wrap.
        let remaining = end &- index

        // Leads are dispatched by range into one path per sequence length, two-byte first, each ending in its
        // own loop test. One path shared by all lengths takes several more taken branches per character, and
        // 1.3 to 1.5 times the cycles on input mixing two-, three- and four-byte characters.
        if firstByte >= 0xC2 && firstByte < 0xE0 {
            if remaining < 2 {
                return .truncated(consumed: index, produced: produced, partial: remaining)
            }
            let secondByte = source[index &+ 1]
            if !isContinuationByte(secondByte) {
                if stopOnError { return .illFormed(consumed: index, produced: produced) }
                produced = replace(at: produced, in: &output, sawError: &sawError)
                index &+= 1
                continue
            }
            output[produced] = UInt16(truncatingIfNeeded: twoByteScalar(firstByte, secondByte))
            produced += 1
            index &+= 2
            // A second two-byte character in a row: decode eight per block while the input is exactly
            // that. Tested after the first, so an isolated one pays only the test of the byte the loop
            // reads next anyway.
            if remaining >= 18 && index >= uniformRetry && source[index] >= 0xC2 {
                var blocks = decodeUniformBlocksWide(
                    sourceBytes, from: index, count: min(remaining &- 2, capacity &- produced),
                    into: &output, at: produced)
                // Not uniform from the start: lengths are mixed, so the table-driven transcoder.
                if blocks.consumed == 0 && index >= 3 {
                    blocks = transcodeUTF8BlocksToUTF16(
                        sourceBytes, from: index, count: min(remaining &- 2, capacity &- produced),
                        into: &output, at: produced)
                }
                index &+= blocks.consumed
                produced &+= blocks.produced
                if blocks.consumed == 0 {
                    uniformRetry = index &+ uniformBackoff
                    uniformBackoff = min(uniformBackoff &* 2, 4096)
                } else {
                    uniformBackoff = 64
                }
            }
            continue
        }

        if firstByte >= 0xE0 && firstByte < 0xF0 {
            if remaining < 3 {
                return .truncated(consumed: index, produced: produced, partial: remaining)
            }
            let secondByte = source[index &+ 1]
            if !isValidSecondByteOfThree(firstByte, secondByte) {
                if stopOnError { return .illFormed(consumed: index, produced: produced) }
                produced = replace(at: produced, in: &output, sawError: &sawError)
                index &+= 1
                continue
            }
            let thirdByte = source[index &+ 2]
            if !isContinuationByte(thirdByte) {
                if stopOnError { return .illFormed(consumed: index, produced: produced) }
                produced = replace(at: produced, in: &output, sawError: &sawError)
                index &+= 2
                continue
            }
            output[produced] = UInt16(truncatingIfNeeded: threeByteScalar(firstByte, secondByte, thirdByte))
            produced += 1
            index &+= 3
            if remaining >= 19 && index >= uniformRetry && source[index] >= 0xC2 {
                var blocks = decodeUniformBlocksWide(
                    sourceBytes, from: index, count: min(remaining &- 3, capacity &- produced),
                    into: &output, at: produced)
                if blocks.consumed == 0 {
                    blocks = transcodeUTF8BlocksToUTF16(
                        sourceBytes, from: index, count: min(remaining &- 3, capacity &- produced),
                        into: &output, at: produced)
                }
                index &+= blocks.consumed
                produced &+= blocks.produced
                if blocks.consumed == 0 {
                    uniformRetry = index &+ uniformBackoff
                    uniformBackoff = min(uniformBackoff &* 2, 4096)
                } else {
                    uniformBackoff = 64
                }
            }
            continue
        }

        if firstByte >= 0xF0 && firstByte < 0xF5 {
            if remaining < 4 {
                return .truncated(consumed: index, produced: produced, partial: remaining)
            }
            let secondByte = source[index &+ 1]
            if !isValidSecondByteOfFour(firstByte, secondByte) {
                if stopOnError { return .illFormed(consumed: index, produced: produced) }
                produced = replace(at: produced, in: &output, sawError: &sawError)
                index &+= 1
                continue
            }
            let thirdByte = source[index &+ 2]
            if !isContinuationByte(thirdByte) {
                if stopOnError { return .illFormed(consumed: index, produced: produced) }
                produced = replace(at: produced, in: &output, sawError: &sawError)
                index &+= 2
                continue
            }
            let fourthByte = source[index &+ 3]
            if !isContinuationByte(fourthByte) {
                if stopOnError { return .illFormed(consumed: index, produced: produced) }
                produced = replace(at: produced, in: &output, sawError: &sawError)
                index &+= 3
                continue
            }
            // Not `appendScalar`: a four-byte scalar is always above U+FFFF, and the width test costs 6% on
            // mixed input.
            produced += appendSurrogatePair(fourByteScalar(firstByte, secondByte, thirdByte, fourthByte), to: &output, at: produced)
            index &+= 4
            if remaining >= 20 && index >= uniformRetry && source[index] >= 0xC2 {
                let blocks = transcodeUTF8BlocksToUTF16(
                    sourceBytes, from: index, count: min(remaining &- 4, capacity &- produced),
                    into: &output, at: produced)
                index &+= blocks.consumed
                produced &+= blocks.produced
                if blocks.consumed == 0 {
                    uniformRetry = index &+ uniformBackoff
                    uniformBackoff = min(uniformBackoff &* 2, 4096)
                } else {
                    uniformBackoff = 64
                }
            }
            continue
        }

        // A continuation byte, C0, C1 or F5 and above: no sequence starts here.
        if stopOnError { return .illFormed(consumed: index, produced: produced) }
        produced = replace(at: produced, in: &output, sawError: &sawError)
        index &+= 1
    }

    return .complete(consumed: index, produced: produced)
}

@inline(always)
private func makeResult(
    consumed: Int,
    produced: Int,
    partialSequence: UInt32 = 0,
    partialSequenceSize: Int = 0,
    needsWide: Bool = false,
    sawError: Bool = false,
    stoppedOnError: Bool = false,
    shouldStripByteOrderMark: Bool = false
) -> PAL.TextCodecUTF8SwiftResult {
    var result = PAL.TextCodecUTF8SwiftResult()
    result.consumedBytes = UInt32(consumed)
    result.producedCharacters = UInt32(produced)
    result.partialSequence = unpackPartialSequence(partialSequence, count: partialSequenceSize)
    result.partialSequenceSize = UInt8(partialSequenceSize)
    result.needsWide = needsWide
    result.sawError = sawError
    result.stoppedOnError = stoppedOnError
    result.shouldStripByteOrderMark = shouldStripByteOrderMark
    return result
}

/// Decodes `input` into the 8-bit `destInput`, stopping with `needsWide` at the first character that
/// is not Latin-1 and leaving `consumedBytes` at that character.
///
/// The spans from `_unsafeCxxSpan:` are sound because `TextCodecUTF8::decode` passes `StringBuffer`
/// spans at their allocated size, the call is synchronous, and each destination is a buffer `decode`
/// allocated after `input` existed, so it cannot overlap `input`. Every access after the conversion is
/// bounds-checked. The destination starts uninitialized and is only written.
///
/// FIXME: Remove `_unsafeCxxSpan:` once Swift can receive a `std::span` safely: rdar://186723514.
@_expose(Cxx)
public func textCodecUTF8DecodeNarrow(
    _ input: PAL.TextCodecUTF8SwiftInput,
    _ destInput: PAL.TextCodecUTF8SwiftNarrowDest,
    _ partialSequence: PAL.TextCodecUTF8SwiftPartialSequence,
    _ partialSequenceSize: UInt8,
    _ flush: Bool,
    _ stopOnError: Bool,
    _ shouldStripByteOrderMark: Bool
) -> PAL.TextCodecUTF8SwiftResult {
    let source = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    var dest = unsafe MutableSpan<UInt8>(_unsafeCxxSpan: destInput)

    var consumed = 0
    var produced = 0
    var packedSize = Int(partialSequenceSize)
    precondition(packedSize <= Int(partialSequence.size()), "a held UTF-8 partial sequence cannot exceed four bytes")
    var packed = packPartialSequence(partialSequence, count: packedSize)
    var sawError = false
    var stoppedOnError = false

    // Goes round again only to diagnose a truncated tail the main loop held.
    stages: while true {
        if packedSize != 0 {
            switch handlePartialSequenceNarrow(source, from: consumed, partialSequence: packed, size: packedSize, flush: flush) {
            case .waiting(let held, let size, let cursor):
                packed = held
                packedSize = size
                consumed = cursor
                break stages

            case .needsWide(let held, let size, let cursor):
                // Passed on even under `flush`: the 16-bit half emits the U+FFFD for it.
                return makeResult(
                    consumed: cursor,
                    produced: produced,
                    partialSequence: held,
                    partialSequenceSize: size,
                    needsWide: true,
                    sawError: sawError,
                    shouldStripByteOrderMark: shouldStripByteOrderMark
                )

            case .latin1(let character, let cursor):
                dest[produced] = character
                produced += 1
                consumed = cursor
                packed = 0
                packedSize = 0
            }
        }

        guard consumed < source.count else { break stages }

        switch decodeChunk(source, from: consumed, into: &dest, startingAt: produced) {
        case .needsWide(let chunkConsumed, let chunkProduced):
            return makeResult(
                consumed: chunkConsumed,
                produced: chunkProduced,
                needsWide: true,
                sawError: sawError,
                shouldStripByteOrderMark: shouldStripByteOrderMark
            )

        case .illFormed(let chunkConsumed, let chunkProduced):
            produced = chunkProduced
            consumed = chunkConsumed
            sawError = true
            if !stopOnError {
                return makeResult(
                    consumed: consumed,
                    produced: produced,
                    needsWide: true,
                    sawError: true,
                    shouldStripByteOrderMark: shouldStripByteOrderMark
                )
            }
            stoppedOnError = true
            break stages

        case .truncated(let chunkConsumed, let chunkProduced, let partialSize):
            produced = chunkProduced
            packed = packPartialSequence(source, from: chunkConsumed, count: partialSize)
            packedSize = partialSize
            consumed = chunkConsumed + partialSize
            continue stages

        case .complete(let chunkConsumed, let chunkProduced):
            produced = chunkProduced
            precondition(chunkConsumed == source.count, "UTF-8 narrow decode stopped short of its input")
            consumed = chunkConsumed
            break stages
        }
    }

    return makeResult(
        consumed: consumed,
        produced: produced,
        partialSequence: flush ? 0 : packed,
        partialSequenceSize: flush ? 0 : packedSize,
        sawError: sawError,
        stoppedOnError: stoppedOnError,
        shouldStripByteOrderMark: shouldStripByteOrderMark
    )
}

/// Resumes from `narrow`, a `needsWide` result of `textCodecUTF8DecodeNarrow`, over the same `input`.
///
/// The caller has widened the 8-bit output into the start of `destInput`. The result's `sawError`
/// covers this call only; its other fields are totals.
///
/// FIXME: Remove `_unsafeCxxSpan:` once Swift can receive a `std::span` safely: rdar://186723514.
@_expose(Cxx)
public func textCodecUTF8DecodeWide(
    _ input: PAL.TextCodecUTF8SwiftInput,
    _ destInput: PAL.TextCodecUTF8SwiftWideDest,
    _ narrow: PAL.TextCodecUTF8SwiftResult,
    _ flush: Bool,
    _ stopOnError: Bool
) -> PAL.TextCodecUTF8SwiftResult {
    let source = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    var dest = unsafe MutableSpan<UInt16>(_unsafeCxxSpan: destInput)

    var consumed = Int(narrow.consumedBytes)
    var produced = Int(narrow.producedCharacters)
    precondition(consumed <= source.count && produced <= dest.count, "UTF-8 wide decode resumed outside its buffers")
    var packedSize = Int(narrow.partialSequenceSize)
    precondition(packedSize <= Int(narrow.partialSequence.size()), "a held UTF-8 partial sequence cannot exceed four bytes")
    var packed = packPartialSequence(narrow.partialSequence, count: packedSize)
    var sawError = false
    var stoppedOnError = false
    var shouldStrip = narrow.shouldStripByteOrderMark

    stages: while true {
        if packedSize != 0 {
            let outcome = handlePartialSequenceWide(
                source,
                from: consumed,
                partialSequence: packed,
                size: packedSize,
                flush: flush,
                stopOnError: stopOnError,
                into: &dest,
                units: &produced,
                sawError: &sawError,
                shouldStripByteOrderMark: &shouldStrip
            )
            switch outcome {
            case .decoded(let cursor):
                consumed = cursor
                packed = 0
                packedSize = 0

            case .waiting(let held, let size, let cursor):
                packed = held
                packedSize = size
                consumed = cursor
                break stages

            case .stopped(let held, let size, let cursor):
                packed = held
                packedSize = size
                consumed = cursor
                sawError = true
                stoppedOnError = true
                break stages
            }
        }

        guard consumed < source.count else { break stages }

        // The main loop strips a byte order mark only at index 0 of the buffer. Checking for EF BB BF,
        // its only valid encoding, here keeps the test out of `decodeWideChunk`.
        if shouldStrip && produced == 0
            && consumed + 3 <= source.count
            && source[consumed] == byteOrderMarkBytes.0
            && source[consumed + 1] == byteOrderMarkBytes.1
            && source[consumed + 2] == byteOrderMarkBytes.2
        {
            shouldStrip = false
            consumed += 3
        }

        switch decodeWideChunk(
            source, from: consumed, into: &dest, startingAt: produced,
            stopOnError: stopOnError, sawError: &sawError) {
        case .needsWide:
            preconditionFailure("the UTF-8 16-bit kernel cannot ask to widen")

        case .illFormed(let errorAt, let chunkProduced):
            precondition(stopOnError, "the UTF-8 16-bit kernel replaces ill-formed input unless stopping on error")
            sawError = true
            consumed = errorAt
            produced = chunkProduced
            stoppedOnError = true
            break stages

        case .truncated(let chunkConsumed, let chunkProduced, let partialSize):
            packed = packPartialSequence(source, from: chunkConsumed, count: partialSize)
            packedSize = partialSize
            consumed = chunkConsumed + partialSize
            produced = chunkProduced
            continue stages

        case .complete(let chunkConsumed, let chunkProduced):
            precondition(chunkConsumed == source.count, "UTF-8 wide decode stopped short of its input")
            consumed = chunkConsumed
            produced = chunkProduced
            break stages
        }
    }

    return makeResult(
        consumed: consumed,
        produced: produced,
        partialSequence: flush ? 0 : packed,
        partialSequenceSize: flush ? 0 : packedSize,
        sawError: sawError,
        stoppedOnError: stoppedOnError,
        shouldStripByteOrderMark: shouldStrip
    )
}

#endif // USE_SWIFT_TEXT_CODEC_UTF8
