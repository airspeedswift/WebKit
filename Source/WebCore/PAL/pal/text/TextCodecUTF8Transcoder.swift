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

// PROTOTYPE. UTF-8 -> UTF-16 block transcoder for TextCodecUTF8.swift: a port of simdutf's arm64
// validating transcoder (convert_masked_utf8_to_utf16 and its driver) to portable Swift SIMD, using
// neon_tbl (TextCodecUTF8SIMD.swift) for the data-dependent byte shuffle and simdutf's own tables
// (TextCodecUTF8Tables.swift). arm64 lowers neon_tbl to TBL; x86_64 with HAVE_SSSE3 to PSHUFB; other
// targets use the scalar fallback.
//
// Only well-formed input is transcoded: a 64-byte block with any error stops the transcoder, and the
// caller's scalar code decodes that block, so ill-formed input keeps exactly the scalar semantics.

// MARK: - Validation (simdutf's check_special_cases / check_multibyte_lengths)

private let tooShort: UInt8 = 1 << 0
private let tooLong: UInt8 = 1 << 1
private let overlong3: UInt8 = 1 << 2
private let tooLarge: UInt8 = 1 << 3
private let surrogate: UInt8 = 1 << 4
private let overlong2: UInt8 = 1 << 5
private let tooLarge1000: UInt8 = 1 << 6
private let overlong4: UInt8 = 1 << 6
private let twoConts: UInt8 = 1 << 7
private let carry: UInt8 = tooShort | tooLong | twoConts

/// The three nibble tables. Built once per call and passed in: a global `let` costs a
/// one-time-initialization check per access.
struct UTF8ValidationTables {
    let byte1High: SIMD16<UInt8>
    let byte1Low: SIMD16<UInt8>
    let byte2High: SIMD16<UInt8>

    @inline(always)
    init() {
        byte1High = SIMD16(
            tooLong, tooLong, tooLong, tooLong, tooLong, tooLong, tooLong, tooLong,
            twoConts, twoConts, twoConts, twoConts,
            tooShort | overlong2,
            tooShort,
            tooShort | overlong3 | surrogate,
            tooShort | tooLarge | tooLarge1000 | overlong4)
        byte1Low = SIMD16(
            carry | overlong3 | overlong2 | overlong4,
            carry | overlong2,
            carry, carry,
            carry | tooLarge,
            carry | tooLarge | tooLarge1000,
            carry | tooLarge | tooLarge1000,
            carry | tooLarge | tooLarge1000,
            carry | tooLarge | tooLarge1000,
            carry | tooLarge | tooLarge1000,
            carry | tooLarge | tooLarge1000,
            carry | tooLarge | tooLarge1000,
            carry | tooLarge | tooLarge1000,
            carry | tooLarge | tooLarge1000 | surrogate,
            carry | tooLarge | tooLarge1000,
            carry | tooLarge | tooLarge1000)
        let cont1000 = tooLong | overlong2 | twoConts | overlong3 | tooLarge1000 | overlong4
        let cont1001 = tooLong | overlong2 | twoConts | overlong3 | tooLarge
        let cont101 = tooLong | overlong2 | twoConts | surrogate | tooLarge
        byte2High = SIMD16(
            tooShort, tooShort, tooShort, tooShort, tooShort, tooShort, tooShort, tooShort,
            cont1000, cont1001, cont101, cont101,
            tooShort, tooShort, tooShort, tooShort)
    }
}

/// Nonzero lanes where `input` is not well-formed UTF-8, given the same 16 bytes shifted by 1, 2 and 3
/// (`prev1` ... `prev3`, the bytes before each lane). Those come from unaligned loads, not lane shuffles
/// of `input`: LLVM computes shuffles of a vector used in several shapes lane by lane.
@inline(always)
func utf8Errors(_ input: SIMD16<UInt8>, prev1: SIMD16<UInt8>, prev2: SIMD16<UInt8>, prev3: SIMD16<UInt8>, _ tables: UTF8ValidationTables) -> SIMD16<UInt8> {
    let special = neon_tbl(tables.byte1High, prev1 &>> 4)
        & neon_tbl(tables.byte1Low, prev1 & 0x0F)
        & neon_tbl(tables.byte2High, input &>> 4)
    // must_be_2_3_continuation: prev2 >= E0 xor prev3 >= F0, as 0x80.
    let third = saturatingSubtract(prev2, SIMD16(repeating: 0xDF))
    let fourth = saturatingSubtract(prev3, SIMD16(repeating: 0xEF))
    let must23 = ((third &+ 0x7F) ^ (fourth &+ 0x7F)) & 0x80
    return must23 ^ special
}

// MARK: - 12-byte transcoding step (simdutf's convert_masked_utf8_to_utf16)

/// Transcodes the characters that end within the first 12 bytes of `input` (16 for all-ASCII), as
/// described by `endMask` (bit i set when byte i ends a character), storing code units at byte offset
/// `outputOffset` of `output`. Returns (bytes consumed, units produced). Stores up to 16 units whatever
/// it produces; the caller leaves room.
@inline(always)
private func transcodeStep(
    _ input: SIMD16<UInt8>, endMask: UInt64,
    shuffles: RawSpan, bigIndex: RawSpan,
    into output: inout MutableRawSpan, at unsignedOutputOffset: UInt
) -> (consumed: UInt, produced: UInt) {
    // Unsigned: the span precondition compares offsets as UInt, and only an unsigned offset carries
    // `>= 0` from its type into that proof.
    let outputOffset = Int(bitPattern: unsignedOutputOffset)
    let mask12 = Int(truncatingIfNeeded: endMask & 0xFFF)
    if endMask & 0xFFFF == 0xFFFF {
        output.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: input.lowHalf), toByteOffset: outputOffset, as: SIMD8<UInt16>.self)
        output.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: input.highHalf), toByteOffset: outputOffset &+ 16, as: SIMD8<UInt16>.self)
        return (16, 16)
    }
    if mask12 == 0x924 {
        // Four three-byte characters: 1110aaaa 10bbbbbb 10cccccc at 0, 3, 6, 9.
        let l = SIMD8<UInt16>(truncatingIfNeeded: SIMD8<UInt8>(input[0], input[3], input[6], input[9], input[0], input[3], input[6], input[9]))
        let m = SIMD8<UInt16>(truncatingIfNeeded: SIMD8<UInt8>(input[1], input[4], input[7], input[10], input[1], input[4], input[7], input[10]))
        let r = SIMD8<UInt16>(truncatingIfNeeded: SIMD8<UInt8>(input[2], input[5], input[8], input[11], input[2], input[5], input[8], input[11]))
        output.storeBytes(of: ((l & 0x0F) &<< 12) | ((m & 0x3F) &<< 6) | (r & 0x3F), toByteOffset: outputOffset, as: SIMD8<UInt16>.self)
        return (12, 4)
    }
    if mask12 == 0xAAA {
        // Six two-byte characters: 110aaaaa 10bbbbbb.
        let pairs = reinterpretAsUInt16(input)
        let composed = ((pairs & 0x1F) &<< 6) | ((pairs &>> 8) & 0x3F)
        output.storeBytes(of: composed, toByteOffset: outputOffset, as: SIMD8<UInt16>.self)
        return (12, 6)
    }
    let row = Int(bigIndex.load(fromByteOffset: mask12 &* 2, as: UInt8.self))
    let consumed = UInt(bigIndex.load(fromByteOffset: mask12 &* 2 &+ 1, as: UInt8.self))
    if row < 64 {
        // Six one- or two-byte characters, each shuffled into a 16-bit lane: 0bbbbbbb or 110aaaaa 10bbbbbb.
        let perm = reinterpretAsUInt16(neon_tbl(input, shuffles.load(fromByteOffset: row &* 16, as: SIMD16<UInt8>.self)))
        let composed = (perm & 0x7F) | ((perm & 0x1F00) &>> 2)
        output.storeBytes(of: composed, toByteOffset: outputOffset, as: SIMD8<UInt16>.self)
        return (consumed, 6)
    }
    if row < 145 {
        // Four one- to three-byte characters, each shuffled into a 32-bit lane.
        let perm = reinterpretAsUInt32(neon_tbl(input, shuffles.load(fromByteOffset: row &* 16, as: SIMD16<UInt8>.self)))
        let lowPerm = SIMD4<UInt16>(truncatingIfNeeded: perm)
        let highPerm = SIMD4<UInt16>(truncatingIfNeeded: perm &>> 16)
        let middleLow = (lowPerm & 0x7F) | ((lowPerm & 0xFF00) &>> 2)
        let composed = (middleLow & 0x0FFF) | (highPerm &<< 12)
        output.storeBytes(of: composed, toByteOffset: outputOffset, as: SIMD4<UInt16>.self)
        return (consumed, 4)
    }
    if mask12 == 0x888 {
        // Three four-byte characters: three surrogate pairs (simdutf's dedicated path, no table).
        // Byte-swapped pairs: 10cccccc 10dddddd | 11110aaa 10bbbbbb.
        let swap = SIMD16<UInt8>(input[1], input[0], input[3], input[2], input[5], input[4], input[7], input[6],
                                 input[9], input[8], input[11], input[10], input[13], input[12], input[15], input[14])
        let shift = reinterpretAsUInt32(swap &<< 2)
        let swap32 = reinterpretAsUInt32(swap)
        let trail = (swap32 & 0x0000_FF00) | (shift & ~0x0000_FF00)
        let magicWithLow2 = reinterpretAsUInt16(SIMD4<UInt32>(repeating: 0xDC00_E7C0) &+ (shift &>> 30))
        let swap16 = reinterpretAsUInt16(swap)
        let in16 = reinterpretAsUInt16(input)
        let lead = reinterpretAsUInt32((in16 &<< 6) | (swap16 & 0x3F)) & 0x03FF_FFFF
        let blend = reinterpretAsUInt16((trail & 0x0000_FFFF) | (lead & 0xFFFF_0000))
        output.storeBytes(of: blend &+ magicWithLow2, toByteOffset: outputOffset, as: SIMD8<UInt16>.self)
        return (12, 6)
    }
    if row < 209 {
        // Three one- to four-byte characters, each shuffled into a 32-bit lane (first byte highest).
        let perm = reinterpretAsUInt32(neon_tbl(input, shuffles.load(fromByteOffset: row &* 16, as: SIMD16<UInt8>.self)))
        let ascii = perm & 0x7F
        let middleHigh = perm &<< 2
        let middleByte = perm & 0x3F00
        let ab = (perm & 0xFF00_0000) | (middleHigh & ~0xFF00_0000)
        let abc = (ab & 0xFFFC_0000) | ((middleByte &<< 4) & ~0xFFFC_0000)
        let composed = ascii &+ (abc &>> 6)
        let mixed = (abc & 0xFFFF_0000) | (composed & 0x0000_FFFF)
        let maskedPair = mixed & 0xFFFF_03FF
        // Adding E7C0 to the high half and DC00 to the low half, as 16-bit lanes, completes the pair.
        let highHalf = ((maskedPair &>> 16) &+ 0xE7C0) & 0xFFFF
        let lowHalf = ((maskedPair & 0xFFFF) &+ 0xDC00) & 0xFFFF
        let surrogates = (highHalf &<< 16) | lowHalf
        var produced = 0
        defer { _ = produced }
        for i in 0..<3 {
            if perm[i] & 0xF800_0000 == 0xF000_0000 {
                output.storeBytes(of: UInt16(truncatingIfNeeded: surrogates[i] &>> 16), toByteOffset: outputOffset &+ produced &* 2, as: UInt16.self)
                output.storeBytes(of: UInt16(truncatingIfNeeded: surrogates[i]), toByteOffset: outputOffset &+ produced &* 2 &+ 2, as: UInt16.self)
                produced &+= 2
            } else {
                output.storeBytes(of: UInt16(truncatingIfNeeded: composed[i]), toByteOffset: outputOffset &+ produced &* 2, as: UInt16.self)
                produced &+= 1
            }
        }
        return (consumed, UInt(produced))
    }
    return (0, 0) // unreachable on validated input
}

// MARK: - Driver (simdutf's validating_transcoder::convert)


/// Transcodes well-formed UTF-8 from `sourceBytes[index...]` into `output` at `produced`, in 64-byte
/// blocks, and returns (bytes consumed, units produced). Stops at the first block with an error, and
/// 80 bytes before the end of `run` (the last block's 12-byte steps read 16 bytes and may stop up to
/// 16 short of the block end). `index` must be a character boundary at least 3 bytes into
/// `sourceBytes` (the bytes before a block end a character, so they validate as its predecessors).
/// `run` bounds both views: no
/// character produces more units than it has bytes, and every store fits in `run` units.
@inline(never)
func transcodeUTF8BlocksToUTF16(
    _ sourceBytes: RawSpan, from index: Int, count run: Int,
    into output: inout MutableSpan<UInt16>, at produced: Int
) -> (consumed: Int, produced: Int) {
    let source = sourceBytes.extracting((index &- 3)..<(index &+ run))
    var outputBytes = output.mutableBytes
    var out = outputBytes._mutatingExtracting((produced &* 2)..<((produced &+ run) &* 2))
    let shuffles = utf8ToUTF16Shuffles.span.bytes
    let bigIndex = utf8ToUTF16BigIndex.span.bytes
    let tables = UTF8ValidationTables()
    var pos = 0
    var units = 0
    while pos &+ 80 <= run {
        // Per-block views of CONSTANT size, each checked once here: a literal range (0..<83) gives the
        // literal count. (A computed range gives a difference LLVM does not fold, and extracting(first:)
        // clamps to min(n, count) instead of requiring n.) 83 source bytes
        // (3 before the block and 80 from it) and 80 output units (no block produces more units than
        // it consumes bytes).
        let block = source.extracting(droppingFirst: pos).extracting(0..<83)
        var outTail = out._mutatingExtracting(droppingFirst: units &* 2)
        var blockOut = outTail._mutatingExtracting(0..<160)
        let a = block.load(fromByteOffset: 3, as: SIMD16<UInt8>.self)
        let b = block.load(fromByteOffset: 19, as: SIMD16<UInt8>.self)
        let c = block.load(fromByteOffset: 35, as: SIMD16<UInt8>.self)
        let d = block.load(fromByteOffset: 51, as: SIMD16<UInt8>.self)
        if ((a | b) | (c | d)).max() < 0x80 {
            blockOut.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: a.lowHalf), toByteOffset: 0, as: SIMD8<UInt16>.self)
            blockOut.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: a.highHalf), toByteOffset: 16, as: SIMD8<UInt16>.self)
            blockOut.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: b.lowHalf), toByteOffset: 32, as: SIMD8<UInt16>.self)
            blockOut.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: b.highHalf), toByteOffset: 48, as: SIMD8<UInt16>.self)
            blockOut.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: c.lowHalf), toByteOffset: 64, as: SIMD8<UInt16>.self)
            blockOut.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: c.highHalf), toByteOffset: 80, as: SIMD8<UInt16>.self)
            blockOut.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: d.lowHalf), toByteOffset: 96, as: SIMD8<UInt16>.self)
            blockOut.storeBytes(of: SIMD8<UInt16>(truncatingIfNeeded: d.highHalf), toByteOffset: 112, as: SIMD8<UInt16>.self)
            units &+= 64
            pos &+= 64
            continue
        }
        var errors = SIMD16<UInt8>()
        for k in 0..<4 {
            let o = 3 &+ k &* 16
            errors |= utf8Errors(
                block.load(fromByteOffset: o, as: SIMD16<UInt8>.self),
                prev1: block.load(fromByteOffset: o &- 1, as: SIMD16<UInt8>.self),
                prev2: block.load(fromByteOffset: o &- 2, as: SIMD16<UInt8>.self),
                prev3: block.load(fromByteOffset: o &- 3, as: SIMD16<UInt8>.self),
                tables)
        }
        if errors.max() != 0 { break }
        // Continuation bytes are 0x80-0xBF: top bit set and bit 6 clear.
        let continuation = UInt64(highBitMask(a & ~(a &<< 1)))
            | UInt64(highBitMask(b & ~(b &<< 1))) &<< 16
            | UInt64(highBitMask(c & ~(c &<< 1))) &<< 32
            | UInt64(highBitMask(d & ~(d &<< 1))) &<< 48
        if continuation & 1 != 0 { break }
        var endMask = ~continuation &>> 1
        // Unsigned step counters bounded by the loop's own guards: a 16-byte load from stepPos + 3 < 55
        // ends within 83 bytes, and a store of up to 16 units at stepUnits < 64 within 80 units. The
        // second guard is always true and is there for the proof.
        var stepPos: UInt = 0
        var stepUnits: UInt = 0
        while stepPos < 52 && stepUnits < 64 {
            let step = transcodeStep(
                block.load(fromByteOffset: Int(bitPattern: stepPos &+ 3), as: SIMD16<UInt8>.self), endMask: endMask,
                shuffles: shuffles, bigIndex: bigIndex, into: &blockOut, at: stepUnits &* 2)
            stepPos &+= step.consumed
            stepUnits &+= step.produced
            endMask &>>= UInt64(step.consumed)
        }
        pos &+= Int(bitPattern: stepPos)
        units &+= Int(bitPattern: stepUnits)
    }
    return (pos, units)
}

#endif // USE_SWIFT_TEXT_CODEC_UTF8
