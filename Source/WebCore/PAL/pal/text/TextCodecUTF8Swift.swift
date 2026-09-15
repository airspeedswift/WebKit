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

// UTF-8 decoding.
//
// `TextCodecUTF8::decode` decodes optimistically into an 8-bit `StringBuffer` and abandons it
// for a 16-bit one the moment it meets a character Latin-1 cannot hold, an ill-formed
// sequence, or a byte order mark. This file covers WELL-FORMED input at either width: ASCII and
// the 0xC2/0xC3 two-byte sequences fill the 8-bit buffer, and the first character above U+00FF
// flips the output to a 16-bit buffer that the sink allocates and owns from then on --
// `TextCodecUTF8SwiftSink` records why the width is this arm's to choose rather than the
// caller's to decide up front.
//
// WHAT STILL DECLINES, and a decline is a WHOLE-INPUT decline: the C++ re-runs its own loop over
// the same bytes from the top, so one byte outside the subset costs that chunk's Swift attempt
// entirely. Namely any ill-formed sequence -- the C++ answers one with U+FFFD, and `stopOnError`
// interacts with it -- plus a partial sequence parked by a previous call, plus the two cases the
// caller's precondition excludes: a pending byte order mark and empty input.
// `textCodecUTF8SwiftCounters()` is what makes that boundary visible, because a declining arm
// and an agreeing arm are byte-identical by construction.
//
// A TRUNCATED TAIL IS PARKED ONLY WHEN THE BYTES PRESENT ARE A VALID PREFIX, which is narrower
// than the C++'s park and has to be. The C++'s main loops park on sequence LENGTH alone, without
// looking at the bytes present, and `handlePartialSequence` then diagnoses EAGERLY: its
// park-and-wait fires only when the recomputed subpart length still equals the parked size, and
// an already-invalid prefix makes it smaller. So {0xF0, 0x80} at the end of a chunk emits two
// U+FFFD from that chunk with `flush` false -- it does not wait for more input -- and an arm
// that parked it would answer differently.
//
// AND ONLY A BYTE THAT IS A VALID LEAD IS EVER PARKED. A lead byte whose sequence length is zero
// (0x80-0xC1 and 0xF5-0xFF) reaches `nonCharacter` in the C++ before it reaches the park, so the
// C++ can NEVER park one. A park keyed on "the input ended and the last byte is non-ASCII" would
// therefore create a state only one arm can enter, which no differential can catch, because
// only one arm can produce the transcript to compare. The length test comes before the
// truncation test in both kernels below for that reason and no other.
//
// WHAT THE WORD-AT-A-TIME SCAN BUYS IS SPEED, NOT SAFETY, and the C++ it shadows has no
// over-read to fix. `RawSpan.load(fromByteOffset:as:)` (SE-0525) is bounds-checked and has no
// alignment precondition, so the loop here runs at any cursor offset. The C++ reaches the same
// width by reinterpreting a pointer, so it gates the whole loop on
// `isAlignedToMachineWord(source.data())` and pays up to seven bytes of scalar work to
// re-align after every multi-byte sequence. Its bound is sound: `alignToMachineWord` rounds
// DOWN (`& ~machineWordAlignmentMask`), so `alignedEnd` is at or below `source.end()`, and an
// aligned `source.data() < alignedEnd` therefore has a whole word in bounds.
//
// BOUNDS CHECKING IS A WASH, not a win. Reads here go through a checked `Span` subscript or a
// checked `load`, and `decodeNonASCIISequence`'s `sequence[1]`..`sequence[3]` are checked too,
// because PAL's C++ compiles with `_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE`
// and `std::span::operator[]` asserts under it. The difference is where the guarantee lives:
// libc++'s is a `-D` on the command line over a default of `_LIBCPP_HARDENING_MODE_NONE`,
// and it bounds the subscript against the whole remaining input rather than against the
// sequence, so what actually keeps those three reads inside the sequence is the separately
// computed `count <= source.size()` -- exactly as the `index + 2 > end` test does here.

public import pal.Core.text.TextCodecUTF8SwiftTypes

/// Set in every byte of a machine word whose corresponding input byte is non-ASCII.
private let highBitsOfEachByte: UInt64 = 0x8080_8080_8080_8080

/// How many bytes the sequence led by `firstByte` occupies, or 0 if it cannot lead one.
///
/// The C++'s `nonASCIISequenceLength` is a 256-entry table; this is three branch-predictable
/// compares, and it is deliberately not a table. A Swift `let` global of non-trivial type costs a
/// one-time-initialization token check on every access, and 256 entries would be 256 source facts
/// that no behavioural harness can see -- half of them are the zeros, which every caller reads as
/// "decline" and so can never distinguish from a wrong non-zero.
///
/// Callers test for ASCII first, so 0x00-0x7F reaching here would be a caller bug rather than a
/// sequence of length one; it answers 0, the same as the continuation bytes and 0xC0/0xC1, whose
/// two-byte forms are overlong.
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
/// Four leads have a narrower wall than the plain continuation range, and each is a labelled case
/// of `decodeNonASCIISequence`: `case 0xE0` needs 0xA0-0xBF (below that is overlong), `case 0xED`
/// needs 0x80-0x9F (above that is the surrogates), `case 0xF0` needs 0x90-0xBF (overlong again)
/// and `case 0xF4` needs 0x80-0x8F (above that is beyond U+10FFFF). Every other lead takes the
/// whole range, which is what both `default:` arms and the two-byte branch test.
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

/// Whether `byte` is valid at index 2 or 3 of a sequence: the three `sequence[2]`/`sequence[3]`
/// tests in `decodeNonASCIISequence`, all of them the plain continuation range.
@inline(always)
private func isContinuationByte(_ byte: UInt8) -> Bool {
    byte >= 0x80 && byte <= 0xBF
}

/// Packs `count` bytes of `source` starting at `start` the way a parked partial sequence crosses
/// the boundary: byte `i` of the sequence at bit `8 * i` of the result, nothing above `count`.
///
/// The bit position is the byte's index within the sequence and nothing else, so the packed value
/// means the same on a big-endian host as on a little-endian one. That is written down because it
/// is unobservable here: every differential this island has runs on arm64 only, so a packing-order
/// mistake would be invisible to it in both directions.
@inline(always)
private func packSequenceBytes(_ source: Span<UInt8>, from start: Int, count: Int) -> UInt32 {
    var packed: UInt32 = 0
    for offset in 0..<count {
        packed |= UInt32(source[start + offset]) &<< (8 &* offset)
    }
    return packed
}

/// Spreads the low four bytes of `x` into the four 16-bit lanes of the result: byte at bit
/// position `8*i` of `x` moves to bit position `16*i`, and the odd bytes of the result are zero.
/// The high four bytes of `x` are ignored, so a caller may pass a whole word for the low half.
///
/// Each term moves one byte by exactly the distance that separates its two positions -- byte 0 by
/// 0, byte 1 by 8, byte 2 by 16, byte 3 by 24 -- and the four source fields are disjoint, so the
/// four results are disjoint too and `|` is a sum. `<<` on a fixed-width integer discards rather
/// than traps, and the widest term here is `0xFF00_0000 << 24`, whose top bit lands at 55: nothing
/// is discarded in any case.
@inline(always)
private func spreadFourBytesToUTF16Lanes(_ x: UInt64) -> UInt64 {
    (x & 0xFF) | ((x & 0xFF00) << 8) | ((x & 0xFF_0000) << 16) | ((x & 0xFF00_0000) << 24)
}

/// The outcome of decoding into one scratch buffer's worth of output.
private enum ChunkOutcome {
    /// The scratch buffer filled, or the input ran out.
    case complete(consumed: Int, produced: Int)
    /// The input ended mid-sequence. `consumed` excludes the truncated sequence.
    case truncated(consumed: Int, produced: Int, partial: Int)
    /// The 8-bit kernel met a character above U+00FF. Nothing is consumed for it: the 16-bit
    /// kernel re-reads the sequence from `consumed`, which is also where its validity is decided.
    case needsWide(consumed: Int, produced: Int)
    /// Something outside this arm's subset; the caller declines the whole input.
    case declined
}

/// Decodes from `source[start...]` into `output`, one Latin-1 character per byte, until `output`
/// is full, `source` runs out, or a character above U+00FF calls for the 16-bit kernel instead.
///
/// Bails out the moment it meets anything it does not cover, so a decline costs at most one
/// scratch buffer of wasted work rather than a pass over the whole input.
private func decodeChunk(
    _ source: Span<UInt8>,
    _ sourceBytes: RawSpan,
    from start: Int,
    into output: inout MutableSpan<UInt8>
) -> ChunkOutcome {
    var index = start
    var produced = 0
    let end = source.count
    // Every character this arm produces is exactly one byte and costs at least one input
    // byte, so output capacity bounds input consumption directly and the loop needs no
    // per-character space check.
    let limit = min(end, index + output.count)

    while index < limit {
        // ONE COMPARE GATES THE WORD LOOP, as in the 16-bit kernel and for the same reason: input
        // whose next byte is not ASCII would otherwise pay the limit test, the `load`'s two-part
        // bounds check, the eight-byte load, the mask and the branch to learn what one `ldrb` and
        // one `cmp` answer. Latin-1 text is a run of two-byte sequences with no ASCII between
        // them, so that is eleven wasted instructions per character on it, not a corner case.
        //
        // AND THE GATE'S BYTE IS SPENT, not re-read. Reading `source[index]` again after the word
        // loop -- the shape the 16-bit kernel uses, where the cursor has to be re-examined anyway
        // -- costs a second checked subscript on every ASCII byte the word loop does not cover,
        // and those bytes are the majority whenever the ASCII runs are shorter than eight: at one
        // wide character every eight, the runs are seven bytes and the word loop never fires at
        // all. Measured, that re-read form gave up 4-7% across periods 8 to 32 for the 51% it won
        // on pure Latin-1. Emitting the gate's own byte and running the word loop from the byte
        // AFTER it keeps both: the scalar path reads each byte exactly once, as it did before the
        // gate existed, and one byte of every ASCII run is emitted scalar, which the run's
        // remaining words amortise away.
        let firstByte = source[index]
        if firstByte < 0x80 {
            output[produced] = firstByte
            produced += 1
            index += 1

            // ASCII, a machine word at a time. No alignment gate: `load` has no alignment
            // precondition, so unlike the C++ this needs no scalar run to re-align the cursor
            // after every multi-byte sequence.
            //
            // The copy is FUSED with the test on purpose. Measuring the ASCII run first and
            // copying it afterwards reads the source twice, and on long runs -- the common case
            // here -- that costs more than the wider stores buy.
            //
            // The word goes back out as ONE store, through a raw view of the same output. That is
            // not merely the shape a store-merging pass would have had to reconstruct from eight
            // element stores: it is also what keeps the copy order-preserving on any host, because
            // the store's byte order is the load's by construction. Eight shift-and-truncate
            // stores would take input byte 0 from the low bits of the word and so reverse every
            // group on a big-endian host.
            //
            // The raw view is scoped to this loop so that its exclusive borrow of `output` ends
            // before the tail below writes through `output` itself.
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
            // `limit` bounds `index` from above and `produced == index - start` throughout, so the
            // outer condition is the only one this needs; a byte was consumed above, so the loop
            // cannot spin.
            continue
        }

        // 0xC2 and 0xC3 are the only lead bytes whose sequences reach Latin-1 and no further:
        // 0xC0 and 0xC1 are overlong, 0xC4 upwards starts at U+0100, and the three- and
        // four-byte forms start at U+0800 and U+10000. So everything else either widens the
        // output or is ill-formed, and the order the C++ decides that in is the order here:
        // length first, then truncation, and only then the width.
        let length = sequenceLength(firstByte)
        if length == 0 { return .declined }

        if index + length > end {
            // Truncated at the very end of the input; nothing is consumed for it. The C++ parks
            // a truncated tail of ANY width, because its 8-bit loop reaches the park before it
            // reaches `isLatin1` -- so a chunk ending in a valid prefix of a wide sequence still
            // finishes as an 8-bit string. Only a valid prefix may be parked, and at most three
            // bytes can be present, so there is no fourth byte to test.
            let available = end - index
            if available >= 2 && !isValidSecondByte(firstByte, source[index + 1]) { return .declined }
            if available >= 3 && !isContinuationByte(source[index + 2]) { return .declined }
            return .truncated(consumed: index, produced: produced, partial: available)
        }

        if firstByte > 0xC3 { return .needsWide(consumed: index, produced: produced) }

        let secondByte = source[index + 1]
        if secondByte < 0x80 || secondByte > 0xBF { return .declined }

        // The C++'s `((sequence[0] << 6) + sequence[1]) - 0x00003080`, which for these two
        // lead bytes always lands in 0x80...0xFF.
        output[produced] = UInt8(truncatingIfNeeded: (UInt32(firstByte) << 6) &+ UInt32(secondByte) &- 0x3080)
        produced += 1
        index += 2
    }

    return .complete(consumed: index, produced: produced)
}

/// Decodes from `source[start...]` into 16-bit `output` until `output` is full or `source` runs
/// out, covering every well-formed sequence: this is where the 0xC4-and-up two-byte forms, all
/// three-byte forms and all four-byte forms are decoded, the last as surrogate pairs.
///
/// Never answers `.needsWide` -- it is already the wide kernel.
private func decodeWideChunk(
    _ source: Span<UInt8>,
    _ sourceBytes: RawSpan,
    from start: Int,
    into output: inout MutableSpan<UInt16>
) -> ChunkOutcome {
    var index = start
    var produced = 0
    let end = source.count
    let capacity = output.count

    // A four-byte sequence produces TWO code units, so unlike the 8-bit kernel this loop cannot
    // bound consumption by capacity once and forget it: room for a surrogate pair is checked at
    // every character.
    while index < end && produced + 2 <= capacity {
        // ONE COMPARE GATES THE WORD LOOP. Entering it unconditionally makes input with no ASCII
        // in it at all -- a CJK document is the ordinary case, not a corner one -- pay two limit
        // tests, the `load`'s own two-part bounds check, the eight-byte load, the mask and a
        // branch before learning that the byte under the cursor was never ASCII: sixteen
        // instructions per character where one `ldrsb` and one `tbnz` answer it. It is why the C++
        // tests `isASCII(*source)` before its own word loop rather than after it.
        //
        // BUT THE GATE'S BYTE IS RE-READ HERE, NOT SPENT, which is the opposite of the 8-bit
        // kernel and is measured rather than chosen. Emitting the gate's code unit first and
        // running the word loop from the byte after it -- the shape that is right for the 8-bit
        // kernel -- costs this one 17-20% on the long-ASCII-run bands, because `produced` then
        // stops being a multiple of eight at the top of the word loop and the two `storeBytes`
        // lose both the merge into a single sixteen-byte store and the constant-folded capacity
        // check: 31 instructions per eight bytes become 37, plus an overflow check. It buys 8-13%
        // back at periods four to sixteen and that is the smaller half. The asymmetry is real: the
        // 8-bit kernel's store offset IS `produced`, so nothing there depends on its residue.
        var firstByte = source[index]
        if firstByte < 0x80 {
            // ASCII, eight bytes at a time, and this matters as much here as in the 8-bit kernel: a
            // document that needs 16-bit output is not a document that stops being mostly ASCII
            // markup.
            //
            // ONE CHECKED LOAD AND TWO CHECKED STORES, not sixteen subscripts. Widening the eight
            // bytes through `output[produced + offset] = source[index + offset]` reads the same
            // bytes and produces the same values, but it presents the optimiser with eight separate
            // source indices and eight separate output indices to bound, and it does not eliminate
            // them: it emitted a four-wide NEON comparison of the source indices plus three scalar
            // ones, and a fifteen-instruction OR-tree coalescing the eight output indices, for 73
            // instructions per eight bytes against the 8-bit kernel's 16. Presenting the same work
            // as one `load` and two `storeBytes` puts three bounds checks in front of it instead of
            // sixteen.
            //
            // ENDIANNESS, WRITTEN OUT, because no differential that runs here can catch getting it
            // wrong -- and the 8-bit kernel's version of this comment is what let a byte-order bug
            // through review once already.
            //
            //   * THE MASK TEST IS BYTE-ORDER-INDEPENDENT and stays exactly as it was.
            //     `highBitsOfEachByte` holds the same value in all eight byte lanes, so
            //     `word & highBitsOfEachByte != 0` cannot depend on which end of `word` input byte 0
            //     landed in. Only the widening below needs an argument.
            //   * `UInt64(littleEndian: word)` NORMALISES ONCE. `load` uses host byte order, so on a
            //     little-endian host input byte `i` is already at bit `8*i` of `word` and this is the
            //     identity; on a big-endian host it is at bit `8*(7-i)` and this is a byte swap. After
            //     it, input byte `i` is at bit `8*i` of `w` on EITHER host, so `w` -- not `word` -- is
            //     what the arithmetic may look at.
            //   * THE SPLIT IS BY INPUT POSITION, not by "low half then high half of memory". Input
            //     bytes 0-3 are the low 32 bits of `w` and become `lo`; bytes 4-7 are the high 32 and
            //     become `hi`. `lo` is stored first because output element 0 comes first, and that is
            //     a statement about `w`, which is host-independent, not about `word`, which is not.
            //   * `.littleEndian` ON THE WAY OUT UNDOES THE NORMALISATION. `storeBytes` also uses
            //     host byte order, so storing `lo.littleEndian` writes lane `j` of `lo` to output
            //     element `j` on either host: the identity little-endian, and a swap on big-endian
            //     that exactly cancels `storeBytes`'s own reordering. Choosing the value whose
            //     little-endian representation is wanted is what makes the resulting memory
            //     host-independent.
            //
            // The raw view is scoped to this loop, as in the 8-bit kernel, so its exclusive borrow of
            // `output` ends before the tail below writes through `output` itself.
            do {
                var outputBytes = output.mutableBytes
                while index + 8 <= end && produced + 8 <= capacity {
                    let word = sourceBytes.load(fromByteOffset: index, as: UInt64.self)
                    if word & highBitsOfEachByte != 0 { break }
                    let w = UInt64(littleEndian: word)
                    let lo = spreadFourBytesToUTF16Lanes(w)
                    let hi = spreadFourBytesToUTF16Lanes(w &>> 32)
                    // BYTE offsets, and `produced` counts 16-bit elements. `produced + 8 <=
                    // capacity` above, and `capacity` is a `MutableSpan<UInt16>`'s count, so
                    // `produced * 2 + 16` is within the raw view and cannot overflow.
                    let byteOffset = produced &* 2
                    outputBytes.storeBytes(of: lo.littleEndian, toByteOffset: byteOffset, as: UInt64.self)
                    outputBytes.storeBytes(of: hi.littleEndian, toByteOffset: byteOffset &+ 8, as: UInt64.self)
                    produced += 8
                    index += 8
                }
            }
            if index >= end || produced + 2 > capacity { break }

            // The cursor may have moved, and the sequence tail below needs the byte under it NOW.
            // Both routes into that tail therefore leave `firstByte == source[index]` with its
            // high bit set.
            firstByte = source[index]
            if firstByte < 0x80 {
                output[produced] = UInt16(truncatingIfNeeded: firstByte)
                produced += 1
                index += 1
                continue
            }
        }

        // Length before truncation, and truncation before any byte is examined, for the reason
        // at the top of this file: a zero-length lead is one the C++ can never park.
        let length = sequenceLength(firstByte)
        if length == 0 { return .declined }

        if index + length > end {
            let available = end - index
            if available >= 2 && !isValidSecondByte(firstByte, source[index + 1]) { return .declined }
            if available >= 3 && !isContinuationByte(source[index + 2]) { return .declined }
            return .truncated(consumed: index, produced: produced, partial: available)
        }

        let secondByte = source[index + 1]
        if !isValidSecondByte(firstByte, secondByte) { return .declined }
        if length == 2 {
            // The C++'s `((sequence[0] << 6) + sequence[1]) - 0x00003080`. 0xC2 0x80 is the
            // smallest, U+0080, and 0xDF 0xBF the largest, U+07FF.
            output[produced] = UInt16(truncatingIfNeeded: (UInt32(firstByte) << 6) &+ UInt32(secondByte) &- 0x3080)
            produced += 1
            index += 2
            continue
        }

        let thirdByte = source[index + 2]
        if !isContinuationByte(thirdByte) { return .declined }
        if length == 3 {
            // `((sequence[0] << 12) + (sequence[1] << 6) + sequence[2]) - 0x000E2080`. The walls
            // above bound this at U+0800 (0xE0 0xA0 0x80) and U+FFFF (0xEF 0xBF 0xBF), and cut
            // out D800-DFFF, so it is always exactly one code unit and never a lone surrogate.
            // U+FEFF is emitted verbatim: a byte order mark only ever gets stripped when
            // `m_shouldStripByteOrderMark` is set, and this arm is not entered when it is.
            output[produced] = UInt16(truncatingIfNeeded:
                (UInt32(firstByte) << 12) &+ (UInt32(secondByte) << 6) &+ UInt32(thirdByte) &- 0xE2080)
            produced += 1
            index += 3
            continue
        }

        let fourthByte = source[index + 3]
        if !isContinuationByte(fourthByte) { return .declined }
        // `((sequence[0] << 18) + (sequence[1] << 12) + (sequence[2] << 6) + sequence[3]) -
        // 0x03C82080`, which the walls bound at U+10000 (0xF0 0x90 0x80 0x80) and U+10FFFF
        // (0xF4 0x8F 0xBF 0xBF).
        let character = (UInt32(firstByte) << 18) &+ (UInt32(secondByte) << 12)
            &+ (UInt32(thirdByte) << 6) &+ UInt32(fourthByte) &- 0x3C82080
        // U16_LEAD and U16_TRAIL, as arithmetic rather than through `Unicode.Scalar`: that
        // initializer is failing, so it would add an Optional and a trap edge to a value whose
        // range the two lines above have already established.
        output[produced] = UInt16(truncatingIfNeeded: (character &>> 10) &+ 0xD7C0)
        output[produced + 1] = UInt16(truncatingIfNeeded: (character & 0x3FF) &+ 0xDC00)
        produced += 2
        index += 4
    }

    return .complete(consumed: index, produced: produced)
}

/// How many characters an attempt buffers before handing them to the sink.
///
/// This buffer is the price of the boundary: Swift cannot be handed the destination (see
/// `TextCodecUTF8SwiftSink`), so the output is written twice -- once here, once by
/// `takeChunk`'s copy. Chunking keeps the second write a hot-cache memcpy rather than a
/// second pass over cold memory.
///
/// 1024 balances two costs that pull opposite ways, and both should be measured rather than
/// argued: `InlineArray` has no uninitialized form, so the zero-fill is paid once per decode
/// whatever the input length -- which favours a small buffer for the many short decodes a
/// streaming load makes -- while each flush is a boundary crossing plus a `memcpy` call,
/// which favours a large one.
private typealias DecodeScratch = InlineArray<1024, UInt8>

/// The same, for 16-bit output, and it is a SECOND scratch rather than one shared buffer narrowed
/// on the way out. That is measured, not assumed: one shared `InlineArray<1024, UInt16>` with a
/// narrowing pass costs the Latin-1 path 1.70x at 8 input bytes and 1.021x at 1024, because that
/// path then pays a 2048-byte zero-fill and an extra pass it has no use for.
///
/// 512 elements rather than 1024 keeps that zero-fill at 1024 bytes, identical to the narrow
/// scratch above, where 1024 elements would be 2048. Treat the choice as a measurable and not a
/// settled win: the flush count doubles in exchange, and which way that lands depends on the
/// input lengths a real load presents.
private typealias WideDecodeScratch = InlineArray<512, UInt16>

/// Decodes `input` as UTF-8, provided every sequence in it is well formed.
///
/// `partialSequence` and `partialSequenceSize` are the sequence a previous call parked, packed as
/// `packSequenceBytes` packs one. They are a COPY: this function reads them, works on locals and
/// reports a new park in its result, and the caller applies that only when `answered` is true. It
/// reads no other codec state and writes none, so a decline is free of consequences -- the caller
/// discards whatever the sink was handed simply by not advancing its destination, or by not taking
/// the 16-bit buffer, and its own park is untouched.
///
/// The caller guarantees there is no byte order mark to strip and that `input` is not empty.
///
/// Answers `answered == false`, meaning the caller must decode the whole input itself, for an
/// ill-formed sequence, for a truncated sequence at a `flush`, for a truncated sequence whose
/// bytes are not a valid prefix even when `flush` is false, and for an incoming park that is not
/// a valid prefix either.
///
/// TODO(unsafe): the one `unsafe` marker in this island. `input` arrives as an imported
/// `std::span`, and turning that into a `Span` needs `Span(_unsafeCxxSpan:)` because Swift has
/// no safe way to receive a bounds-carrying view from C++ (rdar://186723514). The borrow is
/// well formed -- `TextCodecUTF8::decode` owns the bytes for the whole call and nothing here
/// outlives it -- but the initializer is `@unsafe`, so the marker stands until the radar
/// lands. `CSSTokenizerSwift.swift` carries the same two sites for the same reason.
@_expose(Cxx)
public func textCodecUTF8DecodeSwift(
    _ input: PAL.TextCodecUTF8SwiftInput,
    _ partialSequence: UInt32,
    _ partialSequenceSize: UInt8,
    _ flush: Bool,
    _ sink: PAL.TextCodecUTF8SwiftSink
) -> PAL.TextCodecUTF8SwiftResult {
    let source = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    let sourceBytes = source.bytes
    let declined = PAL.TextCodecUTF8SwiftResult()

    // A sequence parked on entry is the next slice; declined here so that the boundary's new
    // shape lands on its own.
    if partialSequenceSize != 0 { return declined }

    var scratch = DecodeScratch(repeating: 0)
    // `consumed` is the cursor into `source` AND the byte count the caller advances by, so bytes
    // that go into a new park count toward it -- the park may hold bytes that were never in
    // `source` at all, so it cannot be taken off the end of the input the way it once was.
    var consumed = 0
    var produced = 0
    var packedPartial: UInt32 = 0
    var partial = 0
    var wide = false

    while consumed < source.count {
        var output = scratch.mutableSpan
        let outcome = decodeChunk(source, sourceBytes, from: consumed, into: &output)

        switch outcome {
        case .declined:
            return declined

        case .needsWide(let chunkConsumed, let chunkProduced):
            // The narrow scratch is flushed BEFORE the first wide chunk, and the sink asserts
            // that ordering: it widens the characters already in the 8-bit buffer when the
            // first wide chunk arrives, so anything still sitting here would be lost.
            if chunkProduced > 0 { sink.takeChunk(output.span.extracting(0..<chunkProduced)) }
            consumed = chunkConsumed
            produced += chunkProduced
            wide = true

        case .truncated(let chunkConsumed, let chunkProduced, let partialSize):
            // A truncated sequence at a flush is not this arm's to answer: the C++ turns it
            // into a replacement character, which is ill-formed handling.
            if flush { return declined }
            if chunkProduced > 0 { sink.takeChunk(output.span.extracting(0..<chunkProduced)) }
            packedPartial = packSequenceBytes(source, from: chunkConsumed, count: partialSize)
            partial = partialSize
            consumed = chunkConsumed + partialSize
            produced += chunkProduced

        case .complete(let chunkConsumed, let chunkProduced):
            if chunkProduced > 0 { sink.takeChunk(output.span.extracting(0..<chunkProduced)) }
            consumed = chunkConsumed
            produced += chunkProduced
            continue
        }
        break
    }

    if wide {
        // Constructed HERE, inside the branch, so the Latin-1 majority never pays for its
        // zero-fill. The flip is one-way, so the loop above cannot resume.
        var wideScratch = WideDecodeScratch(repeating: 0)

        while consumed < source.count {
            var output = wideScratch.mutableSpan
            let outcome = decodeWideChunk(source, sourceBytes, from: consumed, into: &output)

            switch outcome {
            // `.needsWide` cannot come back from the wide kernel; it is already wide.
            case .declined, .needsWide:
                return declined

            case .truncated(let chunkConsumed, let chunkProduced, let partialSize):
                if flush { return declined }
                if chunkProduced > 0 { sink.takeWideChunk(output.span.extracting(0..<chunkProduced)) }
                packedPartial = packSequenceBytes(source, from: chunkConsumed, count: partialSize)
                partial = partialSize
                consumed = chunkConsumed + partialSize
                produced += chunkProduced

            case .complete(let chunkConsumed, let chunkProduced):
                if chunkProduced > 0 { sink.takeWideChunk(output.span.extracting(0..<chunkProduced)) }
                consumed = chunkConsumed
                produced += chunkProduced
                continue
            }
            break
        }
    }

    var result = PAL.TextCodecUTF8SwiftResult()
    // `consumed` is bounded by the input length and `produced` by `consumed`, and the caller has
    // already established that the input length fits in a `uint32_t`: it sized the destination as
    // the input length plus the parked partial sequence and bailed out above UINT_MAX. One
    // character never costs less than one byte, at either width -- the only sequence that yields
    // two code units is four bytes long. `partial` is at most 3.
    result.consumedBytes = UInt32(consumed)
    result.producedCharacters = UInt32(produced)
    result.partialSequence = packedPartial
    result.partialSequenceSize = UInt8(partial)
    result.answered = true
    return result
}
