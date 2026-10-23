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

// FFT-based multiplication, due to Schönhage and Strassen, ported from V8 [1]. The implementation mostly follows the
// description given in Christoph Lüders: Fast Multiplication of Large Integers,
// http://arxiv.org/abs/1503.04955
//
// [1]: https://source.chromium.org/chromium/chromium/src/+/main:v8/src/bigint/mul-fft.cc
let minFFTTotalSize = 2177
let minFFTSmallerSize = 586

@inline(always)
func shouldUseFFT(_ largerSize: Int, _ smallerSize: Int) -> Bool {
    // The sizes are digit counts, so their sum cannot overflow.
    smallerSize >= minFFTSmallerSize && largerSize &+ smallerSize >= minFFTTotalSize
}

// x[start ..< start + count] += carry, propagating through the whole range at most. Returns the carry that is left.
func addDigitAndPropagate(_ x: inout MutableSpan<UInt64>, _ start: Int, _ count: Int, _ carry: UInt64) -> UInt64 {
    // start is an index into x and count a digit count, so this index arithmetic cannot overflow.
    precondition(x.count &- start >= count)
    var carry = carry
    var i = 0
    while i < count && carry != 0 {
        var newCarry: UInt64 = 0
        x[start &+ i] = digitAdd(x[start &+ i], carry, &newCarry)
        carry = newCarry
        i += 1
    }
    return carry
}

// x[start ..< start + count] -= borrow, propagating through the whole range at most. Returns the borrow that is left.
func subtractDigitAndPropagate(_ x: inout MutableSpan<UInt64>, _ start: Int, _ count: Int, _ borrow: UInt64) -> UInt64 {
    // start is an index into x and count a digit count, so this index arithmetic cannot overflow.
    precondition(x.count &- start >= count)
    var borrow = borrow
    var i = 0
    while i < count && borrow != 0 {
        var newBorrow: UInt64 = 0
        x[start &+ i] = digitSub(x[start &+ i], borrow, &newBorrow)
        borrow = newBorrow
        i += 1
    }
    return borrow
}

// destination[start ..< start + count] := source, zero-extended.
func copyAndZeroExtend(_ destination: inout MutableSpan<UInt64>, _ start: Int, _ count: Int, _ source: Span<UInt64>) {
    // start is an index into destination and count a digit count, so this index arithmetic cannot overflow.
    precondition(start >= 0 && count >= source.count && destination.count &- start >= count)
    for i in 0..<source.count {
        destination[start &+ i] = source[i]
    }
    for i in source.count..<count {
        destination[start &+ i] = 0
    }
}

enum FFT {
    static let log2DigitBits = 6 // digitBits == 1 << log2DigitBits

    // Residues of at least this many digits (K + 1) are multiplied by a recursive FFT.
    static let innerThreshold = 200

    // Part 1: Functions for "mod F_n" arithmetic.
    // F_n is of the shape 2^K + 1, and for convenience we use K to count the number of digits rather than the number
    // of bits, so F_n (or K) are implicit and deduced from the length of the digits, which is K + 1. A residue below
    // is the `length` digits of a buffer from `start`.

    // Folds the top digit `high` back into the residue: 2^K == -1 (mod F_n), so this subtracts `high` from the low
    // digits (adds when negative) and clears x[K]. The borrow can leave x[K] == -1, hence the repeated calls in modFn.
    static func modFnHelper(_ x: inout MutableSpan<UInt64>, _ start: Int, _ length: Int, _ high: Int64) {
        // The residue's digits are indices into x, so this index arithmetic cannot overflow.
        x[start &+ length &- 1] = 0
        if high > 0 {
            _ = subtractDigitAndPropagate(&x, start, length, UInt64(bitPattern: high))
        } else {
            // -high, as a digit. The top digit of a residue is small, so this is its magnitude.
            _ = addDigitAndPropagate(&x, start, length, 0 &- UInt64(bitPattern: high))
        }
    }

    // The residue := itself mod F_n, assuming that it is "slightly" larger than F_n (e.g. after addition of two
    // numbers that were mod-F_n-normalized before).
    static func modFn(_ x: inout MutableSpan<UInt64>, _ start: Int, _ length: Int) {
        // The residue's digits are indices into x, so this index arithmetic cannot overflow.
        precondition(length >= 1 && x.count &- start >= length)
        let top = start &+ length &- 1
        var high = Int64(bitPattern: x[top])
        if high == 0 {
            return
        }
        modFnHelper(&x, start, length, high)
        high = Int64(bitPattern: x[top])
        if high == 0 {
            return
        }
        assert(high == 1 || high == -1)
        modFnHelper(&x, start, length, high)
        high = Int64(bitPattern: x[top])
        if high == -1 {
            modFnHelper(&x, start, length, high)
        }
    }

    // The residue := input mod F_n, assuming that input is about twice as long as F_n (e.g. after multiplication of
    // two numbers that were mod-F_n-normalized before).
    static func modFnDoubleWidth(_ result: inout MutableSpan<UInt64>, _ start: Int, _ length: Int, _ input: Span<UInt64>) {
        // The residue's digits are indices into result, so this index arithmetic cannot overflow.
        precondition(length >= 1 && result.count &- start >= length)
        // swift-format-ignore: AlwaysUseLowerCamelCase
        let K = length - 1
        precondition(input.count > 2 * K)
        let borrow = subtractAndReturnBorrow(&result, start, input.extracting(0..<K), input.extracting(K..<(2 * K)))
        var newBorrow: UInt64 = 0
        result[start &+ K] = digitSub2(0, input[2 * K], borrow, &newBorrow)
        // newBorrow may be non-zero here, that's OK as modFn will take care of it.
        modFn(&result, start, length)
    }

    // Sets the residue at aStart to a + b and the one at bStart to a - b, which is more efficient than computing sum
    // and difference separately. Applies "mod F_n" normalization to both results.
    static func sumDiff(_ x: inout MutableSpan<UInt64>, _ aStart: Int, _ bStart: Int, _ length: Int) {
        // The residues' digits are indices into x, so this index arithmetic cannot overflow.
        precondition(x.count &- aStart >= length && x.count &- bStart >= length)
        var carry: UInt64 = 0
        var borrow: UInt64 = 0
        for i in 0..<length {
            // Read both values first, because inputs and outputs overlap.
            let ai = x[aStart &+ i]
            let bi = x[bStart &+ i]
            var newCarry: UInt64 = 0
            x[aStart &+ i] = digitAdd3(ai, bi, carry, &newCarry)
            carry = newCarry
            var newBorrow: UInt64 = 0
            x[bStart &+ i] = digitSub2(ai, bi, borrow, &newBorrow)
            borrow = newBorrow
        }
        modFn(&x, aStart, length)
        modFn(&x, bStart, length)
    }

    // sumDiff, with a - b going to diff[diffStart ..< diffStart + length] instead.
    static func sumDiff(
        _ x: inout MutableSpan<UInt64>,
        _ aStart: Int,
        _ bStart: Int,
        _ diff: inout MutableSpan<UInt64>,
        _ diffStart: Int,
        _ length: Int
    ) {
        // The residues' digits are indices into x and diff, so this index arithmetic cannot overflow.
        precondition(x.count &- aStart >= length && x.count &- bStart >= length && diff.count &- diffStart >= length)
        var carry: UInt64 = 0
        var borrow: UInt64 = 0
        for i in 0..<length {
            // Read both values first, because inputs and outputs overlap.
            let ai = x[aStart &+ i]
            let bi = x[bStart &+ i]
            var newCarry: UInt64 = 0
            x[aStart &+ i] = digitAdd3(ai, bi, carry, &newCarry)
            carry = newCarry
            var newBorrow: UInt64 = 0
            diff[diffStart &+ i] = digitSub2(ai, bi, borrow, &newBorrow)
            borrow = newBorrow
        }
        modFn(&x, aStart, length)
        modFn(&diff, diffStart, length)
    }

    // sumDiff, with b read from `b` instead, and a - b going to the residue at diffStart.
    static func sumDiff(_ x: inout MutableSpan<UInt64>, _ aStart: Int, _ diffStart: Int, _ b: Span<UInt64>) {
        // The residues' digits are indices into x, so this index arithmetic cannot overflow.
        let length = b.count
        precondition(x.count &- aStart >= length && x.count &- diffStart >= length)
        var carry: UInt64 = 0
        var borrow: UInt64 = 0
        for i in 0..<length {
            // Read both values first, because inputs and outputs overlap.
            let ai = x[aStart &+ i]
            let bi = b[i]
            var newCarry: UInt64 = 0
            x[aStart &+ i] = digitAdd3(ai, bi, carry, &newCarry)
            carry = newCarry
            var newBorrow: UInt64 = 0
            x[diffStart &+ i] = digitSub2(ai, bi, borrow, &newBorrow)
            borrow = newBorrow
        }
        modFn(&x, aStart, length)
        modFn(&x, diffStart, length)
    }

    // The residue at resultStart := (input << shift) mod F_n, where shift >= K.
    static func shiftModFnLarge(
        _ result: inout MutableSpan<UInt64>,
        _ resultStart: Int,
        _ input: Span<UInt64>,
        _ digitShift: Int,
        _ bitsShift: Int
    ) {
        // digitShift < 2K and every index is at most r + K, so this index arithmetic cannot overflow.
        // swift-format-ignore: AlwaysUseLowerCamelCase
        let K = input.count - 1
        let r = resultStart
        // If digitShift is greater than K, we use the following transformation (where, since everything is
        // mod 2^K + 1, we are allowed to add or subtract any multiple of 2^K + 1 at any time):
        //      x * 2^{K+m}   mod 2^K + 1
        //   == x * 2^K * 2^m - (2^K + 1)*(x * 2^m)   mod 2^K + 1
        //   == x * 2^K * 2^m - x * 2^K * 2^m - x * 2^m   mod 2^K + 1
        //   == -x * 2^m   mod 2^K + 1
        // So the flow is the same as for m < K, but we invert the subtraction's operands. In order to avoid underflow,
        // we virtually initialize the result to 2^K + 1:
        //   input  =  [ iK ][iK-1] ....  .... [ i1 ][ i0 ]
        //   result =  [   1][0000] ....  .... [0000][0001]
        //            +                  [ iK ] .... [ iX ]
        //            -      [iX-1] .... [ i0 ]
        assert(digitShift >= K)
        let digitShift = digitShift &- K
        var borrow: UInt64 = 0
        if bitsShift == 0 {
            var carry: UInt64 = 1
            for i in 0..<digitShift {
                var newCarry: UInt64 = 0
                result[r &+ i] = digitAdd(input[i &+ K &- digitShift], carry, &newCarry)
                carry = newCarry
            }
            // input[K] is at most 1 in a normalized residue. Were it all ones, the sum would wrap and give a wrong
            // digit.
            result[r &+ digitShift] = digitSub(input[K] &+ carry, input[0], &borrow)
            var i = digitShift &+ 1
            while i < K {
                let d = input[i &- digitShift]
                var newBorrow: UInt64 = 0
                result[r &+ i] = digitSub2(0, d, borrow, &newBorrow)
                borrow = newBorrow
                i += 1
            }
        } else {
            precondition(bitsShift < digitBits)
            let bits = UInt64(bitsShift)
            var addCarry: UInt64 = 1
            var inputCarry = input[K &- digitShift &- 1] &>> (UInt64(digitBits) - bits)
            for i in 0..<digitShift {
                let d = input[i &+ K &- digitShift]
                let summand = (d &<< bits) | inputCarry
                var newCarry: UInt64 = 0
                result[r &+ i] = digitAdd(summand, addCarry, &newCarry)
                addCarry = newCarry
                inputCarry = d &>> (UInt64(digitBits) - bits)
            }
            do {
                // result[digitShift] = (addCarry + iKPart) - i0Part
                var d = input[K]
                let iKPart = (d &<< bits) | inputCarry
                var iKCarry = d &>> (UInt64(digitBits) - bits)
                var newCarry: UInt64 = 0
                let sum = digitAdd(addCarry, iKPart, &newCarry)
                addCarry = newCarry
                // iKCarry is less than a full digit, so we can merge addCarry into it without overflow.
                iKCarry &+= addCarry
                d = input[0]
                let i0Part = d &<< bits
                result[r &+ digitShift] = digitSub(sum, i0Part, &borrow)
                inputCarry = d &>> (UInt64(digitBits) - bits)
                if digitShift &+ 1 < K {
                    d = input[1]
                    let subtrahend = (d &<< bits) | inputCarry
                    var newBorrow: UInt64 = 0
                    result[r &+ digitShift &+ 1] = digitSub2(iKCarry, subtrahend, borrow, &newBorrow)
                    borrow = newBorrow
                    inputCarry = d &>> (UInt64(digitBits) - bits)
                }
            }
            var i = digitShift &+ 2
            while i < K {
                let d = input[i &- digitShift]
                let subtrahend = (d &<< bits) | inputCarry
                var newBorrow: UInt64 = 0
                result[r &+ i] = digitSub2(0, subtrahend, borrow, &newBorrow)
                borrow = newBorrow
                inputCarry = d &>> (UInt64(digitBits) - bits)
                i += 1
            }
        }
        // The virtual 1 in result[K] should be eliminated by borrow. If there is no borrow, then the virtual
        // initialization was too much. Subtract 2^K + 1.
        result[r &+ K] = 0
        if borrow != 1 && subtractDigitAndPropagate(&result, r, K, 1) != 0 {
            // The result must be 2^K.
            for i in 0..<K {
                result[r &+ i] = 0
            }
            result[r &+ K] = 1
        }
    }

    // Sets the residue at resultStart := input * 2^powerOfTwo mod (2^K + 1). input is known to be zero from index
    // zeroAbove on.
    // This function is highly relevant for overall performance.
    static func shiftModFn(
        _ result: inout MutableSpan<UInt64>,
        _ resultStart: Int,
        _ input: Span<UInt64>,
        _ powerOfTwo: Int,
        _ zeroAbove: Int = .max
    ) {
        precondition(resultStart >= 0 && powerOfTwo >= 0 && input.count >= 2 && result.count - resultStart >= input.count)
        // The input indices are below K and the result indices in [r, r + K], so this index arithmetic cannot overflow.
        // swift-format-ignore: AlwaysUseLowerCamelCase
        let K = input.count - 1
        let r = resultStart
        // The modulo-reduction amounts to a subtraction, which we combine with the shift as follows:
        //   input  =  [ iK ][iK-1] ....  .... [ i1 ][ i0 ]
        //   result =        [iX-1] .... [ i0 ] <---------- shift by powerOfTwo
        //            -                  [ iK ] .... [ iX ]
        // where "X" is the index "K - digitShift".
        var digitShift = powerOfTwo / digitBits
        let bitsShift = powerOfTwo % digitBits
        // By an analogous construction to the "digitShift >= K" case, it turns out that:
        //    x * 2^{2K+m} == x * 2^m   mod 2^K + 1.
        while digitShift >= 2 * K {
            digitShift &-= 2 * K // Faster than '%'!
        }
        if digitShift >= K {
            shiftModFnLarge(&result, resultStart, input, digitShift, bitsShift)
            return
        }
        var borrow: UInt64 = 0
        if bitsShift == 0 {
            // We do a single pass over input, starting by copying digits [i1] to [iX-1] to result indices
            // digitShift+1 to K-1.
            var i = 1
            // Read input digits unless we know they are zero.
            var cap = min(K &- digitShift, zeroAbove)
            while i < cap {
                result[r &+ i &+ digitShift] = input[i]
                i += 1
            }
            // Any remaining work can hard-code the knowledge that input[i] == 0.
            while i < K &- digitShift {
                assert(input[i] == 0)
                result[r &+ i &+ digitShift] = 0
                i += 1
            }
            // Second phase: subtract input digits [iX] to [iK] from (virtually) zero-initialized result indices 0 to
            // digitShift-1.
            cap = min(K, zeroAbove)
            while i < cap {
                let d = input[i]
                var newBorrow: UInt64 = 0
                result[r &+ (i &- K &+ digitShift)] = digitSub2(0, d, borrow, &newBorrow)
                borrow = newBorrow
                i += 1
            }
            // Any remaining work can hard-code the knowledge that input[i] == 0.
            while i < K {
                assert(input[i] == 0)
                var newBorrow: UInt64 = 0
                result[r &+ (i &- K &+ digitShift)] = digitSub(0, borrow, &newBorrow)
                borrow = newBorrow
                i += 1
            }
            // Last step: subtract [iK] from [i0] and store at result index digitShift.
            var newBorrow: UInt64 = 0
            result[r &+ digitShift] = digitSub2(input[0], input[K], borrow, &newBorrow)
            borrow = newBorrow
        } else {
            // Same flow as before, but taking bitsShift != 0 into account.
            // First phase: result indices digitShift+1 to K.
            let bits = UInt64(bitsShift)
            var carry: UInt64 = 0
            var i = 0
            // Read input digits unless we know they are zero.
            var cap = min(K &- digitShift, zeroAbove)
            while i < cap {
                let d = input[i]
                result[r &+ i &+ digitShift] = (d &<< bits) | carry
                carry = d &>> (UInt64(digitBits) - bits)
                i += 1
            }
            // Any remaining work can hard-code the knowledge that input[i] == 0.
            while i < K &- digitShift {
                assert(input[i] == 0)
                result[r &+ i &+ digitShift] = carry
                carry = 0
                i += 1
            }
            // Second phase: result indices 0 to digitShift - 1.
            cap = min(K, zeroAbove)
            while i < cap {
                let d = input[i]
                var newBorrow: UInt64 = 0
                result[r &+ (i &- K &+ digitShift)] = digitSub2(0, (d &<< bits) | carry, borrow, &newBorrow)
                borrow = newBorrow
                carry = d &>> (UInt64(digitBits) - bits)
                i += 1
            }
            // Any remaining work can hard-code the knowledge that input[i] == 0.
            if i < K {
                assert(input[i] == 0)
                var newBorrow: UInt64 = 0
                result[r &+ (i &- K &+ digitShift)] = digitSub2(0, carry, borrow, &newBorrow)
                borrow = newBorrow
                carry = 0
                i += 1
            }
            while i < K {
                assert(input[i] == 0)
                var newBorrow: UInt64 = 0
                result[r &+ (i &- K &+ digitShift)] = digitSub(0, borrow, &newBorrow)
                borrow = newBorrow
                i += 1
            }
            // Last step: compute result[digitShift].
            let d = input[K]
            var newBorrow: UInt64 = 0
            result[r &+ digitShift] = digitSub2(result[r &+ digitShift], (d &<< bits) | carry, borrow, &newBorrow)
            borrow = newBorrow
            // No carry left.
            assert(d &>> (UInt64(digitBits) - bits) == 0)
        }
        result[r &+ K] = 0
        if subtractDigitAndPropagate(&result, r &+ digitShift &+ 1, K &- digitShift, borrow) != 0 {
            // Underflow means we subtracted too much. Add 2^K + 1.
            _ = addDigitAndPropagate(&result, r, K &+ 1, 1)
            // The borrow left result[K] all ones, so this wraps it to 0 on purpose.
            result[r &+ K] &+= 1
        }
    }

    // Part 2: FFT-based multiplication is very sensitive to appropriate choice of parameters. The following functions
    // choose the parameters that the subsequent actual computation will use. This is partially based on formal
    // constraints and partially on experimentally-determined heuristics.

    struct Parameters {
        var m = 0 // log2(n).
        // swift-format-ignore: AlwaysUseLowerCamelCase
        var K = 0 // Length of a residue in digits: arithmetic is mod F_n = 2^(K * digitBits) + 1.
        var n = 0 // Number of chunks, which is the length of the transform.
        var s = 0 // Length of an input chunk in digits.
        var r = 0 // K * digitBits == r * n / 2 (outer layer) or r * n (inner layer).
    }
    // Since 2^(K * digitBits) == -1 (mod F_n), powers of two are roots of unity. omega and theta below are exponents:
    // multiplying by the root omega^k is a shift by omega * k bits.

    // WTF's roundUpToMultipleOf, for a power-of-two divisor.
    @inline(always)
    static func roundUpToMultipleOf(_ divisor: Int, _ x: Int) -> Int {
        // divisor and x are FFT parameters, so this cannot overflow.
        let remainderMask = divisor &- 1
        return (x &+ remainderMask) & ~remainderMask
    }

    // std::bit_width.
    @inline(always)
    static func bitWidth(_ x: Int) -> Int {
        // leadingZeroBitCount is at most Int.bitWidth, so this cannot overflow.
        Int.bitWidth &- x.leadingZeroBitCount
    }

    // Computes parameters for the main calculation, given the length N of the product in digits and an m. See the
    // paper for details.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    static func computeParameters(_ N: Int, _ m: Int) -> Parameters {
        // N is a digit count of at most 2 * maxLength and m is below Int.bitWidth, so this arithmetic cannot overflow.
        let N = N &* digitBits
        let n = 1 &<< m // 2^m
        let nhalf = n &>> 1
        var s = (N &+ n &- 1) &>> m // ceil(N/n)
        s = roundUpToMultipleOf(digitBits, s)
        var K = m &+ 2 &* s &+ 1 // K must be at least this big...
        K = roundUpToMultipleOf(nhalf, K) // ...and a multiple of n/2.

        // We want recursive calls to make progress, so force K to be a multiple of 8 if it's above the recursion
        // threshold. Otherwise, K must be a multiple of digitBits.
        let threshold = (K &+ 1 >= innerThreshold * digitBits) ? 3 + log2DigitBits : log2DigitBits
        var trailingZeros = K.trailingZeroBitCount
        while trailingZeros < threshold {
            K &+= 1 &<< trailingZeros
            trailingZeros = K.trailingZeroBitCount
        }
        let r = K &>> (m &- 1) // Which multiple of n/2?

        assert(K % digitBits == 0)
        assert(s % digitBits == 0)
        return Parameters(m: m, K: K / digitBits, n: n, s: s / digitBits, r: r)
    }

    // Computes parameters for recursive invocations ("inner layer").
    // swift-format-ignore: AlwaysUseLowerCamelCase
    static func computeParametersInner(_ N: Int) -> Parameters {
        // N is a residue length, below 2 * maxLength digits, so this arithmetic cannot overflow.
        let maxM = UInt32(N.trailingZeroBitCount)
        let NBits = UInt32(bitWidth(N))
        // In unsigned arithmetic: for NBits < 4 the subtraction wraps, and maxM is the smaller.
        let m = Int(min(maxM, NBits &- 4)) // Don't let s get too small.
        let N = N &* digitBits
        let n = 1 &<< m // 2^m
        // We can't round up s in the inner layer, because N = n*s is fixed.
        let s = N &>> m
        assert(N == s * n)
        var K = m &+ 2 &* s &+ 1 // K must be at least this big...
        K = roundUpToMultipleOf(n, K) // ...and a multiple of n and digitBits.
        K = roundUpToMultipleOf(digitBits, K)
        let r = K &>> m // Which multiple?
        assert(K % digitBits == 0)
        assert(s % digitBits == 0)
        return Parameters(m: m, K: K / digitBits, n: n, s: s / digitBits, r: r)
    }

    // Applies heuristics to decide whether m should be decremented, by looking at what would happen to K and s if m
    // was decremented.
    static func shouldDecrementM(_ current: Parameters, _ next: Parameters, _ afterNext: Parameters) -> Bool {
        // K == 64 seems to work particularly well.
        if current.K == 64 && next.K >= 112 {
            return false
        }
        // Small values for s are never efficient.
        if current.s < 6 {
            return true
        }
        // The time is roughly determined by K * n. When we decrement m, then n always halves, and K usually gets
        // bigger, by up to 2x.
        // For not-quite-so-small s, look at how much bigger K would get: if the K increase is small enough, making n
        // smaller is worth it.
        // Empirically, it's most meaningful to look at the K *after* next.
        // The specific threshold values have been chosen by running many benchmarks on inputs of many sizes, and
        // manually selecting thresholds that seemed to produce good results.
        let factor = Double(afterNext.K) / Double(current.K)
        if (current.s == 6 && factor < 3.85)
            || (current.s == 7 && factor < 3.73)
            || (current.s == 8 && factor < 3.55)
            || (current.s == 9 && factor < 3.50)
            || factor < 3.4
        {
            return true
        }
        // If K is just below the recursion threshold, make sure we do recurse, unless doing so would be particularly
        // inefficient (large inner K).
        // If K is just above the recursion threshold, doubling it often makes the inner call more efficient.
        if current.K >= 160 && current.K < 250 && computeParametersInner(next.K).K < 28 {
            return true
        }
        // If we found no reason to decrement, keep m as large as possible.
        return false
    }

    // Decides what parameters to use for a product of N digits.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    static func getParameters(_ N: Int) -> Parameters {
        // NBits and m are below Int.bitWidth, so this arithmetic cannot overflow.
        let NBits = bitWidth(N)
        var maxM = NBits &- 3 // Larger m make s too small.
        maxM = max(log2DigitBits, maxM) // Smaller m break the logic below.
        var m = maxM
        var current = computeParameters(N, m)
        var next = computeParameters(N, m &- 1)
        while m > 2 {
            let afterNext = computeParameters(N, m &- 2)
            if !shouldDecrementM(current, next, afterNext) {
                break
            }
            m -= 1
            current = next
            next = afterNext
        }
        return current
    }

    // Part 3: Fast Fourier Transformation.

    // Helper function for FFTContainer.counterWeightAndRecombine below. After counter-weighting, coefficient k is the
    // sum of k + 1 products of two s-digit chunks, so it is below threshold * 2^(2 * s * digitBits); anything larger
    // is a negative value wrapped mod F_n.
    static func shouldBeNegative(_ x: Span<UInt64>, _ threshold: UInt64, _ s: Int) -> Bool {
        precondition(x.count > 2 * s)
        if x[2 * s] >= threshold {
            return true
        }
        var i = 2 * s + 1
        while i < x.count {
            if x[i] > 0 {
                return true
            }
            i += 1
        }
        return false
    }

    // Forward transformation of parts [start, start + length) of `parts`, whose residues are `partLength` digits.
    // We use the "DIF" aka "decimation in frequency" transform, because it leaves the result in "bit reversed" order,
    // which is precisely what we need as input for the "DIT" aka "decimation in time" backwards transform.
    static func forwardFFT(
        _ parts: inout MutableSpan<UInt64>,
        _ temp: inout MutableSpan<UInt64>,
        _ partLength: Int,
        _ start: Int,
        _ length: Int,
        _ omega: Int
    ) {
        // Part offsets are below parts.count and root exponents are residue bit counts, so this cannot overflow.
        assert(length & 1 == 0)
        let half = length / 2
        sumDiff(&parts, start &* partLength, (start &+ half) &* partLength, partLength)
        var k = 1
        while k < half {
            sumDiff(&parts, (start &+ k) &* partLength, (start &+ half &+ k) &* partLength, &temp, 0, partLength)
            let w = omega &* k
            shiftModFn(&parts, (start &+ half &+ k) &* partLength, temp.span.extracting(0..<partLength), w)
            k += 1
        }
        forwardFFTRecurse(&parts, &temp, partLength, start, half, omega)
    }

    // Recursive step of forwardFFT, also entered directly by FFTContainer.start.
    static func forwardFFTRecurse(
        _ parts: inout MutableSpan<UInt64>,
        _ temp: inout MutableSpan<UInt64>,
        _ partLength: Int,
        _ start: Int,
        _ half: Int,
        _ omega: Int
    ) {
        // The root exponents are bit counts of a residue, so this arithmetic cannot overflow.
        if half > 1 {
            forwardFFT(&parts, &temp, partLength, start, half, 2 &* omega)
            forwardFFT(&parts, &temp, partLength, start &+ half, half, 2 &* omega)
        }
    }

    // Backward transformation of parts [start, start + length).
    // We use the "DIT" aka "decimation in time" transform here, because it turns bit-reversed input into normally
    // sorted output.
    static func backwardFFT(
        _ parts: inout MutableSpan<UInt64>,
        _ temp: inout MutableSpan<UInt64>,
        _ partLength: Int,
        _ start: Int,
        _ length: Int,
        _ omega: Int
    ) {
        // Part offsets are below parts.count and root exponents are residue bit counts, so this cannot overflow.
        assert(length & 1 == 0)
        let half = length / 2
        // Don't recurse for half == 2, as pointwiseMultiply already performed the first level of the backwards FFT
        // (the butterflies on adjacent parts).
        if half > 2 {
            backwardFFT(&parts, &temp, partLength, start, half, 2 &* omega)
            backwardFFT(&parts, &temp, partLength, start &+ half, half, 2 &* omega)
        }
        sumDiff(&parts, start &* partLength, (start &+ half) &* partLength, partLength)
        var k = 1
        while k < half {
            let w = omega &* (length - k)
            let highPart = (start &+ half &+ k) &* partLength
            shiftModFn(&temp, 0, parts.span.extracting(droppingFirst: highPart).extracting(0..<partLength), w)
            sumDiff(&parts, (start &+ k) &* partLength, highPart, temp.span.extracting(0..<partLength))
            k += 1
        }
    }
}

struct FFTContainer: ~Copyable {
    let n: Int // Number of parts.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    let K: Int // Always length - 1.
    let length: Int // Length of each part, in digits.
    var storage: UniqueArray<UInt64> // Combined storage of all parts.
    var temp: UniqueArray<UInt64> // Temporary storage with size 2 * length.

    // n is the number of chunks, whose length is K+1. K determines F_n = 2^(K * digitBits) + 1.
    init(_ n: Int, _ K: Int) {
        self.n = n
        self.K = K
        // K and n are FFT parameters for at most 2 * maxLength digits, so this cannot overflow.
        length = K &+ 1
        storage = UniqueArray(repeating: 0, count: length &* n)
        temp = UniqueArray(repeating: 0, count: length &* 2)
    }

    // Reads x into the parts, dividing it into chunks while doing so; then performs the forward FFT.
    mutating func startDefault(_ x: Span<UInt64>, _ chunkSize: Int, _ theta: Int, _ omega: Int) {
        precondition(chunkSize < length)
        var x = x
        var chunkSize = chunkSize
        var parts = storage.mutableSpan
        var t = temp.mutableSpan
        var currentTheta = 0
        var i = 0
        // partStart is at most parts.count, and the counts and exponents are FFT parameters, so this cannot overflow.
        var partStart = 0
        while i < n && !x.isEmpty {
            chunkSize = min(chunkSize, x.count)
            // For the inner layer of pointwiseMultiply, x.count == n * chunkSize + 1, because the outer layer's "K"
            // is passed as the inner layer's "N". Since x is (mod Fn)-normalized on the outer layer, there is the rare
            // corner case where x[n * chunkSize] == 1. Detect that case, and handle the extra bit as part of the last
            // chunk; we always have the space.
            if i == n &- 1 && x.count == chunkSize &+ 1 {
                assert(x[chunkSize] <= 1)
                chunkSize += 1
            }
            if currentTheta != 0 {
                // Multiply with theta^i, and reduce modulo 2^K + 1. We pass theta as a shift amount; it really means
                // 2^theta.
                copyAndZeroExtend(&t, 0, length, x.extracting(0..<chunkSize))
                FFT.shiftModFn(&parts, partStart, t.span.extracting(0..<length), currentTheta, chunkSize)
            } else {
                copyAndZeroExtend(&parts, partStart, length, x.extracting(0..<chunkSize))
            }
            x = x.extracting(droppingFirst: chunkSize)
            i += 1
            partStart &+= length
            currentTheta &+= theta
        }
        assert(x.isEmpty)
        // Parts i ..< n, the rest of parts, are zero.
        for j in partStart..<parts.count {
            parts[j] = 0
        }
        FFT.forwardFFT(&parts, &t, length, 0, n, omega)
    }

    // Like startDefault with theta == 0, optimized for the case where ~half of the container will be filled with
    // padding zeros: the first level of the forward FFT then combines each part with zero, so it is folded into the
    // load.
    mutating func start(_ x: Span<UInt64>, _ chunkSize: Int, _ omega: Int) {
        precondition(chunkSize < length)
        // partStart and halfStart index parts; the counts and exponents are FFT parameters, so this cannot overflow.
        if x.count > n &* chunkSize / 2 {
            startDefault(x, chunkSize, 0, omega)
            return
        }
        var x = x
        var chunkSize = chunkSize
        var parts = storage.mutableSpan
        var t = temp.mutableSpan
        let nhalf = n / 2
        let halfStart = nhalf &* length
        // Unrolled first iteration.
        chunkSize = min(chunkSize, x.count)
        copyAndZeroExtend(&parts, 0, length, x.extracting(0..<chunkSize))
        copyAndZeroExtend(&parts, halfStart, length, x.extracting(0..<chunkSize))
        x = x.extracting(droppingFirst: chunkSize)
        var i = 1
        var partStart = length
        while i < nhalf && !x.isEmpty {
            chunkSize = min(chunkSize, x.count)
            copyAndZeroExtend(&parts, partStart, length, x.extracting(0..<chunkSize))
            // The shift reads the chunk while writing another part, so it reads it from temp.
            copyAndZeroExtend(&t, 0, length, x.extracting(0..<chunkSize))
            let w = omega &* i
            FFT.shiftModFn(&parts, halfStart &+ partStart, t.span.extracting(0..<length), w, chunkSize)
            x = x.extracting(droppingFirst: chunkSize)
            i += 1
            partStart &+= length
        }
        // Parts i ..< nhalf and i + nhalf ..< 2 * nhalf are zero.
        for j in partStart..<halfStart {
            parts[j] = 0
        }
        for j in (halfStart &+ partStart)..<(2 &* halfStart) {
            parts[j] = 0
        }
        FFT.forwardFFTRecurse(&parts, &t, length, 0, nhalf, omega)
    }

    mutating func backwardFFT(_ omega: Int) {
        var parts = storage.mutableSpan
        var t = temp.mutableSpan
        FFT.backwardFFT(&parts, &t, length, 0, n, omega)
    }

    // Recombines the result's parts into z[zStart ..< zStart + zCount], after backwards FFT.
    mutating func normalizeAndRecombine(
        _ omega: Int,
        _ m: Int,
        _ z: inout MutableSpan<UInt64>,
        _ zStart: Int,
        _ zCount: Int,
        _ chunkSize: Int
    ) {
        // zStart indexes z, and the counts and exponents are FFT parameters, so this cannot overflow.
        precondition(z.count &- zStart >= zCount)
        for i in zStart..<(zStart &+ zCount) {
            z[i] = 0
        }
        // The parts from part i on.
        var parts = storage.span
        var t = temp.mutableSpan
        var zIndex = 0
        // 2^(n * omega) == 1 (mod F_n), so this shift multiplies by 2^-m, i.e. divides by n as the inverse transform
        // requires.
        let shift = n &* omega &- m
        // The parts that would land beyond z are zero.
        var i = 0
        while i < n && zIndex < zCount {
            FFT.shiftModFn(&t, 0, parts.extracting(0..<length), shift)
            parts = parts.extracting(droppingFirst: length)
            let carry = inplaceAddAndPropagate(&z, zStart &+ zIndex, zCount &- zIndex, t.span.extracting(0..<length))
            assert(carry == 0)
            i += 1
            zIndex &+= chunkSize
        }
    }

    // Same as normalizeAndRecombine above, but for the needs of the recursive invocation ("inner layer") of FFT
    // multiplication, where an additional counter-weighting step is required. z is all of `z`.
    mutating func counterWeightAndRecombine(_ theta: Int, _ m: Int, _ z: inout MutableSpan<UInt64>, _ chunkSize: Int) {
        // zIndex <= n * chunkSize, i < length, and the exponents are FFT parameters, so this cannot overflow.
        precondition(z.count > (n &- 1) &* chunkSize)
        for i in 0..<z.count {
            z[i] = 0
        }
        // The parts from part k on.
        var parts = storage.span
        var shifted = temp.mutableSpan
        var zIndex = 0
        for k in 0..<n {
            // shift = -theta * k - m, taken modulo 2 * n * theta (the order of 2^theta).
            var shift = theta &* k &+ m
            assert(shift <= 2 * n * theta)
            if shift != 0 {
                shift = 2 &* n &* theta &- shift
            }
            FFT.shiftModFn(&shifted, 0, parts.extracting(0..<length), shift)
            parts = parts.extracting(droppingFirst: length)
            let remainingZ = z.count &- zIndex
            if FFT.shouldBeNegative(shifted.span.extracting(0..<length), UInt64(k &+ 1), chunkSize) {
                // Subtract F_n from input before adding to result. We use the following transformation (knowing that
                // X < F_n):
                // Z + (X - F_n) == Z - (F_n - X)
                var borrowZ: UInt64 = 0
                var borrowFn: UInt64 = 0
                do {
                    // i == 0:
                    let d = digitSub(1, shifted[0], &borrowFn)
                    z[zIndex] = digitSub(z[zIndex], d, &borrowZ)
                }
                var i = 1
                while i < K && i < remainingZ {
                    var newBorrowFn: UInt64 = 0
                    let d = digitSub2(0, shifted[i], borrowFn, &newBorrowFn)
                    borrowFn = newBorrowFn
                    var newBorrowZ: UInt64 = 0
                    z[zIndex &+ i] = digitSub2(z[zIndex &+ i], d, borrowZ, &newBorrowZ)
                    borrowZ = newBorrowZ
                    i += 1
                }
                assert(i == K)
                while i < length && i < remainingZ {
                    var newBorrowFn: UInt64 = 0
                    let d = digitSub2(1, shifted[i], borrowFn, &newBorrowFn)
                    borrowFn = newBorrowFn
                    var newBorrowZ: UInt64 = 0
                    z[zIndex &+ i] = digitSub2(z[zIndex &+ i], d, borrowZ, &newBorrowZ)
                    borrowZ = newBorrowZ
                    i += 1
                }
                assert(borrowFn == 0)
                while borrowZ > 0 && i < remainingZ {
                    var newBorrowZ: UInt64 = 0
                    z[zIndex &+ i] = digitSub(z[zIndex &+ i], borrowZ, &newBorrowZ)
                    borrowZ = newBorrowZ
                    i += 1
                }
            } else {
                // The carry might be != 0 here if z was negative before. That's fine.
                _ = inplaceAddAndPropagate(&z, zIndex, remainingZ, shifted.span.extracting(0..<length))
            }
            zIndex &+= chunkSize
        }
    }

    // Reduces the product in temp into part i, which starts at digit partStart, and, to improve cache friendliness,
    // performs the first level of the backwards FFT on it and part i - 1 once both are there.
    mutating func reduceAndButterfly(_ i: Int, _ partStart: Int) {
        var parts = storage.mutableSpan
        FFT.modFnDoubleWidth(&parts, partStart, length, temp.span)
        if i & 1 != 0 {
            // Part i - 1 starts length digits below part i, so this cannot overflow.
            FFT.sumDiff(&parts, partStart &- length, partStart, length)
        }
    }

    // Requiring K to be a multiple of 4 makes sure that the inner FFT gets to split the work into at least 4 chunks.
    var multipliesPartsWithKaratsuba: Bool {
        length < FFT.innerThreshold || K & 3 != 0
    }

    // Pointwise multiplication of the parts by other's.
    mutating func pointwiseMultiply(_ other: borrowing FFTContainer) {
        precondition(n == other.n && length == other.length)
        if multipliesPartsWithKaratsuba {
            // Karatsuba multiplies the parts, and all products share its scratch space.
            var scratch = UniqueArray<UInt64>(repeating: 0, count: length >= karatsubaThreshold ? 4 * karatsubaLength(length) : 0)
            var scratchDigits = scratch.mutableSpan
            // partStart is part i's first digit, below storage.count, so advancing it cannot overflow.
            var partStart = 0
            for i in 0..<n {
                do {
                    var result = temp.mutableSpan
                    let digits = storage.span.extracting(droppingFirst: partStart).extracting(0..<length)
                    let otherDigits = other.storage.span.extracting(droppingFirst: partStart).extracting(0..<length)
                    karatsubaChunk(&result, 0, 2 * length, digits, otherDigits, false, &scratchDigits)
                }
                reduceAndButterfly(i, partStart)
                partStart &+= length
            }
            return
        }

        // Recursive invocation ("inner layer"), which needs an additional weighting by powers of theta. All products
        // share the containers.
        let params = FFT.computeParametersInner(K)
        let omega = 2 * params.r // 2^omega is a primitive n-th root of unity mod F_n.
        let theta = params.r // 2^theta is a primitive 2n-th root, the weight.
        var a = FFTContainer(params.n, params.K)
        var b = FFTContainer(params.n, params.K)
        // partStart is part i's first digit, below storage.count, so advancing it cannot overflow.
        var partStart = 0
        for i in 0..<n {
            a.startDefault(storage.span.extracting(droppingFirst: partStart).extracting(0..<length), params.s, theta, omega)
            b.startDefault(other.storage.span.extracting(droppingFirst: partStart).extracting(0..<length), params.s, theta, omega)
            a.pointwiseMultiply(b)
            a.backwardFFT(omega)
            do {
                var result = temp.mutableSpan
                a.counterWeightAndRecombine(theta, params.m, &result, params.s)
            }
            reduceAndButterfly(i, partStart)
            partStart &+= length
        }
    }

    // pointwiseMultiply by self, squaring each part.
    mutating func pointwiseSquare() {
        if multipliesPartsWithKaratsuba {
            // Karatsuba multiplies the parts, and all products share its scratch space.
            var scratch = UniqueArray<UInt64>(repeating: 0, count: length >= karatsubaThreshold ? 4 * karatsubaLength(length) : 0)
            var scratchDigits = scratch.mutableSpan
            // partStart is part i's first digit, below storage.count, so advancing it cannot overflow.
            var partStart = 0
            for i in 0..<n {
                do {
                    var result = temp.mutableSpan
                    let digits = storage.span.extracting(droppingFirst: partStart).extracting(0..<length)
                    karatsubaChunk(&result, 0, 2 * length, digits, digits, true, &scratchDigits)
                }
                reduceAndButterfly(i, partStart)
                partStart &+= length
            }
            return
        }

        // Recursive invocation ("inner layer"), as in pointwiseMultiply; squaring needs only one container.
        let params = FFT.computeParametersInner(K)
        let omega = 2 * params.r // 2^omega is a primitive n-th root of unity mod F_n.
        let theta = params.r // 2^theta is a primitive 2n-th root, the weight.
        var a = FFTContainer(params.n, params.K)
        // partStart is part i's first digit, below storage.count, so advancing it cannot overflow.
        var partStart = 0
        for i in 0..<n {
            a.startDefault(storage.span.extracting(droppingFirst: partStart).extracting(0..<length), params.s, theta, omega)
            a.pointwiseSquare()
            a.backwardFFT(omega)
            do {
                var result = temp.mutableSpan
                a.counterWeightAndRecombine(theta, params.m, &result, params.s)
            }
            reduceAndButterfly(i, partStart)
            partStart &+= length
        }
    }
}

// Part 4: Tying everything together into a multiplication algorithm.
// result[offset ..< offset + x.count + y.count] := x * y, with x.count >= y.count and shouldUseFFT. With isSquare, y
// is x. Returns x.count + y.count.
func multiplyFFT(_ x: Span<UInt64>, _ y: Span<UInt64>, _ isSquare: Bool, _ result: inout MutableSpan<UInt64>, _ offset: Int) -> Int {
    // The counts are digit counts and offset an index into result, so this index arithmetic cannot overflow.
    assert(x.count >= y.count)
    assert(shouldUseFFT(x.count, y.count))
    let fullSize = x.count &+ y.count
    precondition(result.count &- offset >= fullSize)

    let params = FFT.getParameters(fullSize)
    let omega = params.r // 2^omega is a primitive n-th root of unity mod F_n.
    var a = FFTContainer(params.n, params.K)
    a.start(x, params.s, omega)
    if isSquare {
        a.pointwiseSquare()
    } else {
        var b = FFTContainer(params.n, params.K)
        b.start(y, params.s, omega)
        a.pointwiseMultiply(b)
    }
    a.backwardFFT(omega)
    a.normalizeAndRecombine(omega, params.m, &result, offset, fullSize, params.s)
    return fullSize
}

#endif // USE_SWIFT_BIGINT_DIGITS
