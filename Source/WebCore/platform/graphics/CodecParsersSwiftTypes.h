/*
 * Copyright (C) 2018-2021 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <array>
#include <atomic>
#include <optional>
#include <wtf/text/StringView.h>

#include "HEVCUtilities.h"

namespace WebCore {

// A candidate codec string, crossing into Swift *by value*.
//
// WHY A VALUE AND NOT A VIEW. A Swift function exposed to C++ is a Swift *callee*, and Swift
// can PASS a bounds-carrying view to C++ but can never RECEIVE one: `@_expose(Cxx)` silently
// omits a `Span<T>` parameter from the generated header, and an imported `std::span` needs
// `Span(_unsafeCxxSpan:)`, which is `@unsafe`. `StringView` does not rescue it either -- its raw
// pointer member makes the enclosing type import `@unsafe` and the unsafety propagates. A value
// carries no lifetime, so the question disappears: `std::array<T, N>` holds no pointer, is
// therefore not an unsafe imported type, and its `operator[]` imports as an ordinary Swift
// subscript indexed below a *constant* capacity. This is `CSSSwiftColorText`'s design
// (CSSTokenizerSwiftTypes.h:199) applied to a second boundary.
//
// THE CAPACITY IS A DECLINE THRESHOLD, NOT A GRAMMAR BOUND, and this is where the codec strings
// differ from the CSS colours the design is borrowed from. A candidate longer than the longest
// named colour cannot *be* a colour, so the colour fast path answers `notAColor` above its
// capacity and never declines. No such bound exists here: `parseInteger<uint8_t>` accepts
// unlimited leading zeros, so `dvh1.0000000000000000004.09` is a *valid* DoVi string today and
// there is no length above which a string is certainly invalid. Answering "not a codec" above
// the capacity would therefore be a behaviour change. The Swift arm DECLINES instead, and every
// decline is counted -- see the counters in HEVCUtilities.cpp, and note that a decline is
// invisible in a differential and reads as parity unless it is counted.
//
// 32 is chosen to clear every grammar's canonical form with headroom: the longest is AV1's
// `av01.0.04M.10.0.112.09.16.09.0` at 30, with VP9's 28-character form next. Two consequences
// to accept explicitly rather than discover:
//
//  * It is ABOVE the register-passing cliff, which is at 32 bytes total (measured: a 28-byte
//    and a 32-byte struct pass in registers, a 36-byte one passes as `const void *`). At
//    capacity 32 this struct is 40 bytes and crosses by address, so Swift copies it onto its
//    own frame on top of the copy `makeCodecStringText` already made. The colour boundary at
//    capacity 24 does not pay this. Codec parsing runs on media load rather than in a parse
//    loop, so the copy is expected to be irrelevant -- but measure it, do not assume it.
//  * A capacity that fits in registers would be 24, which is BELOW VP9's and AV1's canonical
//    forms and would decline on ordinary input. Do not shrink it back for the ABI.
static constexpr size_t codecStringTextCapacity = 32;

// `length` is the candidate's true length, which may exceed the capacity; `units` holds its
// first `min(length, capacity)` code units and is zero-filled beyond them, so no index below the
// capacity is indeterminate. Swift treats `length > capacity` as its decline condition.
//
// ONE WIDTH, unlike the colour path's two. Every character a DoVi, AVC, HEVC, VP or AV1 codec
// string can contain is ASCII: the codec tags and profile mnemonics are ASCII letters and
// digits, `parseInteger` accepts only ASCII digits, a single '+' and the six characters of
// `isUnicodeCompatibleASCIIWhitespace` (' ', '\n', '\t', '\r', '\f', '\v'). A 16-bit-backed
// candidate is therefore narrowed rather than given its own instantiation, and one that does not
// narrow cannot be valid.
struct CodecStringText {
    std::array<Latin1Character, codecStringTextCapacity> units;
    uint32_t length;
};

// Swift cannot spell a C++ template instantiation directly, so the entry point's return type
// needs a name. It is `parseDoViCodecParameters`' own return type, unchanged: Swift constructs
// `DoViParameters` itself -- default member initializers and the nested `enum class Codec`
// included -- so there is no parallel POD, no outcome enum and no conversion function anywhere
// in this island. Measured, not assumed: `std::optional<T>` of a record with those features
// round-trips at `unsafe` = 0 and appears in the generated header as
// `std::__1::optional<WebCore::DoViParameters>`.
using OptionalDoViParameters = std::optional<DoViParameters>;

// Per-entry-point coverage, and it is mandatory from the first commit rather than retrofitted.
//
// A DECLINE IS INVISIBLE. Both arms answer `nullopt` for input the Swift arm refuses to look
// at, so a differential over the layout tests reports a declining island as a passing one, and
// a coverage figure quoted in aggregate across entry points hides an entry point at zero. These
// two counters are the only thing that distinguishes "the Swift arm agreed" from "the Swift arm
// never ran", and the second is what a capacity-bounded crossing value makes possible.
//
// Relaxed ordering: they are a coverage census read after a run, never a synchronisation
// mechanism, and nothing branches on them.
struct CodecParserCounters {
    std::atomic<uint64_t> answered { 0 };
    std::atomic<uint64_t> declined { 0 };
};

WEBCORE_EXPORT CodecParserCounters& doViCodecParserCounters();

} // namespace WebCore
