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

// Kernels whose operands' size is fixed, for the sizes JSBigInt's dispatchers special-case.
enum FixedSizeDigits<let N: Int> {
    // result := x + y, of N + 1 digits. Returns N + 1.
    @inline(always)
    static func addSchoolbook(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>) -> Int {
        let x = x.extracting(0..<N)
        let y = y.extracting(0..<N)
        precondition(result.count >= N + 1)
        var carry: UInt64 = 0
        for i in 0..<N {
            var newCarry: UInt64 = 0
            result[i] = digitAdd3(x[i], y[i], carry, &newCarry)
            carry = newCarry
        }
        result[N] = carry
        return N + 1
    }

    // result := x - y, of N digits, with x >= y. Returns N.
    @inline(always)
    static func subSchoolbook(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>) -> Int {
        let x = x.extracting(0..<N)
        let y = y.extracting(0..<N)
        precondition(result.count >= N)
        var borrow: UInt64 = 0
        for i in 0..<N {
            var newBorrow: UInt64 = 0
            result[i] = digitSub2(x[i], y[i], borrow, &newBorrow)
            borrow = newBorrow
        }
        assert(borrow == 0)
        return N
    }
}

// result := x + y, with x.count >= y.count. Returns x.count + 1.
func addSchoolbook(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>) -> Int {
    precondition(x.count >= y.count)
    precondition(result.count > x.count)
    var carry: UInt64 = 0
    var i = 0
    while i < y.count {
        var newCarry: UInt64 = 0
        result[i] = digitAdd3(x[i], y[i], carry, &newCarry)
        carry = newCarry
        i += 1
    }

    while i < x.count {
        var newCarry: UInt64 = 0
        result[i] = digitAdd(x[i], carry, &newCarry)
        carry = newCarry
        i += 1
    }

    result[i] = carry
    return i + 1
}

// result := x + y, with x.count >= y.count and result.count > x.count. Returns the sum's length, x.count + 1.
@inline(always)
func addDigitsInto(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>) -> Int {
    assert(x.count >= y.count)
    assert(result.count >= x.count + 1)

    if x.count == y.count {
        switch x.count {
        case 1:
            return FixedSizeDigits<1>.addSchoolbook(x, y, &result)
        case 2:
            return FixedSizeDigits<2>.addSchoolbook(x, y, &result)
        case 3:
            return FixedSizeDigits<3>.addSchoolbook(x, y, &result)
        case 4:
            return FixedSizeDigits<4>.addSchoolbook(x, y, &result)
        default:
            break
        }
    }
    return addSchoolbook(x, y, &result)
}

// result := x + y, with x.count >= 1 and a single digit y. Returns x.count + 1.
@inline(always)
func addSingle(_ x: Span<UInt64>, _ y: UInt64, _ result: inout MutableSpan<UInt64>) -> Int {
    precondition(!x.isEmpty)
    precondition(result.count > x.count)
    var carry: UInt64 = 0
    result[0] = digitAdd(x[0], y, &carry)
    var i = 1
    while i < x.count {
        var newCarry: UInt64 = 0
        result[i] = digitAdd(x[i], carry, &newCarry)
        carry = newCarry
        i += 1
    }

    result[i] = carry
    return i + 1
}

// result := x - y, with x >= y and a single digit y. Returns x.count.
@inline(always)
func subSingle(_ x: Span<UInt64>, _ y: UInt64, _ result: inout MutableSpan<UInt64>) -> Int {
    precondition(!x.isEmpty)
    precondition(result.count >= x.count)
    var borrow: UInt64 = 0
    result[0] = digitSub(x[0], y, &borrow)
    var i = 1
    while i < x.count {
        var newBorrow: UInt64 = 0
        result[i] = digitSub(x[i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }

    assert(borrow == 0)
    return x.count
}

// result := x - y, with x >= y. Returns x.count.
func subSchoolbook(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>, _ offset: Int = 0) -> Int {
    precondition(x.count >= y.count)
    // offset is an index into result and x.count a digit count, so this arithmetic cannot overflow.
    precondition(result.count &- offset >= x.count)
    var borrow: UInt64 = 0
    var i = 0
    while i < y.count {
        var newBorrow: UInt64 = 0
        result[offset &+ i] = digitSub2(x[i], y[i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }

    while i < x.count {
        var newBorrow: UInt64 = 0
        result[offset &+ i] = digitSub(x[i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }

    assert(borrow == 0)
    return x.count
}

// result := x - y, with x >= y and result.count >= x.count. Returns the difference's length, x.count.
func subDigitsInto(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>) -> Int {
    assert(x.count >= y.count)
    assert(compareDigits(x, y) >= 0)
    assert(result.count >= x.count)

    if x.count == y.count {
        switch x.count {
        case 1:
            return FixedSizeDigits<1>.subSchoolbook(x, y, &result)
        case 2:
            return FixedSizeDigits<2>.subSchoolbook(x, y, &result)
        case 3:
            return FixedSizeDigits<3>.subSchoolbook(x, y, &result)
        case 4:
            return FixedSizeDigits<4>.subSchoolbook(x, y, &result)
        default:
            break
        }
    }
    return subSchoolbook(x, y, &result)
}

// The entry points' kernels for addition and subtraction. Each entry point's kernels take its result by value, so
// that the entry point, inlined into its C++ caller, passes the span in registers rather than through the caller's
// stack.

@inline(never)
func addDigits(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: consuming MutableSpan<UInt64>) -> Int {
    if y.count == 1 {
        return addSingle(x, y[0], &result)
    }
    return addDigitsInto(x, y, &result)
}

@inline(never)
func subDigits(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: consuming MutableSpan<UInt64>) -> Int {
    if y.count == 1 {
        return subSingle(x, y[0], &result)
    }
    return subDigitsInto(x, y, &result)
}

// Bitwise operations on absolute values.

enum ExtraDigitsHandling {
    case copy
    case skip
}

enum DigitBitwiseOperation {
    case and
    case or
    case xor
}

@inline(always)
func apply(_ operation: DigitBitwiseOperation, _ a: UInt64, _ b: UInt64) -> UInt64 {
    switch operation {
    case .and:
        a & b
    case .or:
        a | b
    case .xor:
        a ^ b
    }
}

// Performs the given binary operation on digit pairs of x and y; when the end of the shorter of the two is reached,
// extraDigits configures how remaining digits in the longer input are handled: copied to the result or ignored.
// Example:
//       y:             [ y2 ][ y1 ][ y0 ]
//       x:       [ x3 ][ x2 ][ x1 ][ x0 ]
//                   |     |     |     |
//                (Copy)  (op)  (op)  (op)
//                   |     |     |     |
//                   v     v     v     v
// result: [  0 ][ x3 ][ r2 ][ r1 ][ r0 ]
@inline(always)
func absoluteBitwiseOp(
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ extraDigits: ExtraDigitsHandling,
    _ operation: DigitBitwiseOperation,
    _ result: inout MutableSpan<UInt64>
) -> Int {
    let numPairs = min(x.count, y.count)
    let longer = x.count < y.count ? y : x
    let resultLength = extraDigits == .copy ? longer.count : numPairs
    precondition(result.count >= resultLength)

    var i = 0
    while i < numPairs {
        result[i] = apply(operation, x[i], y[i])
        i += 1
    }

    if extraDigits == .copy {
        while i < longer.count {
            result[i] = longer[i]
            i += 1
        }
    }

    return resultLength
}

// result := x & y. Returns min(x.count, y.count).
@inline(always)
func absoluteAnd(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: consuming MutableSpan<UInt64>) -> Int {
    absoluteBitwiseOp(x, y, .skip, .and, &result)
}

// result := x | y. Returns max(x.count, y.count).
@inline(always)
func absoluteOr(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: consuming MutableSpan<UInt64>) -> Int {
    absoluteBitwiseOp(x, y, .copy, .or, &result)
}

// result := x ^ y. Returns max(x.count, y.count).
@inline(always)
func absoluteXor(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: consuming MutableSpan<UInt64>) -> Int {
    absoluteBitwiseOp(x, y, .copy, .xor, &result)
}

// result := x & ~y. Returns x.count.
@inline(always)
func absoluteAndNot(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: consuming MutableSpan<UInt64>) -> Int {
    precondition(result.count >= x.count)

    var i = 0
    while i < min(x.count, y.count) {
        result[i] = x[i] & ~y[i]
        i += 1
    }

    while i < x.count {
        result[i] = x[i]
        i += 1
    }

    return x.count
}

// result := x + 1. Returns x.count, or x.count + 1 if the addition carries out of x's top digit.
@inline(always)
func absoluteAddOne(_ x: Span<UInt64>, _ result: consuming MutableSpan<UInt64>) -> Int {
    precondition(result.count > x.count)
    var carry: UInt64 = 1
    var i = 0
    while i < x.count {
        var newCarry: UInt64 = 0
        result[i] = digitAdd(x[i], carry, &newCarry)
        carry = newCarry
        i += 1
    }
    if carry != 0 {
        result[i] = carry
        i += 1
    }
    return i
}

// result := x - 1, with x not zero. Returns x.count.
@inline(always)
func absoluteSubOne(_ x: Span<UInt64>, _ result: consuming MutableSpan<UInt64>) -> Int {
    assert(!x.isEmpty)
    precondition(result.count >= x.count)
    var borrow: UInt64 = 1
    for i in 0..<x.count {
        var newBorrow: UInt64 = 0
        result[i] = digitSub(x[i], borrow, &newBorrow)
        borrow = newBorrow
    }
    assert(borrow == 0)
    return x.count
}

// The fill loops of the JavaScript shift operators.

// result := x << (digitShift * digitBits + bitsShift), where result has x.count + digitShift digits, plus one when
// the shift carries out of x's top digit.
@inline(never)
func shiftLeftDigits(_ x: Span<UInt64>, _ digitShift: Int, _ bitsShift: Int, _ result: consuming MutableSpan<UInt64>) {
    let length = x.count
    let resultLength = result.count
    if bitsShift == 0 {
        var i = 0
        while i < digitShift {
            result[i] = 0
            i += 1
        }

        while i < resultLength {
            // i is at least digitShift, so this cannot overflow.
            result[i] = x[i &- digitShift]
            i += 1
        }
    } else {
        precondition(bitsShift < digitBits)
        let bitsShift = UInt64(bitsShift)
        var carry: UInt64 = 0
        for i in 0..<digitShift {
            result[i] = 0
        }

        // i + digitShift and length + digitShift are at most result.count, so they cannot overflow.
        for i in 0..<length {
            let d = x[i]
            result[i &+ digitShift] = (d &<< bitsShift) | carry
            carry = d &>> (UInt64(digitBits) - bitsShift)
        }

        if resultLength > length &+ digitShift {
            result[length &+ digitShift] = carry
        } else {
            assert(carry == 0)
        }
    }
}

// result := x >> (digitShift * digitBits + bitsShift), where result has x.count - digitShift digits, plus one when
// rounding down a shift by whole digits can carry out of the top digit; with roundDown, adds one to it, which is
// rounding a negative value's shift down.
@inline(never)
func shiftRightDigits(
    _ x: Span<UInt64>,
    _ digitShift: Int,
    _ bitsShift: Int,
    _ roundDown: Bool,
    _ result: consuming MutableSpan<UInt64>
) {
    let length = x.count
    let resultLength = result.count
    if bitsShift == 0 {
        result[resultLength - 1] = 0
        let source = x.extracting(droppingFirst: digitShift)
        for i in 0..<source.count {
            result[i] = source[i]
        }
    } else {
        precondition(bitsShift < digitBits)
        let bitsShift = UInt64(bitsShift)
        var carry = x[digitShift] &>> bitsShift
        let last = length - digitShift - 1
        let source = x.extracting(droppingFirst: digitShift).extracting(droppingFirst: 1)
        for i in 0..<last {
            let d = source[i]
            result[i] = (d &<< (UInt64(digitBits) - bitsShift)) | carry
            carry = d &>> bitsShift
        }
        result[last] = carry
    }

    if roundDown {
        // Rounding down adds one to the result's magnitude; its top digit is never all ones, so this cannot carry out.
        var carry: UInt64 = 1
        var i = 0
        while i < resultLength && carry != 0 {
            var newCarry: UInt64 = 0
            result[i] = digitAdd(result[i], carry, &newCarry)
            carry = newCarry
            i += 1
        }
        assert(carry == 0)
    }
}

#endif // USE_SWIFT_BIGINT_DIGITS
