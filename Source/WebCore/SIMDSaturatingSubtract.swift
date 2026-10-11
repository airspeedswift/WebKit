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

// Lane-wise saturating subtraction (UQSUB, PSUBUSB), an operation expected in the Swift standard library. This file goes away
// when it lands. It is internal because a public @_transparent body naming Builtin would be printed into
// WebCore's .swiftinterface, which cannot import Builtin.

import Builtin

/// Lane-wise saturating subtraction: `max(a - b, 0)` for each unsigned lane.
///
/// Equivalent to the ARM instruction:
/// ```
/// UQSUB Vd.16b, Vn.16b, Vm.16b
/// ```
/// or the x86 SSE2 instruction `PSUBUSB`.
@_transparent
func saturatingSubtract(
  _ a: SIMD16<UInt8>,
  _ b: SIMD16<UInt8>
) -> SIMD16<UInt8> {
  var result = SIMD16<UInt8>()
  result._storage._value = Builtin.int_usub_sat_Vec16xInt8(
    a._storage._value, b._storage._value
  )
  return result
}
