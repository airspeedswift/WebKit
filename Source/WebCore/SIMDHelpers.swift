/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

// Shared SIMD building blocks for WebCore's Swift. Safe Swift only. The operations that need the Builtin module are
// in the vendored files beside this one (SIMDTableLookup.swift, SIMDSaturatingSubtract.swift,
// SIMDHighBitMask.swift), which stand in for standard library features until those land.
//
// Each helper is one or two instructions on arm64.

/// True when any lane of `v` has its top bit set (UMAXV on arm64).
@inline(always)
func anyHighBit(_ v: SIMD16<UInt8>) -> Bool {
    v.max() >= 0x80
}

/// 0xFF in each lane of `v` whose top bit is set, 0 in the others (CMLT on arm64).
@inline(always)
func signLanes(_ v: SIMD16<UInt8>) -> SIMD16<UInt8> {
    SIMD16<UInt8>(truncatingIfNeeded: SIMD16<Int8>(truncatingIfNeeded: v) &>> 7)
}

/// The number of leading lanes of `v` below 0x80: 16 when all are.
@inline(always)
func leadingASCIICount(_ v: SIMD16<UInt8>) -> Int {
    highBitMask(v).trailingZeroBitCount
}

/// The low eight lanes of `v`, zero-extended to 16 bits.
@inline(always)
func widenLow(_ v: SIMD16<UInt8>) -> SIMD8<UInt16> {
    SIMD8<UInt16>(truncatingIfNeeded: v.lowHalf)
}

/// The high eight lanes of `v`, zero-extended to 16 bits.
@inline(always)
func widenHigh(_ v: SIMD16<UInt8>) -> SIMD8<UInt16> {
    SIMD8<UInt16>(truncatingIfNeeded: v.highHalf)
}

/// The low byte of each 16-bit lane of `low` then `high`, as sixteen bytes.
@inline(always)
func narrowToLowBytes(_ low: SIMD8<UInt16>, _ high: SIMD8<UInt16>) -> SIMD16<UInt8> {
    SIMD16(lowHalf: SIMD8<UInt8>(truncatingIfNeeded: low), highHalf: SIMD8<UInt8>(truncatingIfNeeded: high))
}

/// True when any 16-bit lane of `v` is at least `limit`.
@inline(always)
func anyLane(_ v: SIMD8<UInt16>, atLeast limit: UInt16) -> Bool {
    v.max() >= limit
}

/// Sixteen bytes of `span` starting at `offset`, bounds-checked. The offset need not be aligned.
@inline(always)
func load16(_ span: Span<UInt8>, at offset: Int) -> SIMD16<UInt8> {
    span.bytes.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
}

/// Stores `v` into sixteen bytes of `span` starting at `offset`, bounds-checked. The offset need not be aligned.
@inline(always)
func store16(_ v: SIMD16<UInt8>, into span: inout MutableSpan<UInt8>, at offset: Int) {
    var bytes = span.mutableBytes
    bytes.storeBytes(of: v, toByteOffset: offset, as: SIMD16<UInt8>.self)
}
