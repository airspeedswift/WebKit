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

// UTF-8 decoding, the Latin-1 half.
//
// `TextCodecUTF8::decode` decodes optimistically into an 8-bit `StringBuffer` and abandons it
// for a 16-bit one the moment it meets a character Latin-1 cannot hold, an ill-formed
// sequence, or a byte order mark. This file covers the arm that does not abandon: input whose
// every character is U+0000-U+00FF. That is ASCII plus one two-byte sequence form, and it is
// what the overwhelming majority of the web's bytes are.
//
// EVERYTHING ELSE DECLINES, and a decline is a whole-input decline: the C++ re-runs its own
// loop over the same bytes from the top. So one CJK character in a chunk costs that chunk's
// Swift attempt entirely. That is this slice's boundary, not the end state -- the 16-bit path
// is the next slice -- and `textCodecUTF8SwiftCounters()` is what makes it visible, because a
// declining arm and an agreeing arm are byte-identical by construction.
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

/// The outcome of decoding into one scratch buffer's worth of output.
private enum ChunkOutcome {
    /// The scratch buffer filled, or the input ran out.
    case complete(consumed: Int, produced: Int)
    /// The input ended mid-sequence. `consumed` excludes the truncated sequence.
    case truncated(consumed: Int, produced: Int, partial: Int)
    /// Something outside this arm's subset; the caller declines the whole input.
    case declined
}

/// Decodes from `source[start...]` into `output` until `output` is full or `source` runs out.
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
        if index >= limit { break }

        let firstByte = source[index]
        if firstByte < 0x80 {
            output[produced] = firstByte
            produced += 1
            index += 1
            continue
        }

        // 0xC2 and 0xC3 are the only lead bytes whose sequences reach Latin-1 and no further:
        // 0xC0 and 0xC1 are overlong, 0xC4 upwards starts at U+0100, and the three- and
        // four-byte forms start at U+0800 and U+10000. So one range test stands in for the
        // C++'s 256-entry `nonASCIISequenceLength` table plus its `isLatin1` check, and
        // everything it excludes -- ill-formed and merely-too-large alike -- declines.
        if firstByte != 0xC2 && firstByte != 0xC3 { return .declined }

        if index + 2 > end {
            // Truncated at the very end of the input; nothing is consumed for it.
            return .truncated(consumed: index, produced: produced, partial: end - index)
        }
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

/// Decodes `input` as UTF-8, provided every character of it fits in Latin-1.
///
/// The caller guarantees there is no parked partial sequence and no byte order mark to strip,
/// so this function reads no codec state and writes none: it reports what it consumed and the
/// caller applies it. That is what makes a decline free of consequences -- the caller discards
/// whatever the sink was handed simply by not advancing its destination.
///
/// Answers `answered == false`, meaning the caller must decode the whole input itself, for a
/// character above U+00FF, an ill-formed sequence, or a truncated sequence at a `flush`.
///
/// TODO(unsafe): the one `unsafe` marker in this island. `input` arrives as an imported
/// `std::span`, and turning that into a `Span` needs `Span(_unsafeCxxSpan:)` because Swift has
/// no safe way to receive a bounds-carrying view from C++ (rdar://186723514). The borrow is
/// well formed -- `TextCodecUTF8::decode` owns the bytes for the whole call and nothing here
/// outlives it -- but the initializer is `@unsafe`, so the marker stands until the radar
/// lands. `CSSTokenizerSwift.swift` carries the same two sites for the same reason.
@_expose(Cxx)
public func textCodecUTF8DecodeLatin1Swift(
    _ input: PAL.TextCodecUTF8SwiftInput,
    _ flush: Bool,
    _ sink: PAL.TextCodecUTF8SwiftSink
) -> PAL.TextCodecUTF8SwiftResult {
    let source = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    let sourceBytes = source.bytes
    let declined = PAL.TextCodecUTF8SwiftResult()

    var scratch = DecodeScratch(repeating: 0)
    var consumed = 0
    var partial = 0

    while consumed < source.count {
        var output = scratch.mutableSpan
        let outcome = decodeChunk(source, sourceBytes, from: consumed, into: &output)

        switch outcome {
        case .declined:
            return declined

        case .truncated(let chunkConsumed, let produced, let partialSize):
            // A truncated sequence at a flush is not this arm's to answer: the C++ turns it
            // into a replacement character, which is not Latin-1, and upconverts.
            if flush { return declined }
            sink.takeChunk(output.span.extracting(0..<produced))
            consumed = chunkConsumed
            partial = partialSize

        case .complete(let chunkConsumed, let produced):
            sink.takeChunk(output.span.extracting(0..<produced))
            consumed = chunkConsumed
            continue
        }
        break
    }

    var result = PAL.TextCodecUTF8SwiftResult()
    result.consumedBytes = UInt32(consumed)
    result.partialSequenceSize = UInt8(partial)
    result.answered = true
    return result
}
