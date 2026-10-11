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

// A mask of each lane's top bit (PMOVMSKB), an operation expected in the Swift standard library. This file goes away
// when it lands. It is internal because a public @_transparent body naming Builtin would be printed into
// WebCore's .swiftinterface, which cannot import Builtin.

import Builtin

/// A 16-bit mask with bit `i` set when lane `i` of `v` has its top bit set (a "movemask").
///
/// Equivalent to the x86 SSE2 instruction `PMOVMSKB`. On arm64, which has no single instruction for it, this
/// narrows each lane's sign to a nibble (SHRN) and gathers the 16 nibbles with a fixed shift-or network.
/// An AND with per-lane weights 1, 2, 4, ... followed by ADDP is shorter, but LLVM specialises the
/// lane-varying weights and computes lanes in scalar code.
@_transparent
func highBitMask(_ v: SIMD16<UInt8>) -> UInt16 {
#if arch(arm64)
  let sign = SIMD16<UInt8>(truncatingIfNeeded: SIMD16<Int8>(truncatingIfNeeded: v) &>> 7)
  let nibbles = SIMD8<UInt8>(truncatingIfNeeded: bitCast(sign, to: SIMD8<UInt16>.self) &>> 4)
  var x = bitCast(nibbles, to: UInt64.self) & 0x1111_1111_1111_1111
  x = (x | (x &>> 3)) & 0x0303_0303_0303_0303
  x = (x | (x &>> 6)) & 0x000F_000F_000F_000F
  x = (x | (x &>> 12)) & 0x0000_00FF_0000_00FF
  x = (x | (x &>> 24)) & 0xFFFF
  return UInt16(truncatingIfNeeded: x)
#elseif arch(x86_64)
  return UInt16(truncatingIfNeeded: Int32(Builtin.int_x86_sse2_pmovmskb_128(v._storage._value)))
#else
  var result: UInt16 = 0
  for i in 0..<16 where v[i] & 0x80 != 0 { result |= 1 << i }
  return result
#endif
}
