// Copyright (C) 2017 Caio Lima <ticaiolima@gmail.com>
// Copyright (C) 2017-2024 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Parts of the implementation below:
//
// Copyright 2017-2021 the V8 project authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
//
// Copyright (c) 2014 the Dart project authors.  Please see the AUTHORS file [1]
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file [2].
//
// [1] https://github.com/dart-lang/sdk/blob/master/AUTHORS
// [2] https://github.com/dart-lang/sdk/blob/master/LICENSE
//
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file [3].
//
// [3] https://golang.org/LICENSE

#if USE_SWIFT_BIGINT_DIGITS

// The running sum of one product column, in three digits.
struct DigitColumnAccumulator {
    var t0: UInt64 = 0
    var t1: UInt64 = 0
    var t2: UInt64 = 0

    // Each sum is formed in two digits, so its carry is the upper digit rather than a branch.
    @inline(always)
    mutating func mac(_ a: UInt64, _ b: UInt64) {
        let product = UInt128(a) * UInt128(b)
        let sum0 = UInt128(t0) + UInt128(UInt64(truncatingIfNeeded: product))
        t0 = UInt64(truncatingIfNeeded: sum0)
        let sum1 = UInt128(t1) + (product >> 64) + (sum0 >> 64)
        t1 = UInt64(truncatingIfNeeded: sum1)
        // t2 counts one carry per product, at most maxLength per column, so this cannot overflow.
        t2 &+= UInt64(truncatingIfNeeded: sum1 >> 64)
    }

    @inline(always)
    mutating func storeAndShift() -> UInt64 {
        let result = t0
        t0 = t1
        t1 = t2
        t2 = 0
        return result
    }

    @inline(always)
    func low() -> UInt64 { t0 }

    // True once the running sum fits in the single digit low() returns, which is what callers rely on at the final
    // column.
    @inline(always)
    func fitsInLow() -> Bool { t1 == 0 && t2 == 0 }
}

// JSBigInt::maxCombaFixedSize.
let maxCombaFixedSize = 16

// The running sum of one product column of the fixed-size kernels: the two low digits as one UInt128, and the digit
// above them, which counts the carries out of it. Adding each product with one addingReportingOverflow keeps a column's
// additions in one chain of carries.
struct CombaAccumulator {
    var t: UInt128 = 0
    var t2: UInt64 = 0

    @inline(always)
    mutating func mac(_ a: UInt64, _ b: UInt64) {
        let (sum, carry) = t.addingReportingOverflow(UInt128(a) * UInt128(b))
        t = sum
        // t2 counts one carry per product, at most maxCombaFixedSize per column, so this cannot overflow.
        t2 &+= carry ? 1 : 0
    }

    // Accumulates 2 * a * b. The doubled product needs one bit more than the two digits a * b occupies, and that bit
    // lands in t2.
    @inline(always)
    mutating func macDoubled(_ a: UInt64, _ b: UInt64) {
        let product = UInt128(a) * UInt128(b)
        let top = UInt64(truncatingIfNeeded: product >> 127)
        let (sum, carry) = t.addingReportingOverflow(product << 1)
        t = sum
        // Cannot overflow: as in mac, t2 counts at most two carries per product.
        t2 &+= (carry ? 1 : 0) &+ top
    }

    @inline(always)
    mutating func storeAndShift() -> UInt64 {
        let result = UInt64(truncatingIfNeeded: t)
        t = (UInt128(t2) << 64) | (t >> 64)
        t2 = 0
        return result
    }

    @inline(always)
    func low() -> UInt64 { UInt64(truncatingIfNeeded: t) }
}

// result[offset ..< offset + 2N] := x * y over x's and y's first N digits, and x * x over x's first N digits, by
// product scanning with every column written out, so that the operands stay in registers. The squares accumulate the
// products of (i, j) and (j, i) once at twice the weight. Each returns 2N.
@inline(always)
func multiplyCombaFixed1(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 1 && y.count >= 1 && offset >= 0 && result.count - offset >= 2)
    // Cannot overflow: offset + 2 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    let b0 = y[0]
    var c = CombaAccumulator()
    c.mac(a0, b0)
    result[offset &+ 0] = c.storeAndShift()
    result[offset &+ 1] = c.low()
    return 2
}

@inline(always)
func squareCombaFixed1(_ x: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 1 && offset >= 0 && result.count - offset >= 2)
    // Cannot overflow: offset + 2 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    var c = CombaAccumulator()
    c.mac(a0, a0)
    result[offset &+ 0] = c.storeAndShift()
    result[offset &+ 1] = c.low()
    return 2
}

@inline(always)
func multiplyCombaFixed2(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 2 && y.count >= 2 && offset >= 0 && result.count - offset >= 4)
    // Cannot overflow: offset + 4 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    let a1 = x[1]
    let b0 = y[0]
    let b1 = y[1]
    var c = CombaAccumulator()
    c.mac(a0, b0)
    result[offset &+ 0] = c.storeAndShift()
    c.mac(a0, b1)
    c.mac(a1, b0)
    result[offset &+ 1] = c.storeAndShift()
    c.mac(a1, b1)
    result[offset &+ 2] = c.storeAndShift()
    result[offset &+ 3] = c.low()
    return 4
}

@inline(always)
func squareCombaFixed2(_ x: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 2 && offset >= 0 && result.count - offset >= 4)
    // Cannot overflow: offset + 4 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    let a1 = x[1]
    var c = CombaAccumulator()
    c.mac(a0, a0)
    result[offset &+ 0] = c.storeAndShift()
    c.macDoubled(a0, a1)
    result[offset &+ 1] = c.storeAndShift()
    c.mac(a1, a1)
    result[offset &+ 2] = c.storeAndShift()
    result[offset &+ 3] = c.low()
    return 4
}

@inline(always)
func multiplyCombaFixed4(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 4 && y.count >= 4 && offset >= 0 && result.count - offset >= 8)
    // Cannot overflow: offset + 8 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    let a1 = x[1]
    let a2 = x[2]
    let a3 = x[3]
    let b0 = y[0]
    let b1 = y[1]
    let b2 = y[2]
    let b3 = y[3]
    var c = CombaAccumulator()
    c.mac(a0, b0)
    result[offset &+ 0] = c.storeAndShift()
    c.mac(a0, b1)
    c.mac(a1, b0)
    result[offset &+ 1] = c.storeAndShift()
    c.mac(a0, b2)
    c.mac(a1, b1)
    c.mac(a2, b0)
    result[offset &+ 2] = c.storeAndShift()
    c.mac(a0, b3)
    c.mac(a1, b2)
    c.mac(a2, b1)
    c.mac(a3, b0)
    result[offset &+ 3] = c.storeAndShift()
    c.mac(a1, b3)
    c.mac(a2, b2)
    c.mac(a3, b1)
    result[offset &+ 4] = c.storeAndShift()
    c.mac(a2, b3)
    c.mac(a3, b2)
    result[offset &+ 5] = c.storeAndShift()
    c.mac(a3, b3)
    result[offset &+ 6] = c.storeAndShift()
    result[offset &+ 7] = c.low()
    return 8
}

@inline(always)
func squareCombaFixed4(_ x: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 4 && offset >= 0 && result.count - offset >= 8)
    // Cannot overflow: offset + 8 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    let a1 = x[1]
    let a2 = x[2]
    let a3 = x[3]
    var c = CombaAccumulator()
    c.mac(a0, a0)
    result[offset &+ 0] = c.storeAndShift()
    c.macDoubled(a0, a1)
    result[offset &+ 1] = c.storeAndShift()
    c.macDoubled(a0, a2)
    c.mac(a1, a1)
    result[offset &+ 2] = c.storeAndShift()
    c.macDoubled(a0, a3)
    c.macDoubled(a1, a2)
    result[offset &+ 3] = c.storeAndShift()
    c.macDoubled(a1, a3)
    c.mac(a2, a2)
    result[offset &+ 4] = c.storeAndShift()
    c.macDoubled(a2, a3)
    result[offset &+ 5] = c.storeAndShift()
    c.mac(a3, a3)
    result[offset &+ 6] = c.storeAndShift()
    result[offset &+ 7] = c.low()
    return 8
}

@inline(never)
func multiplyCombaFixed8(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 8 && y.count >= 8 && offset >= 0 && result.count - offset >= 16)
    // Cannot overflow: offset + 16 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    let a1 = x[1]
    let a2 = x[2]
    let a3 = x[3]
    let a4 = x[4]
    let a5 = x[5]
    let a6 = x[6]
    let a7 = x[7]
    let b0 = y[0]
    let b1 = y[1]
    let b2 = y[2]
    let b3 = y[3]
    let b4 = y[4]
    let b5 = y[5]
    let b6 = y[6]
    let b7 = y[7]
    var c = CombaAccumulator()
    c.mac(a0, b0)
    result[offset &+ 0] = c.storeAndShift()
    c.mac(a0, b1)
    c.mac(a1, b0)
    result[offset &+ 1] = c.storeAndShift()
    c.mac(a0, b2)
    c.mac(a1, b1)
    c.mac(a2, b0)
    result[offset &+ 2] = c.storeAndShift()
    c.mac(a0, b3)
    c.mac(a1, b2)
    c.mac(a2, b1)
    c.mac(a3, b0)
    result[offset &+ 3] = c.storeAndShift()
    c.mac(a0, b4)
    c.mac(a1, b3)
    c.mac(a2, b2)
    c.mac(a3, b1)
    c.mac(a4, b0)
    result[offset &+ 4] = c.storeAndShift()
    c.mac(a0, b5)
    c.mac(a1, b4)
    c.mac(a2, b3)
    c.mac(a3, b2)
    c.mac(a4, b1)
    c.mac(a5, b0)
    result[offset &+ 5] = c.storeAndShift()
    c.mac(a0, b6)
    c.mac(a1, b5)
    c.mac(a2, b4)
    c.mac(a3, b3)
    c.mac(a4, b2)
    c.mac(a5, b1)
    c.mac(a6, b0)
    result[offset &+ 6] = c.storeAndShift()
    c.mac(a0, b7)
    c.mac(a1, b6)
    c.mac(a2, b5)
    c.mac(a3, b4)
    c.mac(a4, b3)
    c.mac(a5, b2)
    c.mac(a6, b1)
    c.mac(a7, b0)
    result[offset &+ 7] = c.storeAndShift()
    c.mac(a1, b7)
    c.mac(a2, b6)
    c.mac(a3, b5)
    c.mac(a4, b4)
    c.mac(a5, b3)
    c.mac(a6, b2)
    c.mac(a7, b1)
    result[offset &+ 8] = c.storeAndShift()
    c.mac(a2, b7)
    c.mac(a3, b6)
    c.mac(a4, b5)
    c.mac(a5, b4)
    c.mac(a6, b3)
    c.mac(a7, b2)
    result[offset &+ 9] = c.storeAndShift()
    c.mac(a3, b7)
    c.mac(a4, b6)
    c.mac(a5, b5)
    c.mac(a6, b4)
    c.mac(a7, b3)
    result[offset &+ 10] = c.storeAndShift()
    c.mac(a4, b7)
    c.mac(a5, b6)
    c.mac(a6, b5)
    c.mac(a7, b4)
    result[offset &+ 11] = c.storeAndShift()
    c.mac(a5, b7)
    c.mac(a6, b6)
    c.mac(a7, b5)
    result[offset &+ 12] = c.storeAndShift()
    c.mac(a6, b7)
    c.mac(a7, b6)
    result[offset &+ 13] = c.storeAndShift()
    c.mac(a7, b7)
    result[offset &+ 14] = c.storeAndShift()
    result[offset &+ 15] = c.low()
    return 16
}

@inline(never)
func squareCombaFixed8(_ x: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 8 && offset >= 0 && result.count - offset >= 16)
    // Cannot overflow: offset + 16 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    let a1 = x[1]
    let a2 = x[2]
    let a3 = x[3]
    let a4 = x[4]
    let a5 = x[5]
    let a6 = x[6]
    let a7 = x[7]
    var c = CombaAccumulator()
    c.mac(a0, a0)
    result[offset &+ 0] = c.storeAndShift()
    c.macDoubled(a0, a1)
    result[offset &+ 1] = c.storeAndShift()
    c.macDoubled(a0, a2)
    c.mac(a1, a1)
    result[offset &+ 2] = c.storeAndShift()
    c.macDoubled(a0, a3)
    c.macDoubled(a1, a2)
    result[offset &+ 3] = c.storeAndShift()
    c.macDoubled(a0, a4)
    c.macDoubled(a1, a3)
    c.mac(a2, a2)
    result[offset &+ 4] = c.storeAndShift()
    c.macDoubled(a0, a5)
    c.macDoubled(a1, a4)
    c.macDoubled(a2, a3)
    result[offset &+ 5] = c.storeAndShift()
    c.macDoubled(a0, a6)
    c.macDoubled(a1, a5)
    c.macDoubled(a2, a4)
    c.mac(a3, a3)
    result[offset &+ 6] = c.storeAndShift()
    c.macDoubled(a0, a7)
    c.macDoubled(a1, a6)
    c.macDoubled(a2, a5)
    c.macDoubled(a3, a4)
    result[offset &+ 7] = c.storeAndShift()
    c.macDoubled(a1, a7)
    c.macDoubled(a2, a6)
    c.macDoubled(a3, a5)
    c.mac(a4, a4)
    result[offset &+ 8] = c.storeAndShift()
    c.macDoubled(a2, a7)
    c.macDoubled(a3, a6)
    c.macDoubled(a4, a5)
    result[offset &+ 9] = c.storeAndShift()
    c.macDoubled(a3, a7)
    c.macDoubled(a4, a6)
    c.mac(a5, a5)
    result[offset &+ 10] = c.storeAndShift()
    c.macDoubled(a4, a7)
    c.macDoubled(a5, a6)
    result[offset &+ 11] = c.storeAndShift()
    c.macDoubled(a5, a7)
    c.mac(a6, a6)
    result[offset &+ 12] = c.storeAndShift()
    c.macDoubled(a6, a7)
    result[offset &+ 13] = c.storeAndShift()
    c.mac(a7, a7)
    result[offset &+ 14] = c.storeAndShift()
    result[offset &+ 15] = c.low()
    return 16
}

@inline(never)
func multiplyCombaFixed16(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 16 && y.count >= 16 && offset >= 0 && result.count - offset >= 32)
    // Cannot overflow: offset + 32 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    let a1 = x[1]
    let a2 = x[2]
    let a3 = x[3]
    let a4 = x[4]
    let a5 = x[5]
    let a6 = x[6]
    let a7 = x[7]
    let a8 = x[8]
    let a9 = x[9]
    let a10 = x[10]
    let a11 = x[11]
    let a12 = x[12]
    let a13 = x[13]
    let a14 = x[14]
    let a15 = x[15]
    let b0 = y[0]
    let b1 = y[1]
    let b2 = y[2]
    let b3 = y[3]
    let b4 = y[4]
    let b5 = y[5]
    let b6 = y[6]
    let b7 = y[7]
    let b8 = y[8]
    let b9 = y[9]
    let b10 = y[10]
    let b11 = y[11]
    let b12 = y[12]
    let b13 = y[13]
    let b14 = y[14]
    let b15 = y[15]
    var c = CombaAccumulator()
    c.mac(a0, b0)
    result[offset &+ 0] = c.storeAndShift()
    c.mac(a0, b1)
    c.mac(a1, b0)
    result[offset &+ 1] = c.storeAndShift()
    c.mac(a0, b2)
    c.mac(a1, b1)
    c.mac(a2, b0)
    result[offset &+ 2] = c.storeAndShift()
    c.mac(a0, b3)
    c.mac(a1, b2)
    c.mac(a2, b1)
    c.mac(a3, b0)
    result[offset &+ 3] = c.storeAndShift()
    c.mac(a0, b4)
    c.mac(a1, b3)
    c.mac(a2, b2)
    c.mac(a3, b1)
    c.mac(a4, b0)
    result[offset &+ 4] = c.storeAndShift()
    c.mac(a0, b5)
    c.mac(a1, b4)
    c.mac(a2, b3)
    c.mac(a3, b2)
    c.mac(a4, b1)
    c.mac(a5, b0)
    result[offset &+ 5] = c.storeAndShift()
    c.mac(a0, b6)
    c.mac(a1, b5)
    c.mac(a2, b4)
    c.mac(a3, b3)
    c.mac(a4, b2)
    c.mac(a5, b1)
    c.mac(a6, b0)
    result[offset &+ 6] = c.storeAndShift()
    c.mac(a0, b7)
    c.mac(a1, b6)
    c.mac(a2, b5)
    c.mac(a3, b4)
    c.mac(a4, b3)
    c.mac(a5, b2)
    c.mac(a6, b1)
    c.mac(a7, b0)
    result[offset &+ 7] = c.storeAndShift()
    c.mac(a0, b8)
    c.mac(a1, b7)
    c.mac(a2, b6)
    c.mac(a3, b5)
    c.mac(a4, b4)
    c.mac(a5, b3)
    c.mac(a6, b2)
    c.mac(a7, b1)
    c.mac(a8, b0)
    result[offset &+ 8] = c.storeAndShift()
    c.mac(a0, b9)
    c.mac(a1, b8)
    c.mac(a2, b7)
    c.mac(a3, b6)
    c.mac(a4, b5)
    c.mac(a5, b4)
    c.mac(a6, b3)
    c.mac(a7, b2)
    c.mac(a8, b1)
    c.mac(a9, b0)
    result[offset &+ 9] = c.storeAndShift()
    c.mac(a0, b10)
    c.mac(a1, b9)
    c.mac(a2, b8)
    c.mac(a3, b7)
    c.mac(a4, b6)
    c.mac(a5, b5)
    c.mac(a6, b4)
    c.mac(a7, b3)
    c.mac(a8, b2)
    c.mac(a9, b1)
    c.mac(a10, b0)
    result[offset &+ 10] = c.storeAndShift()
    c.mac(a0, b11)
    c.mac(a1, b10)
    c.mac(a2, b9)
    c.mac(a3, b8)
    c.mac(a4, b7)
    c.mac(a5, b6)
    c.mac(a6, b5)
    c.mac(a7, b4)
    c.mac(a8, b3)
    c.mac(a9, b2)
    c.mac(a10, b1)
    c.mac(a11, b0)
    result[offset &+ 11] = c.storeAndShift()
    c.mac(a0, b12)
    c.mac(a1, b11)
    c.mac(a2, b10)
    c.mac(a3, b9)
    c.mac(a4, b8)
    c.mac(a5, b7)
    c.mac(a6, b6)
    c.mac(a7, b5)
    c.mac(a8, b4)
    c.mac(a9, b3)
    c.mac(a10, b2)
    c.mac(a11, b1)
    c.mac(a12, b0)
    result[offset &+ 12] = c.storeAndShift()
    c.mac(a0, b13)
    c.mac(a1, b12)
    c.mac(a2, b11)
    c.mac(a3, b10)
    c.mac(a4, b9)
    c.mac(a5, b8)
    c.mac(a6, b7)
    c.mac(a7, b6)
    c.mac(a8, b5)
    c.mac(a9, b4)
    c.mac(a10, b3)
    c.mac(a11, b2)
    c.mac(a12, b1)
    c.mac(a13, b0)
    result[offset &+ 13] = c.storeAndShift()
    c.mac(a0, b14)
    c.mac(a1, b13)
    c.mac(a2, b12)
    c.mac(a3, b11)
    c.mac(a4, b10)
    c.mac(a5, b9)
    c.mac(a6, b8)
    c.mac(a7, b7)
    c.mac(a8, b6)
    c.mac(a9, b5)
    c.mac(a10, b4)
    c.mac(a11, b3)
    c.mac(a12, b2)
    c.mac(a13, b1)
    c.mac(a14, b0)
    result[offset &+ 14] = c.storeAndShift()
    c.mac(a0, b15)
    c.mac(a1, b14)
    c.mac(a2, b13)
    c.mac(a3, b12)
    c.mac(a4, b11)
    c.mac(a5, b10)
    c.mac(a6, b9)
    c.mac(a7, b8)
    c.mac(a8, b7)
    c.mac(a9, b6)
    c.mac(a10, b5)
    c.mac(a11, b4)
    c.mac(a12, b3)
    c.mac(a13, b2)
    c.mac(a14, b1)
    c.mac(a15, b0)
    result[offset &+ 15] = c.storeAndShift()
    c.mac(a1, b15)
    c.mac(a2, b14)
    c.mac(a3, b13)
    c.mac(a4, b12)
    c.mac(a5, b11)
    c.mac(a6, b10)
    c.mac(a7, b9)
    c.mac(a8, b8)
    c.mac(a9, b7)
    c.mac(a10, b6)
    c.mac(a11, b5)
    c.mac(a12, b4)
    c.mac(a13, b3)
    c.mac(a14, b2)
    c.mac(a15, b1)
    result[offset &+ 16] = c.storeAndShift()
    c.mac(a2, b15)
    c.mac(a3, b14)
    c.mac(a4, b13)
    c.mac(a5, b12)
    c.mac(a6, b11)
    c.mac(a7, b10)
    c.mac(a8, b9)
    c.mac(a9, b8)
    c.mac(a10, b7)
    c.mac(a11, b6)
    c.mac(a12, b5)
    c.mac(a13, b4)
    c.mac(a14, b3)
    c.mac(a15, b2)
    result[offset &+ 17] = c.storeAndShift()
    c.mac(a3, b15)
    c.mac(a4, b14)
    c.mac(a5, b13)
    c.mac(a6, b12)
    c.mac(a7, b11)
    c.mac(a8, b10)
    c.mac(a9, b9)
    c.mac(a10, b8)
    c.mac(a11, b7)
    c.mac(a12, b6)
    c.mac(a13, b5)
    c.mac(a14, b4)
    c.mac(a15, b3)
    result[offset &+ 18] = c.storeAndShift()
    c.mac(a4, b15)
    c.mac(a5, b14)
    c.mac(a6, b13)
    c.mac(a7, b12)
    c.mac(a8, b11)
    c.mac(a9, b10)
    c.mac(a10, b9)
    c.mac(a11, b8)
    c.mac(a12, b7)
    c.mac(a13, b6)
    c.mac(a14, b5)
    c.mac(a15, b4)
    result[offset &+ 19] = c.storeAndShift()
    c.mac(a5, b15)
    c.mac(a6, b14)
    c.mac(a7, b13)
    c.mac(a8, b12)
    c.mac(a9, b11)
    c.mac(a10, b10)
    c.mac(a11, b9)
    c.mac(a12, b8)
    c.mac(a13, b7)
    c.mac(a14, b6)
    c.mac(a15, b5)
    result[offset &+ 20] = c.storeAndShift()
    c.mac(a6, b15)
    c.mac(a7, b14)
    c.mac(a8, b13)
    c.mac(a9, b12)
    c.mac(a10, b11)
    c.mac(a11, b10)
    c.mac(a12, b9)
    c.mac(a13, b8)
    c.mac(a14, b7)
    c.mac(a15, b6)
    result[offset &+ 21] = c.storeAndShift()
    c.mac(a7, b15)
    c.mac(a8, b14)
    c.mac(a9, b13)
    c.mac(a10, b12)
    c.mac(a11, b11)
    c.mac(a12, b10)
    c.mac(a13, b9)
    c.mac(a14, b8)
    c.mac(a15, b7)
    result[offset &+ 22] = c.storeAndShift()
    c.mac(a8, b15)
    c.mac(a9, b14)
    c.mac(a10, b13)
    c.mac(a11, b12)
    c.mac(a12, b11)
    c.mac(a13, b10)
    c.mac(a14, b9)
    c.mac(a15, b8)
    result[offset &+ 23] = c.storeAndShift()
    c.mac(a9, b15)
    c.mac(a10, b14)
    c.mac(a11, b13)
    c.mac(a12, b12)
    c.mac(a13, b11)
    c.mac(a14, b10)
    c.mac(a15, b9)
    result[offset &+ 24] = c.storeAndShift()
    c.mac(a10, b15)
    c.mac(a11, b14)
    c.mac(a12, b13)
    c.mac(a13, b12)
    c.mac(a14, b11)
    c.mac(a15, b10)
    result[offset &+ 25] = c.storeAndShift()
    c.mac(a11, b15)
    c.mac(a12, b14)
    c.mac(a13, b13)
    c.mac(a14, b12)
    c.mac(a15, b11)
    result[offset &+ 26] = c.storeAndShift()
    c.mac(a12, b15)
    c.mac(a13, b14)
    c.mac(a14, b13)
    c.mac(a15, b12)
    result[offset &+ 27] = c.storeAndShift()
    c.mac(a13, b15)
    c.mac(a14, b14)
    c.mac(a15, b13)
    result[offset &+ 28] = c.storeAndShift()
    c.mac(a14, b15)
    c.mac(a15, b14)
    result[offset &+ 29] = c.storeAndShift()
    c.mac(a15, b15)
    result[offset &+ 30] = c.storeAndShift()
    result[offset &+ 31] = c.low()
    return 32
}

@inline(never)
func squareCombaFixed16(_ x: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(x.count >= 16 && offset >= 0 && result.count - offset >= 32)
    // Cannot overflow: offset + 32 is at most result.count, so every offset &+ k below is an index in result.
    let a0 = x[0]
    let a1 = x[1]
    let a2 = x[2]
    let a3 = x[3]
    let a4 = x[4]
    let a5 = x[5]
    let a6 = x[6]
    let a7 = x[7]
    let a8 = x[8]
    let a9 = x[9]
    let a10 = x[10]
    let a11 = x[11]
    let a12 = x[12]
    let a13 = x[13]
    let a14 = x[14]
    let a15 = x[15]
    var c = CombaAccumulator()
    c.mac(a0, a0)
    result[offset &+ 0] = c.storeAndShift()
    c.macDoubled(a0, a1)
    result[offset &+ 1] = c.storeAndShift()
    c.macDoubled(a0, a2)
    c.mac(a1, a1)
    result[offset &+ 2] = c.storeAndShift()
    c.macDoubled(a0, a3)
    c.macDoubled(a1, a2)
    result[offset &+ 3] = c.storeAndShift()
    c.macDoubled(a0, a4)
    c.macDoubled(a1, a3)
    c.mac(a2, a2)
    result[offset &+ 4] = c.storeAndShift()
    c.macDoubled(a0, a5)
    c.macDoubled(a1, a4)
    c.macDoubled(a2, a3)
    result[offset &+ 5] = c.storeAndShift()
    c.macDoubled(a0, a6)
    c.macDoubled(a1, a5)
    c.macDoubled(a2, a4)
    c.mac(a3, a3)
    result[offset &+ 6] = c.storeAndShift()
    c.macDoubled(a0, a7)
    c.macDoubled(a1, a6)
    c.macDoubled(a2, a5)
    c.macDoubled(a3, a4)
    result[offset &+ 7] = c.storeAndShift()
    c.macDoubled(a0, a8)
    c.macDoubled(a1, a7)
    c.macDoubled(a2, a6)
    c.macDoubled(a3, a5)
    c.mac(a4, a4)
    result[offset &+ 8] = c.storeAndShift()
    c.macDoubled(a0, a9)
    c.macDoubled(a1, a8)
    c.macDoubled(a2, a7)
    c.macDoubled(a3, a6)
    c.macDoubled(a4, a5)
    result[offset &+ 9] = c.storeAndShift()
    c.macDoubled(a0, a10)
    c.macDoubled(a1, a9)
    c.macDoubled(a2, a8)
    c.macDoubled(a3, a7)
    c.macDoubled(a4, a6)
    c.mac(a5, a5)
    result[offset &+ 10] = c.storeAndShift()
    c.macDoubled(a0, a11)
    c.macDoubled(a1, a10)
    c.macDoubled(a2, a9)
    c.macDoubled(a3, a8)
    c.macDoubled(a4, a7)
    c.macDoubled(a5, a6)
    result[offset &+ 11] = c.storeAndShift()
    c.macDoubled(a0, a12)
    c.macDoubled(a1, a11)
    c.macDoubled(a2, a10)
    c.macDoubled(a3, a9)
    c.macDoubled(a4, a8)
    c.macDoubled(a5, a7)
    c.mac(a6, a6)
    result[offset &+ 12] = c.storeAndShift()
    c.macDoubled(a0, a13)
    c.macDoubled(a1, a12)
    c.macDoubled(a2, a11)
    c.macDoubled(a3, a10)
    c.macDoubled(a4, a9)
    c.macDoubled(a5, a8)
    c.macDoubled(a6, a7)
    result[offset &+ 13] = c.storeAndShift()
    c.macDoubled(a0, a14)
    c.macDoubled(a1, a13)
    c.macDoubled(a2, a12)
    c.macDoubled(a3, a11)
    c.macDoubled(a4, a10)
    c.macDoubled(a5, a9)
    c.macDoubled(a6, a8)
    c.mac(a7, a7)
    result[offset &+ 14] = c.storeAndShift()
    c.macDoubled(a0, a15)
    c.macDoubled(a1, a14)
    c.macDoubled(a2, a13)
    c.macDoubled(a3, a12)
    c.macDoubled(a4, a11)
    c.macDoubled(a5, a10)
    c.macDoubled(a6, a9)
    c.macDoubled(a7, a8)
    result[offset &+ 15] = c.storeAndShift()
    c.macDoubled(a1, a15)
    c.macDoubled(a2, a14)
    c.macDoubled(a3, a13)
    c.macDoubled(a4, a12)
    c.macDoubled(a5, a11)
    c.macDoubled(a6, a10)
    c.macDoubled(a7, a9)
    c.mac(a8, a8)
    result[offset &+ 16] = c.storeAndShift()
    c.macDoubled(a2, a15)
    c.macDoubled(a3, a14)
    c.macDoubled(a4, a13)
    c.macDoubled(a5, a12)
    c.macDoubled(a6, a11)
    c.macDoubled(a7, a10)
    c.macDoubled(a8, a9)
    result[offset &+ 17] = c.storeAndShift()
    c.macDoubled(a3, a15)
    c.macDoubled(a4, a14)
    c.macDoubled(a5, a13)
    c.macDoubled(a6, a12)
    c.macDoubled(a7, a11)
    c.macDoubled(a8, a10)
    c.mac(a9, a9)
    result[offset &+ 18] = c.storeAndShift()
    c.macDoubled(a4, a15)
    c.macDoubled(a5, a14)
    c.macDoubled(a6, a13)
    c.macDoubled(a7, a12)
    c.macDoubled(a8, a11)
    c.macDoubled(a9, a10)
    result[offset &+ 19] = c.storeAndShift()
    c.macDoubled(a5, a15)
    c.macDoubled(a6, a14)
    c.macDoubled(a7, a13)
    c.macDoubled(a8, a12)
    c.macDoubled(a9, a11)
    c.mac(a10, a10)
    result[offset &+ 20] = c.storeAndShift()
    c.macDoubled(a6, a15)
    c.macDoubled(a7, a14)
    c.macDoubled(a8, a13)
    c.macDoubled(a9, a12)
    c.macDoubled(a10, a11)
    result[offset &+ 21] = c.storeAndShift()
    c.macDoubled(a7, a15)
    c.macDoubled(a8, a14)
    c.macDoubled(a9, a13)
    c.macDoubled(a10, a12)
    c.mac(a11, a11)
    result[offset &+ 22] = c.storeAndShift()
    c.macDoubled(a8, a15)
    c.macDoubled(a9, a14)
    c.macDoubled(a10, a13)
    c.macDoubled(a11, a12)
    result[offset &+ 23] = c.storeAndShift()
    c.macDoubled(a9, a15)
    c.macDoubled(a10, a14)
    c.macDoubled(a11, a13)
    c.mac(a12, a12)
    result[offset &+ 24] = c.storeAndShift()
    c.macDoubled(a10, a15)
    c.macDoubled(a11, a14)
    c.macDoubled(a12, a13)
    result[offset &+ 25] = c.storeAndShift()
    c.macDoubled(a11, a15)
    c.macDoubled(a12, a14)
    c.mac(a13, a13)
    result[offset &+ 26] = c.storeAndShift()
    c.macDoubled(a12, a15)
    c.macDoubled(a13, a14)
    result[offset &+ 27] = c.storeAndShift()
    c.macDoubled(a13, a15)
    c.mac(a14, a14)
    result[offset &+ 28] = c.storeAndShift()
    c.macDoubled(a14, a15)
    result[offset &+ 29] = c.storeAndShift()
    c.mac(a15, a15)
    result[offset &+ 30] = c.storeAndShift()
    result[offset &+ 31] = c.low()
    return 32
}

// x * y into result[offset...] by the fixed-size kernel for x.count, which equals y.count, or nil when there is none
// of more than one digit.
@inline(always)
func multiplyCombaFixed(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int? {
    switch x.count {
    case 2:
        return multiplyCombaFixed2(x, y, &result, offset)
    case 4:
        return multiplyCombaFixed4(x, y, &result, offset)
    case 8:
        return multiplyCombaFixed8(x, y, &result, offset)
    case maxCombaFixedSize:
        return multiplyCombaFixed16(x, y, &result, offset)
    default:
        return nil
    }
}

// x * x into result[offset...] by the fixed-size kernel for x.count, or nil when there is none of more than one digit.
@inline(always)
func squareCombaFixed(_ x: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int? {
    switch x.count {
    case 2:
        return squareCombaFixed2(x, &result, offset)
    case 4:
        return squareCombaFixed4(x, &result, offset)
    case 8:
        return squareCombaFixed8(x, &result, offset)
    case maxCombaFixedSize:
        return squareCombaFixed16(x, &result, offset)
    default:
        return nil
    }
}

// Accumulates one column per digit of result[start ..< end], from a window of x sliding up by one digit per column,
// each digit of the window multiplied with y's digits from the top down: first windows of y.count digits, then,
// once fewer than that remain in x, the shrinking rest. Stops when the result or x runs out, and returns the index of
// the first result digit it did not write.
@inline(always)
func accumulateSlidingColumns(
    _ xWindow: Span<UInt64>,
    _ y: Span<UInt64>,
    _ result: inout MutableSpan<UInt64>,
    _ start: Int,
    _ end: Int,
    _ accumulator: inout DigitColumnAccumulator
) -> Int {
    precondition(start >= 0 && end <= result.count)
    var xWindow = xWindow
    var r = start
    let top = y.count - 1

    // Steady state
    while r < end && xWindow.count >= y.count {
        let xPart = xWindow.extracting(0..<y.count)
        // Two products per step: the column's sum does not depend on their order.
        var k = 0
        while k < top {
            accumulator.mac(xPart[k], y[top - k])
            accumulator.mac(xPart[k + 1], y[top - k - 1])
            // k is below top, a digit index, so this cannot overflow.
            k &+= 2
        }
        if k == top {
            accumulator.mac(xPart[k], y[0])
        }
        result[r] = accumulator.storeAndShift()
        r += 1
        xWindow = xWindow.extracting(droppingFirst: 1)
    }

    // Shrinking: each column pairs xWindow with as many of the top digits of y.
    while r < end && !xWindow.isEmpty {
        let width = xWindow.count
        let yPart = y.extracting((y.count - width)..<y.count)
        for k in 0..<width {
            accumulator.mac(xWindow[k], yPart[width - 1 - k])
        }
        result[r] = accumulator.storeAndShift()
        r += 1
        xWindow = xWindow.extracting(droppingFirst: 1)
    }

    return r
}

// result[offset ..< offset + x.count + 1] := multiplicand * multiplier. Returns multiplicand.count + 1.
func multiplySingle(_ multiplicand: Span<UInt64>, _ multiplier: UInt64, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    // offset + i is at most result.count, so this arithmetic cannot overflow.
    precondition(result.count &- offset > multiplicand.count)
    var carry: UInt64 = 0
    var high: UInt64 = 0
    var i = 0
    while i < multiplicand.count {
        let (low, newHigh) = digitMul(multiplicand[i], multiplier)
        var newCarry: UInt64 = 0
        result[offset &+ i] = digitAdd3(low, high, carry, &newCarry)
        high = newHigh
        carry = newCarry
        i += 1
    }
    // high <= 2^digitBits - 2, so adding the carry cannot overflow.
    result[offset &+ i] = carry &+ high
    return i &+ 1
}

// result[offset ..< offset + x.count + y.count] := x * y. Returns x.count + y.count.
// O(n^2) "schoolbook" multiplication algorithm. Rather than looping over X for every digit of Y (or vice versa), it
// loops over Z. foldProduct below folds one product of relevant digits of X and Y into the digit of Z being computed.
// This yields a nearly 2x improvement compared to more obvious implementations.
// This function is *highly* performance sensitive even for the advanced algorithms, which use it as the base case of
// their recursive calls.
func multiplySchoolbook(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(!y.isEmpty)
    precondition(x.count >= y.count)
    // The counts are digit counts and offset an index into result, so this index arithmetic cannot overflow.
    let fullSize = x.count &+ y.count
    precondition(result.count &- offset >= fullSize)

    // zi is the digit of Z being computed and next the carry into the one above it, each with its own carry counter.
    // They live across columns, so foldProduct can take just the two digits.
    var zi: UInt64 = 0
    var next: UInt64 = 0
    var nextCarry: UInt64 = 0
    var carry: UInt64 = 0
    @inline(always)
    func foldProduct(_ xDigit: UInt64, _ yDigit: UInt64) {
        let (low, high) = digitMul(xDigit, yDigit)
        zi = digitAdd(zi, low, &carry)
        next = digitAdd(next, high, &nextCarry)
    }
    // Starts a column from the carries of the one below it.
    @inline(always)
    func startColumn() {
        var temp: UInt64 = 0
        zi = digitAdd(next, carry, &temp)
        // nextCarry counts at most one carry per product of a column, so adding one more cannot overflow.
        next = nextCarry &+ temp
        carry = 0
        nextCarry = 0
    }

    let xHead = x.extracting(0..<y.count)
    let headCount = y.count

    // Unrolled first iteration: it's trivial.
    do {
        let (low, high) = digitMul(xHead[0], y[0])
        result[offset] = low
        next = high
    }
    var i = 1
    // Unrolled second iteration: a little less setup.
    if i < headCount {
        zi = next
        next = 0
        for j in 0...1 {
            foldProduct(xHead[j], y[i - j])
        }
        result[offset &+ i] = zi
        i += 1
    }

    // Main part: since x.count >= y.count > i, every index is in bounds.
    while i < headCount {
        startColumn()
        let xPart = xHead.extracting(0..<(i + 1))
        let yPart = y.extracting(0..<(i + 1))
        for j in 0..<xPart.count {
            foldProduct(xPart[j], yPart[i - j])
        }
        result[offset &+ i] = zi
        i += 1
    }

    // Last part: i exceeds y now, so each remaining column but the last is a sliding window over x.
    var xWindow = x.extracting(droppingFirst: 1)
    let top = y.count - 1
    var r = offset &+ headCount
    let end = offset &+ fullSize
    while r < end && xWindow.count >= y.count {
        let xPart = xWindow.extracting(0..<y.count)
        startColumn()
        for k in 0..<xPart.count {
            foldProduct(xPart[k], y[top - k])
        }
        result[r] = zi
        r += 1
        xWindow = xWindow.extracting(droppingFirst: 1)
    }
    while r < end && !xWindow.isEmpty {
        let width = xWindow.count
        let yPart = y.extracting((y.count - width)..<y.count)
        startColumn()
        for k in 0..<width {
            foldProduct(xWindow[k], yPart[width - 1 - k])
        }
        result[r] = zi
        r += 1
        xWindow = xWindow.extracting(droppingFirst: 1)
    }

    // Write the last digit.
    var temp: UInt64 = 0
    result[end &- 1] = digitAdd(next, carry, &temp)
    assert(temp == 0)
    return fullSize
}

// For the needs of cachedMod, computes only the low digits of x * y, into result[range].
func multiplySpecialLow(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ range: Range<Int>) {
    precondition(y.count >= 1)
    precondition(x.count >= 2)
    precondition(x.count >= y.count - 1)
    precondition(!range.isEmpty && range.upperBound <= result.count)

    let base = range.lowerBound
    var accumulator = DigitColumnAccumulator()
    // range is a range of indices into result and the counts are digit counts, so this arithmetic cannot overflow.
    let lastColumn = range.upperBound &- range.lowerBound &- 1
    var column = 0

    // Expanding phase: both operands still cover the whole column, so the term range is exactly [0, column] and
    // needs no clamping.
    let headCount = min(x.count, y.count, lastColumn)
    let xHead = x.extracting(0..<headCount)
    let yHead = y.extracting(0..<headCount)
    while column < headCount {
        let xPart = xHead.extracting(0..<(column + 1))
        let yPart = yHead.extracting(0..<(column + 1))
        for k in 0..<xPart.count {
            accumulator.mac(xPart[k], yPart[column - k])
        }
        result[base &+ column] = accumulator.storeAndShift()
        column += 1
    }

    // The expanding phase stops short of y only when x or the result runs out first, so at most one column is still
    // clipped at the y end. Peel it, and the rest is the sliding window over x.
    if column < y.count && column <= lastColumn {
        let yPart = y.extracting(0..<(column + 1))
        let xPart = x.extracting(0..<min(x.count, yPart.count))
        let top = yPart.count - 1
        for k in 0..<xPart.count {
            accumulator.mac(xPart[k], yPart[top &- k])
        }
        result[base &+ column] = accumulator.storeAndShift()
        column += 1
    }

    if column > lastColumn {
        return
    }

    assert(column >= y.count)
    let xWindow = x.extracting(droppingFirst: min(column &+ 1 &- y.count, x.count))
    var r = accumulateSlidingColumns(xWindow, y, &result, base &+ column, range.upperBound, &accumulator)
    // Columns past the end of x have no terms of their own and only flush the accumulator.
    while r < range.upperBound {
        result[r] = accumulator.storeAndShift()
        r += 1
    }
}

// For the needs of cachedMod, computes only the product digits from startPosition onward, into result[offset...],
// where result[offset + startPosition] is product digit startPosition. The accumulator state from positions below
// startPosition is lost, so the computed digits are an *approximate* value.
func multiplySpecialHigh(
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ result: inout MutableSpan<UInt64>,
    _ offset: Int,
    _ startPosition: Int
) {
    precondition(y.count >= 1)
    precondition(x.count >= y.count)
    // The counts are digit counts and offset an index into result, so this index arithmetic cannot overflow.
    let fullSize = x.count &+ y.count
    precondition(startPosition >= 0 && startPosition < fullSize)
    precondition(result.count &- offset >= fullSize)

    var accumulator = DigitColumnAccumulator()
    var column = startPosition

    // Expanding phase: column < y.count, so the term range starts at 0.
    while column < y.count {
        let xPart = x.extracting(0..<(column + 1))
        let yPart = y.extracting(0..<(column + 1))
        for (k, j) in zip(xPart.indices, yPart.indices.reversed()) {
            accumulator.mac(xPart[k], yPart[j])
        }
        result[offset &+ column] = accumulator.storeAndShift()
        column += 1
    }

    // x runs out one column before the result does, so the walk leaves exactly the last column.
    let end = offset &+ fullSize
    let trailing = accumulateSlidingColumns(
        x.extracting(droppingFirst: column &+ 1 &- y.count),
        y,
        &result,
        offset &+ column,
        end,
        &accumulator
    )
    assert(trailing == end - 1)

    assert(accumulator.fitsInLow())
    result[end &- 1] = accumulator.low()
}

// multiplySchoolbook unrolls its first two columns, so it is faster for short operands. Product scanning, one
// add-with-carry chain per column, is faster for long columns and very thin operands.
let minCombaSmallerSize = 8
let maxCombaThinSmallerSize = 2
let minCombaThinLargerSize = 16

@inline(always)
func shouldUseComba(_ largerSize: Int, _ smallerSize: Int) -> Bool {
    smallerSize >= minCombaSmallerSize || (smallerSize <= maxCombaThinSmallerSize && largerSize >= minCombaThinLargerSize)
}

// result[offset ..< offset + x.count + y.count] := x * y by product scanning. Each column's running sum lives in three
// digits, so every product feeds a single add-with-carry chain instead of materializing a carry bit per addend.
// Returns x.count + y.count.
func multiplyComba(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    precondition(!y.isEmpty)
    precondition(x.count >= y.count)
    // The counts are digit counts and offset an index into result, so this index arithmetic cannot overflow.
    let fullSize = x.count &+ y.count
    precondition(result.count &- offset >= fullSize)

    var accumulator = DigitColumnAccumulator()

    // Ramp up: every column starts at x[0], because y does not yet reach back that far.
    var i = 0
    while i < y.count {
        let xPart = x.extracting(0..<(i + 1))
        let yPart = y.extracting(0..<(i + 1))
        for k in 0..<xPart.count {
            accumulator.mac(xPart[k], yPart[i - k])
        }
        result[offset &+ i] = accumulator.storeAndShift()
        i += 1
    }

    _ = accumulateSlidingColumns(
        x.extracting(droppingFirst: 1),
        y,
        &result,
        offset &+ i,
        offset &+ i &+ x.count &- 1,
        &accumulator
    )

    assert(accumulator.fitsInLow())
    result[offset &+ fullSize &- 1] = accumulator.low()
    return fullSize
}

// x[offset ..< offset + length], cut short where x ends.
@_lifetime(copy x)
@inline(always)
func clampedSubspan(_ x: Span<UInt64>, _ offset: Int, _ length: Int) -> Span<UInt64> {
    if offset >= x.count {
        return x.extracting(x.count..<x.count)
    }
    return x.extracting(droppingFirst: offset).extracting(first: length)
}

// The length of clampedSubspan(x, offset, length) for an x of `count` digits.
@inline(always)
func clampedCount(_ count: Int, _ offset: Int, _ length: Int) -> Int {
    if offset >= count {
        return 0
    }
    // offset is below count, a digit count, so this cannot overflow.
    return min(length, count &- offset)
}

// z[zStart ..< zStart + zCount] += x, carrying through the whole range at most. Returns the carry that is left.
func inplaceAddAndPropagate(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ x: Span<UInt64>) -> UInt64 {
    let x = normalize(x)
    // zStart is an index into z and the counts are digit counts, so this arithmetic cannot overflow.
    precondition(zCount >= x.count && z.count &- zStart >= zCount)
    var carry = inplaceAdd(&z, zStart, x)
    var i = x.count
    while i < zCount && carry != 0 {
        var newCarry: UInt64 = 0
        z[zStart &+ i] = digitAdd(z[zStart &+ i], carry, &newCarry)
        carry = newCarry
        i += 1
    }
    return carry
}

// z[zStart ..< zStart + zCount] -= x, borrowing through the whole range at most. Returns the borrow that is left.
func inplaceSubAndPropagate(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ x: Span<UInt64>) -> UInt64 {
    let x = normalize(x)
    // zStart is an index into z and the counts are digit counts, so this arithmetic cannot overflow.
    precondition(zCount >= x.count && z.count &- zStart >= zCount)
    var borrow = inplaceSub(&z, zStart, x)
    var i = x.count
    while i < zCount && borrow != 0 {
        var newBorrow: UInt64 = 0
        z[zStart &+ i] = digitSub(z[zStart &+ i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    return borrow
}

// inplaceAddAndPropagate for a z and an x that are disjoint ranges of the same digits, x at
// digits[xStart ..< xStart + xCount].
func inplaceAddAndPropagate(_ digits: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ xStart: Int, _ xCount: Int) -> UInt64 {
    precondition(zStart >= 0 && xStart >= 0 && xCount >= 0 && digits.count - xStart >= xCount)
    let xCount = normalizedCount(digits, xStart, xCount)
    precondition(zCount >= xCount && digits.count - zStart >= zCount)
    var carry: UInt64 = 0
    var i = 0
    while i < xCount {
        var newCarry: UInt64 = 0
        digits[zStart + i] = digitAdd3(digits[zStart + i], digits[xStart + i], carry, &newCarry)
        carry = newCarry
        i += 1
    }
    // zStart + i is below digits.count, so it cannot overflow.
    while i < zCount && carry != 0 {
        var newCarry: UInt64 = 0
        digits[zStart &+ i] = digitAdd(digits[zStart &+ i], carry, &newCarry)
        carry = newCarry
        i += 1
    }
    return carry
}

// inplaceSubAndPropagate for a z and an x that are disjoint ranges of the same digits, x at
// digits[xStart ..< xStart + xCount].
func inplaceSubAndPropagate(_ digits: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ xStart: Int, _ xCount: Int) -> UInt64 {
    precondition(zStart >= 0 && xStart >= 0 && xCount >= 0 && digits.count - xStart >= xCount)
    let xCount = normalizedCount(digits, xStart, xCount)
    precondition(zCount >= xCount && digits.count - zStart >= zCount)
    var borrow: UInt64 = 0
    var i = 0
    while i < xCount {
        var newBorrow: UInt64 = 0
        digits[zStart + i] = digitSub2(digits[zStart + i], digits[xStart + i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    // zStart + i is below digits.count, so it cannot overflow.
    while i < zCount && borrow != 0 {
        var newBorrow: UInt64 = 0
        digits[zStart &+ i] = digitSub(digits[zStart &+ i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    return borrow
}

// z[zStart ..< zStart + zCount] := x * y, zero-padded. With isSquare, y is x.
func multiplyZeroPadded(
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ isSquare: Bool,
    _ z: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int
) {
    // zStart is an index into z and zCount a digit count, so this cannot overflow.
    precondition(z.count &- zStart >= zCount)
    let length = multiplyDigitsNormalized(x, y, isSquare, &z, zStart, zCount)
    // zStart + i is below z.count, so it cannot overflow.
    precondition(zStart >= 0)
    for i in length..<zCount {
        z[zStart &+ i] = 0
    }
}

// Karatsuba multiplication, ported from V8 [1], which is in turn based on Go's math/big [2].
//
// [1]: https://source.chromium.org/chromium/chromium/src/+/main:v8/src/bigint/mul-karatsuba.cc
// [2]: https://go.dev/src/math/big/nat.go
let karatsubaThreshold = 44

func karatsubaRoundUpLength(_ length: Int) -> Int {
    if length <= 36 {
        return (length + 1) & ~1
    }
    var shift = Int.bitWidth - length.leadingZeroBitCount - 5
    if (length &>> shift) >= 0x18 {
        shift += 1
    }
    let additive = (1 &<< shift) - 1
    if shift >= 2 && (length & additive) < (1 &<< (shift - 2)) {
        return length
    }
    // length is a digit count and additive is below it, so this cannot overflow.
    return ((length &+ additive) &>> shift) &<< shift
}

// Returns a chunk width k for splitting an n-digit operand. Callers size product buffers as 2 * k and fill them
// with up to n digits, so they need 2 * k >= n. That holds with room to spare because the loop below halves n only
// until it reaches karatsubaThreshold, leaving the re-shift to discard far less than half.
func karatsubaLength(_ n: Int) -> Int {
    var n = karatsubaRoundUpLength(n)
    var i = 0
    while n > karatsubaThreshold {
        n &>>= 1
        i += 1
    }
    return n &<< i
}

// result[start ..< start + count] := |x - y|, zero-padded. Toggles negative if x < y.
func karatsubaAbsoluteDifference(
    _ result: inout MutableSpan<UInt64>,
    _ start: Int,
    _ count: Int,
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ negative: inout Bool
) {
    let x = normalize(x)
    let y = normalize(y)
    if compareDigits(x, y) < 0 {
        negative = !negative
        karatsubaAbsoluteDifferenceOrdered(&result, start, count, y, x)
        return
    }
    karatsubaAbsoluteDifferenceOrdered(&result, start, count, x, y)
}

@inline(always)
func karatsubaAbsoluteDifferenceOrdered(
    _ result: inout MutableSpan<UInt64>,
    _ start: Int,
    _ count: Int,
    _ x: Span<UInt64>,
    _ y: Span<UInt64>
) {
    precondition(count >= x.count)
    let length = subSchoolbook(x, y, &result, start)
    // start + i is below result.count, so it cannot overflow.
    precondition(start >= 0)
    for i in length..<count {
        result[start &+ i] = 0
    }
}

// karatsubaAbsoluteDifference for a result and operands that are disjoint ranges of the same digits.
func karatsubaAbsoluteDifference(
    _ digits: inout MutableSpan<UInt64>,
    _ start: Int,
    _ count: Int,
    _ xStart: Int,
    _ xCount: Int,
    _ yStart: Int,
    _ yCount: Int,
    _ negative: inout Bool
) {
    precondition(
        start >= 0 && xStart >= 0 && yStart >= 0 && xCount >= 0 && yCount >= 0 && digits.count - xStart >= xCount
            && digits.count - yStart >= yCount
    )
    var xStart = xStart
    var yStart = yStart
    var xCount = normalizedCount(digits, xStart, xCount)
    var yCount = normalizedCount(digits, yStart, yCount)
    if compareDigits(
        digits.span.extracting(droppingFirst: xStart).extracting(0..<xCount),
        digits.span.extracting(droppingFirst: yStart).extracting(0..<yCount)
    ) < 0 {
        negative = !negative
        swap(&xStart, &yStart)
        swap(&xCount, &yCount)
    }
    precondition(xCount >= yCount && count >= xCount && digits.count - start >= count)
    var borrow: UInt64 = 0
    var i = 0
    // start, xStart and yStart are indices into digits and i is below the counts, so this arithmetic cannot overflow.
    while i < yCount {
        var newBorrow: UInt64 = 0
        digits[start &+ i] = digitSub2(digits[xStart &+ i], digits[yStart &+ i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    while i < xCount {
        var newBorrow: UInt64 = 0
        digits[start &+ i] = digitSub(digits[xStart &+ i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    assert(borrow == 0)
    // start + i is below digits.count, so it cannot overflow.
    while i < count {
        digits[start &+ i] = 0
        i += 1
    }
}

// z[zStart ..< zStart + zCount] := x * y for operands of at most n digits, n even unless below
// karatsubaThreshold, using scratch[scratchStart ..< scratchStart + 4n]. With isSquare, y is x.
//
// Each level computes p0 = x0 * y0 into scratch[0, n), p2 = x1 * y1 into scratch[n, 2n), then |x1 - x0| and
// |y0 - y1| into scratch[0, n) and their product p1 into scratch[n, 2n), recursing into scratch[2n, 4n). The two
// karatsubaMainInScratch functions below are this one for a z in the scratch, with operands outside it or within
// it.
func karatsubaMain(
    _ z: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ isSquare: Bool,
    _ scratch: inout MutableSpan<UInt64>,
    _ scratchStart: Int,
    _ n: Int
) {
    if n < karatsubaThreshold {
        precondition(zCount >= 2 * n)
        multiplyZeroPadded(x, y, isSquare, &z, zStart, 2 * n)
        return
    }
    precondition(n <= Int.max / 4)
    // The offsets below index z and scratch, and n is at most Int.max / 4, so this arithmetic cannot overflow.
    precondition(scratch.count &- scratchStart >= 4 * n)
    precondition(zCount >= n && z.count &- zStart >= zCount)
    assert(n & 1 == 0)
    let n2 = n &>> 1
    let x0 = clampedSubspan(x, 0, n2)
    let x1 = clampedSubspan(x, n2, n2)
    let y0 = clampedSubspan(y, 0, n2)
    let y1 = clampedSubspan(y, n2, n2)
    let p0Start = scratchStart
    let p2Start = scratchStart &+ n
    let recursionStart = scratchStart &+ 2 &* n

    karatsubaMainInScratch(&scratch, p0Start, n, x0, y0, isSquare, recursionStart, n2)
    // The indices below are below the counts of their spans, so they cannot overflow.
    precondition(zStart >= 0 && p0Start >= 0)
    for i in 0..<n {
        z[zStart &+ i] = scratch[p0Start &+ i]
    }

    karatsubaMainInScratch(&scratch, p2Start, n, x1, y1, isSquare, recursionStart, n2)
    let z2Count = clampedCount(zCount, n, n)
    for i in 0..<z2Count {
        z[zStart &+ n &+ i] = scratch[p2Start &+ i]
    }
    assert(normalizedCount(scratch, p2Start, n) <= z2Count)

    // overflow sums carries and borrows that cancel out, so it wraps on purpose.
    var overflow = inplaceAddAndPropagate(&z, zStart &+ n2, zCount &- n2, scratch.span.extracting(droppingFirst: p0Start).extracting(0..<n))
    overflow &+= inplaceAddAndPropagate(&z, zStart &+ n2, zCount &- n2, scratch.span.extracting(droppingFirst: p2Start).extracting(0..<n))

    var negative = false
    karatsubaAbsoluteDifference(&scratch, scratchStart, n2, x1, x0, &negative)
    karatsubaAbsoluteDifference(&scratch, scratchStart &+ n2, n2, y0, y1, &negative)
    let p1Start = scratchStart &+ n
    karatsubaMainInScratch(&scratch, p1Start, n, scratchStart, n2, scratchStart &+ n2, n2, recursionStart, n2)
    if negative {
        overflow &-= inplaceSubAndPropagate(
            &z,
            zStart &+ n2,
            zCount &- n2,
            scratch.span.extracting(droppingFirst: p1Start).extracting(0..<n)
        )
    } else {
        overflow &+= inplaceAddAndPropagate(
            &z,
            zStart &+ n2,
            zCount &- n2,
            scratch.span.extracting(droppingFirst: p1Start).extracting(0..<n)
        )
    }
    assert(overflow == 0)
}

// karatsubaMain for a z at scratch[zStart ..< zStart + zCount], below scratchStart.
func karatsubaMainInScratch(
    _ scratch: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ isSquare: Bool,
    _ scratchStart: Int,
    _ n: Int
) {
    if n < karatsubaThreshold {
        precondition(zCount >= 2 * n)
        multiplyZeroPadded(x, y, isSquare, &scratch, zStart, 2 * n)
        return
    }
    precondition(n <= Int.max / 4)
    // The offsets below are indices into scratch, and n is at most Int.max / 4, so this arithmetic cannot overflow.
    precondition(scratch.count &- scratchStart >= 4 * n)
    precondition(zCount >= n)
    assert(zStart + zCount <= scratchStart)
    assert(n & 1 == 0)
    let n2 = n &>> 1
    let x0 = clampedSubspan(x, 0, n2)
    let x1 = clampedSubspan(x, n2, n2)
    let y0 = clampedSubspan(y, 0, n2)
    let y1 = clampedSubspan(y, n2, n2)
    let p0Start = scratchStart
    let p2Start = scratchStart &+ n
    let recursionStart = scratchStart &+ 2 &* n

    karatsubaMainInScratch(&scratch, p0Start, n, x0, y0, isSquare, recursionStart, n2)
    // The indices below are below the counts of their spans, so they cannot overflow.
    precondition(zStart >= 0 && p0Start >= 0)
    for i in 0..<n {
        scratch[zStart &+ i] = scratch[p0Start &+ i]
    }

    karatsubaMainInScratch(&scratch, p2Start, n, x1, y1, isSquare, recursionStart, n2)
    let z2Count = clampedCount(zCount, n, n)
    for i in 0..<z2Count {
        scratch[zStart &+ n &+ i] = scratch[p2Start &+ i]
    }
    assert(normalizedCount(scratch, p2Start, n) <= z2Count)

    // overflow sums carries and borrows that cancel out, so it wraps on purpose.
    var overflow = inplaceAddAndPropagate(&scratch, zStart &+ n2, zCount &- n2, p0Start, n)
    overflow &+= inplaceAddAndPropagate(&scratch, zStart &+ n2, zCount &- n2, p2Start, n)

    var negative = false
    karatsubaAbsoluteDifference(&scratch, scratchStart, n2, x1, x0, &negative)
    karatsubaAbsoluteDifference(&scratch, scratchStart &+ n2, n2, y0, y1, &negative)
    let p1Start = scratchStart &+ n
    karatsubaMainInScratch(&scratch, p1Start, n, scratchStart, n2, scratchStart &+ n2, n2, recursionStart, n2)
    if negative {
        overflow &-= inplaceSubAndPropagate(&scratch, zStart &+ n2, zCount &- n2, p1Start, n)
    } else {
        overflow &+= inplaceAddAndPropagate(&scratch, zStart &+ n2, zCount &- n2, p1Start, n)
    }
    assert(overflow == 0)
}

// karatsubaMain for a z at scratch[zStart ..< zStart + zCount] and operands at scratch[xStart ..< xStart + xCount]
// and scratch[yStart ..< yStart + yCount], all below scratchStart. The operands are differences, so this is never a
// square.
func karatsubaMainInScratch(
    _ scratch: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ xStart: Int,
    _ xCount: Int,
    _ yStart: Int,
    _ yCount: Int,
    _ scratchStart: Int,
    _ n: Int
) {
    if n < karatsubaThreshold {
        precondition(zCount >= 2 * n)
        // The product goes into the digits the operands live in, so it reads them from copies. Each operand has at
        // most n digits.
        precondition(xCount <= n && yCount <= n)
        var xDigits = [43 of UInt64](repeating: 0)
        var yDigits = [43 of UInt64](repeating: 0)
        var xCopy = xDigits.mutableSpan
        var yCopy = yDigits.mutableSpan
        // xStart + i and yStart + i are below scratch.count, so they cannot overflow.
        for i in 0..<xCount {
            xCopy[i] = scratch[xStart &+ i]
        }
        for i in 0..<yCount {
            yCopy[i] = scratch[yStart &+ i]
        }
        multiplyZeroPadded(xCopy.span.extracting(0..<xCount), yCopy.span.extracting(0..<yCount), false, &scratch, zStart, 2 * n)
        return
    }
    precondition(n <= Int.max / 4)
    // The offsets below are indices into scratch, and n is at most Int.max / 4, so this arithmetic cannot overflow.
    precondition(scratch.count &- scratchStart >= 4 * n)
    precondition(zCount >= n)
    assert(zStart + zCount <= scratchStart && xStart + xCount <= scratchStart && yStart + yCount <= scratchStart)
    assert(n & 1 == 0)
    let n2 = n &>> 1
    let x0Count = clampedCount(xCount, 0, n2)
    let x1Count = clampedCount(xCount, n2, n2)
    let y0Count = clampedCount(yCount, 0, n2)
    let y1Count = clampedCount(yCount, n2, n2)
    let x1Start = xStart &+ min(n2, xCount)
    let y1Start = yStart &+ min(n2, yCount)
    let p0Start = scratchStart
    let p2Start = scratchStart &+ n
    let recursionStart = scratchStart &+ 2 &* n

    karatsubaMainInScratch(&scratch, p0Start, n, xStart, x0Count, yStart, y0Count, recursionStart, n2)
    // The indices below are below the counts of their spans, so they cannot overflow.
    precondition(zStart >= 0 && p0Start >= 0)
    for i in 0..<n {
        scratch[zStart &+ i] = scratch[p0Start &+ i]
    }

    karatsubaMainInScratch(&scratch, p2Start, n, x1Start, x1Count, y1Start, y1Count, recursionStart, n2)
    let z2Count = clampedCount(zCount, n, n)
    for i in 0..<z2Count {
        scratch[zStart &+ n &+ i] = scratch[p2Start &+ i]
    }
    assert(normalizedCount(scratch, p2Start, n) <= z2Count)

    // overflow sums carries and borrows that cancel out, so it wraps on purpose.
    var overflow = inplaceAddAndPropagate(&scratch, zStart &+ n2, zCount &- n2, p0Start, n)
    overflow &+= inplaceAddAndPropagate(&scratch, zStart &+ n2, zCount &- n2, p2Start, n)

    var negative = false
    karatsubaAbsoluteDifference(&scratch, scratchStart, n2, x1Start, x1Count, xStart, x0Count, &negative)
    karatsubaAbsoluteDifference(&scratch, scratchStart &+ n2, n2, yStart, y0Count, y1Start, y1Count, &negative)
    let p1Start = scratchStart &+ n
    karatsubaMainInScratch(&scratch, p1Start, n, scratchStart, n2, scratchStart &+ n2, n2, recursionStart, n2)
    if negative {
        overflow &-= inplaceSubAndPropagate(&scratch, zStart &+ n2, zCount &- n2, p1Start, n)
    } else {
        overflow &+= inplaceAddAndPropagate(&scratch, zStart &+ n2, zCount &- n2, p1Start, n)
    }
    assert(overflow == 0)
}

// z[zStart ..< zStart + zCount] := x * y, with leading zeros ignored, zero-padded. With isSquare, y is x.
func karatsubaChunk(
    _ z: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ isSquare: Bool,
    _ scratch: inout MutableSpan<UInt64>
) {
    let x = normalize(x)
    let y = normalize(y)
    if x.count < y.count {
        karatsubaChunk(&z, zStart, zCount, y, x, isSquare, &scratch)
        return
    }
    if y.count < karatsubaThreshold {
        multiplyZeroPadded(x, y, isSquare, &z, zStart, zCount)
        return
    }
    karatsubaStart(&z, zStart, zCount, x, y, isSquare, &scratch, karatsubaLength(y.count))
}

// z[zStart ..< zStart + zCount] := x * y, zero-padded, in k-digit chunks of x. With isSquare, y is x.
func karatsubaStart(
    _ z: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ isSquare: Bool,
    _ scratch: inout MutableSpan<UInt64>,
    _ k: Int
) {
    // zStart indexes z, and i, k and the counts are digit counts, so the index arithmetic below cannot overflow.
    // The chunk loop below indexes z at offsets below x.count + y.count; these two bounds are what prove those
    // offsets in range.
    precondition(y.count <= zCount)
    precondition(x.count <= zCount &- y.count)
    karatsubaMain(&z, zStart, zCount, x, y, isSquare, &scratch, 0, k)
    if zCount > 2 * k {
        // zStart + i is below z.count, so it cannot overflow.
        precondition(zStart >= 0)
        for i in (2 * k)..<zCount {
            z[zStart &+ i] = 0
        }
    }
    if k >= x.count {
        return
    }

    var chunkProduct = UniqueArray<UInt64>(repeating: 0, count: 2 * k)
    let x0 = x.extracting(0..<k)
    let y0 = clampedSubspan(y, 0, k)
    let y1 = clampedSubspan(y, k, y.count)
    // overflow only feeds the assertion below, and sums carries that are all 0.
    var overflow: UInt64 = 0
    if !y1.isEmpty {
        do {
            var product = chunkProduct.mutableSpan
            karatsubaChunk(&product, 0, 2 * k, x0, y1, false, &scratch)
        }
        overflow &+= inplaceAddAndPropagate(&z, zStart &+ k, zCount &- k, chunkProduct.span)
    }
    var i = k
    while i < x.count {
        let xi = clampedSubspan(x, i, k)
        do {
            var product = chunkProduct.mutableSpan
            karatsubaChunk(&product, 0, 2 * k, xi, y0, false, &scratch)
        }
        overflow &+= inplaceAddAndPropagate(&z, zStart &+ i, zCount &- i, chunkProduct.span)
        if !y1.isEmpty {
            do {
                var product = chunkProduct.mutableSpan
                karatsubaChunk(&product, 0, 2 * k, xi, y1, false, &scratch)
            }
            overflow &+= inplaceAddAndPropagate(&z, zStart &+ i &+ k, zCount &- i &- k, chunkProduct.span)
        }
        i &+= k
    }
    assert(overflow == 0)
}

// result[offset ..< offset + x.count + y.count] := x * y, with x.count >= y.count >= karatsubaThreshold. With
// isSquare, y is x. Returns x.count + y.count.
func multiplyKaratsuba(_ x: Span<UInt64>, _ y: Span<UInt64>, _ isSquare: Bool, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    assert(x.count >= y.count)
    // The counts are digit counts and offset an index into result, so this index arithmetic cannot overflow.
    let fullSize = x.count &+ y.count
    precondition(result.count &- offset >= fullSize)
    let k = karatsubaLength(y.count)
    var scratch = UniqueArray<UInt64>(repeating: 0, count: 4 * k)
    var scratchDigits = scratch.mutableSpan
    karatsubaStart(&result, offset, fullSize, x, y, isSquare, &scratchDigits, k)
    return fullSize
}

// Toom-3 multiplication, ported from V8 [1], which follows Wikipedia's description [2].
//
// [1]: https://source.chromium.org/chromium/chromium/src/+/main:v8/src/bigint/mul-toom.cc
// [2]: https://en.wikipedia.org/wiki/Toom%E2%80%93Cook_multiplication
let toom3Threshold = 508

// z[zStart ..< zStart + zCount] := x + y, zero-padded.
func addZeroPadded(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ x: Span<UInt64>, _ y: Span<UInt64>) {
    if x.count < y.count {
        addZeroPadded(&z, zStart, zCount, y, x)
        return
    }
    // zStart is an index into z and i is below zCount, so this index arithmetic cannot overflow.
    precondition(zCount >= x.count && z.count &- zStart >= zCount)
    var carry: UInt64 = 0
    var i = 0
    while i < y.count {
        var newCarry: UInt64 = 0
        z[zStart &+ i] = digitAdd3(x[i], y[i], carry, &newCarry)
        carry = newCarry
        i += 1
    }
    while i < x.count {
        var newCarry: UInt64 = 0
        z[zStart &+ i] = digitAdd(x[i], carry, &newCarry)
        carry = newCarry
        i += 1
    }
    while i < zCount {
        z[zStart &+ i] = carry
        carry = 0
        i += 1
    }
}

// z[zStart ..< zStart + zCount] += y, dropping the carry out of the top.
func addZeroPaddedInPlace(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ y: Span<UInt64>) {
    // zStart is an index into z and i is below zCount, so this index arithmetic cannot overflow.
    precondition(zCount >= y.count && z.count &- zStart >= zCount)
    var carry: UInt64 = 0
    var i = 0
    while i < y.count {
        var newCarry: UInt64 = 0
        z[zStart &+ i] = digitAdd3(z[zStart &+ i], y[i], carry, &newCarry)
        carry = newCarry
        i += 1
    }
    while i < zCount {
        var newCarry: UInt64 = 0
        z[zStart &+ i] = digitAdd(z[zStart &+ i], carry, &newCarry)
        carry = newCarry
        i += 1
    }
}

// z[zStart ..< zStart + zCount] := x - y for normalized x >= y, zero-padded.
func subZeroPadded(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ x: Span<UInt64>, _ y: Span<UInt64>) {
    precondition(x.count >= y.count)
    // zStart is an index into z and i is below zCount, so this index arithmetic cannot overflow.
    precondition(zCount >= x.count && z.count &- zStart >= zCount)
    var borrow: UInt64 = 0
    var i = 0
    while i < y.count {
        var newBorrow: UInt64 = 0
        z[zStart &+ i] = digitSub2(x[i], y[i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    while i < x.count {
        var newBorrow: UInt64 = 0
        z[zStart &+ i] = digitSub(x[i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    assert(borrow == 0)
    // zStart + i is below z.count, so it cannot overflow.
    precondition(zStart >= 0)
    while i < zCount {
        z[zStart &+ i] = 0
        i += 1
    }
}

// z[zStart ..< zStart + zCount] := z - y, where z's digits below zStart + xCount are its normalized value, and
// that value is at least y, which is normalized. Zero-padded.
func subZeroPaddedInPlace(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ xCount: Int, _ y: Span<UInt64>) {
    precondition(xCount >= y.count)
    // zStart is an index into z and i is below zCount, so this index arithmetic cannot overflow.
    precondition(zCount >= xCount && z.count &- zStart >= zCount)
    var borrow: UInt64 = 0
    var i = 0
    while i < y.count {
        var newBorrow: UInt64 = 0
        z[zStart &+ i] = digitSub2(z[zStart &+ i], y[i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    while i < xCount {
        var newBorrow: UInt64 = 0
        z[zStart &+ i] = digitSub(z[zStart &+ i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    assert(borrow == 0)
    // zStart + i is below z.count, so it cannot overflow.
    precondition(zStart >= 0)
    while i < zCount {
        z[zStart &+ i] = 0
        i += 1
    }
}

// z[zStart ..< zStart + zCount] := x - z, where z's digits below zStart + yCount are its normalized value, and x,
// which is normalized, is at least that value. Zero-padded.
func subZeroPaddedFromInPlace(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ x: Span<UInt64>, _ yCount: Int) {
    precondition(x.count >= yCount)
    // zStart is an index into z and i is below zCount, so this index arithmetic cannot overflow.
    precondition(zCount >= x.count && z.count &- zStart >= zCount)
    var borrow: UInt64 = 0
    var i = 0
    while i < yCount {
        var newBorrow: UInt64 = 0
        z[zStart &+ i] = digitSub2(x[i], z[zStart &+ i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    while i < x.count {
        var newBorrow: UInt64 = 0
        z[zStart &+ i] = digitSub(x[i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    assert(borrow == 0)
    // zStart + i is below z.count, so it cannot overflow.
    precondition(zStart >= 0)
    while i < zCount {
        z[zStart &+ i] = 0
        i += 1
    }
}

func lessThanNormalized(_ x: Span<UInt64>, _ y: Span<UInt64>) -> Bool {
    if x.count != y.count {
        return x.count < y.count
    }
    var i = x.count
    while i > 0 {
        i -= 1
        if x[i] != y[i] {
            return x[i] < y[i]
        }
    }
    return false
}

// z[zStart ..< zStart + zCount] := x + y on sign-magnitude values, returning the sign of z.
func addSigned(
    _ z: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ x: Span<UInt64>,
    _ xNegative: Bool,
    _ y: Span<UInt64>,
    _ yNegative: Bool
) -> Bool {
    if xNegative == yNegative {
        addZeroPadded(&z, zStart, zCount, x, y)
        return xNegative
    }
    let x = normalize(x)
    let y = normalize(y)
    if !lessThanNormalized(x, y) {
        subZeroPadded(&z, zStart, zCount, x, y)
        return xNegative
    }
    subZeroPadded(&z, zStart, zCount, y, x)
    return !xNegative
}

// z[zStart ..< zStart + zCount] += y on sign-magnitude values, returning the sign of z.
func addSignedInPlace(
    _ z: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ zNegative: Bool,
    _ y: Span<UInt64>,
    _ yNegative: Bool
) -> Bool {
    if zNegative == yNegative {
        addZeroPaddedInPlace(&z, zStart, zCount, y)
        return zNegative
    }
    let xCount = normalizedCount(z, zStart, zCount)
    let y = normalize(y)
    if !lessThanNormalized(z.span.extracting(droppingFirst: zStart).extracting(0..<xCount), y) {
        subZeroPaddedInPlace(&z, zStart, zCount, xCount, y)
        return zNegative
    }
    subZeroPaddedFromInPlace(&z, zStart, zCount, y, xCount)
    return !zNegative
}

// z[zStart ..< zStart + zCount] -= y on sign-magnitude values, returning the sign of z.
@inline(always)
func subtractSignedInPlace(
    _ z: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ zNegative: Bool,
    _ y: Span<UInt64>,
    _ yNegative: Bool
) -> Bool {
    addSignedInPlace(&z, zStart, zCount, zNegative, y, !yNegative)
}

// z[zStart ..< zStart + zCount] := x - z on sign-magnitude values, returning the sign of z.
func subtractSignedFromInPlace(
    _ z: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ x: Span<UInt64>,
    _ xNegative: Bool,
    _ zNegative: Bool
) -> Bool {
    let yNegative = !zNegative
    if xNegative == yNegative {
        // x + z, which adds digit by digit just as z + x does.
        addZeroPaddedInPlace(&z, zStart, zCount, x)
        return xNegative
    }
    let x = normalize(x)
    let yCount = normalizedCount(z, zStart, zCount)
    if !lessThanNormalized(x, z.span.extracting(droppingFirst: zStart).extracting(0..<yCount)) {
        subZeroPaddedFromInPlace(&z, zStart, zCount, x, yCount)
        return xNegative
    }
    subZeroPaddedInPlace(&z, zStart, zCount, yCount, x)
    return !xNegative
}

func timesTwo(_ x: inout MutableSpan<UInt64>, _ start: Int, _ count: Int) {
    precondition(x.count - start >= count)
    var carry: UInt64 = 0
    for i in start..<(start + count) {
        let d = x[i]
        x[i] = (d &<< 1) | carry
        carry = d &>> (UInt64(digitBits) - 1)
    }
}

func divideByTwo(_ x: inout MutableSpan<UInt64>, _ start: Int, _ count: Int) {
    precondition(x.count - start >= count)
    var carry: UInt64 = 0
    var i = start + count
    while i > start {
        i -= 1
        let d = x[i]
        x[i] = (d &>> 1) | carry
        carry = d &<< (UInt64(digitBits) - 1)
    }
}

func divideByThree(_ x: inout MutableSpan<UInt64>, _ start: Int, _ count: Int) {
    precondition(x.count - start >= count)
    var remainder: UInt64 = 0
    var i = start + count
    while i > start {
        i -= 1
        let d = x[i]
        // remainder < 3, so neither shift loses bits.
        let upper = (remainder &<< halfDigitBits) | (d &>> halfDigitBits)
        let (upperResult, upperRemainder) = upper.quotientAndRemainder(dividingBy: 3)
        let lower = (upperRemainder &<< halfDigitBits) | (d & halfDigitMask)
        let (lowerResult, lowerRemainder) = lower.quotientAndRemainder(dividingBy: 3)
        remainder = lowerRemainder
        x[i] = (upperResult &<< halfDigitBits) | lowerResult
    }
}

func toom3ScratchLength(_ longerOperandLength: Int) -> Int {
    // longerOperandLength is a digit count, so this cannot overflow.
    let i = (longerOperandLength &+ 2) / 3
    let pLength = i + 1
    let rLength = 2 * pLength
    return 4 * rLength
}

// Toom-3's temporary storage, toom3ScratchLength digits in four parts of 2 * (i + 1) digits each, which the
// interpolation reuses as follows:
//
//   part   | -------- time ----------->
//   t0     |( po, qo )( pm1, qm1 )( rm2 )
//   t1     |( p1, q1 )( pm2, qm2 )( rinf )
//   t2     |          ( r1                )
//   t3     |                 ( rm1        )
//
// Each part is its own buffer because a product reads two parts and writes a third.
struct Toom3Scratch: ~Copyable {
    var t0: UniqueArray<UInt64>
    var t1: UniqueArray<UInt64>
    var t2: UniqueArray<UInt64>
    var t3: UniqueArray<UInt64>

    init(_ longerOperandLength: Int) {
        let partLength = toom3ScratchLength(longerOperandLength) / 4
        t0 = UniqueArray(repeating: 0, count: partLength)
        t1 = UniqueArray(repeating: 0, count: partLength)
        t2 = UniqueArray(repeating: 0, count: partLength)
        t3 = UniqueArray(repeating: 0, count: partLength)
    }
}

// z[zStart ..< zStart + zCount] := x * y. With isSquare, y is x.
func toom3Main(
    _ z: inout MutableSpan<UInt64>,
    _ zStart: Int,
    _ zCount: Int,
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ isSquare: Bool,
    _ scratch: inout Toom3Scratch
) {
    assert(zCount >= x.count + y.count)
    // Phase 1: Splitting.
    // The counts are digit counts and zStart an index into z, so this index arithmetic cannot overflow.
    let i = (max(x.count, y.count) &+ 2) / 3
    let x0 = clampedSubspan(x, 0, i)
    let x1 = clampedSubspan(x, i, i)
    let x2 = clampedSubspan(x, 2 * i, i)
    let y0 = clampedSubspan(y, 0, i)
    let y1 = clampedSubspan(y, i, i)
    let y2 = clampedSubspan(y, 2 * i, i)

    // Temporary storage.
    let pLength = i + 1 // For all px, qx below.
    let rLength = 2 * pLength // For all r_x, Rx below.
    // We will use the same variable names as the Wikipedia article: our "pm1" is their "p(-1)" etc. For consistency
    // with other algorithms, we use X and Y where Wikipedia uses m and n.
    precondition(scratch.t0.count >= rLength && scratch.t1.count >= rLength && scratch.t2.count >= rLength && scratch.t3.count >= rLength)
    var t0 = scratch.t0.mutableSpan
    var t1 = scratch.t1.mutableSpan
    var t2 = scratch.t2.mutableSpan
    var t3 = scratch.t3.mutableSpan
    let po = 0..<pLength // In t0, then pm1.
    let qo = pLength..<rLength // In t0, then qm1.
    let p1 = 0..<pLength // In t1, then pm2.
    let q1 = pLength..<rLength // In t1, then qm2.
    let r = 0..<rLength // r1 in t2, rm1 in t3, rm2 in t0, rinf in t1.

    // We can also share the backing stores of Z, r0, R0.
    precondition(zCount >= rLength && z.count &- zStart >= zCount)
    let r0 = zStart // r0 is z[r0 ..< r0 + rLength].

    // Phase 2a: Evaluation, steps 0, 1, m1.
    // po = X0 + X2
    addZeroPadded(&t0, po.lowerBound, pLength, x0, x2)
    // p0 = X0
    // p1 = po + X1
    addZeroPadded(&t1, p1.lowerBound, pLength, t0.span.extracting(po), x1)
    // pm1 = po - X1
    let pm1Sign = subtractSignedInPlace(&t0, po.lowerBound, pLength, false, x1, false)

    // qo = Y0 + Y2
    addZeroPadded(&t0, qo.lowerBound, pLength, y0, y2)
    // q0 = Y0
    // q1 = qo + Y1
    addZeroPadded(&t1, q1.lowerBound, pLength, t0.span.extracting(qo), y1)
    // qm1 = qo - Y1
    let qm1Sign = subtractSignedInPlace(&t0, qo.lowerBound, pLength, false, y1, false)

    // Phase 3a: Pointwise multiplication, steps 0, 1, m1.
    multiplyZeroPadded(x0, y0, isSquare, &z, r0, rLength)
    multiplyZeroPadded(t1.span.extracting(p1), t1.span.extracting(q1), false, &t2, r.lowerBound, rLength)
    multiplyZeroPadded(t0.span.extracting(po), t0.span.extracting(qo), false, &t3, r.lowerBound, rLength)
    let rm1Sign = pm1Sign != qm1Sign

    // Phase 2b: Evaluation, steps m2 and inf.
    // pm2 = (pm1 + X2) * 2 - X0
    var pm2Sign = addSigned(&t1, p1.lowerBound, pLength, t0.span.extracting(po), pm1Sign, x2, false)
    timesTwo(&t1, p1.lowerBound, pLength)
    pm2Sign = subtractSignedInPlace(&t1, p1.lowerBound, pLength, pm2Sign, x0, false)
    // pinf = X2

    // qm2 = (qm1 + Y2) * 2 - Y0
    var qm2Sign = addSigned(&t1, q1.lowerBound, pLength, t0.span.extracting(qo), qm1Sign, y2, false)
    timesTwo(&t1, q1.lowerBound, pLength)
    qm2Sign = subtractSignedInPlace(&t1, q1.lowerBound, pLength, qm2Sign, y0, false)
    // qinf = Y2

    // Phase 3b: Pointwise multiplication, steps m2 and inf.
    multiplyZeroPadded(t1.span.extracting(p1), t1.span.extracting(q1), false, &t0, r.lowerBound, rLength)
    let rm2Sign = pm2Sign != qm2Sign

    multiplyZeroPadded(x2, y2, isSquare, &t1, r.lowerBound, rLength)

    // Phase 4: Interpolation. R0 is r0, R4 is rinf in t1.
    // R3 <- (rm2 - r1) / 3, in t0
    // swift-format-ignore: AlwaysUseLowerCamelCase
    var R3Sign = subtractSignedInPlace(&t0, r.lowerBound, rLength, rm2Sign, t2.span.extracting(r), false)
    divideByThree(&t0, r.lowerBound, rLength)
    // R1 <- (r1 - rm1) / 2, in t2
    // swift-format-ignore: AlwaysUseLowerCamelCase
    var R1Sign = subtractSignedInPlace(&t2, r.lowerBound, rLength, false, t3.span.extracting(r), rm1Sign)
    divideByTwo(&t2, r.lowerBound, rLength)
    // R2 <- rm1 - r0, in t3
    // swift-format-ignore: AlwaysUseLowerCamelCase
    var R2Sign = subtractSignedInPlace(&t3, r.lowerBound, rLength, rm1Sign, z.span.extracting(droppingFirst: r0).extracting(r), false)
    // R3 <- (R2 - R3) / 2 + 2 * rinf
    R3Sign = subtractSignedFromInPlace(&t0, r.lowerBound, rLength, t3.span.extracting(r), R2Sign, R3Sign)
    divideByTwo(&t0, r.lowerBound, rLength)
    R3Sign = addSignedInPlace(&t0, r.lowerBound, rLength, R3Sign, t1.span.extracting(r), false)
    R3Sign = addSignedInPlace(&t0, r.lowerBound, rLength, R3Sign, t1.span.extracting(r), false)
    // R2 <- R2 + R1 - R4
    R2Sign = addSignedInPlace(&t3, r.lowerBound, rLength, R2Sign, t2.span.extracting(r), R1Sign)
    R2Sign = subtractSignedInPlace(&t3, r.lowerBound, rLength, R2Sign, t1.span.extracting(r), false)
    // R1 <- R1 - R3
    R1Sign = subtractSignedInPlace(&t2, r.lowerBound, rLength, R1Sign, t0.span.extracting(r), R3Sign)

    assert(!R1Sign || normalizedCount(t2, r.lowerBound, rLength) == 0)
    assert(!R2Sign || normalizedCount(t3, r.lowerBound, rLength) == 0)
    assert(!R3Sign || normalizedCount(t0, r.lowerBound, rLength) == 0)

    // Phase 5: Recomposition. R0 is already in place. Overflow can't happen.
    // zStart + j is below z.count, so it cannot overflow.
    precondition(zStart >= 0)
    for j in rLength..<zCount {
        z[zStart &+ j] = 0
    }
    _ = inplaceAddAndPropagate(&z, zStart &+ i, zCount &- i, t2.span.extracting(r))
    _ = inplaceAddAndPropagate(&z, zStart &+ 2 &* i, zCount &- 2 &* i, t3.span.extracting(r))
    _ = inplaceAddAndPropagate(&z, zStart &+ 3 &* i, zCount &- 3 &* i, t0.span.extracting(r))
    _ = inplaceAddAndPropagate(&z, zStart &+ 4 &* i, zCount &- 4 &* i, t1.span.extracting(r))
}

// result[offset ..< offset + x.count + y.count] := x * y, with x.count >= y.count >= toom3Threshold. With isSquare,
// y is x. Returns x.count + y.count.
func multiplyToom3(_ x: Span<UInt64>, _ y: Span<UInt64>, _ isSquare: Bool, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    assert(x.count >= y.count)
    assert(y.count >= toom3Threshold)
    // The counts are digit counts and offset an index into result, so this index arithmetic cannot overflow.
    let fullSize = x.count &+ y.count
    precondition(result.count &- offset >= fullSize)
    // toom3Main splits both operands into thirds of the larger one, so a moderately longer x costs the same five
    // products as a balanced pair and beats chunking x into y-sized pieces. Beyond that ratio the padding wastes more
    // than the chunking does.
    if x.count &* 3 <= y.count &* 5 {
        var scratch = Toom3Scratch(x.count)
        toom3Main(&result, offset, fullSize, x, y, isSquare, &scratch)
        return fullSize
    }
    // A square has x.count == y.count, so it took the branch above.
    let k = y.count
    var scratch = Toom3Scratch(k)
    toom3Main(&result, offset, fullSize, x.extracting(0..<k), y, false, &scratch)
    if k < x.count {
        var chunkProduct = UniqueArray<UInt64>(repeating: 0, count: 2 * k)
        var i = k
        while i < x.count {
            let xi = clampedSubspan(x, i, k)
            do {
                var product = chunkProduct.mutableSpan
                if xi.count < k {
                    // The last chunk is shorter, so let the size dispatch pick its algorithm.
                    multiplyZeroPadded(xi, y, false, &product, 0, 2 * k)
                } else {
                    toom3Main(&product, 0, 2 * k, xi, y, false, &scratch)
                }
            }
            _ = inplaceAddAndPropagate(&result, offset &+ i, fullSize &- i, chunkProduct.span)
            i &+= k
        }
    }
    return fullSize
}

// result[offset ..< offset + x.count + y.count] := x * y, with x.count >= y.count >= 1. With isSquare, y is x, and the
// product is computed as a square where an algorithm has a square form. Returns x.count + y.count.
func multiplyDigitsInto(
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ isSquare: Bool,
    _ result: inout MutableSpan<UInt64>,
    _ offset: Int
) -> Int {
    assert(!y.isEmpty)
    assert(x.count >= y.count)
    assert(result.count - offset >= x.count + y.count)

    if x.count == y.count {
        if x.count == 1 {
            if isSquare {
                return squareCombaFixed1(x, &result, offset)
            }
            return multiplyCombaFixed1(x, y, &result, offset)
        }
        if isSquare {
            if let length = squareCombaFixed(x, &result, offset) {
                return length
            }
        } else if let length = multiplyCombaFixed(x, y, &result, offset) {
            return length
        }
    }
    if y.count == 1 {
        return multiplySingle(x, y[0], &result, offset)
    }
    if shouldUseFFT(x.count, y.count) {
        return multiplyFFT(x, y, isSquare, &result, offset)
    }
    if y.count >= toom3Threshold {
        return multiplyToom3(x, y, isSquare, &result, offset)
    }
    if y.count >= karatsubaThreshold {
        return multiplyKaratsuba(x, y, isSquare, &result, offset)
    }
    if shouldUseComba(x.count, y.count) {
        return multiplyComba(x, y, &result, offset)
    }
    return multiplySchoolbook(x, y, &result, offset)
}

// The entry point's kernel: with isSquare, y is empty and the product is x * x. It takes the result by value, as the
// addition and subtraction kernels do. Two- and four-digit products are computed here; the rest go to
// multiplyDigitsGeneral. The entry point computes one-digit products itself.
@inline(never)
func multiplyDigits(_ x: Span<UInt64>, _ y: Span<UInt64>, _ isSquare: Bool, _ result: consuming MutableSpan<UInt64>) -> Int {
    if x.count == 2 && (isSquare || y.count == 2) {
        if isSquare {
            return squareCombaFixed2(x, &result, 0)
        }
        return multiplyCombaFixed2(x, y, &result, 0)
    }
    if x.count == 4 && (isSquare || y.count == 4) {
        if isSquare {
            return squareCombaFixed4(x, &result, 0)
        }
        return multiplyCombaFixed4(x, y, &result, 0)
    }
    return multiplyDigitsGeneral(x, y, isSquare, result)
}

// multiplyDigits for every size: the fixed-size kernels, then the size dispatch.
@inline(never)
func multiplyDigitsGeneral(_ x: Span<UInt64>, _ y: Span<UInt64>, _ isSquare: Bool, _ result: consuming MutableSpan<UInt64>) -> Int {
    if isSquare {
        if let length = squareCombaFixed(x, &result, 0) {
            return length
        }
        if x.count < karatsubaThreshold {
            return smallMultiply(x, x, &result)
        }
        return multiplyDigitsInto(x, x, true, &result, 0)
    }
    if x.count == y.count, let length = multiplyCombaFixed(x, y, &result, 0) {
        return length
    }
    if y.count < karatsubaThreshold {
        return smallMultiply(x, y, &result)
    }
    return multiplyDigitsInto(x, y, false, &result, 0)
}

// The size dispatch below Karatsuba, for x.count >= y.count: no product this small takes FFT or Toom-3.
@inline(always)
func smallMultiply(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>) -> Int {
    if y.count == 1 {
        return multiplySingle(x, y[0], &result, 0)
    }
    if shouldUseComba(x.count, y.count) {
        if y.count == 2 {
            return multiplyCombaTwo(x, y, &result, 0)
        }
        return multiplyComba(x, y, &result, 0)
    }
    return multiplySchoolbook(x, y, &result, 0)
}

// result[offset ..< offset + x.count + 2] := x * y for a two-digit y, by product scanning with y's digits held across
// the columns: column i takes x[i] * y[0] and x[i - 1] * y[1]. Returns x.count + 2.
@inline(never)
func multiplyCombaTwo(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    // x.count is a digit count, so adding 2 cannot overflow.
    precondition(y.count == 2 && x.count >= 2 && offset >= 0 && result.count - offset >= x.count &+ 2)
    let y0 = y[0]
    let y1 = y[1]
    var previous = x[0]
    let first = UInt128(previous) * UInt128(y0)
    result[offset] = UInt64(truncatingIfNeeded: first)
    // The carry into the next column: below 2^65, so its top digit is 0 or 1.
    var carry = first >> 64
    for i in 1..<x.count {
        let digit = x[i]
        // Cannot overflow: digit * y0 is at most 2^128 - 2^65 + 1 and carry is below 2^65 - 2.
        let partial = UInt128(digit) * UInt128(y0) &+ carry
        let (column, overflow) = partial.addingReportingOverflow(UInt128(previous) * UInt128(y1))
        // Cannot overflow: offset + x.count + 2 is at most result.count.
        result[offset &+ i] = UInt64(truncatingIfNeeded: column)
        carry = (column >> 64) | (UInt128(overflow ? 1 : 0) << 64)
        previous = digit
    }
    // Cannot overflow: x * y fits in x.count + 2 digits, so the top column is below 2^128.
    let last = UInt128(previous) * UInt128(y1) &+ carry
    // Cannot overflow: offset + x.count + 2 is at most result.count.
    result[offset &+ x.count] = UInt64(truncatingIfNeeded: last)
    result[offset &+ x.count &+ 1] = UInt64(truncatingIfNeeded: last >> 64)
    return x.count + 2
}

#endif // USE_SWIFT_BIGINT_DIGITS
