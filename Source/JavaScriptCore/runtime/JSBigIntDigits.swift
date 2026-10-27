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

#if USE_SWIFT_BIGINT_DIGITS

internal import JSCSwiftBoundary

// JSBigInt's digit arithmetic, called from JSBigInt.cpp. Every span is valid for the call and nothing else writes
// it: the digits of a JSBigInt cell or of an Int32BigIntImpl or Int64BigIntImpl on the caller's stack, a Vector the
// caller owns, or VM::m_bigIntCachedInverse. The caller allocates no cell and runs no JavaScript during the call.
// A result's digits may be uninitialized, so each entry point writes a result digit before it reads it. The digits are
// uint64_t, which has no invalid values, and nothing else reads a result span during the call.
// FIXME: Take Span and MutableSpan parameters once a std::span can cross safely (rdar://186723514).

/// Multiplies `x` by `y` into `result` and returns the product's length.
///
/// With `isSquare`, `y` is empty and the product is `x * x`. `result` overlaps neither operand.
@_expose(Cxx)
func jsBigIntMultiplyDigits(
    _ x: JSC.JSBigIntDigits,
    _ y: JSC.JSBigIntDigits,
    _ isSquare: Bool,
    _ result: JSC.JSBigIntMutableDigits
) -> Int {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let y = unsafe Span<UInt64>(_unsafeCxxSpan: y)
    var result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    // One-digit operands skip the size dispatch.
    if x.count == 1 {
        if isSquare {
            return squareCombaFixed1(x, &result, 0)
        }
        if y.count == 1 {
            return multiplyCombaFixed1(x, y, &result, 0)
        }
    }
    return multiplyDigits(x, y, isSquare, result)
}

/// Adds `y` to `x` into `result` and returns the sum's length.
///
/// `result` overlaps neither operand.
@_expose(Cxx)
func jsBigIntAddDigits(_ x: JSC.JSBigIntDigits, _ y: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let y = unsafe Span<UInt64>(_unsafeCxxSpan: y)
    var result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    // An x of one or two digits and a y no longer than x skip the size dispatch and the call to it, in a path short
    // enough for the C++ caller to inline this entry. A one-digit y has 0 as its second digit.
    if x.count <= 2 && y.count >= 1 && y.count <= x.count {
        precondition(result.count > x.count)
        var carry: UInt64 = 0
        result[0] = digitAdd(x[0], y[0], &carry)
        if x.count == 2 {
            var topCarry: UInt64 = 0
            result[1] = digitAdd3(x[1], y.count == 2 ? y[1] : 0, carry, &topCarry)
            result[2] = topCarry
        } else {
            result[1] = carry
        }
        return x.count + 1
    }
    return addDigits(x, y, result)
}

/// Subtracts `y` from `x`, which is not smaller, into `result` and returns the difference's length.
///
/// `result` overlaps neither operand.
@_expose(Cxx)
func jsBigIntSubDigits(_ x: JSC.JSBigIntDigits, _ y: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let y = unsafe Span<UInt64>(_unsafeCxxSpan: y)
    var result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    // As in jsBigIntAddDigits. With x >= y, the second digit has no borrow out.
    if x.count <= 2 && y.count >= 1 && y.count <= x.count {
        precondition(result.count >= x.count)
        var borrow: UInt64 = 0
        result[0] = digitSub(x[0], y[0], &borrow)
        if x.count == 2 {
            var topBorrow: UInt64 = 0
            result[1] = digitSub2(x[1], y.count == 2 ? y[1] : 0, borrow, &topBorrow)
        }
        return x.count
    }
    return subDigits(x, y, result)
}

/// Computes `x & y` over the absolute values into `result` and returns min(x.count, y.count).
///
/// `result` overlaps neither operand.
@_expose(Cxx)
func jsBigIntAndDigits(_ x: JSC.JSBigIntDigits, _ y: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let y = unsafe Span<UInt64>(_unsafeCxxSpan: y)
    let result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    assert(result.count >= min(x.count, y.count))
    return absoluteAnd(x, y, result)
}

/// Computes `x | y` over the absolute values into `result` and returns max(x.count, y.count).
///
/// `result` overlaps neither operand.
@_expose(Cxx)
func jsBigIntOrDigits(_ x: JSC.JSBigIntDigits, _ y: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let y = unsafe Span<UInt64>(_unsafeCxxSpan: y)
    let result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    assert(result.count >= max(x.count, y.count))
    return absoluteOr(x, y, result)
}

/// Computes `x & ~y` over the absolute values into `result` and returns x.count.
///
/// `result` overlaps neither operand.
@_expose(Cxx)
func jsBigIntAndNotDigits(_ x: JSC.JSBigIntDigits, _ y: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let y = unsafe Span<UInt64>(_unsafeCxxSpan: y)
    let result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    return absoluteAndNot(x, y, result)
}

/// Computes `x ^ y` over the absolute values into `result` and returns max(x.count, y.count).
///
/// `result` overlaps neither operand.
@_expose(Cxx)
func jsBigIntXorDigits(_ x: JSC.JSBigIntDigits, _ y: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let y = unsafe Span<UInt64>(_unsafeCxxSpan: y)
    let result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    assert(result.count >= max(x.count, y.count))
    return absoluteXor(x, y, result)
}

/// Computes `x + 1` into `result` and returns its length, x.count or x.count + 1.
///
/// `result` does not overlap `x`.
@_expose(Cxx)
func jsBigIntAddOneDigits(_ x: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    return absoluteAddOne(x, result)
}

/// Computes `x - 1`, with `x` not zero, into `result` and returns x.count.
///
/// `result` does not overlap `x`.
@_expose(Cxx)
func jsBigIntSubOneDigits(_ x: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    return absoluteSubOne(x, result)
}

/// Divides `a` by the single digit `divisor` into `quotient` and returns the remainder.
///
/// An empty `quotient` asks for the remainder alone. `quotient` does not overlap `a`; an in-place division calls
/// jsBigIntDivideSingleInPlace.
@_expose(Cxx)
func jsBigIntDivideSingle(_ quotient: JSC.JSBigIntMutableDigits, _ a: JSC.JSBigIntDigits, _ divisor: UInt64) -> UInt64 {
    let quotient = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: quotient)
    let a = unsafe Span<UInt64>(_unsafeCxxSpan: a)
    return divideSingle(quotient, a, divisor)
}

/// Divides `digits` by the single digit `divisor` in place and returns the remainder.
///
/// `digits` is a Vector the caller owns, which nothing else reads or writes during the call.
@_expose(Cxx)
func jsBigIntDivideSingleInPlace(_ digits: JSC.JSBigIntMutableDigits, _ divisor: UInt64) -> UInt64 {
    let digits = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: digits)
    return divideSingleInPlace(digits, divisor)
}

/// Divides `a` by `b` into `quotient` and `remainder`, either of which may be empty.
///
/// `b` has at least two digits and is shorter than `a`. Returns the length of `quotient` if it is not empty, and else
/// that of `remainder`. `quotient` and `remainder` overlap neither each other nor the inputs.
@_expose(Cxx)
func jsBigIntDivideDigits(
    _ quotient: JSC.JSBigIntMutableDigits,
    _ remainder: JSC.JSBigIntMutableDigits,
    _ a: JSC.JSBigIntDigits,
    _ b: JSC.JSBigIntDigits
) -> Int {
    var quotient = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: quotient)
    var remainder = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: remainder)
    let a = unsafe Span<UInt64>(_unsafeCxxSpan: a)
    let b = unsafe Span<UInt64>(_unsafeCxxSpan: b)
    return divideDigits(&quotient, &remainder, a, b)
}

/// Divides `a` by `b` into `quotient` and `remainder`, either of which may be empty, and returns the quotient's length
/// shifted left 32 bits ORed with the remainder's (each is at most 16,384 digits).
///
/// `b` has at least two digits and is no longer than `a`. `quotient` and `remainder` overlap neither each other nor the
/// inputs.
@_expose(Cxx)
func jsBigIntDivideDigitsInto(
    _ quotient: JSC.JSBigIntMutableDigits,
    _ remainder: JSC.JSBigIntMutableDigits,
    _ a: JSC.JSBigIntDigits,
    _ b: JSC.JSBigIntDigits
) -> Int {
    var quotient = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: quotient)
    var remainder = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: remainder)
    let a = unsafe Span<UInt64>(_unsafeCxxSpan: a)
    let b = unsafe Span<UInt64>(_unsafeCxxSpan: b)
    let (quotientCount, remainderCount) = divideDigitsInto(&quotient, &remainder, a, b)
    return quotientCount << 32 | remainderCount
}

/// Returns `a / b`, a single digit, for `a` greater than `b`.
///
/// `a` and `b` have the same length, of at least two digits.
@_expose(Cxx)
func jsBigIntDivideSameSize(_ a: JSC.JSBigIntDigits, _ b: JSC.JSBigIntDigits) -> UInt64 {
    let a = unsafe Span<UInt64>(_unsafeCxxSpan: a)
    let b = unsafe Span<UInt64>(_unsafeCxxSpan: b)
    return divideSameSize(a, b)
}

/// Computes `a % b` into `remainder` and returns the remainder's length, that of `a`.
///
/// `a` is greater than `b`, and they have the same length, of at least two digits. `remainder` overlaps neither.
@_expose(Cxx)
func jsBigIntRemainderSameSize(
    _ remainder: JSC.JSBigIntMutableDigits,
    _ a: JSC.JSBigIntDigits,
    _ b: JSC.JSBigIntDigits
) -> Int {
    let remainder = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: remainder)
    let a = unsafe Span<UInt64>(_unsafeCxxSpan: a)
    let b = unsafe Span<UInt64>(_unsafeCxxSpan: b)
    return remainderSameSize(remainder, a, b)
}

/// Reduces `a` modulo `b` into `remainder` and returns the remainder's length.
///
/// It uses the VM's cached `foldFactor` for `b`, or when that is 0, its cached `inverse` (VM::m_bigIntCachedInverse).
/// `remainder` overlaps none of the inputs.
@_expose(Cxx)
func jsBigIntCachedMod(
    _ remainder: JSC.JSBigIntMutableDigits,
    _ a: JSC.JSBigIntDigits,
    _ b: JSC.JSBigIntDigits,
    _ foldFactor: UInt64,
    _ inverse: JSC.JSBigIntDigits
) -> Int {
    var remainder = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: remainder)
    let a = unsafe Span<UInt64>(_unsafeCxxSpan: a)
    let b = unsafe Span<UInt64>(_unsafeCxxSpan: b)
    let inverse = unsafe Span<UInt64>(_unsafeCxxSpan: inverse)
    return cachedMod(&remainder, a, b, foldFactor, inverse)
}

/// Returns the fold factor for the divisor `b`, or 0 if `b` has none.
@_expose(Cxx)
func jsBigIntCachedModFoldFactor(_ b: JSC.JSBigIntDigits) -> UInt64 {
    let b = unsafe Span<UInt64>(_unsafeCxxSpan: b)
    return cachedModFoldFactor(b)
}

/// Computes the inverse of the divisor `b` into `inverse`, which has `b.count + 1` digits.
///
/// `inverse` is VM::m_bigIntCachedInverse, which nothing else reads or writes during the call, and does not overlap
/// `b`.
@_expose(Cxx)
func jsBigIntCachedModMakeInverse(_ b: JSC.JSBigIntDigits, _ inverse: JSC.JSBigIntMutableDigits) {
    let b = unsafe Span<UInt64>(_unsafeCxxSpan: b)
    var inverse = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: inverse)
    cachedModMakeInverse(b, &inverse)
}

/// Sets `digits` to `digits * factor + summand` in place.
///
/// `digits` is a Vector the caller owns, which nothing else reads or writes during the call.
@_expose(Cxx)
func jsBigIntMultiplyAddInPlace(_ digits: JSC.JSBigIntMutableDigits, _ factor: UInt64, _ summand: UInt64) {
    var digits = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: digits)
    multiplyAddInPlace(&digits, factor, summand)
}

/// Writes `x` shifted left by `digitShift` digits and `bitsShift` bits into `result`, which the caller sized for it.
///
/// `result` does not overlap `x`.
@_expose(Cxx)
func jsBigIntShiftLeftDigits(
    _ x: JSC.JSBigIntDigits,
    _ digitShift: Int,
    _ bitsShift: Int,
    _ result: JSC.JSBigIntMutableDigits
) {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    shiftLeftDigits(x, digitShift, bitsShift, result)
}

/// Writes `x` shifted right by `digitShift` digits and `bitsShift` bits into `result`, which the caller sized for it.
///
/// With `roundDown`, it adds one to the result. `result` does not overlap `x`.
@_expose(Cxx)
func jsBigIntShiftRightDigits(
    _ x: JSC.JSBigIntDigits,
    _ digitShift: Int,
    _ bitsShift: Int,
    _ roundDown: Bool,
    _ result: JSC.JSBigIntMutableDigits
) {
    let x = unsafe Span<UInt64>(_unsafeCxxSpan: x)
    let result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    shiftRightDigits(x, digitShift, bitsShift, roundDown, result)
}

/// Writes the integer square root of the non-zero `value` into `result` and returns its length.
///
/// `result` has `value.count + 2` digits and does not overlap `value`.
@_expose(Cxx)
func jsBigIntSqrtDigits(_ value: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let value = unsafe Span<UInt64>(_unsafeCxxSpan: value)
    var result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    return sqrtDigits(value, &result)
}

/// Writes the integer cube root of the absolute value of the non-zero `value` into `result` and returns its length.
///
/// `result` has `value.count + 2` digits and does not overlap `value`.
@_expose(Cxx)
func jsBigIntCbrtDigits(_ value: JSC.JSBigIntDigits, _ result: JSC.JSBigIntMutableDigits) -> Int {
    let value = unsafe Span<UInt64>(_unsafeCxxSpan: value)
    var result = unsafe MutableSpan<UInt64>(_unsafeCxxSpan: result)
    return cbrtDigits(value, &result)
}

#endif // USE_SWIFT_BIGINT_DIGITS
