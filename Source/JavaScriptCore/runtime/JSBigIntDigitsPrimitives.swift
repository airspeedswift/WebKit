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

// JSBigInt::digitBits, halfDigitBits and halfDigitMask; JSBigInt.cpp checks the first two.
let digitBits = 64
let halfDigitBits = 32
let halfDigitMask: UInt64 = (1 << 32) - 1

// Adds `b` to `a`, and adds the carry, 0 or 1, to `carry`.
@inline(always)
func digitAdd(_ a: UInt64, _ b: UInt64, _ carry: inout UInt64) -> UInt64 {
    // The sum is formed in two digits, so its carry is the upper digit. It is at most 2^65 - 2, so the add cannot
    // overflow.
    let sum = UInt128(a) + UInt128(b)
    // carry counts the carries of one column, of which there are at most one per digit.
    carry &+= UInt64(truncatingIfNeeded: sum >> 64)
    return UInt64(truncatingIfNeeded: sum)
}

// Returns a + b + c, with `c` 0 or 1, and sets `carry` to the carry out, 0 or 1.
@inline(always)
func digitAdd3(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ carry: inout UInt64) -> UInt64 {
    assert(c <= 1)
    let (partial, carryFromPartial) = a.addingReportingOverflow(b)
    let (result, carryFromC) = partial.addingReportingOverflow(c)
    // a + b <= 2^digitBits * 2 - 2, so at most one of the two additions can carry.
    carry = (carryFromPartial ? 1 : 0) | (carryFromC ? 1 : 0)
    return result
}

// Subtracts `b` from `a`, and adds the borrow, 0 or 1, to `borrow`.
@inline(always)
func digitSub(_ a: UInt64, _ b: UInt64, _ borrow: inout UInt64) -> UInt64 {
    let (difference, overflow) = a.subtractingReportingOverflow(b)
    // borrow counts the borrows of one digit, of which there is at most one per subtraction.
    borrow &+= overflow ? 1 : 0
    return difference
}

// Returns a - b - borrowIn, with `borrowIn` 0 or 1, and sets `borrowOut` to the borrow out, 0 or 1.
@inline(always)
func digitSub2(_ a: UInt64, _ b: UInt64, _ borrowIn: UInt64, _ borrowOut: inout UInt64) -> UInt64 {
    assert(borrowIn <= 1)
    let (partial, borrowFromPartial) = a.subtractingReportingOverflow(b)
    let (result, borrowFromBorrowIn) = partial.subtractingReportingOverflow(borrowIn)
    // b + borrowIn <= 2^digitBits, so at most one of the two subtractions can borrow.
    borrowOut = (borrowFromPartial ? 1 : 0) | (borrowFromBorrowIn ? 1 : 0)
    return result
}

// Returns the low and high digits of a * b.
@inline(always)
func digitMul(_ a: UInt64, _ b: UInt64) -> (low: UInt64, high: UInt64) {
    let (high, low) = a.multipliedFullWidth(by: b)
    return (low, high)
}

// Returns the quotient and remainder of (high << digitBits + low) / divisor, which needs high < divisor.
func digitDiv(_ high: UInt64, _ low: UInt64, _ divisor: UInt64) -> (quotient: UInt64, remainder: UInt64) {
    digitDivInline(high, low, divisor)
}

// digitDiv, always inlined, for estimateQhat: the same-size division kernels then make no call.
// Adapted from Warren, Hacker's Delight, p. 152.
@inline(always)
func digitDivInline(_ high: UInt64, _ low: UInt64, _ divisor: UInt64) -> (quotient: UInt64, remainder: UInt64) {
    assert(high < divisor)
    // Fast path: if high is zero, the computation can be done within Digit range.
    if high == 0 {
        return (low / divisor, low % divisor)
    }

    let halfDigitBase: UInt64 = 1 << halfDigitBits

    // s < digitBits, since divisor is not zero.
    let s = UInt64(divisor.leadingZeroBitCount)
    let divisor = divisor &<< s

    let vn1 = divisor >> halfDigitBits
    let vn0 = divisor & halfDigitMask

    // sZeroMask is 0 if s == 0 and all 1-bits otherwise, which clears low's contribution when the shift below
    // would be by digitBits. s is at most 63, so neither subtraction can wrap.
    let sZeroMask = UInt64(bitPattern: (0 &- Int64(s)) >> (digitBits - 1))
    let un32 = (high &<< s) | ((low &>> ((UInt64(digitBits) &- s) & (UInt64(digitBits) - 1))) & sZeroMask)

    let un10 = low &<< s
    let un1 = un10 >> halfDigitBits
    let un0 = un10 & halfDigitMask
    // As in Hacker's Delight, the products subtracted from un32 * halfDigitBase wrap on purpose; q1, q0 and rhat are
    // below 2^33, so their updates do not.
    var q1 = un32 / vn1
    var rhat = un32 &- q1 &* vn1

    while q1 >= halfDigitBase || q1 &* vn0 > rhat &* halfDigitBase &+ un1 {
        q1 &-= 1
        rhat &+= vn1
        if rhat >= halfDigitBase {
            break
        }
    }

    let un21 = un32 &* halfDigitBase &+ un1 &- q1 &* divisor
    var q0 = un21 / vn1
    rhat = un21 &- q0 &* vn1

    while q0 >= halfDigitBase || q0 &* vn0 > rhat &* halfDigitBase &+ un0 {
        q0 &-= 1
        rhat &+= vn1
        if rhat >= halfDigitBase {
            break
        }
    }

    let remainder = (un21 &* halfDigitBase &+ un0 &- q0 &* divisor) &>> s
    return (q1 &* halfDigitBase &+ q0, remainder)
}

// Division of two digits by one, by a fixed normalized divisor, with its precomputed inverse.
// The algorithm is from "Division by Invariant Integers using Multiplication", Granlund and Montgomery, PLDI'94.
// https://gmplib.org/~tege/divcnst-pldi94.pdf
// This is summarized in "Improved division by invariant integers", Moller and Granlund, as "Previous Methods".
// https://gmplib.org/~tege/division-paper.pdf
//
// `div` (Granlund-Montgomery) serves Knuth's algorithm D; `div2by1` (Moller-Granlund algorithm 4) serves
// `divideSingle`, where each step waits on the previous remainder.
struct DigitDiv {
    let divisor: UInt64
    let inverse: UInt64

    init(_ d: UInt64) {
        // d is already normalized.
        assert(d & (1 << (UInt64(digitBits) - 1)) != 0)
        divisor = d
        // floor((beta^2 - 1) / d) - beta, the quotient of (beta - 1 - d, beta - 1) by d: its top digit is below d.
        inverse = digitDiv(~d, ~0, d).quotient
    }

    // Returns the quotient and remainder of (high << digitBits + low) / divisor, which needs high < divisor so that
    // the quotient is a single digit.
    @inline(always)
    func div(_ high: UInt64, _ low: UInt64) -> (quotient: UInt64, remainder: UInt64) {
        assert(high < divisor)
        let u1 = high
        let u0 = low
        let v = inverse
        let d = divisor

        // 1. q = ((v * u1) / beta) + u1
        var q = u1 &+ u1.multipliedFullWidth(by: v).high

        // 2. <p1, p0> = q * d
        let p = UInt128(q) &* UInt128(d)

        // 3. <r1, r0> = <u1, u0> - <p1, p0>
        let u = (UInt128(u1) &<< 64) | UInt128(u0)
        var rem = u &- p

        // 4. while (r1 > 0 || r0 >= d) { q++; <r1, r0> = <r1, r0> - d; }
        while rem >= UInt128(d) {
            q &+= 1
            rem &-= UInt128(d)
        }

        return (q, UInt64(truncatingIfNeeded: rem))
    }

    // The same division by the method of "Improved division by invariant integers", Moller and Granlund, algorithm 4,
    // with the same inverse. Its first correction is taken about half the time; the second is rare.
    @inline(always)
    func div2by1(_ high: UInt64, _ low: UInt64) -> (quotient: UInt64, remainder: UInt64) {
        assert(high < divisor)
        let d = divisor
        // <q1, q0> = v * u1 + <u1 + 1, u0>, with the sum's carry out of the low digit added to q1. As in the paper,
        // q1 and r are computed modulo beta.
        let product = inverse.multipliedFullWidth(by: high)
        let (q0, carry) = product.low.addingReportingOverflow(low)
        var q1 = product.high &+ high &+ 1 &+ (carry ? 1 : 0)
        // r = u0 - q1 * d, modulo beta: the true remainder plus 0 or d, or minus d.
        var r = low &- q1 &* d
        let tooBig: UInt64 = r > q0 ? ~0 : 0
        q1 &+= tooBig
        r &+= d & tooBig
        if r >= d {
            q1 &+= 1
            r -= d
        }
        return (q1, r)
    }
}

// The digits of `x` without its leading zero digits.
@_lifetime(copy x)
@inline(always)
func normalize(_ x: Span<UInt64>) -> Span<UInt64> {
    var count = x.count
    while count > 0 && x[count - 1] == 0 {
        count -= 1
    }
    return x.extracting(0..<count)
}

// The number of digits of result[0 ..< count] without its leading zero digits.
@inline(always)
func normalizedCount(_ result: borrowing MutableSpan<UInt64>, _ start: Int, _ count: Int) -> Int {
    let digits = result.span.extracting(droppingFirst: start)
    var count = count
    while count > 0 && digits[count - 1] == 0 {
        count -= 1
    }
    return count
}

// Returns -1, 0 or 1 as x is less than, equal to or greater than y, ignoring leading zero digits.
func compareDigits(_ x: Span<UInt64>, _ y: Span<UInt64>) -> Int {
    let x = normalize(x)
    let y = normalize(y)
    if x.count != y.count {
        return x.count < y.count ? -1 : 1
    }
    var i = x.count
    while i > 0 {
        i -= 1
        if x[i] != y[i] {
            return x[i] < y[i] ? -1 : 1
        }
    }
    return 0
}

// result := x + y, with leading zeros ignored and the sum normalized. Returns the sum's length.
func addDigitsNormalized(_ x: Span<UInt64>, _ y: Span<UInt64>, _ result: inout MutableSpan<UInt64>) -> Int {
    let x = normalize(x)
    let y = normalize(y)
    if x.count < y.count {
        return addDigitsNormalized(y, x, &result)
    }
    precondition(result.count > x.count)
    let length = addDigitsInto(x, y, &result)
    return normalizedCount(result, 0, length)
}

// result[offset ..< offset + count] := x * y, with leading zeros ignored and the product normalized, in the low digits
// of that range. With isSquare, y is x. Returns the product's length.
func multiplyDigitsNormalized(
    _ x: Span<UInt64>,
    _ y: Span<UInt64>,
    _ isSquare: Bool,
    _ result: inout MutableSpan<UInt64>,
    _ offset: Int,
    _ count: Int
) -> Int {
    let x = normalize(x)
    let y = normalize(y)
    if x.isEmpty || y.isEmpty {
        return 0
    }
    if x.count < y.count {
        return multiplyDigitsNormalized(y, x, isSquare, &result, offset, count)
    }
    // The counts are digit counts and offset an index into result, so this arithmetic cannot overflow.
    precondition(count >= x.count &+ y.count && result.count &- offset >= count)
    let length = multiplyDigitsInto(x, y, isSquare, &result, offset)
    return normalizedCount(result, offset, length)
}

// quotient := x / y, with leading zeros ignored and the quotient normalized. Returns the quotient's length.
func divideDigitsNormalized(_ quotient: inout MutableSpan<UInt64>, _ x: Span<UInt64>, _ y: Span<UInt64>) -> Int {
    let x = normalize(x)
    let y = normalize(y)
    precondition(!y.isEmpty)

    let comparisonResult = compareDigits(x, y)
    if comparisonResult < 0 {
        return 0
    }

    precondition(quotient.count >= x.count)
    if comparisonResult == 0 {
        quotient[0] = 1
        return 1
    }

    // x > y, thus x.count >= y.count.
    if y.count == 1 {
        let length = x[x.count - 1] >= y[0] ? x.count : x.count - 1
        _ = divideSingleInto(&quotient, x, y[0])
        return normalizedCount(quotient, 0, length)
    }

    if x.count == y.count {
        let quotientDigit = divideSameSize(x, y)
        if quotientDigit == 0 {
            return 0
        }
        quotient[0] = quotientDigit
        return 1
    }

    var noRemainder = MutableSpan<UInt64>()
    let length = divideDigits(&quotient, &noRemainder, x, y)
    return normalizedCount(quotient, 0, length)
}

// result := 1 << bitIndex. Returns its length.
func oneShiftedLeft(_ result: inout MutableSpan<UInt64>, _ bitIndex: Int) -> Int {
    let digitIndex = bitIndex / digitBits
    precondition(result.count >= digitIndex + 1)
    for i in 0..<digitIndex {
        result[i] = 0
    }
    result[digitIndex] = 1 &<< UInt64(bitIndex % digitBits)
    return digitIndex + 1
}

// digits := digits * factor + summand.
func multiplyAddInPlace(_ digits: inout MutableSpan<UInt64>, _ factor: UInt64, _ summand: UInt64) {
    var carry = summand
    var high: UInt64 = 0
    for i in 0..<digits.count {
        // Compute this round's multiplication.
        var (current, newHigh) = digitMul(digits[i], factor)

        // Add last round's carryovers.
        var newCarry: UInt64 = 0
        current = digitAdd(current, high, &newCarry)
        current = digitAdd(current, carry, &newCarry)

        // Store result and prepare for next round.
        digits[i] = current
        carry = newCarry
        high = newHigh
    }
    assert(carry &+ high == 0)
}

#endif // USE_SWIFT_BIGINT_DIGITS
