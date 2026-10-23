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

// Computes the quotient Q and the remainder of A / b, such that Q = (A - remainder) / b, with 0 <= remainder < b.
// Writes Q into `quotient` unless that is empty, and returns the remainder. Q has a.count digits if a's top digit is
// at least b, and else a.count - 1, and quotient[a.count - 1] is then left alone.
//
// Every quotient digit divides two digits by the same divisor, so the divisor is shifted left until its top bit is set
// and its inverse computed once (DigitDiv); the dividend is shifted with it, a digit at a time, which leaves each
// quotient digit unchanged and the remainder shifted.
//
// The quotient is taken by value, so that it is passed in registers; a caller that reads it afterwards calls
// divideSingleInto.
func divideSingle(_ quotient: consuming MutableSpan<UInt64>, _ a: Span<UInt64>, _ b: UInt64) -> UInt64 {
    divideSingleInto(&quotient, a, b)
}

// divideSingle, for a caller that reads the quotient afterwards.
@inline(always)
func divideSingleInto(_ quotient: inout MutableSpan<UInt64>, _ a: Span<UInt64>, _ b: UInt64) -> UInt64 {
    precondition(b != 0)
    precondition(a.count > 0)
    if quotient.isEmpty {
        return divideSingleDigits(&quotient, a, b, writesQuotient: false)
    }
    precondition(quotient.count >= (a[a.count - 1] >= b ? a.count : a.count - 1))
    return divideSingleDigits(&quotient, a, b, writesQuotient: true)
}

@inline(always)
private func divideSingleDigits(_ quotient: inout MutableSpan<UInt64>, _ a: Span<UInt64>, _ b: UInt64, writesQuotient: Bool) -> UInt64 {
    let length = a.count
    let top = a[length - 1]
    // s is below digitBits, since b is not zero.
    let s = UInt64(b.leadingZeroBitCount)
    let divider = DigitDiv(b &<< s)
    if s == 0 {
        var remainder: UInt64 = 0
        var i = length
        if top < b {
            remainder = top
            i = length - 1
        }
        while i > 0 {
            i -= 1
            let (q, r) = divider.div2by1(remainder, a[i])
            if writesQuotient {
                quotient[i] = q
            }
            remainder = r
        }
        return remainder
    }

    // The shifted dividend's digit i is (a[i] << s) | (a[i - 1] >> rs), and its top digit is a[length - 1] >> rs.
    // s is between 1 and digitBits - 1 here, so neither shift is by digitBits or more.
    let rs = UInt64(digitBits) - s
    var remainder: UInt64
    var i: Int
    if top >= b {
        remainder = top &>> rs
        i = length
    } else {
        // The quotient's top digit is zero: start from the two top digits of the shifted dividend, which form
        // top << s plus the bits shifted in, below b << s.
        remainder = top &<< s
        if length > 1 {
            remainder |= a[length - 2] &>> rs
        }
        i = length - 1
    }
    while i > 1 {
        i -= 1
        let (q, r) = divider.div2by1(remainder, (a[i] &<< s) | (a[i - 1] &>> rs))
        if writesQuotient {
            quotient[i] = q
        }
        remainder = r
    }
    if i == 1 {
        let (q, r) = divider.div2by1(remainder, a[0] &<< s)
        if writesQuotient {
            quotient[0] = q
        }
        remainder = r
    }
    return remainder &>> s
}

// divideSingle with the quotient written over the dividend `digits`.
// Each step reads the dividend's digits i and i - 1 before it writes quotient digit i, so the shifted dividend is
// read before it is overwritten.
func divideSingleInPlace(_ digits: consuming MutableSpan<UInt64>, _ b: UInt64) -> UInt64 {
    precondition(b != 0)
    precondition(digits.count > 0)
    let length = digits.count
    let top = digits[length - 1]
    // s is below digitBits, since b is not zero.
    let s = UInt64(b.leadingZeroBitCount)
    let divider = DigitDiv(b &<< s)
    if s == 0 {
        var remainder: UInt64 = 0
        var i = length
        if top < b {
            remainder = top
            i = length - 1
        }
        while i > 0 {
            i -= 1
            (digits[i], remainder) = divider.div2by1(remainder, digits[i])
        }
        return remainder
    }

    // As in divideSingleDigits: s is between 1 and digitBits - 1.
    let rs = UInt64(digitBits) - s
    var remainder: UInt64
    var i: Int
    if top >= b {
        remainder = top &>> rs
        i = length
    } else {
        remainder = top &<< s
        if length > 1 {
            remainder |= digits[length - 2] &>> rs
        }
        i = length - 1
    }
    while i > 1 {
        i -= 1
        (digits[i], remainder) = divider.div2by1(remainder, (digits[i] &<< s) | (digits[i - 1] &>> rs))
    }
    if i == 1 {
        (digits[0], remainder) = divider.div2by1(remainder, digits[0] &<< s)
    }
    return remainder &>> s
}

// z[zStart...] := x - y over y's digits. Returns the borrow, 0 or 1.
func subtractAndReturnBorrow(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ x: Span<UInt64>, _ y: Span<UInt64>) -> UInt64 {
    // zStart is an index into z and the counts are digit counts, so this arithmetic cannot overflow.
    precondition(z.count &- zStart >= y.count && x.count >= y.count)
    var borrow: UInt64 = 0
    for i in 0..<y.count {
        var borrowOut: UInt64 = 0
        z[zStart &+ i] = digitSub2(x[i], y[i], borrow, &borrowOut)
        borrow = borrowOut
    }
    return borrow
}

// z[zStart...] += x. Returns the carry (0 or 1) after adding all of x's digits.
func inplaceAdd(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ x: Span<UInt64>) -> UInt64 {
    // zStart is an index into z and x.count a digit count, so this cannot overflow.
    precondition(z.count &- zStart >= x.count)
    var carry: UInt64 = 0
    for i in 0..<x.count {
        var newCarry: UInt64 = 0
        z[zStart + i] = digitAdd3(z[zStart + i], x[i], carry, &newCarry)
        carry = newCarry
    }
    return carry
}

// z[zStart...] -= x. Returns the borrow (0 or 1) after subtracting all of x's digits.
func inplaceSub(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ x: Span<UInt64>) -> UInt64 {
    // zStart is an index into z and x.count a digit count, so this cannot overflow.
    precondition(z.count &- zStart >= x.count)
    var borrow: UInt64 = 0
    for i in 0..<x.count {
        var borrowOut: UInt64 = 0
        z[zStart + i] = digitSub2(z[zStart + i], x[i], borrow, &borrowOut)
        borrow = borrowOut
    }
    return borrow
}

func greaterThanOrEqual(_ a: Span<UInt64>, _ b: Span<UInt64>) -> Bool {
    precondition(a.count == b.count)
    var i = a.count
    while i > 0 {
        i -= 1
        if a[i] != b[i] {
            return a[i] > b[i]
        }
    }
    return true
}

// JSBigInt::maxLength; JSBigInt.cpp checks it.
let maxLength = 16384

// Returns whether factor1 * factor2 > (high << digitBits) + low.
@inline(always)
func productGreaterThan(_ factor1: UInt64, _ factor2: UInt64, _ high: UInt64, _ low: UInt64) -> Bool {
    let (resultLow, resultHigh) = digitMul(factor1, factor2)
    return resultHigh > high || (resultHigh == high && resultLow > low)
}

// z[zStart ..< zStart + zCount] := x << shift, with shift < digitBits and zCount >= x.count. Returns the length
// written: x.count, plus the carry digit when shift is not 0 and zCount has room for it.
func leftShift(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ x: Span<UInt64>, _ shift: Int) -> Int {
    precondition(shift < digitBits)
    // zStart is an index into z and the counts are digit counts, so this arithmetic cannot overflow.
    precondition(zCount >= x.count && z.count &- zStart >= zCount)
    if shift == 0 {
        for i in 0..<x.count {
            z[zStart &+ i] = x[i]
        }
        return x.count
    }

    let shift = UInt64(shift)
    var carry: UInt64 = 0
    var i = 0
    while i < x.count {
        let d = x[i]
        z[zStart &+ i] = (d &<< shift) | carry
        carry = d &>> (UInt64(digitBits) - shift)
        i += 1
    }

    if i < zCount {
        z[zStart &+ i] = carry
        return i + 1
    }
    assert(carry == 0)
    return i
}

// z[zStart ..< zStart + zCount] := x >> shift, with shift < digitBits and x's leading zero digits ignored. Returns
// the length written, which is that of x without its leading zero digits.
func rightShift(_ z: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ x: Span<UInt64>, _ shift: Int) -> Int {
    precondition(shift < digitBits)
    // zStart is an index into z and the counts are digit counts, so this arithmetic cannot overflow.
    precondition(z.count &- zStart >= zCount)
    let x = normalize(x)
    if shift == 0 {
        precondition(zCount >= x.count)
        for i in 0..<x.count {
            z[zStart &+ i] = x[i]
        }
        return x.count
    }

    if x.isEmpty {
        return 0
    }

    precondition(zCount >= x.count)
    let shift = UInt64(shift)
    var carry = x[0] &>> shift
    let last = x.count - 1
    for i in 0..<last {
        let d = x[i + 1]
        z[zStart &+ i] = (d &<< (UInt64(digitBits) - shift)) | carry
        carry = d &>> shift
    }
    z[zStart &+ last] = carry
    return x.count
}

// Calls body with divideSchoolbook's buffers for a dividend of dividendCount digits and a divisor of divisorCount:
// the dividend's dividendCount + 1 digits, the normalized divisor's divisorCount and the divisor multiple's
// divisorCount + 1. They are zeroed, and on the stack when the dividend has at most 63 digits and the divisor at most
// 31 (64 digits in all for at most 31 and 15, else 128).
@inline(always)
func withSchoolbookBuffers<R>(
    _ dividendCount: Int,
    _ divisorCount: Int,
    _ body: (inout MutableSpan<UInt64>, inout MutableSpan<UInt64>, inout MutableSpan<UInt64>) -> R
) -> R {
    if dividendCount < 32 && divisorCount < 16 {
        var dividendStorage = [32 of UInt64](repeating: 0)
        var divisorStorage = [16 of UInt64](repeating: 0)
        var multipleStorage = [16 of UInt64](repeating: 0)
        var dividend = dividendStorage.mutableSpan
        var divisor = divisorStorage.mutableSpan
        var multiple = multipleStorage.mutableSpan
        return body(&dividend, &divisor, &multiple)
    }
    if dividendCount < 64 && divisorCount < 32 {
        var dividendStorage = [64 of UInt64](repeating: 0)
        var divisorStorage = [32 of UInt64](repeating: 0)
        var multipleStorage = [32 of UInt64](repeating: 0)
        var dividend = dividendStorage.mutableSpan
        var divisor = divisorStorage.mutableSpan
        var multiple = multipleStorage.mutableSpan
        return body(&dividend, &divisor, &multiple)
    }
    // The counts are digit counts, so adding one cannot overflow.
    var dividendStorage = UniqueArray<UInt64>(repeating: 0, count: dividendCount &+ 1)
    var divisorStorage = UniqueArray<UInt64>(repeating: 0, count: divisorCount)
    var multipleStorage = UniqueArray<UInt64>(repeating: 0, count: divisorCount &+ 1)
    var dividend = dividendStorage.mutableSpan
    var divisor = divisorStorage.mutableSpan
    var multiple = multipleStorage.mutableSpan
    return body(&dividend, &divisor, &multiple)
}

// The quotient loop of divideSchoolbook, steps D2 to D7, over the normalized dividend u, of m + n + 1 digits, and
// the normalized divisor, of n digits. Writes the quotient digits below qCount to q[qStart...]; u is left holding
// the normalized remainder. qhatv is scratch of n + 1 digits.
func divideSchoolbookLoop(
    _ q: inout MutableSpan<UInt64>,
    _ qStart: Int,
    _ qCount: Int,
    _ u: inout MutableSpan<UInt64>,
    _ divisor: Span<UInt64>,
    _ qhatv: inout MutableSpan<UInt64>,
    _ m: Int
) {
    let n = divisor.count
    // m, n and qStart are digit counts and offsets into u and q, so this arithmetic cannot overflow.
    precondition(n >= 2 && u.count &- m > n && qhatv.count > n)
    precondition(qCount == 0 || q.count &- qStart >= qCount)

    // D2.
    // Iterate over the dividend's digits (like the "grad school" algorithm).
    // {vn1} is the divisor's most significant digit.
    // Since {n} is >= 2, {vn1} and {vn2} are always accessible.
    let vn1 = divisor[n - 1]
    let vn2 = divisor[n - 2]
    let digitDiv = DigitDiv(vn1)
    var j = m &+ 1
    while j > 0 {
        j -= 1

        // D3.
        // Estimate the current iteration's quotient digit (see Knuth for details).
        // {qhat} is the current quotient digit.
        var qhat = UInt64.max

        // {ujn} is the dividend's most significant remaining digit.
        let ujn = u[j &+ n]
        if ujn != vn1 {
            // {rhat} is the current iteration's remainder.
            var rhat: UInt64 = 0
            // Estimate the current quotient digit by dividing the most significant digits of dividend and divisor.
            // The result will not be too small, but could be a bit too large.
            (qhat, rhat) = digitDiv.div(ujn, u[j &+ n &- 1])

            // Decrement the quotient estimate as needed by looking at the next digit, i.e. by testing whether
            // qhat * v_{n-2} > (rhat << digitBits) + u_{j+n-2}.
            let ujn2 = u[j &+ n &- 2]
            while productGreaterThan(qhat, vn2, rhat, ujn2) {
                // A product greater than a value has a non-zero factor, so this cannot wrap.
                qhat &-= 1
                let (newRhat, overflow) = rhat.addingReportingOverflow(vn1)
                rhat = newRhat
                if overflow {
                    break
                }
            }
        }

        // D4.
        // Multiply the divisor with the current quotient digit, and subtract it from the dividend. If there was
        // "borrow", then the quotient digit was one too high, so we must correct it and undo one subtraction of the
        // (shifted) divisor.
        if qhat != 0 {
            let filled = multiplySingle(divisor, qhat, &qhatv, 0)
            assert(filled == n + 1)

            var c = inplaceSub(&u, j, qhatv.span.extracting(0..<(n + 1)))
            if c != 0 {
                c = inplaceAdd(&u, j, divisor)
                // The carry out of the top digit cancels the borrow out of it.
                u[j &+ n] = u[j &+ n] &+ c
                qhat -= 1
            }
        }

        if j < qCount {
            q[qStart &+ j] = qhat
        } else {
            assert(qCount == 0 || qhat == 0)
        }
    }
}

// Steps D1 to D7 of divideSchoolbook, into the buffers withSchoolbookBuffers makes: writes Q to q[qStart...], and
// leaves the remainder in u, shifted left by the returned shift. Returns the length of Q, and the shift.
func divideSchoolbookIntoBuffers(
    _ q: inout MutableSpan<UInt64>,
    _ qStart: Int,
    _ qCount: Int,
    _ a: Span<UInt64>,
    _ b: Span<UInt64>,
    _ u: inout MutableSpan<UInt64>,
    _ divisorScratch: inout MutableSpan<UInt64>,
    _ qhatv: inout MutableSpan<UInt64>
) -> (quotientCount: Int, shift: Int) {
    let n = b.count
    let m = a.count - n

    // D1.
    // Left-shift inputs so that the divisor's MSB is set. This is necessary to prevent the digit-wise divisions (see
    // digitDiv call below) from overflowing (they take a two digits wide input, and return a one digit result).
    let shift = b[n - 1].leadingZeroBitCount

    // U holds the (continuously updated) remaining part of the dividend, which eventually becomes the remainder.
    let uCount = a.count + 1
    let filled = leftShift(&u, 0, uCount, a, shift)
    for i in filled..<uCount {
        u[i] = 0
    }

    // Each iteration reads and writes the n + 1 digit window of U starting at its own digit, and writes one digit of Q.
    // m + 1 is at most a.count, so it cannot overflow.
    let quotientCount = qCount == 0 ? 0 : min(m &+ 1, qCount)
    if shift > 0 {
        let filled = leftShift(&divisorScratch, 0, n, b, shift)
        assert(filled == n)
        divideSchoolbookLoop(&q, qStart, quotientCount, &u, divisorScratch.span.extracting(0..<n), &qhatv, m)
    } else {
        divideSchoolbookLoop(&q, qStart, quotientCount, &u, b, &qhatv, m)
    }
    return (quotientCount, shift)
}

// Computes Q(uotient) and R(emainder) for A/B, such that Q = (A - R) / B, with 0 <= R < B.
// Q is q[qStart ..< qStart + qCount] and R is r[rStart ..< rStart + rCount]. Both are optional: callers that are only
// interested in one of them can pass the other with a count of 0.
// If Q is present, its count must be at least a.count - b.count + 1, or a.count - b.count if the top digit of the
// quotient is known to be zero. If R is present, its count must be at least b.count.
// Returns the lengths written to Q and R. Callers must not assume either is trimmed of leading zero digits.
// See Knuth, Volume 2, section 4.3.1, Algorithm D.
func divideSchoolbook(
    _ q: inout MutableSpan<UInt64>,
    _ qStart: Int,
    _ qCount: Int,
    _ r: inout MutableSpan<UInt64>,
    _ rStart: Int,
    _ rCount: Int,
    _ a: Span<UInt64>,
    _ b: Span<UInt64>
) -> (quotientCount: Int, remainderCount: Int) {
    precondition(b.count >= 2) // Use divideSingle otherwise.
    precondition(a.count >= b.count) // No-op otherwise.
    precondition(qCount == 0 || qCount >= a.count - b.count)
    precondition(rCount == 0 || rCount >= b.count)
    // Every divisor reaching here is a BigInt's digits or a cached-modulo buffer, so this cannot fail.
    precondition(b.count <= maxLength)

    return withSchoolbookBuffers(a.count, b.count) { u, divisorScratch, qhatv in
        let (quotientCount, shift) = divideSchoolbookIntoBuffers(&q, qStart, qCount, a, b, &u, &divisorScratch, &qhatv)
        var remainderCount = 0
        if rCount != 0 {
            remainderCount = rightShift(&r, rStart, rCount, u.span.extracting(0...a.count), shift)
        }
        return (quotientCount, remainderCount)
    }
}

// Burnikel-Ziegler division, ported from V8 [1].
// Reference: "Fast Recursive Division" by Christoph Burnikel and Joachim Ziegler, Research Report
// MPI-I-98-1-022, Max-Planck-Institut fuer Informatik, 1998.
//
// [1]: https://source.chromium.org/chromium/chromium/src/+/main:v8/src/bigint/div-burnikel.cc
//
// Below, Q is in a buffer q of its own, B in a Span, and every other operand, the remainders and the scratch at given
// offsets in one buffer t.
let burnikelZieglerThreshold = 16
let minBurnikelZieglerDivisorSize = 24
let minBurnikelZieglerQuotientSize = 48

// t[zStart ..< zStart + zCount] := t[xStart ..< xStart + xCount] - y for normalized x >= y, zero-padded. The two
// ranges do not overlap.
func subZeroPaddedWithin(_ t: inout MutableSpan<UInt64>, _ zStart: Int, _ zCount: Int, _ xStart: Int, _ xCount: Int, _ y: Span<UInt64>) {
    precondition(xCount >= y.count)
    // zStart and xStart are indices into t and the counts are digit counts, so this arithmetic cannot overflow.
    precondition(zCount >= xCount && t.count &- zStart >= zCount && t.count &- xStart >= xCount)
    var borrow: UInt64 = 0
    var i = 0
    while i < y.count {
        var newBorrow: UInt64 = 0
        t[zStart &+ i] = digitSub2(t[xStart &+ i], y[i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    while i < xCount {
        var newBorrow: UInt64 = 0
        t[zStart &+ i] = digitSub(t[xStart &+ i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    assert(borrow == 0)
    while i < zCount {
        t[zStart &+ i] = 0
        i += 1
    }
}

// t[zStart...] := t[xStart...] + y over y's digits, for ranges that do not overlap. Returns the carry, 0 or 1.
func addAndReturnCarryWithin(_ t: inout MutableSpan<UInt64>, _ zStart: Int, _ xStart: Int, _ y: Span<UInt64>) -> UInt64 {
    // zStart and xStart are indices into t and y.count a digit count, so this arithmetic cannot overflow.
    precondition(t.count &- zStart >= y.count && t.count &- xStart >= y.count)
    var carry: UInt64 = 0
    for i in 0..<y.count {
        var newCarry: UInt64 = 0
        t[zStart &+ i] = digitAdd3(t[xStart &+ i], y[i], carry, &newCarry)
        carry = newCarry
    }
    return carry
}

// t[zStart ..< zStart + count] -= t[xStart ..< xStart + count], for ranges that do not overlap. Returns the borrow,
// 0 or 1.
func inplaceSubWithin(_ t: inout MutableSpan<UInt64>, _ zStart: Int, _ xStart: Int, _ count: Int) -> UInt64 {
    // zStart and xStart are indices into t and count a digit count, so this arithmetic cannot overflow.
    precondition(t.count &- zStart >= count && t.count &- xStart >= count)
    var borrow: UInt64 = 0
    for i in 0..<count {
        var borrowOut: UInt64 = 0
        t[zStart &+ i] = digitSub2(t[zStart &+ i], t[xStart &+ i], borrow, &borrowOut)
        borrow = borrowOut
    }
    return borrow
}

// t[destinationStart ..< destinationStart + destinationCount] := t[sourceStart ..< sourceStart + sourceCount],
// zero-extended, for ranges that do not overlap.
func copyAndZeroExtendWithin(
    _ t: inout MutableSpan<UInt64>,
    _ destinationStart: Int,
    _ destinationCount: Int,
    _ sourceStart: Int,
    _ sourceCount: Int
) {
    precondition(destinationCount >= sourceCount)
    // The starts are indices into t and the counts are digit counts, so this arithmetic cannot overflow.
    precondition(t.count &- destinationStart >= destinationCount && t.count &- sourceStart >= sourceCount)
    assert(destinationStart + destinationCount <= sourceStart || sourceStart + sourceCount <= destinationStart)
    for i in 0..<sourceCount {
        t[destinationStart &+ i] = t[sourceStart &+ i]
    }
    for i in sourceCount..<destinationCount {
        t[destinationStart &+ i] = 0
    }
}

// Q := A / B and R := A % B for B normalized (its top bit is set), A of exactly twice B's length and A's top half
// less than B, so that Q has B's length too. Q is q[qStart...]; A and R are t[aStart...] and t[rStart...]. Every
// digit of Q and R is written.
func burnikelZieglerBasecase(
    _ q: inout MutableSpan<UInt64>,
    _ qStart: Int,
    _ t: inout MutableSpan<UInt64>,
    _ rStart: Int,
    _ aStart: Int,
    _ b: Span<UInt64>
) {
    let n = b.count
    // The starts are indices into q and t and n is at most maxLength, so this arithmetic cannot overflow.
    precondition(q.count &- qStart >= n && t.count &- rStart >= n && t.count &- aStart >= 2 &* n)
    assert(b[n - 1] >> (UInt64(digitBits) - 1) != 0)
    let aCount = normalizedCount(t, aStart, 2 &* n)
    let comparison = compareDigits(t.span.extracting(droppingFirst: aStart).extracting(0..<aCount), b)
    if comparison <= 0 {
        for i in 0..<n {
            q[qStart &+ i] = 0
        }
        if comparison == 0 {
            // If A == B, then Q = 1, R = 0.
            for i in 0..<n {
                t[rStart &+ i] = 0
            }
            q[qStart] = 1
        } else {
            // If A < B, then Q = 0, R = A.
            copyAndZeroExtendWithin(&t, rStart, n, aStart, aCount)
        }
        return
    }

    let (quotientCount, remainderCount) = withSchoolbookBuffers(aCount, n) { u, divisorScratch, qhatv in
        precondition(n <= maxLength)
        let (quotientCount, shift) = divideSchoolbookIntoBuffers(
            &q,
            qStart,
            n,
            t.span.extracting(droppingFirst: aStart).extracting(0..<aCount),
            b,
            &u,
            &divisorScratch,
            &qhatv
        )
        let remainderCount = rightShift(&t, rStart, n, u.span.extracting(0...aCount), shift)
        return (quotientCount, remainderCount)
    }
    for i in quotientCount..<n {
        q[qStart &+ i] = 0
    }
    for i in remainderCount..<n {
        t[rStart &+ i] = 0
    }
}

// Algorithm 2 from the paper. Variable names same as there.
// Returns Q(uotient) and R(emainder) for A/B, with B having two thirds the size of A = [A1, A2, A3]: Q is n digits at
// q[qStart...], R 2n digits at t[rStart...], [A1, A2] 2n digits at t[a1a2Start...], A3 n digits at t[a3Start...]
// and B 2n digits. The scratch at t[scratchStart ..< scratchStart + scratchCount] holds the product D = Qhat * B2 and,
// while D is not live yet, the recursion.
func burnikelZieglerD3n2n(
    _ q: inout MutableSpan<UInt64>,
    _ qStart: Int,
    _ t: inout MutableSpan<UInt64>,
    _ rStart: Int,
    _ a1a2Start: Int,
    _ a3Start: Int,
    _ scratchStart: Int,
    _ scratchCount: Int,
    _ b: Span<UInt64>
) {
    precondition(b.count & 1 == 0)
    let n = b.count / 2
    // The starts are indices into q and t and n is at most maxLength, so this arithmetic cannot overflow.
    precondition(q.count &- qStart >= n)
    precondition(t.count &- rStart >= 2 &* n && t.count &- a1a2Start >= 2 &* n && t.count &- a3Start >= n)
    precondition(scratchCount >= 2 &* n && t.count &- scratchStart >= scratchCount)
    // Actual condition is stricter than length: A < B * 2^(digitBits * n)
    assert(compareDigits(t.span.extracting(a1a2Start..<(a1a2Start + 2 * n)), b) < 0)
    // 1. Split A into three parts A = [A1, A2, A3] with Ai < 2^(digitBits * n).
    let a1Start = a1a2Start &+ n
    let a2Start = a1a2Start
    // 2. Split B into two parts B = [B1, B2] with Bi < 2^(digitBits * n).
    let b1 = b.extracting(n..<(2 * n))
    let b2 = b.extracting(0..<n)
    // 3. Distinguish the cases A1 < B1 or A1 >= B1.
    let r1Start = rStart &+ n
    var r1High: UInt64 = 0
    if compareDigits(t.span.extracting(droppingFirst: a1Start).extracting(0..<n), b1) < 0 {
        // 3a. If A1 < B1, compute Qhat = floor([A1, A2] / B1) with remainder R1 using algorithm D2n1n.
        burnikelZieglerD2n1n(&q, qStart, &t, r1Start, a1a2Start, scratchStart, scratchCount, b1)
    } else {
        // 3b. If A1 >= B1, set Qhat = 2^(digitBits * n) - 1 and set R1 = [A1, A2] - [B1, 0] + [0, B1]
        for i in 0..<n {
            q[qStart &+ i] = UInt64.max
        }
        // Step 1: compute A1 - B1, which can't underflow because of the comparison guarding this else-branch, and
        // always has a one-digit result because of this function's preconditions.
        subZeroPaddedWithin(&t, r1Start, n, a1Start, n, b1)
        assert(normalizedCount(t, r1Start, n) <= 1)
        r1High = t[r1Start]
        // Step 2: compute A2 + B1.
        // [A1, A2] < B makes A1 at most B1, so here A1 == B1 and r1High is 0 before the carry.
        r1High &+= addAndReturnCarryWithin(&t, r1Start, a2Start, b1)
    }
    // 4. Compute D = Qhat * B2 using (Karatsuba) multiplication.
    let dStart = scratchStart
    multiplyZeroPadded(q.span.extracting(droppingFirst: qStart).extracting(0..<n), b2, false, &t, dStart, 2 &* n)
    // 5. Compute Rhat = R1*2^(digitBits * n) + A3 - D = [R1, A3] - D.
    copyAndZeroExtendWithin(&t, rStart, n, a3Start, n)
    // 6. As long as Rhat < 0, repeat:
    while r1High == 0
        && !greaterThanOrEqual(
            t.span.extracting(droppingFirst: rStart).extracting(0..<(2 &* n)),
            t.span.extracting(droppingFirst: dStart).extracting(0..<(2 &* n))
        )
    {
        // 6a. Rhat = Rhat + B
        r1High += inplaceAdd(&t, rStart, b)
        // 6b. Qhat = Qhat - 1
        let qhatBorrow = subtractDigitAndPropagate(&q, qStart, n, 1)
        assert(qhatBorrow == 0)
    }
    // 5. Compute Rhat = R1*2^(digitBits * n) + A3 - D = [R1, A3] - D.
    let borrow = inplaceSubWithin(&t, rStart, dStart, 2 &* n)
    assert(borrow == r1High)
    assert(compareDigits(t.span.extracting(rStart..<(rStart + 2 * n)), b) < 0)
    // 7. Return R = Rhat, Q = Qhat.
}

// Algorithm 1 from the paper. Variable names same as there.
// Returns Q(uotient) and R(emainder) for A/B, with A twice the size of B: Q is n digits at q[qStart...], R n digits
// at t[rStart...] and A 2n digits at t[aStart...]. The scratch at t[scratchStart ..< scratchStart + scratchCount]
// must have room for the recursion, 2 * b.count digits.
func burnikelZieglerD2n1n(
    _ q: inout MutableSpan<UInt64>,
    _ qStart: Int,
    _ t: inout MutableSpan<UInt64>,
    _ rStart: Int,
    _ aStart: Int,
    _ scratchStart: Int,
    _ scratchCount: Int,
    _ b: Span<UInt64>
) {
    let n = b.count
    // The starts are indices into q and t and n is at most maxLength, so this arithmetic cannot overflow.
    precondition(q.count &- qStart >= n && t.count &- rStart >= n && t.count &- aStart >= 2 &* n)
    // A < B * 2^(digitBits * n)
    assert(compareDigits(t.span.extracting((aStart + n)..<(aStart + 2 * n)), b) < 0)
    // 1. If n is odd or smaller than some convenient constant, compute Q and R by school division and return.
    if n & 1 != 0 || n < burnikelZieglerThreshold {
        burnikelZieglerBasecase(&q, qStart, &t, rStart, aStart, b)
        return
    }
    precondition(scratchCount >= 2 &* n && t.count &- scratchStart >= scratchCount)
    // 2. Split A into four parts A = [A1, ..., A4] with Ai < 2^(digitBits * n / 2). Split B into two parts [B2, B1]
    //    with Bi < 2^(digitBits * n / 2).
    let a1a2Start = aStart &+ n
    let a3Start = aStart &+ n / 2
    let a4Start = aStart
    // 3. Compute the high part Q1 of floor(A/B) as Q1 = floor([A1, A2, A3] / [B1, B2]) with remainder R1 = [R11, R12],
    //    using algorithm D3n2n. R1 outlives the recursion, so it takes the front of the scratch and the recursion the
    //    rest.
    let r1Start = scratchStart
    let recursionStart = scratchStart &+ n
    let recursionCount = scratchCount &- n
    burnikelZieglerD3n2n(&q, qStart &+ n / 2, &t, r1Start, a1a2Start, a3Start, recursionStart, recursionCount, b)
    // 4. Compute the low part Q2 of floor(A/B) as Q2 = floor([R11, R12, A4] / [B1, B2]) with remainder R, using
    //    algorithm D3n2n.
    burnikelZieglerD3n2n(&q, qStart, &t, rStart, r1Start, a4Start, recursionStart, recursionCount, b)
    // 5. Return Q = [Q1, Q2] and R.
}

// Algorithm 3 from the paper. Variable names same as there.
// Returns Q(uotient) and R(emainder) for A/B (no size restrictions). Both Q and R are optional. Every digit of Q and
// of R is written. Returns their lengths.
func divideBurnikelZiegler(
    _ quotient: inout MutableSpan<UInt64>,
    _ remainder: inout MutableSpan<UInt64>,
    _ a: Span<UInt64>,
    _ b: Span<UInt64>
) -> (quotientCount: Int, remainderCount: Int) {
    precondition(a.count >= b.count)
    precondition(remainder.isEmpty || remainder.count >= b.count)
    precondition(quotient.isEmpty || quotient.count > a.count - b.count)
    precondition(a.count <= maxLength)
    assert(a[a.count - 1] != 0)
    assert(b[b.count - 1] != 0)
    let quotientLength = a.count - b.count + 1
    let s = b.count
    // The requirements are:
    // - n >= s, n as small as possible.
    // - m must be a power of two.
    // 1. Set m = min {2^k | 2^k * burnikelZieglerThreshold > s}.
    let m = 1 << (Int.bitWidth - (s / burnikelZieglerThreshold).leadingZeroBitCount)
    // 2. Set j = roundup(s/m) and n = j * m.
    // a.count <= maxLength, so s, m, n and the offsets below cannot overflow.
    let j = (s &+ m &- 1) / m
    let n = j &* m
    // 3. Set sigma = max{tao | 2^tao * B < 2^(digitBits * n)}.
    let sigma = b[s - 1].leadingZeroBitCount
    let digitShift = n &- s
    // We need an extra digit if A's top digit does not have enough space for the left-shift by {sigma}.
    // Additionally, the top bit of A must be 0 (see "-1" in step 5 below), which combined with B being normalized
    // (i.e. B's top bit is 1) ensures the preconditions of the helper functions.
    let extraDigit = a[a.count - 1].leadingZeroBitCount < sigma + 1 ? 1 : 0
    let aLength = a.count &+ digitShift &+ extraDigit
    // 4. Set B = B * 2^sigma to normalize B. Shift A by the same amount.
    // Usage of temporary storage: B[n] and Qi[n] each in their own buffer; Z[2n], Ri[n], scratch for the recursion
    // [2n] and A[aLength] in t. Every digit starts out zero.
    var bStorage = UniqueArray<UInt64>(repeating: 0, count: n)
    do {
        var bShifted = bStorage.mutableSpan
        let shiftedDivisor = leftShift(&bShifted, digitShift, s, b, sigma)
        assert(shiftedDivisor == s)
    }
    let zStart = 0
    let riStart = 2 &* n
    let scratchStart = 3 &* n
    let aStart = 5 &* n
    var tStorage = UniqueArray<UInt64>(repeating: 0, count: 5 &* n &+ aLength)
    var t = tStorage.mutableSpan
    // A shift of zero copies a's digits without the carry digit, which stays zero.
    _ = leftShift(&t, aStart &+ digitShift, aLength &- digitShift, a, sigma)
    let bShifted = bStorage.span
    // 5. Set t = min{t >= 2 | A < 2^(digitBits * t * n - 1)}.
    let blocks = max((aLength &+ n &- 1) / n, 2)
    // Every block below the top one is a full n digits of Q.
    precondition(quotient.isEmpty || quotient.count >= n &* (blocks - 2))
    // 6. Split A conceptually into t blocks.
    // 7. Set Z_(t-2) = [A_(t-1), A_(t-2)].
    let topOffset = min(n &* (blocks - 2), aLength)
    copyAndZeroExtendWithin(&t, zStart, 2 &* n, aStart &+ topOffset, clampedCount(aLength, n &* (blocks - 2), 2 &* n))
    // 8. For i from t-2 downto 0 do:
    var qiStorage = UniqueArray<UInt64>(repeating: 0, count: n)
    var qi = qiStorage.mutableSpan
    do {
        // First iteration unrolled and specialized.
        // We might not have n digits at the top of Q, so use temporary storage for Qi...
        burnikelZieglerD2n1n(&qi, 0, &t, riStart, zStart, scratchStart, 2 &* n, bShifted)
        if !quotient.isEmpty {
            // ...but there *will* be enough space for any non-zero result digits!
            let chunkCount = normalizedCount(qi, 0, n)
            let targetStart = n &* (blocks - 2)
            copyAndZeroExtend(&quotient, targetStart, quotient.count &- targetStart, qi.span.extracting(0..<chunkCount))
        }
    }
    // Now loop over any remaining iterations.
    var i = blocks - 2
    while i > 0 {
        i -= 1
        // 8b. If i > 0, set Z_(i-1) = [Ri, A_(i-1)].
        // (De-duped with unrolled first iteration, hence reading A_(i).)
        copyAndZeroExtendWithin(&t, zStart &+ n, n, riStart, n)
        copyAndZeroExtendWithin(&t, zStart, n, aStart &+ n &* i, clampedCount(aLength, n &* i, n))
        // 8a. Using algorithm D2n1n compute Qi, Ri such that Zi = B*Qi + Ri.
        if quotient.isEmpty {
            burnikelZieglerD2n1n(&qi, 0, &t, riStart, zStart, scratchStart, 2 &* n, bShifted)
        } else {
            burnikelZieglerD2n1n(&quotient, i &* n, &t, riStart, zStart, scratchStart, 2 &* n, bShifted)
        }
    }
    // 9. Return Q = [Q_(t-2), ..., Q_0] and R = R_0 * 2^(-sigma).
    assert(normalizedCount(t, riStart, digitShift) == 0)
    var remainderCount = 0
    if !remainder.isEmpty {
        let shifted = rightShift(
            &remainder,
            0,
            remainder.count,
            t.span.extracting(droppingFirst: riStart).extracting(0..<n).extracting(droppingFirst: digitShift),
            sigma
        )
        for k in shifted..<remainder.count {
            remainder[k] = 0
        }
        remainderCount = s
    }
    return (quotient.isEmpty ? 0 : quotientLength, remainderCount)
}

@inline(always)
func shouldUseBurnikelZiegler(_ dividendSize: Int, _ divisorSize: Int) -> Bool {
    divisorSize >= minBurnikelZieglerDivisorSize && dividendSize - divisorSize + 1 >= minBurnikelZieglerQuotientSize
}

// Computes Q(uotient) and R(emainder) for A/B with the algorithm suited to the operands' sizes. Either Q or R may be
// empty; Q, when present, must have at least a.count - b.count + 1 digits. Returns the lengths written to Q and R,
// which are not normalized.
func divideDigitsInto(
    _ quotient: inout MutableSpan<UInt64>,
    _ remainder: inout MutableSpan<UInt64>,
    _ a: Span<UInt64>,
    _ b: Span<UInt64>
) -> (quotientCount: Int, remainderCount: Int) {
    precondition(b.count >= 2)
    precondition(a.count >= b.count)
    precondition(quotient.isEmpty || quotient.count > a.count - b.count)
    precondition(remainder.isEmpty || remainder.count >= b.count)
    if shouldUseBurnikelZiegler(a.count, b.count) {
        return divideBurnikelZiegler(&quotient, &remainder, a, b)
    }
    return divideSchoolbook(&quotient, 0, quotient.count, &remainder, 0, remainder.count, a, b)
}

// Estimates the single-digit quotient of a / b, with a and b of the same length and a's top digit greater than b's,
// from Algorithm D on their top two or three digits. The estimate is exact or one too large.
@inline(always)
func estimateQhat(_ a: Span<UInt64>, _ b: Span<UInt64>) -> UInt64 {
    assert(a.count == b.count)
    let n = a.count
    assert(n > 1) // one digit case is already handled via divideSingle.
    assert(b[n - 1] != 0) // b should be normalized
    assert(a[n - 1] > b[n - 1])

    // a's top digit > b's, so a > b and quotient is at least 1.
    // Since a and b have the same number of digits, the quotient fits in one digit.
    //
    // We estimate qhat from Algorithm D by normalizing only the top 2-3 digits (no vector allocation), then verify by
    // computing qhat * b and comparing with a.

    let shift = UInt64(b[n - 1].leadingZeroBitCount)

    // Compute normalized top digits inline.
    // vn1 = normalized b[n-1]
    // vn2 = normalized b[n-2]
    // un = overflow from normalizing a (high digit after left shift)
    // un1 = normalized a[n-1]
    // un2 = normalized a[n-2]
    let vn1: UInt64
    let vn2: UInt64
    let un: UInt64
    let un1: UInt64
    let un2: UInt64

    if shift == 0 {
        vn1 = b[n - 1]
        vn2 = b[n - 2]
        un = 0
        un1 = a[n - 1]
        un2 = a[n - 2]
    } else {
        // Left-shift by 'shift' bits to normalize
        let rest = UInt64(digitBits) - shift
        vn1 = (b[n - 1] &<< shift) | (b[n - 2] &>> rest)
        vn2 = (b[n - 2] &<< shift) | (n >= 3 ? (b[n - 3] &>> rest) : 0)
        un = a[n - 1] &>> rest
        un1 = (a[n - 1] &<< shift) | (a[n - 2] &>> rest)
        un2 = (a[n - 2] &<< shift) | (n >= 3 ? (a[n - 3] &>> rest) : 0)
    }

    // Estimate quotient using the normalized top digits.
    // Since a and b have the same number of digits with a's top digit greater than b's, after normalization un < vn1
    // is guaranteed:
    // - vn1 has its MSB set, so vn1 >= 2^(digitBits-1)
    // - un = a[n-1] >> (digitBits - shift), which is at most 2^(digitBits-1) - 1
    assert(un < vn1)

    var (qhat, rhat) = digitDivInline(un, un1, vn1)

    // Refine qhat using the second most significant digit of divisor.
    while productGreaterThan(qhat, vn2, rhat, un2) {
        // A product greater than a value has a non-zero factor, so this cannot wrap.
        qhat &-= 1
        let (newRhat, overflow) = rhat.addingReportingOverflow(vn1)
        rhat = newRhat
        if overflow {
            break
        }
    }

    return qhat
}

// Returns a / b for a > b of the same length, which is a single digit.
func divideSameSize(_ a: Span<UInt64>, _ b: Span<UInt64>) -> UInt64 {
    precondition(a.count == b.count)
    let n = a.count
    precondition(n >= 2) // Use divideSingle otherwise.
    assert(b[n - 1] != 0) // b should be normalized

    // absoluteCompare ensures that a > b.

    // MSB is the same. Thus result is 1 or 0.
    if a[n - 1] == b[n - 1] {
        return 1 // a >= b
    }

    var qhat = estimateQhat(a, b)

    // Verify qhat by computing a - qhat * b inline, one digit at a time, with a single carry that holds the
    // product's high digit plus what the digit's subtraction borrowed. If qhat * b > a, decrement qhat.
    // Since b[i] < 2^digitBits and carry <= qhat, qhat * b[i] + carry <= qhat * 2^digitBits, so the next carry
    // is at most qhat: it fits in a digit, and it is non-zero after the last digit exactly when qhat * b > a.
    var carry: UInt64 = 0
    for i in 0..<n {
        let (low, high) = digitMul(qhat, b[i])
        // Wraps on purpose: the 128-bit difference is negative when the digit borrows, and its high digit is then
        // 2^digitBits minus the borrow, which is 1 or 2.
        let difference = UInt128(a[i]) &- UInt128(low) &- UInt128(carry)
        // Wraps on purpose: subtracting 2^digitBits minus the borrow adds the borrow, and the sum is at most qhat.
        // The shift count is less than the width, so &>> shifts as >> would.
        carry = high &- UInt64(truncatingIfNeeded: difference &>> 64)
    }

    if carry != 0 {
        // estimateQhat's estimate is at least 1, so this cannot wrap.
        qhat &-= 1
    }

    return qhat
}

// remainder := a % b for a > b of the same length. Returns the remainder's length, a.count.
func remainderSameSize(_ remainder: consuming MutableSpan<UInt64>, _ a: Span<UInt64>, _ b: Span<UInt64>) -> Int {
    precondition(a.count == b.count)
    let n = a.count
    precondition(n >= 2) // Use divideSingle otherwise.
    assert(b[n - 1] != 0) // b should be normalized
    assert(remainder.count >= n)

    // absoluteCompare ensures that a > b.

    // a's top digit == b's: quotient is 0 or 1
    if a[n - 1] == b[n - 1] {
        return subSchoolbook(a, b, &remainder)
    }

    let qhat = estimateQhat(a, b)

    // Compute remainder = a - qhat * b inline without allocating a vector, in a single pass with one carry, as
    // divideSameSize does: carry stays at most qhat, and is non-zero after the last digit exactly when qhat * b > a.
    var carry: UInt64 = 0
    for i in 0..<n {
        let (low, high) = digitMul(qhat, b[i])
        // Wraps on purpose: the 128-bit difference is negative when the digit borrows, and its high digit is then
        // 2^digitBits minus the borrow, which is 1 or 2.
        let difference = UInt128(a[i]) &- UInt128(low) &- UInt128(carry)
        remainder[i] = UInt64(truncatingIfNeeded: difference)
        // Wraps on purpose: subtracting 2^digitBits minus the borrow adds the borrow, and the sum is at most qhat.
        // The shift count is less than the width, so &>> shifts as >> would.
        carry = high &- UInt64(truncatingIfNeeded: difference &>> 64)
    }

    // If qhat * b > a, qhat was too large, so add back b.
    if carry != 0 {
        _ = inplaceAdd(&remainder, 0, b)
    }

    return n
}

// The entry point's kernel. Returns the length of quotient if it is not empty, and else that of remainder.
func divideDigits(
    _ quotient: inout MutableSpan<UInt64>,
    _ remainder: inout MutableSpan<UInt64>,
    _ a: Span<UInt64>,
    _ b: Span<UInt64>
) -> Int {
    let (quotientCount, remainderCount) = divideDigitsInto(&quotient, &remainder, a, b)
    return quotient.isEmpty ? remainderCount : quotientCount
}

// The cached modulus, with its fold factor or its inverse kept by the VM.

// JSBigInt::maxCachedModDivisorSize; JSBigInt.cpp checks it.
let maxCachedModDivisorSize = 32

// JSBigInt::maxFixedCachedModDivisorSize; JSBigInt.cpp checks it.
let maxFixedCachedModDivisorSize = 4

// Compute the multiplicative inverse Inv, approximately floor(2^(2n*digitBits) / B), for cached modulo, into inverse.
// Given divisor B with n digits, the inverse has n+1 digits.
// Uses V8's bit-negation trick to avoid a (2n+1)-digit dividend:
//   A = ~(B << n), approximately 2^(2n) - B*2^n - 1, then Inv = A/B + 2^n (undo the subtraction).
//
// This is computing I in Algorithm 2.5 in the following reference.
// R. P. Brent and P. Zimmermann, Modern Computer Arithmetic. Cambridge, U.K.: Cambridge University Press, 2010.
func cachedModMakeInverse(_ b: Span<UInt64>, _ inverse: inout MutableSpan<UInt64>) {
    let n = b.count
    assert(n >= 2 && n <= maxCachedModDivisorSize)
    if n <= maxCachedModDivisorSize {
        var aStorage = [64 of UInt64](repeating: 0) // 2 * maxCachedModDivisorSize
        var a = aStorage.mutableSpan
        cachedModMakeInverse(b, &a, &inverse)
    } else {
        var aStorage = UniqueArray<UInt64>(repeating: 0, count: 2 * n)
        var a = aStorage.mutableSpan
        cachedModMakeInverse(b, &a, &inverse)
    }
}

// cachedModMakeInverse with a, of at least 2 * b.count digits, to construct A in.
func cachedModMakeInverse(_ b: Span<UInt64>, _ a: inout MutableSpan<UInt64>, _ inverse: inout MutableSpan<UInt64>) {
    let n = b.count
    // n is a digit count, so n + 1 and n + i cannot overflow.
    let invLen = n &+ 1

    // Construct A (2n digits) using bit-negation trick:
    // A[0..n-1] = ~0 (all 1-bits), A[n..2n-1] = ~B[i-n]
    for i in 0..<n {
        a[i] = UInt64.max
    }
    for i in 0..<n {
        a[n &+ i] = ~b[i]
    }

    // Inv = A / B. Since A has 2n digits and B has n digits, quotient has at most n+1 digits (which is invLen).
    var noRemainder = MutableSpan<UInt64>()
    _ = divideSchoolbook(&inverse, 0, inverse.count, &noRemainder, 0, 0, a.span.extracting(0..<(2 * n)), b)

    // Undo the bit-negation: add 1 to the upper part (starting at digit n).
    // This corresponds to adding back 2^n that was subtracted by the trick.
    precondition(inverse.count == invLen)
    do {
        var carry: UInt64 = 0
        inverse[n] = digitAdd(inverse[n], 1, &carry)
        assert(carry == 0)
    }

    // Optionally add 1 to the whole inverse to improve convergence of the corrective loop in cachedMod. But don't do
    // it when there's a risk of overflow.
    if inverse[0] != UInt64.max || inverse[invLen - 1] != UInt64.max {
        var carry: UInt64 = 0
        inverse[0] = digitAdd(inverse[0], 1, &carry)
        var j = 1
        while j < invLen && carry != 0 {
            var c: UInt64 = 0
            inverse[j] = digitAdd(inverse[j], carry, &c)
            carry = c
            j += 1
        }
    }
}

// Reduction factor for divisors close to a power of the digit base. With n = b.count and T = 2^(n * digitBits),
// returns C = T mod B when T = q * B + C has a single-digit C and q <= maxFoldQuotient, and 0 otherwise.
func cachedModFoldFactor(_ b: Span<UInt64>) -> UInt64 {
    // This prepares for Crandall reduction, which is efficient when the divisor `b` is a pseudo-Mersenne number
    // 2^k - c with a small c. The fold factor returned here is c << (n * digitBits - k) rather than c itself, since T
    // sits at the next whole digit boundary at or above b.
    let n = b.count
    precondition(n >= 2 && n <= maxCachedModDivisorSize)

    // T is 1 followed by n zero digits, so it needs n + 1 digits. The quotient of an (n + 1)-digit value by an n-digit
    // one needs at most two digits, and the remainder at most n.
    var tStorage = [33 of UInt64](repeating: 0) // maxCachedModDivisorSize + 1
    tStorage[n] = 1

    var qStorage = [2 of UInt64](repeating: 0)
    var rStorage = [32 of UInt64](repeating: 0) // maxCachedModDivisorSize
    var q = qStorage.mutableSpan
    var r = rStorage.mutableSpan
    // Neither result is guaranteed to have its leading zero digits trimmed, so normalize before judging their widths.
    let (quotientCount, remainderCount) = divideSchoolbook(&q, 0, 2, &r, 0, n, tStorage.span.extracting(0...n), b)
    let quotientLength = normalizedCount(q, 0, quotientCount)
    let remainderLength = normalizedCount(r, 0, remainderCount)

    // A divisor B of n digits qualifies for the folding reduction when T = 2^(n * digitBits) satisfies T = q * B + C
    // with C a single digit and q no larger than this bound. C fitting one digit keeps each fold a single-digit
    // multiply and makes two folds always sufficient; q bounds how many times the corrective loop subtracts.
    let maxFoldQuotient: UInt64 = 4
    if quotientLength != 1 || q[0] > maxFoldQuotient {
        return 0
    }

    // An empty remainder would mean B divides T exactly, so B is a power of two, which the shift paths handle and
    // which would collide with the not-qualifying sentinel anyway.
    if remainderLength != 1 {
        return 0
    }

    return r[0]
}

// This is Crandall reduction. R = A mod B, into remainder's first n = b.count digits, for a divisor whose reduction
// factor C = 2^(n * digitBits) mod B is a single digit.
//
// Splitting A into low and high halves of n digits gives A = lo + hi * 2^(n * digitBits), and since
// 2^(n * digitBits) is congruent to C, that is congruent to lo + hi * C. Each such fold is a row of single-digit
// multiplies.
//
// Two folds always suffice. Write D for the digit base. The first fold's running carry never exceeds C: a column
// computes a[i] + a[n + i] * C + carry, so if the incoming carry is at most C the total is at most
// (D - 1) + (D - 1) * C + C = C * D + D - 1, whose high half is again at most C. The carry starts at zero, so one digit
// above the low n always holds it. Folding that digit back multiplies it by C once more, adding less than D^2 to a
// value below D^n, so with n >= 2 the final carry out is at most 1 and the residue stays below 2 * D^n. Since
// B = (D^n - C) / q, that is roughly 2 * q * B, so the corrective loop runs a bounded number of times given the q cap
// the factor check enforces.
@inline(always)
func cachedModFold(_ remainder: inout MutableSpan<UInt64>, _ a: Span<UInt64>, _ b: Span<UInt64>, _ c: UInt64) {
    let n = b.count
    // A one-digit divisor would leave the second fold's carry unpropagated and turn the corrective loop into a walk
    // over the whole digit range, so fail here rather than spin.
    precondition(n >= 2)
    precondition(remainder.count >= n)
    precondition(a.count >= n && a.count <= 2 * n)

    cachedModFoldDigits(&remainder, a, b, c, reducingOnceFirst: false)
}

// cachedModFold for a divisor of exactly n digits and a dividend of exactly aCount digits, with n from 2 to
// maxFixedCachedModDivisorSize and aCount from n to 2n. Called with constant sizes, the fold loops unroll and the
// per-column bound arithmetic folds away.
@inline(always)
func cachedModFoldFixed(
    _ remainder: inout MutableSpan<UInt64>,
    _ a: Span<UInt64>,
    _ b: Span<UInt64>,
    _ c: UInt64,
    _ n: Int,
    _ aCount: Int
) {
    precondition(remainder.count >= n)
    cachedModFoldDigits(&remainder, a.extracting(0..<aCount), b.extracting(0..<n), c, reducingOnceFirst: true)
}

// Subtract b from the value high * 2^(n * digitBits) + r once, if that value is at least b, and return the new high
// digit. The difference is always formed and then selected in or discarded, so no branch depends on the comparison;
// the borrow out of the low n digits answers it, since a borrow is covered exactly when high is non-zero.
@inline(always)
func reduceOnce(_ r: inout MutableSpan<UInt64>, _ b: Span<UInt64>, _ high: UInt64) -> UInt64 {
    let n = b.count
    precondition(n <= maxFixedCachedModDivisorSize && r.count >= n)

    // A SIMD4, so that callers need no stack protector.
    var difference = SIMD4<UInt64>() // maxFixedCachedModDivisorSize digits
    var borrow: UInt64 = 0
    for i in 0..<n {
        var borrowOut: UInt64 = 0
        difference[i] = digitSub2(r[i], b[i], borrow, &borrowOut)
        borrow = borrowOut
    }

    // All ones when the difference replaces r (high is non-zero or nothing was borrowed), else zero. A mask, because
    // -O turns a conditional back into a branch on the borrow.
    let select = 0 &- UInt64((high | (borrow ^ 1)) != 0 ? 1 : 0)
    for i in 0..<n {
        r[i] = (difference[i] & select) | (r[i] & ~select)
    }
    // A borrow out with the mask set needs a non-zero high to cover it, so this cannot wrap.
    return high &- (borrow & select)
}

// The fold of cachedModFold into remainder's first n = b.count digits, for a.count from n to 2n. With
// reducingOnceFirst, the first corrective subtraction is a branch-free one when b's top bit is clear.
@inline(always)
func cachedModFoldDigits(
    _ remainder: inout MutableSpan<UInt64>,
    _ a: Span<UInt64>,
    _ b: Span<UInt64>,
    _ c: UInt64,
    reducingOnceFirst: Bool
) {
    let n = b.count

    // First fold: r = a[0..n-1] + a[n..a.count-1] * c, keeping the carry out separately.
    var carry: UInt64 = 0
    let aHigh = a.extracting(droppingFirst: n)
    for i in 0..<n {
        var high: UInt64 = 0
        var low = a[i]
        if i < aHigh.count {
            // A UInt128 product, not digitMul: -O leaves multipliedFullWidth out of line in a function this large.
            let product = UInt128(aHigh[i]) * UInt128(c)
            let productLow = UInt64(truncatingIfNeeded: product)
            let productHigh = UInt64(truncatingIfNeeded: product >> 64)
            high = productHigh
            var addCarry: UInt64 = 0
            low = digitAdd(low, productLow, &addCarry)
            // productHigh is at most 2^digitBits - 2, so adding the carry cannot wrap.
            high &+= addCarry
        }
        var sumCarry: UInt64 = 0
        remainder[i] = digitAdd(low, carry, &sumCarry)
        // The column's total is below 2^(2 * digitBits) (see above), so its high digit cannot wrap.
        carry = high &+ sumCarry
    }

    // Second fold: the single digit above the low n is worth c times its value.
    if carry != 0 {
        let product = UInt128(carry) * UInt128(c)
        let productLow = UInt64(truncatingIfNeeded: product)
        let productHigh = UInt64(truncatingIfNeeded: product >> 64)
        var addCarry: UInt64 = 0
        remainder[0] = digitAdd(remainder[0], productLow, &addCarry)
        // productHigh is at most 2^digitBits - 2, so adding the carry cannot wrap.
        var propagate = productHigh &+ addCarry
        var i = 1
        while i < n && propagate != 0 {
            var nextCarry: UInt64 = 0
            remainder[i] = digitAdd(remainder[i], propagate, &nextCarry)
            propagate = nextCarry
            i += 1
        }
        carry = propagate
    }

    // When b's top bit is clear the loop below can subtract b more than once, and its branch would mispredict about
    // half the time.
    if reducingOnceFirst && b[n - 1] >> (UInt64(digitBits) - 1) == 0 {
        carry = reduceOnce(&remainder, b, carry)
    }
    while carry != 0 || greaterThanOrEqual(remainder.span.extracting(0..<n), b) {
        // A borrow out needs a non-zero carry to cover it, so this cannot wrap.
        carry &-= inplaceSub(&remainder, 0, b)
    }
}

// Cached modulo: R = A mod B, into remainder's first n = b.count digits, using the precomputed inverse, of n + 1
// digits. A must have between n and 2n digits.
// R. P. Brent and P. Zimmermann, Modern Computer Arithmetic. Cambridge, U.K.: Cambridge University Press, 2010.
//
// Step 1 computes only the high digits of A * Inv, from column startPos = 2n - 2 up, losing the carry out of the
// columns below it, so that the estimated quotient Q = floor(P / B^(2n)) of the product P is the true quotient or
// one less. The loss E is below (2n - 2) * B^(2n-1), which is below B^(2n) since divisors are capped at
// maxCachedModDivisorSize digits; raising that cap anywhere near 2^digitBits would invalidate this. Step 5's
// corrective loop handles Q being off by 1.
//
// Out of line, so that cachedMod keeps a small frame on its folding path.
@inline(never)
func cachedModBarrett(_ remainder: inout MutableSpan<UInt64>, _ a: Span<UInt64>, _ b: Span<UInt64>, _ inverse: Span<UInt64>) {
    // The scratch holds the dividend (at most 2n digits) plus the inverse (n + 1 digits), on the stack up to
    // 3 * maxCachedModDivisorSize + 1 digits.
    // The counts are digit counts, so their sum cannot overflow.
    let scratchSpace = a.count &+ inverse.count
    if scratchSpace <= 3 * maxCachedModDivisorSize + 1 {
        var scratchStorage = [97 of UInt64](repeating: 0)
        var scratch = scratchStorage.mutableSpan
        cachedModBarrett(&remainder, a, b, inverse, &scratch, scratchSpace)
    } else {
        var scratchStorage = UniqueArray<UInt64>(repeating: 0, count: scratchSpace)
        var scratch = scratchStorage.mutableSpan
        cachedModBarrett(&remainder, a, b, inverse, &scratch, scratchSpace)
    }
}

// cachedModBarrett with scratch of at least scratchSpace = a.count + inverse.count digits.
func cachedModBarrett(
    _ remainder: inout MutableSpan<UInt64>,
    _ a: Span<UInt64>,
    _ b: Span<UInt64>,
    _ inverse: Span<UInt64>,
    _ scratch: inout MutableSpan<UInt64>,
    _ scratchSpace: Int
) {
    let n = b.count
    // n is a digit count, so n + 1 cannot overflow.
    precondition(n <= maxCachedModDivisorSize && inverse.count == n &+ 1 && remainder.count >= n)

    // Step 1: Compute only the high digits of A * Inv via multiplySpecialHigh.
    let startPos = 2 * n - 2
    precondition(scratchSpace > 2 * n && scratch.count >= scratchSpace)
    if a.count >= inverse.count {
        multiplySpecialHigh(a, inverse, &scratch, 0, startPos)
    } else {
        multiplySpecialHigh(inverse, a, &scratch, 0, startPos)
    }

    // Step 2: Extract estimated quotient Q from position 2n in the product.
    // This means right-shifting 2n digits.
    let q = scratch.span.extracting((2 * n)..<scratchSpace)

    // Step 3: Compute product_low = B * Q (only low n+1 digits needed).
    var productLowStorage = [33 of UInt64](repeating: 0) // maxCachedModDivisorSize + 1
    var productLow = productLowStorage.mutableSpan
    multiplySpecialLow(b, q, &productLow, 0..<(n + 1))

    // Step 4: R = A[0..n-1] - product_low[0..n-1].
    let borrow = subtractAndReturnBorrow(&remainder, 0, a, productLow.span.extracting(0..<n))

    // Track the extra digit: r_high = A[n] - product_low[n] - borrow, which wraps when R is negative.
    let an = a.count > n ? a[n] : 0
    var rHigh = an &- productLow[n] &- borrow

    // Step 5: Corrective loop using sign bit of r_high.
    let signBit: UInt64 = 1 << (UInt64(digitBits) - 1)
    if rHigh & signBit != 0 {
        // Result is negative: add B back until r_high == 0.
        repeat {
            rHigh &+= inplaceAdd(&remainder, 0, b)
        } while rHigh != 0
    } else {
        // Result is non-negative but may be >= B: subtract B.
        while rHigh != 0 || greaterThanOrEqual(remainder.span.extracting(0..<n), b) {
            rHigh &-= inplaceSub(&remainder, 0, b)
        }
    }
}

// The entry point's kernel: R = A mod B, by folding with foldFactor when it is not 0, and else with the inverse.
// Returns n = b.count; the remainder's first n digits are R, not normalized.
@inline(always)
func cachedMod(
    _ remainder: inout MutableSpan<UInt64>,
    _ a: Span<UInt64>,
    _ b: Span<UInt64>,
    _ foldFactor: UInt64,
    _ inverse: Span<UInt64>
) -> Int {
    let n = b.count
    precondition(n >= 2 && n <= maxCachedModDivisorSize)
    assert(a.count >= n && a.count <= 2 * n)
    precondition(remainder.count >= n)

    // Divisors close to a power of the digit base reduce by folding the high half down with a single-digit multiply.
    // Divisors up to maxFixedCachedModDivisorSize digits get a size-specialized fold for every dividend width from n
    // to 2n, the range cachedMod accepts: which widths occur depends on the modulus, not just on the caller.
    if foldFactor != 0 {
        if n <= maxFixedCachedModDivisorSize {
            switch (n, a.count) {
            case (2, 2): cachedModFoldFixed(&remainder, a, b, foldFactor, 2, 2)
            case (2, 3): cachedModFoldFixed(&remainder, a, b, foldFactor, 2, 3)
            case (2, 4): cachedModFoldFixed(&remainder, a, b, foldFactor, 2, 4)
            case (3, 3): cachedModFoldFixed(&remainder, a, b, foldFactor, 3, 3)
            case (3, 4): cachedModFoldFixed(&remainder, a, b, foldFactor, 3, 4)
            case (3, 5): cachedModFoldFixed(&remainder, a, b, foldFactor, 3, 5)
            case (3, 6): cachedModFoldFixed(&remainder, a, b, foldFactor, 3, 6)
            case (4, 4): cachedModFoldFixed(&remainder, a, b, foldFactor, 4, 4)
            case (4, 5): cachedModFoldFixed(&remainder, a, b, foldFactor, 4, 5)
            case (4, 6): cachedModFoldFixed(&remainder, a, b, foldFactor, 4, 6)
            case (4, 7): cachedModFoldFixed(&remainder, a, b, foldFactor, 4, 7)
            case (4, 8): cachedModFoldFixed(&remainder, a, b, foldFactor, 4, 8)
            default: cachedModFold(&remainder, a, b, foldFactor)
            }
            return n
        }
        cachedModFold(&remainder, a, b, foldFactor)
        return n
    }

    cachedModBarrett(&remainder, a, b, inverse)
    return n
}

// The Newton iterations of BigInt.sqrt and BigInt.cbrt.

// The bit length of the digits of a JSBigInt, as JSBigInt::bitLength.
@inline(always)
func bitLength(_ value: Span<UInt64>) -> Int {
    if value.isEmpty {
        return 1
    }
    return value.count * digitBits - value[value.count - 1].leadingZeroBitCount
}

// Writes floor(sqrt(value)) into result, and returns its length. quotient, sum and next are scratch of at least
// scratchCount = value.count + 2 digits, as is result.
func sqrtNewton(
    _ value: Span<UInt64>,
    _ result: inout MutableSpan<UInt64>,
    _ quotient: inout MutableSpan<UInt64>,
    _ sum: inout MutableSpan<UInt64>,
    _ next: inout MutableSpan<UInt64>,
    _ scratchCount: Int
) -> Int {
    // 2^floor(floor(log2(value)) / 2)
    var resultCount = oneShiftedLeft(&result, (bitLength(value) - 1) >> 1)
    var isFirstIteration = true
    while true {
        // result = ((value / result) + result) >> 1
        let quotientCount = divideDigitsNormalized(&quotient, value, result.span.extracting(0..<resultCount))
        let sumCount = addDigitsNormalized(
            quotient.span.extracting(0..<quotientCount),
            result.span.extracting(0..<resultCount),
            &sum
        )
        let nextCount = normalizedCount(next, 0, rightShift(&next, 0, scratchCount, sum.span.extracting(0..<sumCount), 1))
        if !isFirstIteration {
            if compareDigits(next.span.extracting(0..<nextCount), result.span.extracting(0..<resultCount)) >= 0 {
                break
            }
        }
        isFirstIteration = false

        precondition(result.count >= nextCount)
        for i in 0..<nextCount {
            result[i] = next[i]
        }
        resultCount = nextCount
    }
    return resultCount
}

func sqrtDigits(_ value: Span<UInt64>, _ result: inout MutableSpan<UInt64>) -> Int {
    // value.count is a digit count, so this cannot overflow.
    let scratchCount = value.count &+ 2
    if scratchCount <= 16 {
        var quotientStorage = [16 of UInt64](repeating: 0)
        var sumStorage = [16 of UInt64](repeating: 0)
        var nextStorage = [16 of UInt64](repeating: 0)
        var quotient = quotientStorage.mutableSpan
        var sum = sumStorage.mutableSpan
        var next = nextStorage.mutableSpan
        return sqrtNewton(value, &result, &quotient, &sum, &next, scratchCount)
    }
    var quotientStorage = UniqueArray<UInt64>(repeating: 0, count: scratchCount)
    var sumStorage = UniqueArray<UInt64>(repeating: 0, count: scratchCount)
    var nextStorage = UniqueArray<UInt64>(repeating: 0, count: scratchCount)
    var quotient = quotientStorage.mutableSpan
    var sum = sumStorage.mutableSpan
    var next = nextStorage.mutableSpan
    return sqrtNewton(value, &result, &quotient, &sum, &next, scratchCount)
}

// Writes floor(cbrt(value)) into result, and returns its length. squared, quotient, doubled, sum and next are
// scratch of at least scratchCount = value.count + 2 digits, as is result.
func cbrtNewton(
    _ value: Span<UInt64>,
    _ result: inout MutableSpan<UInt64>,
    _ squared: inout MutableSpan<UInt64>,
    _ quotient: inout MutableSpan<UInt64>,
    _ doubled: inout MutableSpan<UInt64>,
    _ sum: inout MutableSpan<UInt64>,
    _ next: inout MutableSpan<UInt64>,
    _ scratchCount: Int
) -> Int {
    let three: [1 of UInt64] = [3]
    // 2^floor(floor(log2(value)) / 3)
    var resultCount = oneShiftedLeft(&result, (bitLength(value) - 1) / 3)
    var isFirstIteration = true
    while true {
        // result = ((2 * result) + (value / (result * result))) / 3
        let nextCount: Int
        do {
            let resultDigits = result.span.extracting(0..<resultCount)
            let squaredCount = multiplyDigitsNormalized(resultDigits, resultDigits, true, &squared, 0, scratchCount)
            let quotientCount = divideDigitsNormalized(&quotient, value, squared.span.extracting(0..<squaredCount))
            let doubledCount = normalizedCount(doubled, 0, leftShift(&doubled, 0, scratchCount, resultDigits, 1))
            let sumCount = addDigitsNormalized(
                doubled.span.extracting(0..<doubledCount),
                quotient.span.extracting(0..<quotientCount),
                &sum
            )
            nextCount = divideDigitsNormalized(&next, sum.span.extracting(0..<sumCount), three.span)
            if !isFirstIteration {
                if compareDigits(next.span.extracting(0..<nextCount), resultDigits) >= 0 {
                    break
                }
            }
        }
        isFirstIteration = false

        precondition(result.count >= nextCount)
        for i in 0..<nextCount {
            result[i] = next[i]
        }
        resultCount = nextCount
    }
    return resultCount
}

func cbrtDigits(_ value: Span<UInt64>, _ result: inout MutableSpan<UInt64>) -> Int {
    // value.count is a digit count, so this cannot overflow.
    let scratchCount = value.count &+ 2
    if scratchCount <= 16 {
        var squaredStorage = [16 of UInt64](repeating: 0)
        var quotientStorage = [16 of UInt64](repeating: 0)
        var doubledStorage = [16 of UInt64](repeating: 0)
        var sumStorage = [16 of UInt64](repeating: 0)
        var nextStorage = [16 of UInt64](repeating: 0)
        var squared = squaredStorage.mutableSpan
        var quotient = quotientStorage.mutableSpan
        var doubled = doubledStorage.mutableSpan
        var sum = sumStorage.mutableSpan
        var next = nextStorage.mutableSpan
        return cbrtNewton(value, &result, &squared, &quotient, &doubled, &sum, &next, scratchCount)
    }
    var squaredStorage = UniqueArray<UInt64>(repeating: 0, count: scratchCount)
    var quotientStorage = UniqueArray<UInt64>(repeating: 0, count: scratchCount)
    var doubledStorage = UniqueArray<UInt64>(repeating: 0, count: scratchCount)
    var sumStorage = UniqueArray<UInt64>(repeating: 0, count: scratchCount)
    var nextStorage = UniqueArray<UInt64>(repeating: 0, count: scratchCount)
    var squared = squaredStorage.mutableSpan
    var quotient = quotientStorage.mutableSpan
    var doubled = doubledStorage.mutableSpan
    var sum = sumStorage.mutableSpan
    var next = nextStorage.mutableSpan
    return cbrtNewton(value, &result, &squared, &quotient, &doubled, &sum, &next, scratchCount)
}

#endif // USE_SWIFT_BIGINT_DIGITS
