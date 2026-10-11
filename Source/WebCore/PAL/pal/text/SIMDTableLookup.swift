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

// The SIMD table lookup expected in the standard library: neon_tbl and neon_tbx, a byte shuffle selected by the
// lanes of an index vector. This file stands in for it until the standard library has it, and then
// goes away.

#if USE_SWIFT_TEXT_CODEC_UTF8

import Builtin

/// Data-defined (dynamic) vector shuffle (table lookup)
///
/// For each lane of the result, examine the corresponding lane of `index`.
/// If the index is greater-than or equal to `16`, the corresponding
/// lane of the result is set to zero. Otherwise, the index is used to
/// copy the corresponding element of `table` to the result.
///
/// Equivalent to the ARM instruction:
/// ```
/// TBL1 Vd.16b, {Vt0.16b}, Vi.16b
/// ```
/// or the `<arm_neon.h>` intrinsic:
/// ```
/// uint8x16_t vtbl1q_u8(uint8x16_t table, uint8x16_t index)
/// ```
@_transparent
func neon_tbl(
  _ table: SIMD16<UInt8>,
  _ index: SIMD16<UInt8>
) -> SIMD16<UInt8> {
#if arch(arm64)
  var result = SIMD16<UInt8>()
  result._storage._value = Builtin.int_aarch64_neon_tbl1_Vec16xInt8(
    table._storage._value, index._storage._value
  )
  return result
#elseif arch(x86_64) && HAVE_SSSE3
  var result = SIMD16<UInt8>()
  // TBL zeros result if index >= 16, but PSHUFB zeros only if index >= 128.
  let clamped = Builtin.int_uadd_sat_Vec16xInt8(
    index._storage._value, SIMD16<UInt8>(repeating: 112)._storage._value
  )
  result._storage._value = Builtin.int_x86_ssse3_pshuf_b_128(
    table._storage._value, clamped
  )
  return result
#else
  neon_tbx(.init(), table, index)
#endif
}

/// Data-defined (dynamic) vector shuffle (table lookup)
///
/// For each lane of the result, examine the corresponding lane of `index`.
/// If the index is greater-than or equal to `16`, the corresponding
/// lane of `initialValue` is copied in the result. Otherwise, the index is
/// used to copy the corresponding element of `table` to the result.
///
/// Equivalent to the ARM instruction:
/// ```
/// TBX1 Vd.16b, {Vt0.16b}, Vi.16b
/// ```
/// or the `<arm_neon.h>` intrinsic:
/// ```
/// uint8x16_t vtbx1q_u8(uint8x16_t table, uint8x16_t index)
/// ```
@_transparent
func neon_tbx(
  _ initialValue: SIMD16<UInt8>,
  _ table: SIMD16<UInt8>,
  _ index: SIMD16<UInt8>
) -> SIMD16<UInt8> {
#if arch(arm64)
  var result = SIMD16<UInt8>()
  result._storage._value = Builtin.int_aarch64_neon_tbx1_Vec16xInt8(
    initialValue._storage._value, table._storage._value, index._storage._value
  )
  return result
#elseif arch(x86_64) && HAVE_SSSE3
  var result = SIMD16<UInt8>()
  // We're going to BSL the result anyway, so no need to add-sat here.
  let pshufb = Builtin.int_x86_ssse3_pshuf_b_128(
    table._storage._value, index._storage._value
  )
  let inRange = Builtin.cmp_ult_Vec16xInt8(
    index._storage._value, SIMD16<UInt8>(repeating: 16)._storage._value
  )
  result._storage._value  = Builtin.select_Vec16xInt1_Vec16xInt8(
    inRange, pshufb, initialValue._storage._value
  )
  return result
#else
  // Scalar gather fallback
  var result = initialValue
  withUnsafeBytes(of: table) {
    let src = RawSpan(_unsafeBytes: $0)
    withUnsafeBytes(of: index) {
      let idx = RawSpan(_unsafeBytes: $0)
      withUnsafeMutableBytes(of: &result) {
        var dst = MutableRawSpan(_unsafeBytes: $0)
        neon_tbxScalar(into: &dst, from: src, index: idx)
      }
    }
  }
  return result
#endif
}

import Builtin

#if !(arch(arm64) || (arch(x86_64) || arch(i386)) && HAVE_SSSE3)
// Out-of-line scalar fallback for TBL and TBX
@inline(never)
internal func neon_tbxScalar(
    into result: inout MutableRawSpan,
    from table: RawSpan,
    index: RawSpan
) {
  precondition(result.byteCount == index.byteCount)
  for i in 0..<index.byteCount {
    let idx = Int(index[unchecked: i])
    if idx < table.byteCount {
      result[unchecked: i] = table[unchecked: idx]
    }
  }
}
#endif

#endif
