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

// UTF-8 decoding for `TextCodecUTF8::decode`, at both output widths.
//
// `decode` fills an 8-bit `StringBuffer` optimistically and abandons it for a 16-bit one at the
// first character Latin-1 cannot hold. `textCodecUTF8DecodeNarrow` does the 8-bit half and reports
// `needsWide` at that point; the caller widens what it has and calls `textCodecUTF8DecodeWide` to
// finish. Between them they decode every input, so neither may refuse one: where these functions
// are compiled, the C++ decode loops are not.
//
// Four decoding rules worth stating, because getting them backwards produces plausible output:
//
// Maximal subpart: an ill-formed sequence emits one U+FFFD and skips only the bytes that were
// valid, so the byte that ended it comes round again as a fresh lead, and a byte that leads no
// sequence at all skips 1. F0 9F 98 41 is U+FFFD U+0041; F8 88 80 80 80 is five characters.
//
// Width under `stopOnError` is settled in three different places. U+FFFD is not Latin-1, so an
// ill-formed sequence normally forces 16-bit output; but the 8-bit main loop's `stopOnError` exit
// keeps the 8-bit buffer, and an error inside a partial sequence upconverts even under
// `stopOnError`. Get any of the three backwards and `is8Bit()` flips.
//
// Only a valid lead byte is ever held as a partial sequence: a byte of sequence length 0
// (0x80-0xC1, 0xF5-0xFF) is an error before it can be held, which is why both kernels test length
// before truncation.
//
// A truncated tail is held on length alone, bytes unexamined, and diagnosed in the same call. It
// waits for more input only if the recomputed maximal subpart still covers everything held, so
// { 0xE0, 0x80 } emits two U+FFFD with `flush` false.

public import pal.Core.text.TextCodecUTF8SwiftTypes

/// Set in every byte of a machine word whose corresponding input byte is non-ASCII.
private let highBitsOfEachByte: UInt64 = 0x8080_8080_8080_8080

/// U+FFFD, what every ill-formed sequence decodes to. Not Latin-1, so it only ever reaches 16-bit
/// output.
private let replacementCharacter: UInt16 = 0xFFFD

/// U+FEFF, and its only encoding that decodes: the overlong four-byte form F0 8F BB BF fails the
/// second-byte test. So "the next character is a byte order mark" and "the next three bytes are
/// EF BB BF" are the same statement, which is what lets the position-dependent strip rule be
/// settled before the kernel runs rather than inside its per-character path.
private let byteOrderMark: UInt32 = 0xFEFF
private let byteOrderMarkBytes: (UInt8, UInt8, UInt8) = (0xEF, 0xBB, 0xBF)

/// How many bytes the sequence led by `firstByte` occupies, or 0 if it cannot lead one.
///
/// Three compares rather than the C++'s 256-entry table: a Swift `let` global of non-trivial type
/// costs a one-time-initialization check on every access. Callers test for ASCII first, so
/// 0x00-0x7F reaching here is a caller bug; it answers 0.
@inline(always)
private func sequenceLength(_ firstByte: UInt8) -> Int {
    if firstByte < 0xC2 { return 0 }
    if firstByte < 0xE0 { return 2 }
    if firstByte < 0xF0 { return 3 }
    if firstByte < 0xF5 { return 4 }
    return 0
}

/// Whether `secondByte` is valid at index 1 of a sequence led by `firstByte`.
///
/// Four leads have a narrower wall than the plain continuation range: 0xE0 and 0xF0 exclude the
/// overlong forms, 0xED the surrogates, and 0xF4 everything beyond U+10FFFF.
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

/// Whether `byte` is valid at index 2 or 3 of a sequence.
@inline(always)
private func isContinuationByte(_ byte: UInt8) -> Bool {
    byte >= 0x80 && byte <= 0xBF
}

/// The scalar value of a validated sequence of each length.
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

/// Packs `count` bytes of `source` from `start` the way a partial sequence crosses the boundary:
/// byte `i` of the sequence at bit `8 * i`, nothing above `count`.
///
/// The bit position is the byte's index within the sequence, so this means the same on either
/// endianness. `packPartialSequence` in TextCodecUTF8.cpp is the other half of the pair.
@inline(always)
private func packPartialSequence(_ source: Span<UInt8>, from start: Int, count: Int) -> UInt32 {
    var packed: UInt32 = 0
    for offset in 0..<count {
        packed |= UInt32(source[start + offset]) &<< (8 &* offset)
    }
    return packed
}

/// Byte `index` of a packed partial sequence.
@inline(always)
private func partialSequenceByte(_ packed: UInt32, _ index: Int) -> UInt8 {
    UInt8(truncatingIfNeeded: packed &>> (8 &* index))
}

/// Takes bytes off the front of `source` until the packed partial sequence holds `length` of them or
/// the input runs out, validating nothing, as `handlePartialSequence`'s `memcpySpan` validates
/// nothing.
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

/// Spreads the low four bytes of `x` into the four 16-bit lanes of the result: byte at bit `8*i`
/// moves to bit `16*i`, odd bytes zero, high four bytes of `x` ignored. The four terms are disjoint,
/// and the widest lands its top bit at 55, so nothing is discarded.
@inline(always)
private func spreadFourBytesToUTF16Lanes(_ x: UInt64) -> UInt64 {
    (x & 0xFF) | ((x & 0xFF00) << 8) | ((x & 0xFF_0000) << 16) | ((x & 0xFF00_0000) << 24)
}

/// Writes the surrogate pair for `scalar`, which must be above U+FFFF, and answers the two units it
/// took so that a caller can add it to its cursor.
///
/// U16_LEAD and U16_TRAIL as arithmetic rather than through `Unicode.Scalar`, whose failing
/// initializer would add an optional and a trap edge to a value the walls above have bounded. The
/// subscripts are bounds-checked, so a caller that miscounts its destination traps here rather than
/// writing past it.
@inline(always)
private func appendSurrogatePair(_ scalar: UInt32, to output: inout MutableSpan<UInt16>, at produced: Int) -> Int {
    output[produced] = UInt16(truncatingIfNeeded: (scalar &>> 10) &+ 0xD7C0)
    output[produced + 1] = UInt16(truncatingIfNeeded: (scalar & 0x3FF) &+ 0xDC00)
    return 2
}

/// Writes `scalar` at `output[produced]` as one code unit or as a surrogate pair, answering how many
/// units it took. Where the scalar is already known to be above U+FFFF, call `appendSurrogatePair`
/// directly: the test below costs a branch per character, worth 6% on `mixed-234`.
@inline(always)
private func appendScalar(_ scalar: UInt32, to output: inout MutableSpan<UInt16>, at produced: Int) -> Int {
    guard scalar > 0xFFFF else {
        output[produced] = UInt16(truncatingIfNeeded: scalar)
        return 1
    }
    return appendSurrogatePair(scalar, to: &output, at: produced)
}

/// `decodeNonASCIISequence` over a packed partial sequence: the scalar value, or `nil` for
/// `nonCharacter`.
///
/// `subpart` is that function's `uint8_t& length` out-parameter: on `nil` it is the index of the
/// first invalid byte, which is what the caller skips. Bytes above the held size are zero, and zero
/// is not a continuation byte, so an incomplete sequence always answers `nil`.
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

/// The outcome of the 8-bit `handlePartialSequence`.
private enum NarrowPartialSequenceOutcome {
    /// Returned false with the sequence decoded: one Latin-1 character, main loop takes over.
    case latin1(character: UInt8, consumed: Int)
    /// Returned false with the sequence still held: the decode is over and the string is 8-bit.
    case waiting(partialSequence: UInt32, size: Int, consumed: Int)
    /// Returned true, so the 16-bit machinery takes over from exactly this state. Nothing is
    /// emitted: the C++ caller passes that overload a copy of its destination and keeps it only on
    /// false, so anything written before returning true is discarded.
    case needsWide(partialSequence: UInt32, size: Int, consumed: Int)
}

/// The 8-bit `handlePartialSequence`, which is one iteration of its `do`/`while` rather than a loop.
///
/// That rests on two properties of a held sequence, both preconditions here: its first byte is not
/// ASCII, and when that byte leads a sequence the held size is at most that sequence's length. So
/// the one exit that could loop -- a decoded Latin-1 character -- subtracts the whole sequence
/// length from a size that is at most that length. Nothing in this file can produce either shape:
/// a main loop holds a sequence only when a non-ASCII lead runs out of input.
///
/// `@inline(never)` because this is cold and its caller is not. With one call site the optimiser
/// inlines it into `textCodecUTF8DecodeNarrow`, which relays out that function and moves the 8-bit
/// word loop across a cache line: -5% on `ascii` and -3% on `latin1-p8`, loop otherwise unchanged.
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
    // `if (!count) return true;`. This overload takes no `sawError`, so a byte that leads nothing is
    // not recorded as an error until the 16-bit overload meets it again.
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
    // `if (!isLatin1(character)) return true;`, and `isLatin1(nonCharacter)` is false because
    // `nonCharacter` is -1 and `isLatin1` casts to unsigned. That is why an ill-formed partial
    // sequence upconverts even under `stopOnError`: this overload cannot see the flag.
    guard let character, character <= 0xFF else {
        return .needsWide(partialSequence: packed, size: size, consumed: index)
    }
    precondition(size == length, "a held UTF-8 partial sequence cannot outrun its lead byte's sequence")
    return .latin1(character: UInt8(truncatingIfNeeded: character), consumed: index)
}

/// The outcome of the 16-bit `handlePartialSequence`.
private enum WidePartialSequenceOutcome {
    /// Nothing is held any more and the 16-bit main loop takes over.
    case decoded(consumed: Int)
    /// The sequence is still incomplete and the decode is over.
    case waiting(partialSequence: UInt32, size: Int, consumed: Int)
    /// `stopOnError` ended it at an ill-formed sequence, leaving what is held as it stood.
    case stopped(partialSequence: UInt32, size: Int, consumed: Int)
}

/// The 16-bit `handlePartialSequence`, which unlike the 8-bit one is a loop, does apply
/// `stopOnError`, and is one of the two places a byte order mark is stripped.
///
/// It loops because its output is bounded by the input rather than by what is held: it takes fresh
/// bytes on every iteration, so { 0xF0 } against an input of 0xF0 bytes emits one replacement
/// character per input byte without the main loop ever running. The destination is sized for that,
/// at one slot per input byte, which is worst case even for a four-byte sequence, since four bytes
/// produce two UTF-16 units.
///
/// `shouldStripByteOrderMark` is position-independent here, which is the rule this ports rather than
/// an oversight in it: TextCodecUTF8.cpp:318 spends the flag on the first character this decodes,
/// wherever in the buffer it lands, and strips it only if that character is U+FEFF. The main loop's
/// rule at :567 is the position-dependent one. A sequence has to have been held for this rule to
/// apply, so the two differ only on input split across a chunk boundary.
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
        // One slot per character, as in the wide kernel and for the same reason: asking for two
        // stops a character early on an exactly-tight destination. A surrogate pair's second slot is
        // guaranteed by the sizing above and bounds-checked by `appendScalar`.
        precondition(units < output.count, "UTF-8 wide partial sequence ran out of destination")

        let firstByte = partialSequenceByte(packed, 0)
        if firstByte < 0x80 {
            // The shift is `consumePartialSequenceByte`'s `memmove`, since byte `i` is at bit `8*i`.
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
            // Only the maximal subpart is consumed; the bytes after it come round again as fresh
            // lead bytes.
            output[units] = replacementCharacter
            units += 1
            packed = packed &>> (8 &* subpart)
            size -= subpart
            continue
        }

        packed = packed &>> (8 &* length)
        size -= length
        // `if (std::exchange(m_shouldStripByteOrderMark, false) && character == byteOrderMark)
        // continue;`, in that order: the flag is spent on any character decoded here, and only a
        // U+FEFF is dropped.
        if shouldStripByteOrderMark {
            shouldStripByteOrderMark = false
            if character == byteOrderMark { continue }
        }
        units += appendScalar(character, to: &output, at: units)
    } while size != 0

    return .decoded(consumed: index)
}

/// The outcome of decoding into one destination buffer's worth of output.
///
/// Neither kernel settles an ill-formed sequence; both report it and let their callers decide. That
/// is a codegen requirement rather than a preference: `stopOnError` and `sawError` are per-call
/// state, and carrying them through a per-character loop cost two live registers -- enough to evict
/// the three-byte path's constant and spill the surrogate pair's second base pointer, at -5% on
/// `twobyte-wide-only` and -16% on `fourbyte-only`.
private enum ChunkOutcome {
    /// The destination filled, or the input ran out.
    case complete(consumed: Int, produced: Int)
    /// The input ended mid-sequence, with the truncated bytes unexamined and not counted in
    /// `consumed`: both C++ main loops hold a partial sequence on `count > source.size()` alone.
    case truncated(consumed: Int, produced: Int, partial: Int)
    /// The 8-bit kernel met a well-formed character above U+00FF, and consumed nothing for it.
    /// Never from the 16-bit kernel.
    case needsWide(consumed: Int, produced: Int)
    /// An ill-formed sequence, nothing consumed for it. `subpart` is `decodeNonASCIISequence`'s
    /// rewritten `length` -- the maximal subpart to skip -- or 0 for a lead byte that leads nothing.
    /// From the 8-bit kernel it is always 0 and means nothing: that caller consumes nothing either
    /// way, since `stopOnError` decides the width of the whole string there.
    case illFormed(consumed: Int, produced: Int, subpart: Int)
}

/// Whether the sequence at `index`, whose lead is above 0xC3 and which is wholly present, is well
/// formed: whether the 8-bit kernel is looking at a character that widens the output or at an
/// ill-formed sequence.
///
/// `@inline(never)` is the whole point of this existing. Inlined, its `length` tests get hoisted
/// into the 8-bit kernel's per-character path as a precomputed flag register, costing
/// `latin1-only` 12.5%. It runs at most once per chunk, since both answers end the chunk.
@inline(never)
private func classifyWideLead(
    _ source: Span<UInt8>,
    at index: Int,
    produced: Int
) -> ChunkOutcome {
    let firstByte = source[index]
    let length = sequenceLength(firstByte)
    let illFormed = ChunkOutcome.illFormed(consumed: index, produced: produced, subpart: 0)
    if !isValidSecondByte(firstByte, source[index + 1]) { return illFormed }
    if length >= 3 && !isContinuationByte(source[index + 2]) { return illFormed }
    if length == 4 && !isContinuationByte(source[index + 3]) { return illFormed }
    return .needsWide(consumed: index, produced: produced)
}

/// Decodes from `source[start...]` into `output`, one Latin-1 character per byte, until `output` is
/// full, `source` runs out, or a character above U+00FF calls for the 16-bit kernel instead.
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
    // Every character here is one byte and costs at least one input byte, so output capacity bounds
    // input consumption directly and the loop needs no per-character space check.
    let limit = min(end, index + output.count - startProduced)

    while index < limit {
        // One compare gates the word loop, and the gate's byte is spent rather than re-read -- the
        // opposite of the 16-bit kernel, and measured rather than chosen: re-reading costs a second
        // checked subscript on every ASCII byte the word loop misses, worth 4-7% across periods 8
        // to 32 against the 51% it wins on pure Latin-1.
        let firstByte = source[index]
        if firstByte < 0x80 {
            output[produced] = firstByte
            produced += 1
            index += 1

            // ASCII a machine word at a time, the copy fused with the test so the source is read
            // once. No alignment gate: `load` has no alignment precondition, so unlike the C++ this
            // needs no scalar run to re-align after every multi-byte sequence.
            //
            // One store, through a raw view of the same output, which keeps the copy
            // order-preserving on any host: the store's byte order is the load's by construction,
            // where eight shift-and-truncate stores would reverse every group on a big-endian host.
            // The view is scoped so its exclusive borrow ends before the tail writes through
            // `output` itself.
            do {
                var outputBytes = output.mutableBytes
                while index + 8 <= limit {
                    let word = sourceBytes.load(fromByteOffset: index, as: UInt64.self)
                    if word & highBitsOfEachByte != 0 { break }
                    outputBytes.storeBytes(of: word, toByteOffset: produced, as: UInt64.self)
                    produced += 8
                    index += 8
                }
            }
            continue
        }

        // 0xC2 and 0xC3 are the only leads whose sequences reach Latin-1 and no further, so
        // everything else either widens the output or is ill-formed. Length, then truncation, then
        // width -- the order the C++ decides it in.
        let length = sequenceLength(firstByte)
        if length == 0 { return .illFormed(consumed: index, produced: produced, subpart: 0) }

        if index + length > end {
            // A truncated tail is held whatever its width and validity -- the C++ 8-bit loop reaches
            // that point before `decodeNonASCIISequence` or `isLatin1` -- so a chunk ending in a
            // prefix of a wide sequence still finishes as an 8-bit string.
            return .truncated(consumed: index, produced: produced, partial: end - index)
        }

        // A wide lead is validated here, because `stopOnError` makes ill-formed and
        // well-formed-but-wide two different widths. Handing an unvalidated wide lead to the 16-bit
        // kernel would flip `is8Bit()` on `stopOnError` input that is Latin-1 up to the error.
        if firstByte > 0xC3 { return classifyWideLead(source, at: index, produced: produced) }

        let secondByte = source[index + 1]
        if !isContinuationByte(secondByte) { return .illFormed(consumed: index, produced: produced, subpart: 0) }

        // For these two leads the scalar always lands in 0x80...0xFF.
        output[produced] = UInt8(truncatingIfNeeded: twoByteScalar(firstByte, secondByte))
        produced += 1
        index += 2
    }

    return .complete(consumed: index, produced: produced)
}

/// Decodes from `source[start...]` into 16-bit `output` from element `startingAt` on, until `output`
/// is full, `source` runs out, or an ill-formed sequence turns up. Every well-formed sequence, that
/// is: the 0xC4-and-up two-byte forms, all three-byte forms, and all four-byte forms as surrogate
/// pairs.
///
/// `startingAt` is how the caller resumes after settling an ill-formed sequence. It makes `produced`
/// arbitrary at the top of the word loop, which is fine: the loop forms its store pointer from
/// `produced` once on entry and post-increments, and `str q0` has no alignment requirement, so the
/// merge of the two eight-byte stores into one sixteen-byte store does not depend on the residue.
private func decodeWideChunk(
    _ source: Span<UInt8>,
    from start: Int,
    into output: inout MutableSpan<UInt16>,
    startingAt startProduced: Int
) -> ChunkOutcome {
    let sourceBytes = source.bytes
    var index = start
    var produced = startProduced
    let end = source.count
    let capacity = output.count

    // A four-byte sequence produces two code units, so unlike the 8-bit kernel this cannot bound
    // consumption by capacity once and forget it. It must still ask for one slot per character and
    // not two: the caller sizes the destination at one slot per input byte, so
    // `capacity - produced >= end - index` holds on entry and every character consumes at least as
    // many bytes as it produces code units. Demanding two slots for a one-unit character stops the
    // loop a character early on an exactly-tight destination -- any input whose wide region is
    // U+FFFD, the one character costing a slot per byte.
    while index < end && produced < capacity {
        // One compare gates the word loop, as in the 8-bit kernel, but the gate's byte is re-read
        // rather than spent -- again measured: emitting the gate's code unit first costs 17-20% on
        // the long-ASCII-run bands and buys back only 8-13% at periods four to sixteen.
        var firstByte = source[index]
        if firstByte < 0x80 {
            // One checked load and two checked stores, not sixteen subscripts. Widening through
            // `output[produced + offset] = source[index + offset]` leaves the optimiser eight source
            // and eight output indices to bound and it eliminates none of them: 73 instructions per
            // eight bytes against the 8-bit kernel's 16.
            //
            // The mask test needs no byte order: `highBitsOfEachByte` is the same in all eight
            // lanes. `UInt64(littleEndian:)` normalises once, after which input byte `i` is at bit
            // `8*i` of `w` on either host, so `w` and not `word` is what the arithmetic may look at,
            // and the split into `lo`/`hi` is by input position. `.littleEndian` on the way out
            // cancels `storeBytes`'s own host reordering.
            do {
                var outputBytes = output.mutableBytes
                while index + 8 <= end && produced + 8 <= capacity {
                    let word = sourceBytes.load(fromByteOffset: index, as: UInt64.self)
                    if word & highBitsOfEachByte != 0 { break }
                    let w = UInt64(littleEndian: word)
                    let lo = spreadFourBytesToUTF16Lanes(w)
                    let hi = spreadFourBytesToUTF16Lanes(w &>> 32)
                    // Byte offsets, where `produced` counts 16-bit elements. `produced + 8 <=
                    // capacity` above, so `produced * 2 + 16` is within the raw view.
                    let byteOffset = produced &* 2
                    outputBytes.storeBytes(of: lo.littleEndian, toByteOffset: byteOffset, as: UInt64.self)
                    outputBytes.storeBytes(of: hi.littleEndian, toByteOffset: byteOffset &+ 8, as: UInt64.self)
                    produced += 8
                    index += 8
                }
            }
            if index >= end || produced >= capacity { break }

            // The cursor may have moved, and the sequence below needs the byte under it now.
            firstByte = source[index]
            if firstByte < 0x80 {
                output[produced] = UInt16(truncatingIfNeeded: firstByte)
                produced += 1
                index += 1
                continue
            }
        }

        // Length before truncation, and the `subpart` each ill-formed exit carries is
        // `decodeNonASCIISequence`'s rewritten `length`, which does not include the rejected byte.
        let length = sequenceLength(firstByte)
        if length == 0 { return .illFormed(consumed: index, produced: produced, subpart: 0) }

        if index + length > end {
            return .truncated(consumed: index, produced: produced, partial: end - index)
        }

        let secondByte = source[index + 1]
        if !isValidSecondByte(firstByte, secondByte) {
            return .illFormed(consumed: index, produced: produced, subpart: 1)
        }
        if length == 2 {
            output[produced] = UInt16(truncatingIfNeeded: twoByteScalar(firstByte, secondByte))
            produced += 1
            index += 2
            continue
        }

        let thirdByte = source[index + 2]
        if !isContinuationByte(thirdByte) {
            return .illFormed(consumed: index, produced: produced, subpart: 2)
        }
        if length == 3 {
            // The walls above bound this at U+0800 and U+FFFF and cut out D800-DFFF, so it is always
            // one code unit and never a lone surrogate. U+FEFF is emitted verbatim.
            output[produced] = UInt16(truncatingIfNeeded: threeByteScalar(firstByte, secondByte, thirdByte))
            produced += 1
            index += 3
            continue
        }

        let fourthByte = source[index + 3]
        if !isContinuationByte(fourthByte) {
            return .illFormed(consumed: index, produced: produced, subpart: 3)
        }
        // Two slots, where the loop condition asked for one. They are there: this is reached only
        // after `index + 4 <= end`, and `capacity - produced >= end - index` gives at least four.
        // A four-byte sequence is always above U+FFFF, so this goes straight to the pair rather than
        // through `appendScalar`, whose width test would be a branch per character here.
        produced += appendSurrogatePair(fourByteScalar(firstByte, secondByte, thirdByte, fourthByte), to: &output, at: produced)
        index += 4
    }

    return .complete(consumed: index, produced: produced)
}

/// A decoded result. There is no other kind: every input this cannot decode is a precondition
/// violation rather than a return value.
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
    result.partialSequence = partialSequence
    result.partialSequenceSize = UInt8(partialSequenceSize)
    result.needsWide = needsWide
    result.sawError = sawError
    result.stoppedOnError = stoppedOnError
    result.shouldStripByteOrderMark = shouldStripByteOrderMark
    return result
}

/// Decodes `input` as UTF-8 into `destInput`, a Latin-1 destination, reporting `needsWide` at the
/// first character that cannot go there and leaving `consumed` pointing at the triggering sequence
/// so that the caller's wide half re-reads it. Handling a partial sequence can force `needsWide`
/// before the main loop runs, since an error inside one upconverts even under `stopOnError`.
///
/// `partialSequence` and `partialSequenceSize` are a copy of what a previous call left incomplete,
/// packed by `packPartialSequence`. This reads them, works on locals, and reports a new partial
/// sequence for the caller to store. It reads and writes no other codec state: everything that
/// crosses is a value, in and out.
///
/// The caller guarantees nothing about `input`, empty included, which answers with nothing consumed
/// and nothing produced.
///
/// `shouldStripByteOrderMark` is `m_shouldStripByteOrderMark`, and is echoed unchanged in the
/// result: no 8-bit path in the C++ reads or writes that flag, because a byte order mark is not
/// Latin-1, so this reports `needsWide` at one rather than deciding it.
///
/// TODO(unsafe): `_unsafeCxxSpan:` for `input` and `destInput` -- rdar://186723514.
@_expose(Cxx)
public func textCodecUTF8DecodeNarrow(
    _ input: PAL.TextCodecUTF8SwiftInput,
    _ destInput: PAL.TextCodecUTF8SwiftNarrowDest,
    _ partialSequence: UInt32,
    _ partialSequenceSize: UInt8,
    _ flush: Bool,
    _ stopOnError: Bool,
    _ shouldStripByteOrderMark: Bool
) -> PAL.TextCodecUTF8SwiftResult {
    // The destination is a `StringBuffer` the caller has just allocated, so it cannot overlap the
    // input.
    let source = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    var dest = unsafe MutableSpan<UInt8>(_unsafeCxxSpan: destInput)

    var consumed = 0
    var produced = 0
    var packed = partialSequence
    var packedSize = Int(partialSequenceSize)
    var sawError = false
    var stoppedOnError = false

    // `TextCodecUTF8::decode`'s own shape: decode what is held, run the main loop, and go round
    // again if the main loop left a truncated tail for this call to diagnose. It goes round at most
    // once, since a main loop stops only when the input is exhausted.
    stages: while true {
        if packedSize != 0 {
            switch handlePartialSequenceNarrow(source, from: consumed, partialSequence: packed, size: packedSize, flush: flush) {
            case .waiting(let held, let size, let cursor):
                packed = held
                packedSize = size
                consumed = cursor
                break stages

            case .needsWide(let held, let size, let cursor):
                // What is held crosses unconditionally, unlike the terminal result below. This is a
                // hand-off: the caller packs it straight into the wide half's argument, so
                // suppressing it under `flush` would hand that half an empty partial sequence and an
                // empty source, and nobody would emit the truncated tail's U+FFFD.
                return makeResult(consumed: cursor, produced: produced, partialSequence: held, partialSequenceSize: size,
                                  needsWide: true, sawError: sawError,
                                  shouldStripByteOrderMark: shouldStripByteOrderMark)

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
            return makeResult(consumed: chunkConsumed, produced: chunkProduced,
                              needsWide: true, sawError: sawError,
                              shouldStripByteOrderMark: shouldStripByteOrderMark)

        case .illFormed(let chunkConsumed, let chunkProduced, _):
            produced = chunkProduced
            consumed = chunkConsumed
            sawError = true
            // Without `stopOnError` the ill-formed sequence is not Latin-1, so upconvert; with it,
            // the C++ breaks to its 8-bit tail and the string stays 8-bit.
            if !stopOnError {
                return makeResult(consumed: consumed, produced: produced,
                                  needsWide: true, sawError: true,
                                  shouldStripByteOrderMark: shouldStripByteOrderMark)
            }
            stoppedOnError = true
            break stages

        case .truncated(let chunkConsumed, let chunkProduced, let partialSize):
            produced = chunkProduced
            packed = packPartialSequence(source, from: chunkConsumed, count: partialSize)
            packedSize = partialSize
            consumed = chunkConsumed + partialSize
            // Round again: the tail just held has to be diagnosed in this call.
            continue stages

        case .complete(let chunkConsumed, let chunkProduced):
            produced = chunkProduced
            // One Latin-1 character per input byte, and the caller sizes the destination at one slot
            // per input byte, so the kernel stops only at the end of the input. Were it to stop for
            // want of room, this loop would re-enter it with the same arguments and spin, so this
            // guards the spin as well as the short decode.
            precondition(chunkConsumed == source.count, "UTF-8 narrow decode stopped short of its input")
            consumed = chunkConsumed
            break stages
        }
    }

    return makeResult(consumed: consumed, produced: produced,
                      partialSequence: flush ? 0 : packed, partialSequenceSize: flush ? 0 : packedSize,
                      sawError: sawError, stoppedOnError: stoppedOnError,
                      shouldStripByteOrderMark: shouldStripByteOrderMark)
}

/// Decodes `input` as UTF-8 into `destInput`, a UTF-16 destination, after
/// `textCodecUTF8DecodeNarrow` reported `needsWide`. The caller has widened the 8-bit prefix into a
/// `StringBuffer<char16_t>` and passes a span starting past it, so this writes from index zero, and
/// it continues from the partial sequence the narrow half handed over.
///
/// `startsFinalBuffer` says the destination span begins at index 0 of the final string buffer, which
/// is to say that the narrow half produced nothing before handing over. It is the other half of the
/// position-dependent strip rule at TextCodecUTF8.cpp:567,
/// `destination16.data() == buffer16.characters()`, which is not visible from this cursor.
///
/// TODO(unsafe): `_unsafeCxxSpan:` for `input` and `destInput` -- rdar://186723514.
@_expose(Cxx)
public func textCodecUTF8DecodeWide(
    _ input: PAL.TextCodecUTF8SwiftInput,
    _ destInput: PAL.TextCodecUTF8SwiftWideDest,
    _ partialSequence: UInt32,
    _ partialSequenceSize: UInt8,
    _ flush: Bool,
    _ stopOnError: Bool,
    _ shouldStripByteOrderMark: Bool,
    _ startsFinalBuffer: Bool
) -> PAL.TextCodecUTF8SwiftResult {
    // The destination is the caller's second `StringBuffer`, so it cannot overlap the input.
    let source = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    var dest = unsafe MutableSpan<UInt16>(_unsafeCxxSpan: destInput)

    var consumed = 0
    var produced = 0
    var packed = partialSequence
    var packedSize = Int(partialSequenceSize)
    var sawError = false
    var stoppedOnError = false
    var shouldStrip = shouldStripByteOrderMark

    stages: while true {
        if packedSize != 0 {
            let outcome = handlePartialSequenceWide(
                source, from: consumed, partialSequence: packed, size: packedSize,
                flush: flush, stopOnError: stopOnError,
                into: &dest, units: &produced, sawError: &sawError,
                shouldStripByteOrderMark: &shouldStrip)
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

        // The main loop's strip rule, TextCodecUTF8.cpp:567, settled before the kernel runs rather
        // than inside it. It fires only for a U+FEFF landing at index 0 of the final buffer, so it
        // can fire at most once per decode and only while that buffer is still empty -- and a mark
        // there is exactly the three bytes at the cursor, since no other encoding of U+FEFF decodes.
        // Settling it here keeps the wide kernel's per-character path, which is the hot one, free of
        // a flag it would test on every character to use on none. A mark too short to be whole falls
        // through to the kernel, which holds it, and the next call settles it under the other rule.
        if shouldStrip && startsFinalBuffer && produced == 0
            && consumed + 3 <= source.count
            && source[consumed] == byteOrderMarkBytes.0
            && source[consumed + 1] == byteOrderMarkBytes.1
            && source[consumed + 2] == byteOrderMarkBytes.2 {
            shouldStrip = false
            consumed += 3
        }

        while true {
            switch decodeWideChunk(source, from: consumed, into: &dest, startingAt: produced) {
            // Never from the wide kernel: `needsWide` is the 8-bit kernel saying a character does
            // not fit Latin-1, and this destination is already 16-bit.
            case .needsWide:
                preconditionFailure("the UTF-8 16-bit kernel cannot ask to widen")

            case .illFormed(let errorAt, let chunkProduced, let subpart):
                sawError = true
                if stopOnError {
                    consumed = errorAt
                    produced = chunkProduced
                    stoppedOnError = true
                    break stages
                }
                dest[chunkProduced] = replacementCharacter
                produced = chunkProduced + 1
                consumed = errorAt + max(subpart, 1)

            case .truncated(let chunkConsumed, let chunkProduced, let partialSize):
                packed = packPartialSequence(source, from: chunkConsumed, count: partialSize)
                packedSize = partialSize
                consumed = chunkConsumed + partialSize
                produced = chunkProduced
                // Round the outer loop again: the tail just held has to be diagnosed in this call.
                continue stages

            case .complete(let chunkConsumed, let chunkProduced):
                // The kernel's loop ended, so a fresh call with the same arguments would answer the
                // same and re-entering it would spin. It ends either on exhausted input or on a full
                // destination, and the latter would be a silent short decode: one slot per input
                // byte is worst case, so only the former is reachable, and this says so.
                precondition(chunkConsumed == source.count, "UTF-8 wide decode stopped short of its input")
                consumed = chunkConsumed
                produced = chunkProduced
                break stages
            }
        }
    }

    return makeResult(consumed: consumed, produced: produced,
                      partialSequence: flush ? 0 : packed, partialSequenceSize: flush ? 0 : packedSize,
                      sawError: sawError, stoppedOnError: stoppedOnError,
                      shouldStripByteOrderMark: shouldStrip)
}
