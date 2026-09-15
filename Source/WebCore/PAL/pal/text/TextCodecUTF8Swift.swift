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
// sequence, or a byte order mark. This file covers both widths and both kinds of input: ASCII and
// the 0xC2/0xC3 two-byte sequences fill the 8-bit buffer, and the first character above U+00FF --
// or the first U+FFFD an ill-formed sequence produces -- flips the output to a 16-bit buffer that
// the sink allocates and owns from then on. `TextCodecUTF8SwiftSink` records why the width is this
// arm's to choose rather than the caller's to decide up front.
//
// WHAT STILL DECLINES, and a decline is a WHOLE-INPUT decline: only the two cases the caller's
// precondition excludes, a pending byte order mark and empty input. Nothing in the decoding itself
// does any more. Two `.declined` returns remain, both in the 8-bit park drain, and each names a
// park the C++ cannot construct -- they exist so that this arm cannot be the only one that can.
// `textCodecUTF8SwiftCounters()` is what makes that boundary visible, because a declining arm and
// an agreeing arm are byte-identical by construction.
//
// THE MAXIMAL-SUBPART RULE IS `decodeNonASCIISequence`'s `uint8_t& length` OUT-PARAMETER, and it
// is where one ill-formed-UTF-8 decoder is likeliest to differ from another. On a bad continuation
// byte that function OVERWRITES `length` with the number of bytes that WERE valid and returns
// `nonCharacter`; the consumer emits one U+FFFD and skips exactly that many, so THE REJECTED BYTE
// IS NOT CONSUMED and is reprocessed as a fresh lead byte. A byte that leads no sequence at all
// (0x80-0xC1, 0xF5-0xFF) has no valid bytes to count and skips one, which is what
// `skip(source, count ? count : 1)` spells. So 0xF0 0x9F 0x98 0x41 is U+FFFD U+0041 rather than
// U+FFFD alone, 0xF0 0x41 0x80 0x80 is four characters, and 0xF8 0x88 0x80 0x80 0x80 is five.
// Ten assignments to `length` carry the rule, seven of them writing 1.
//
// WIDTH AND `stopOnError` INTERACT, and the C++ settles it in three different places:
//   * U+FFFD is not Latin-1, so an ill-formed sequence normally forces 16-bit output.
//   * BUT THE 8-BIT LOOP'S `stopOnError` EXIT DOES NOT UPCONVERT. It sets `sawError`, `break`s
//     and falls out to the 8-bit tail -- so an ill-formed byte in otherwise-Latin-1 input yields
//     an 8-BIT string when `stopOnError` is true and a 16-bit one when it is false. Get this
//     backwards and `is8Bit()` flips.
//   * BUT AN ERROR INSIDE A PARKED SEQUENCE UPCONVERTS EVEN UNDER `stopOnError`, because the
//     8-bit `handlePartialSequence` overload HAS no `stopOnError` parameter: it returns true for
//     any non-Latin-1 result including `nonCharacter`, `upConvertTo16Bit` copies what the 8-bit
//     buffer holds into a 16-bit one, and only then does the 16-bit overload apply `stopOnError`
//     and return. So "abc" followed by a truncated 0xE0 0x80 is a 16-BIT three-character string
//     with the park left in place.
// The split between `drainParkedSequenceNarrow`, `drainParkedSequenceWide` and the two kernels
// below follows exactly those lines, and `decodeChunk` therefore has to settle an ill-formed
// sequence with a wide lead byte itself rather than handing it to the 16-bit kernel to diagnose.
//
// WHAT `stopOnError` DISCARDS IS THE REST OF THE INPUT, silently: the `break` leaves the loop and
// the string holds everything decoded up to the error. `TextCodecUTF8SwiftResult::stoppedOnError`
// is how that reaches a caller whose destination is otherwise entitled to assume the whole input
// was consumed. `sawError` needs no such care -- it is a sticky flag the caller only ever ORs
// into, never resets.
//
// NEITHER KERNEL SETTLES AN ILL-FORMED SEQUENCE, and that is a codegen requirement rather than a
// preference: both report it and their callers decide. The note on `ChunkOutcome` has the numbers.
//
// A SEQUENCE PARKED BY A PREVIOUS CALL IS COMPLETED HERE, and that is a coverage decision rather
// than a completeness one. A power-of-two chunk boundary lands mid-sequence for almost any
// multi-byte content, so this arm parks a tail, the caller stores it, and the NEXT call used to
// fail the entry precondition and run as pure C++ -- which drained the park, letting the call
// after that in again. Period three on pure three-byte content: the arm's own correct behaviour
// re-armed the precondition that locked it out, and only about a third of `decode` calls on such
// content reached it at all. The two park drains are what close that cycle.
//
// A TRUNCATED TAIL IS PARKED ON SEQUENCE LENGTH ALONE, with the bytes present unexamined, and
// then diagnosed in the SAME call. That is the C++'s shape and not a simplification of it. Its
// main loops park on `count > source.size()` with no validation whatever;
// `handlePartialSequence` zero-fills the bytes it does not have so `decodeNonASCIISequence` can
// classify the ones it does, and its park-and-wait fires only when the recomputed subpart length
// still EQUALS the parked size. An already-invalid prefix makes it smaller, so {0xE0, 0x80} at
// the end of a chunk emits two U+FFFD from that chunk with `flush` false: it does not wait for
// input that could not change the answer. The packed park needs no zero-fill of its own, which
// is the same statement about a packed representation.
//
// AND ONLY A BYTE THAT IS A VALID LEAD IS EVER PARKED. A lead byte whose sequence length is zero
// (0x80-0xC1 and 0xF5-0xFF) reaches `nonCharacter` in the C++ before it reaches the park, so the
// C++ can NEVER park one from its main loops. A park keyed on "the input ended and the last byte
// is non-ASCII" would therefore create a state only one arm can enter, which no differential can
// catch, because only one arm can produce the transcript to compare. The length test comes before
// the truncation test in both kernels below for that reason and no other.
//
// WHAT MAY ARRIVE AS A PARK IS WIDER THAN WHAT THE PARK-AND-WAIT LEAVES, though, and all of it is
// decoded rather than declined. `stopOnError` returns from the 16-bit `handlePartialSequence`
// BEFORE it drops the subpart it just diagnosed, so the park it leaves can be as long as the
// sequence it leads -- {0xF0, 0x80, 0x80, 0x80}, always invalid in that state -- and after one
// such drop it can start with a byte that leads nothing. It can never start with an ASCII byte:
// that branch of `handlePartialSequence` emits and loops, so it is never the state a return
// leaves behind.
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

/// U+FFFD, which is what every ill-formed sequence decodes to: `WTF::Unicode::replacementCharacter`
/// on the C++ side. A `UInt16` because it is only ever stored into 16-bit output -- it is not
/// Latin-1, which is the whole reason an ill-formed sequence widens a decode.
private let replacementCharacter: UInt16 = 0xFFFD

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

/// Byte `index` of a sequence packed the way `packSequenceBytes` packs one. The inverse of that
/// function, and the same statement about byte order applies.
@inline(always)
private func sequenceByte(_ packed: UInt32, _ index: Int) -> UInt8 {
    UInt8(truncatingIfNeeded: packed &>> (8 &* index))
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

/// `decodeNonASCIISequence` over a sequence packed the way `packSequenceBytes` packs one: the
/// scalar value, or `nil` for its `nonCharacter` return.
///
/// `subpart` IS THAT FUNCTION'S `uint8_t& length` OUT-PARAMETER, and it carries the maximal-subpart
/// rule: on `nil` it is the number of leading bytes that were valid, which is the index of the
/// first byte that was not, and it is what the caller skips. On success it is `length` unchanged.
///
/// The caller zero-fills nothing. Bytes above the parked size are already zero in this
/// representation, which is the same guarantee `handlePartialSequence`'s `zeroSpan` establishes by
/// hand -- and zero is not a continuation byte, so an incomplete sequence always answers `nil`
/// here exactly as the C++ asserts it does.
@inline(always)
private func decodePackedSequence(_ packed: UInt32, _ length: Int) -> (character: UInt32?, subpart: Int) {
    let b0 = sequenceByte(packed, 0)
    let b1 = sequenceByte(packed, 1)
    if !isValidSecondByte(b0, b1) { return (nil, 1) }
    if length == 2 { return ((UInt32(b0) << 6) &+ UInt32(b1) &- 0x3080, 2) }
    let b2 = sequenceByte(packed, 2)
    if !isContinuationByte(b2) { return (nil, 2) }
    if length == 3 {
        return ((UInt32(b0) << 12) &+ (UInt32(b1) << 6) &+ UInt32(b2) &- 0xE2080, 3)
    }
    let b3 = sequenceByte(packed, 3)
    if !isContinuationByte(b3) { return (nil, 3) }
    return ((UInt32(b0) << 18) &+ (UInt32(b1) << 12) &+ (UInt32(b2) << 6) &+ UInt32(b3) &- 0x3C82080, 4)
}

/// The outcome of the 8-bit `handlePartialSequence`.
private enum NarrowParkOutcome {
    /// It returned false with the park drained: one Latin-1 character, and the 8-bit main loop
    /// takes over from `consumed`.
    case latin1(character: UInt8, consumed: Int)
    /// It returned false with the park still there -- its one park-and-wait exit, which needs the
    /// bytes present to be a valid prefix, `flush` to be false, and the input to be exhausted. The
    /// decode is over and the string is 8-bit.
    case waiting(park: UInt32, size: Int, consumed: Int)
    /// It returned TRUE, so the 16-bit machinery takes over from exactly this state. Nothing is
    /// emitted, which is not a simplification: the caller passes that overload a COPY of its
    /// destination and only writes it back when the answer is false, so any character the C++
    /// wrote before returning true is discarded -- and by the argument on `.declined` below it
    /// never wrote one.
    case needsWide(park: UInt32, size: Int, consumed: Int)
    /// Outside this arm's subset; the caller declines the whole input.
    case declined
}

/// The 8-bit `handlePartialSequence`, which is ONE ITERATION of its `do`/`while` and not a loop.
///
/// That is a claim about reachable state, and it rests on an invariant of the park the C++ hands
/// over: its first byte is never ASCII, and when that byte leads a sequence at all the parked size
/// is at most that sequence's length. Every writer of the park upholds it -- a main loop parks
/// strictly fewer bytes than the sequence needs, the copy stage below tops the park up to exactly
/// that length, and the 16-bit overload's two park-leaving returns leave a lead byte in place. So
/// of this overload's four exits, three leave the function and the fourth -- a decoded Latin-1
/// character -- subtracts the whole sequence length from a size that is at most that length, which
/// ends the loop.
///
/// TWO STATES ARE DECLINED RATHER THAN DECODED, and both are outside that invariant:
///   * An ASCII first byte, which this overload would emit and loop on. The C++ can produce no
///     such park: a main loop reaches `nonCharacter` before the park for a byte that leads nothing,
///     and every other park byte 0 is a lead byte.
///   * A park LONGER than the sequence its first byte leads, on the success path. The C++ has a
///     latent bug there -- unlike the 16-bit overload it decrements `m_partialSequenceSize` by the
///     sequence length WITHOUT the matching `memmove`, so it would loop on a stale first byte --
///     and the invariant above is exactly what makes that unreachable. Declining is what keeps
///     this arm from being the only one that can enter it.
private func drainParkedSequenceNarrow(
    _ source: Span<UInt8>,
    from start: Int,
    park: UInt32,
    size parkSize: Int,
    flush: Bool
) -> NarrowParkOutcome {
    let firstByte = sequenceByte(park, 0)
    if firstByte < 0x80 { return .declined }
    let length = sequenceLength(firstByte)
    // `if (!count) return true;`, and note what is NOT here: this overload takes no `sawError`, so
    // a byte that leads nothing is not recorded as an error until the 16-bit overload meets it
    // again.
    if length == 0 { return .needsWide(park: park, size: parkSize, consumed: start) }

    // The copy stage: take bytes off the front of the input until the sequence is whole, or until
    // the input runs out. Nothing is validated on the way in, exactly as `memcpySpan` validates
    // nothing.
    var packed = park
    var size = parkSize
    var index = start
    if length > size && index < source.count {
        let additional = min(length - size, source.count - index)
        for _ in 0..<additional {
            packed |= UInt32(source[index]) &<< (8 &* size)
            size += 1
            index += 1
        }
    }

    let tooShort = length > size
    let (character, subpart) = decodePackedSequence(packed, length)
    // The park-and-wait: an incomplete sequence whose bytes are all valid so far is not an error
    // while more input may still arrive.
    if tooShort && !flush && subpart == size {
        return .waiting(park: packed, size: size, consumed: index)
    }
    // `if (!isLatin1(character)) return true;` -- and `isLatin1(nonCharacter)` is false, because
    // `nonCharacter` is -1 and `isLatin1` casts to unsigned before comparing. THAT is why an
    // ill-formed park upconverts even under `stopOnError`: this overload cannot see the flag.
    guard let character, character <= 0xFF else {
        return .needsWide(park: packed, size: size, consumed: index)
    }
    if size != length { return .declined }
    return .latin1(character: UInt8(truncatingIfNeeded: character), consumed: index)
}

/// The outcome of the 16-bit `handlePartialSequence`.
private enum WideParkOutcome {
    /// The park is empty and the 16-bit main loop takes over from `consumed`.
    case drained(consumed: Int)
    /// The output buffer filled. The park is unfinished but well defined, so the caller flushes
    /// and calls again -- see the note on this function about how much output a drain can make.
    case bufferFull(park: UInt32, size: Int, consumed: Int)
    /// Its park-and-wait exit: valid prefix, `flush` false, input exhausted.
    case waiting(park: UInt32, size: Int, consumed: Int)
    /// `stopOnError` ended it at an ill-formed sequence, leaving the park exactly as it stood and
    /// whatever is left of the input to be dropped.
    case stopped(park: UInt32, size: Int, consumed: Int)
}

/// The 16-bit `handlePartialSequence`, which unlike the 8-bit one IS a loop, and unlike the 8-bit
/// one applies `stopOnError`.
///
/// HOW MUCH OUTPUT ONE DRAIN CAN MAKE IS BOUNDED BY THE INPUT, NOT BY THE PARK, which is why this
/// is chunked and resumable rather than writing into a fixed handful of code units. Its copy stage
/// runs on EVERY iteration, so a park whose maximal subpart is one byte can pull a byte from the
/// input, emit one U+FFFD, shift, and come back needing another: {0xF0} against an input of 0xF0
/// bytes emits one replacement character per input byte without the main loop ever running.
/// `.bufferFull` is that case, and the caller's loop over it is the same loop the main kernel gets.
private func drainParkedSequenceWide(
    _ source: Span<UInt8>,
    from start: Int,
    park: UInt32,
    size parkSize: Int,
    flush: Bool,
    stopOnError: Bool,
    into output: inout MutableSpan<UInt16>,
    units: inout Int,
    sawError: inout Bool
) -> WideParkOutcome {
    var packed = park
    var size = parkSize
    var index = start
    repeat {
        // Room for a surrogate pair, as in the wide kernel and for the same reason.
        if units + 2 > output.count { return .bufferFull(park: packed, size: size, consumed: index) }

        let firstByte = sequenceByte(packed, 0)
        if firstByte < 0x80 {
            // `consume(destination) = m_partialSequence[0]; consumePartialSequenceByte();` -- and
            // the shift IS the `memmove`, since byte `i` lives at bit `8 * i`.
            output[units] = UInt16(truncatingIfNeeded: firstByte)
            units += 1
            packed = packed &>> 8
            size -= 1
            continue
        }

        let length = sequenceLength(firstByte)
        if length == 0 {
            sawError = true
            if stopOnError { return .stopped(park: packed, size: size, consumed: index) }
            output[units] = replacementCharacter
            units += 1
            packed = packed &>> 8
            size -= 1
            continue
        }

        if length > size && index < source.count {
            let additional = min(length - size, source.count - index)
            for _ in 0..<additional {
                packed |= UInt32(source[index]) &<< (8 &* size)
                size += 1
                index += 1
            }
        }

        let tooShort = length > size
        let (character, subpart) = decodePackedSequence(packed, length)
        if tooShort && !flush && subpart == size {
            return .waiting(park: packed, size: size, consumed: index)
        }

        guard let character else {
            sawError = true
            if stopOnError { return .stopped(park: packed, size: size, consumed: index) }
            // One U+FFFD for the maximal subpart, and only the subpart leaves the park: the bytes
            // after it are reprocessed from the top of this loop as fresh lead bytes.
            output[units] = replacementCharacter
            units += 1
            packed = packed &>> (8 &* subpart)
            size -= subpart
            continue
        }

        packed = packed &>> (8 &* length)
        size -= length
        // `appendCharacter`. The byte order mark is emitted verbatim: stripping it needs
        // `m_shouldStripByteOrderMark`, and this arm is not entered when that is set.
        if character > 0xFFFF {
            output[units] = UInt16(truncatingIfNeeded: (character &>> 10) &+ 0xD7C0)
            output[units + 1] = UInt16(truncatingIfNeeded: (character & 0x3FF) &+ 0xDC00)
            units += 2
        } else {
            output[units] = UInt16(truncatingIfNeeded: character)
            units += 1
        }
    } while size != 0

    return .drained(consumed: index)
}

/// The outcome of decoding into one scratch buffer's worth of output.
///
/// NEITHER KERNEL CAN DECLINE, which is the shape of this slice rather than a detail of it: every
/// exit below is a decode that continues somewhere. Neither kernel settles an ill-formed sequence
/// either -- both report it and their callers decide -- and that is a CODEGEN requirement, not a
/// preference. `stopOnError` and `sawError` inside the 16-bit kernel are per-CALL state in a
/// per-CHARACTER loop, and the two live registers they cost evicted the `- 0x000E2080` constant
/// from the three-byte path and spilled the second half of the surrogate pair's base pointer in the
/// four-byte path: measured at -5% on `twobyte-wide-only` and -16% on `fourbyte-only`, taking that
/// band below parity. Reporting the error instead costs one loop re-entry per ill-formed sequence
/// and nothing per well-formed character.
private enum ChunkOutcome {
    /// The scratch buffer filled, or the input ran out.
    case complete(consumed: Int, produced: Int)
    /// The input ended mid-sequence. `consumed` excludes the truncated sequence, whose bytes are
    /// UNEXAMINED: both C++ main loops park on `count > source.size()` alone, and the park is then
    /// diagnosed by `handlePartialSequence` in this same call.
    case truncated(consumed: Int, produced: Int, partial: Int)
    /// The 8-bit kernel met a WELL-FORMED character above U+00FF. Nothing is consumed for it: the
    /// 16-bit kernel re-reads the sequence from `consumed`. Never from the 16-bit kernel.
    case needsWide(consumed: Int, produced: Int)
    /// An ill-formed sequence, with nothing consumed for it. `subpart` is
    /// `decodeNonASCIISequence`'s rewritten `length` -- the maximal subpart to skip -- or 0 for a
    /// lead byte that leads nothing, which is `skip(source, count ? count : 1)`'s two cases.
    ///
    /// From the 8-bit kernel `subpart` is always 0 and means nothing: that caller consumes nothing
    /// either way, because `stopOnError` decides the WIDTH of the whole string there and both of
    /// its answers either re-read the sequence or drop it.
    case illFormed(consumed: Int, produced: Int, subpart: Int)
}

/// Whether the sequence at `index`, whose lead byte is above 0xC3 and which is known to be wholly
/// present, is well formed -- and so whether the 8-bit kernel is looking at a character that widens
/// the output or at an ill-formed sequence.
///
/// `@inline(never)`, and that is the whole point of the function existing. Inlined, its
/// `length >= 3` and `length == 4` tests get hoisted into the 8-bit kernel's per-character path as
/// a precomputed flag register, which cost `latin1-only` 12.5%: one extra `mov` per character plus
/// the tail duplication that flag forced on the overflow check. It runs at most once per chunk,
/// since both of its answers end the chunk.
@inline(never)
private func classifyWideLead(
    _ source: Span<UInt8>,
    at index: Int,
    produced: Int
) -> ChunkOutcome {
    let firstByte = source[index]
    let length = sequenceLength(firstByte)
    if !isValidSecondByte(firstByte, source[index + 1]) { return .illFormed(consumed: index, produced: produced, subpart: 0) }
    if length >= 3 && !isContinuationByte(source[index + 2]) { return .illFormed(consumed: index, produced: produced, subpart: 0) }
    if length == 4 && !isContinuationByte(source[index + 3]) { return .illFormed(consumed: index, produced: produced, subpart: 0) }
    return .needsWide(consumed: index, produced: produced)
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
    into output: inout MutableSpan<UInt8>,
    startingAt startProduced: Int = 0
) -> ChunkOutcome {
    var index = start
    var produced = startProduced
    let end = source.count
    // Every character this arm produces is exactly one byte and costs at least one input
    // byte, so output capacity bounds input consumption directly and the loop needs no
    // per-character space check. `startProduced` accounts for characters already committed
    // earlier in the same destination buffer.
    let limit = min(end, index + output.count - startProduced)

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
        if length == 0 { return .illFormed(consumed: index, produced: produced, subpart: 0) }

        if index + length > end {
            // Truncated at the very end of the input; nothing is consumed for it. The C++ parks
            // a truncated tail of ANY width and of any VALIDITY -- its 8-bit loop reaches the park
            // before it reaches either `decodeNonASCIISequence` or `isLatin1` -- so a chunk ending
            // in a prefix of a wide sequence still finishes as an 8-bit string, and a chunk ending
            // in an already-invalid prefix is parked and then diagnosed by the park drain rather
            // than here.
            return .truncated(consumed: index, produced: produced, partial: end - index)
        }

        // A WIDE LEAD BYTE IS VALIDATED, and it has to be, because `stopOnError` makes ill-formed
        // and well-formed-but-wide two different WIDTHS at this point: the C++'s 8-bit loop breaks
        // out to its 8-bit tail on the first and upconverts on the second. Handing an unvalidated
        // wide lead to the 16-bit kernel to diagnose would make every such input 16-bit, and
        // `is8Bit()` would flip on `stopOnError` input that is Latin-1 up to the error. Out of line
        // so that the validation's own tests stay out of this loop.
        if firstByte > 0xC3 { return classifyWideLead(source, at: index, produced: produced) }

        let secondByte = source[index + 1]
        if secondByte < 0x80 || secondByte > 0xBF { return .illFormed(consumed: index, produced: produced, subpart: 0) }

        // The C++'s `((sequence[0] << 6) + sequence[1]) - 0x00003080`, which for these two
        // lead bytes always lands in 0x80...0xFF.
        output[produced] = UInt8(truncatingIfNeeded: (UInt32(firstByte) << 6) &+ UInt32(secondByte) &- 0x3080)
        produced += 1
        index += 2
    }

    return .complete(consumed: index, produced: produced)
}

/// Decodes from `source[start...]` into 16-bit `output` from element `startingAt` on, until
/// `output` is full, `source` runs out, or an ill-formed sequence turns up: every well-formed
/// sequence, that is -- this is where the 0xC4-and-up two-byte forms, all three-byte forms and all
/// four-byte forms are decoded, the last as surrogate pairs.
///
/// `startingAt` is how the caller resumes this after settling an ill-formed sequence, keeping one
/// flush per scratch buffer however many replacement characters a chunk needs. It makes `produced`
/// an arbitrary value at the top of the word loop below, and that is FINE: the loop's store pointer
/// is formed from `produced` once on entry and post-incremented, and `str q0` on arm64 has no
/// alignment requirement, so the merge of the two eight-byte stores into one sixteen-byte store does
/// not depend on `produced`'s residue. Checked in the disassembly rather than assumed.
///
/// Never answers `.needsWide` -- it is already the wide kernel.
private func decodeWideChunk(
    _ source: Span<UInt8>,
    _ sourceBytes: RawSpan,
    from start: Int,
    into output: inout MutableSpan<UInt16>,
    startingAt startProduced: Int
) -> ChunkOutcome {
    var index = start
    var produced = startProduced
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
        // kernel -- costs this one 17-20% on the long-ASCII-run bands: it puts the code unit's
        // store, and the capacity check it needs, ahead of the loop on every entry, and 31
        // instructions per eight bytes become 37 plus an overflow check. It buys 8-13% back at
        // periods four to sixteen and that is the smaller half.
        //
        // WHAT IS *NOT* THE MECHANISM IS `produced`'s RESIDUE, and that was believed here for a
        // while. `produced` is an arbitrary value at the top of this loop -- `startingAt` makes it
        // one whenever a chunk holds a replacement character -- and the two `storeBytes` still
        // merge into one `str q0` and the capacity check is still constant-folded. The loop forms
        // its store pointer from `produced` ONCE on entry and post-increments it, and arm64's
        // 16-byte store has no alignment requirement, so there is nothing for the residue to
        // decide. Checked in the disassembly at both shapes.
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
        //
        // AN ILL-FORMED SEQUENCE IS REPORTED, NOT SETTLED, and the `subpart` each exit carries is
        // `decodeNonASCIISequence`'s rewritten `length`: 1 for a bad second byte, 2 for a bad
        // third, 3 for a bad fourth, and 0 for a lead byte that leads nothing. THE REJECTED BYTE
        // IS NOT PART OF IT and comes round again as a fresh lead byte.
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
            // The C++'s `((sequence[0] << 6) + sequence[1]) - 0x00003080`. 0xC2 0x80 is the
            // smallest, U+0080, and 0xDF 0xBF the largest, U+07FF.
            output[produced] = UInt16(truncatingIfNeeded: (UInt32(firstByte) << 6) &+ UInt32(secondByte) &- 0x3080)
            produced += 1
            index += 2
            continue
        }

        let thirdByte = source[index + 2]
        if !isContinuationByte(thirdByte) {
            return .illFormed(consumed: index, produced: produced, subpart: 2)
        }
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
        if !isContinuationByte(fourthByte) {
            return .illFormed(consumed: index, produced: produced, subpart: 3)
        }
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

// The scratch buffers and the `TextCodecUTF8SwiftSink` class they fed are gone. Both entry
// points below write directly into the C++ `StringBuffer` the caller allocated, accepting
// `unsafe MutableSpan(_unsafeCxxSpan:)` the same way the input is accepted with
// `Span(_unsafeCxxSpan:)`. The cost is two additional `unsafe` markers (one per entry point)
// for the same rdar://186723514 the input already carries. The gain is the elimination of the
// intermediate copy every decoded byte used to pay: Swift scratch → C++ buffer becomes just
// C++ buffer, and the per-call zero-fill of the scratch is gone with it.

/// Decodes `input` as UTF-8.
///
/// `partialSequence` and `partialSequenceSize` are the sequence a previous call parked, packed as
/// `packSequenceBytes` packs one. They are a COPY: this function reads them, works on locals and
/// reports a new park in its result, and the caller applies that only when `answered` is true. It
/// reads no other codec state and writes none, so a decline is free of consequences -- the caller
/// discards whatever the sink was handed simply by not advancing its destination, or by not taking
/// the 16-bit buffer, and its own park is untouched.
///
/// The caller guarantees there is no byte order mark to strip and that `input` is not empty. Those
/// are the only two declines left; the two `.declined` returns the 8-bit park drain still carries
/// are parks the C++ cannot construct, and it says why on itself.
///
/// `stopOnError` is the caller's own parameter, true for XML and nothing else. It does two things,
/// and the second is easy to miss: it replaces the U+FFFD an ill-formed sequence would emit, AND it
/// ends the decode there, silently dropping the rest of the input. `stoppedOnError` in the result is
/// how the second reaches the caller.
///
/// THE SHAPE HERE IS `TextCodecUTF8::decode`'s OWN, which is two stages of
/// `do { drain the park; if it is still there, stop; run the main loop } while (the park is back)`,
/// separated by a one-way upconversion. The park comes back because a main loop parks a truncated
/// tail and then loops round to have it diagnosed IN THE SAME CALL -- and it can only do that once,
/// since a main loop parks only when the input is exhausted and a drain against an exhausted input
/// cannot hand control back to the main loop.
///
/// Decodes `input` as UTF-8 into `destInput`, a Latin-1 destination buffer.
///
/// `partialSequence` and `partialSequenceSize` are the sequence a previous call parked, packed as
/// `packSequenceBytes` packs one. They are a COPY: this function reads them, works on locals and
/// reports a new park in its result, and the caller applies that only when `answered` is true. It
/// reads no other codec state and writes none, so a decline is free of consequences.
///
/// The caller guarantees there is no byte order mark to strip and that `input` is not empty.
///
/// Returns `needsWide = true` at the first character above U+00FF (or the first ill-formed
/// sequence when `stopOnError` is false), leaving `consumed` pointing at the triggering sequence
/// so the caller's wide arm re-reads it. The park drain can also force `needsWide` before the
/// main loop runs -- an error inside a parked sequence upconverts even under `stopOnError`,
/// matching the C++ 8-bit `handlePartialSequence` overload's `return true` path.
///
/// TODO(unsafe): `_unsafeCxxSpan:` for `input` and `destInput` -- rdar://186723514.
@_expose(Cxx)
public func textCodecUTF8DecodeNarrow(
    _ input: PAL.TextCodecUTF8SwiftInput,
    _ destInput: PAL.TextCodecUTF8SwiftNarrowDest,
    _ partialSequence: UInt32,
    _ partialSequenceSize: UInt8,
    _ flush: Bool,
    _ stopOnError: Bool
) -> PAL.TextCodecUTF8SwiftResult {
    let source = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    let sourceBytes = source.bytes
    var dest = unsafe MutableSpan<UInt8>(_unsafeCxxSpan: destInput)
    let declined = PAL.TextCodecUTF8SwiftResult()

    var consumed = 0
    var produced = 0
    var packedPark = partialSequence
    var parkSize = Int(partialSequenceSize)
    var sawError = false
    var stoppedOnError = false
    var stageDone = false

    // ---- The 8-bit park drain. ------------------------------------------------------------
    if parkSize != 0 {
        switch drainParkedSequenceNarrow(source, from: consumed, park: packedPark, size: parkSize, flush: flush) {
        case .declined:
            return declined

        case .waiting(let park, let size, let cursor):
            packedPark = park
            parkSize = size
            consumed = cursor
            stageDone = true

        case .needsWide(let park, let size, let cursor):
            // Park drain forced wide -- signal the caller without producing any narrow output.
            var result = PAL.TextCodecUTF8SwiftResult()
            result.consumedBytes = UInt32(cursor)
            result.producedCharacters = 0
            if !flush {
                result.partialSequence = park
                result.partialSequenceSize = UInt8(size)
            }
            result.needsWide = true
            result.answered = true
            return result

        case .latin1(let character, let cursor):
            dest[produced] = character
            produced += 1
            consumed = cursor
            packedPark = 0
            parkSize = 0
        }
    }

    if !stageDone {
        narrowStage: while true {
            var parked = false
            while consumed < source.count {
                let outcome = decodeChunk(source, sourceBytes, from: consumed, into: &dest, startingAt: produced)

                switch outcome {
                case .needsWide(let chunkConsumed, let chunkProduced):
                    // Signal the caller; it widens the already-produced characters and calls wide.
                    var result = PAL.TextCodecUTF8SwiftResult()
                    result.consumedBytes = UInt32(chunkConsumed)
                    result.producedCharacters = UInt32(chunkProduced)
                    result.needsWide = true
                    result.sawError = sawError
                    result.answered = true
                    return result

                case .illFormed(let chunkConsumed, let chunkProduced, _):
                    produced = chunkProduced
                    consumed = chunkConsumed
                    sawError = true
                    if stopOnError {
                        stoppedOnError = true
                        stageDone = true
                    } else {
                        // Upconvert: the ill-formed sequence is not Latin-1.
                        var result = PAL.TextCodecUTF8SwiftResult()
                        result.consumedBytes = UInt32(consumed)
                        result.producedCharacters = UInt32(produced)
                        result.needsWide = true
                        result.sawError = true
                        result.answered = true
                        return result
                    }

                case .truncated(let chunkConsumed, let chunkProduced, let partialSize):
                    produced = chunkProduced
                    packedPark = packSequenceBytes(source, from: chunkConsumed, count: partialSize)
                    parkSize = partialSize
                    consumed = chunkConsumed + partialSize
                    parked = true

                case .complete(let chunkConsumed, let chunkProduced):
                    produced = chunkProduced
                    consumed = chunkConsumed
                    continue
                }
                break
            }
            if !parked { break }

            switch drainParkedSequenceNarrow(source, from: consumed, park: packedPark, size: parkSize, flush: flush) {
            case .declined:
                return declined

            case .waiting(let park, let size, let cursor):
                packedPark = park
                parkSize = size
                consumed = cursor
                stageDone = true

            case .needsWide(let park, let size, let cursor):
                var result = PAL.TextCodecUTF8SwiftResult()
                result.consumedBytes = UInt32(cursor)
                result.producedCharacters = UInt32(produced)
                if !flush {
                    result.partialSequence = park
                    result.partialSequenceSize = UInt8(size)
                }
                result.needsWide = true
                result.sawError = sawError
                result.answered = true
                return result

            case .latin1(let character, let cursor):
                dest[produced] = character
                produced += 1
                consumed = cursor
                packedPark = 0
                parkSize = 0
                continue narrowStage
            }
            break
        }
    }

    var result = PAL.TextCodecUTF8SwiftResult()
    result.consumedBytes = UInt32(consumed)
    result.producedCharacters = UInt32(produced)
    if !flush {
        result.partialSequence = packedPark
        result.partialSequenceSize = UInt8(parkSize)
    }
    result.sawError = sawError
    result.stoppedOnError = stoppedOnError
    result.answered = true
    return result
}

/// Decodes `input` as UTF-8 into `destInput`, a UTF-16 destination buffer.
///
/// Called by the C++ caller after `textCodecUTF8DecodeNarrow` returns `needsWide = true`. The
/// caller has already widened the narrow prefix into a `StringBuffer<char16_t>` and passes here
/// a span of that buffer starting at the narrow-prefix length, so this function writes from
/// index zero of `destInput`. It handles the same park state the narrow function left behind.
///
/// Returns `.answered = true` always (no decline paths remain at this width).
///
/// TODO(unsafe): `_unsafeCxxSpan:` for `input` and `destInput` -- rdar://186723514.
@_expose(Cxx)
public func textCodecUTF8DecodeWide(
    _ input: PAL.TextCodecUTF8SwiftInput,
    _ destInput: PAL.TextCodecUTF8SwiftWideDest,
    _ partialSequence: UInt32,
    _ partialSequenceSize: UInt8,
    _ flush: Bool,
    _ stopOnError: Bool
) -> PAL.TextCodecUTF8SwiftResult {
    let source = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    let sourceBytes = source.bytes
    var dest = unsafe MutableSpan<UInt16>(_unsafeCxxSpan: destInput)

    var consumed = 0
    var produced = 0
    var packedPark = partialSequence
    var parkSize = Int(partialSequenceSize)
    var sawError = false
    var stoppedOnError = false
    var stageDone = false

    // ---- The 16-bit stage. ----------------------------------------------------------------
    wideStage: while true {
        // Drain any parked partial sequence first, looping because a drain can consume
        // many input bytes before the park empties.
        while parkSize != 0 && !stageDone {
            var units = produced
            let outcome = drainParkedSequenceWide(
                source, from: consumed, park: packedPark, size: parkSize,
                flush: flush, stopOnError: stopOnError,
                into: &dest, units: &units, sawError: &sawError)
            produced = units
            switch outcome {
            case .bufferFull(let park, let size, let cursor):
                packedPark = park
                parkSize = size
                consumed = cursor

            case .drained(let cursor):
                consumed = cursor
                packedPark = 0
                parkSize = 0

            case .waiting(let park, let size, let cursor):
                packedPark = park
                parkSize = size
                consumed = cursor
                stageDone = true

            case .stopped(let park, let size, let cursor):
                packedPark = park
                parkSize = size
                consumed = cursor
                sawError = true
                stoppedOnError = true
                stageDone = true
            }
        }
        if stageDone { break }

        var parked = false
        outer: while consumed < source.count {
            var chunkProduced = produced
            var chunkCursor = consumed
            while true {
                switch decodeWideChunk(
                    source, sourceBytes, from: chunkCursor, into: &dest,
                    startingAt: chunkProduced) {
                // Never from the wide kernel.
                case .needsWide:
                    var result = PAL.TextCodecUTF8SwiftResult()
                    result.answered = false
                    return result

                case .illFormed(let errorAt, let chunkProducedSoFar, let subpart):
                    sawError = true
                    if stopOnError {
                        consumed = errorAt
                        produced = chunkProducedSoFar
                        stoppedOnError = true
                        break outer
                    }
                    dest[chunkProducedSoFar] = replacementCharacter
                    chunkProduced = chunkProducedSoFar + 1
                    chunkCursor = errorAt + (subpart == 0 ? 1 : subpart)

                case .truncated(let chunkConsumed, let chunkProducedSoFar, let partialSize):
                    packedPark = packSequenceBytes(source, from: chunkConsumed, count: partialSize)
                    parkSize = partialSize
                    consumed = chunkConsumed + partialSize
                    produced = chunkProducedSoFar
                    parked = true
                    break outer

                case .complete(let chunkConsumed, let chunkProducedSoFar):
                    consumed = chunkConsumed
                    produced = chunkProducedSoFar
                    continue outer
                }
            }
        }
        if !parked || stoppedOnError { break }
    }

    var result = PAL.TextCodecUTF8SwiftResult()
    result.consumedBytes = UInt32(consumed)
    result.producedCharacters = UInt32(produced)
    if !flush {
        result.partialSequence = packedPark
        result.partialSequenceSize = UInt8(parkSize)
    }
    result.sawError = sawError
    result.stoppedOnError = stoppedOnError
    result.answered = true
    return result
}
