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

// PROTOTYPE. SIMD operations the UTF-8 decoder needs that portable Swift cannot yet spell: a
// data-dependent byte shuffle (TBL on arm64, PSHUFB on x86_64 with SSSE3), free lane
// reinterpretations, saturating subtract and a high-bit mask. They are standard library material
// (the table lookup is expected there soon) and are here, through the Builtin module
// (-enable-experimental-feature BuiltinModule), only for experimentation; this file goes away when
// the standard library has them. Internal, not public as they would be there: a public
// @_transparent body naming Builtin would be printed into PAL's .swiftinterface, which cannot import
// Builtin.

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


#if !(arch(arm64) || (arch(x86_64) || arch(i386)) && HAVE_SSSE3)
// Out-of-line scalar fallback for TBL and TBX
@inline(never)
func neon_tbxScalar(
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

// MARK: - Additions for the UTF-8 decoder experiment
//
// Same shape as neon_tbl above: Builtin-backed, one instruction on arm64 and x86_64, a portable
// fallback elsewhere. Like neon_tbl, these belong in the standard library; they are here only so the
// experiment can use them.

/// The lanes of `v` reinterpreted as four 32-bit lanes (little-endian lane order). Free.
@_transparent
func reinterpretAsUInt32(_ v: SIMD16<UInt8>) -> SIMD4<UInt32> {
  var r = SIMD4<UInt32>()
  r._storage._value = Builtin.bitcast_Vec16xInt8_Vec4xInt32(v._storage._value)
  return r
}

/// The lanes of `v` reinterpreted as eight 16-bit lanes (little-endian lane order). Free.
@_transparent
func reinterpretAsUInt16(_ v: SIMD16<UInt8>) -> SIMD8<UInt16> {
  var r = SIMD8<UInt16>()
  r._storage._value = Builtin.bitcast_Vec16xInt8_Vec8xInt16(v._storage._value)
  return r
}

/// The lanes of `v` reinterpreted as sixteen bytes. Free.
@_transparent
func reinterpretAsBytes(_ v: SIMD4<UInt32>) -> SIMD16<UInt8> {
  var r = SIMD16<UInt8>()
  r._storage._value = Builtin.bitcast_Vec4xInt32_Vec16xInt8(v._storage._value)
  return r
}

/// Lane-wise `max(a - b, 0)` (UQSUB / PSUBUSB).
@_transparent
func saturatingSubtract(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>) -> SIMD16<UInt8> {
  var r = SIMD16<UInt8>()
  r._storage._value = Builtin.int_usub_sat_Vec16xInt8(a._storage._value, b._storage._value)
  return r
}

/// Bit `i` set when lane `i` of `v` has its top bit set (PMOVMSKB; on arm64 AND + three ADDP).
@_transparent
func highBitMask(_ v: SIMD16<UInt8>) -> UInt16 {
#if arch(arm64)
  // SHRN: each byte lane becomes a nibble of a 64-bit value (all ones where the lane's top bit is set),
  // then a fixed bit-gather packs the 16 nibbles into 16 bits. (An AND with per-lane weights 1, 2, 4 ...
  // and ADDP is shorter, but LLVM specializes the lane-varying weights and computes lanes in scalar code.)
  let sign = SIMD16<UInt8>(truncatingIfNeeded: SIMD16<Int8>(truncatingIfNeeded: v) &>> 7)
  let nibbles = SIMD8<UInt8>(truncatingIfNeeded: reinterpretAsUInt16(sign) &>> 4)
  var x = UInt64(Builtin.bitcast_Vec8xInt8_Int64(nibbles._storage._value)) & 0x1111_1111_1111_1111
  x = (x | (x &>> 3)) & 0x0303_0303_0303_0303
  x = (x | (x &>> 6)) & 0x000F_000F_000F_000F
  x = (x | (x &>> 12)) & 0x0000_00FF_0000_00FF
  x = (x | (x &>> 24)) & 0xFFFF
  return UInt16(truncatingIfNeeded: x)
#elseif arch(x86_64)
  return UInt16(truncatingIfNeeded: Int32(Builtin.int_x86_sse2_pmovmskb_128(v._storage._value)))
#else
  var r: UInt16 = 0
  for i in 0..<16 where v[i] & 0x80 != 0 { r |= 1 << i }
  return r
#endif
}

/// Eight 16-bit lanes reinterpreted as four 32-bit lanes (little-endian lane order). Free.
@_transparent
func reinterpretAsUInt32(_ v: SIMD8<UInt16>) -> SIMD4<UInt32> {
  var r = SIMD4<UInt32>()
  r._storage._value = Builtin.bitcast_Vec8xInt16_Vec4xInt32(v._storage._value)
  return r
}

/// Four 32-bit lanes reinterpreted as eight 16-bit lanes (little-endian lane order). Free.
@_transparent
func reinterpretAsUInt16(_ v: SIMD4<UInt32>) -> SIMD8<UInt16> {
  var r = SIMD8<UInt16>()
  r._storage._value = Builtin.bitcast_Vec4xInt32_Vec8xInt16(v._storage._value)
  return r
}

#endif // USE_SWIFT_TEXT_CODEC_UTF8
