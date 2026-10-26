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

// A safe face for CFNumberGetValue and CFNumberCreate.
//
// Both functions take a CFNumberType and an untyped pointer, and read or write
// as many bytes as the CFNumberType implies, whatever the pointee really is.
// A mismatched pair (.float64Type with a Float) silently overwrites adjacent
// memory. This file is the only place that pairs the two, and it makes the
// pairing impossible to get wrong anywhere else:
//
//  * Callers name a Swift type, never a CFNumberType: `n.value(as: Int32.self)`.
//  * The CFNumberType for a Swift type comes from its conformance to
//    CFNumberRepresentable, whose one requirement is a CFNumberTypeToken<Self>.
//  * CFNumberTypeToken's only initializer is fileprivate, so a token can only
//    be made in this file, and it is generic over the type it describes, so a
//    new conformance elsewhere cannot borrow another type's token. Conforming
//    a type outside this file therefore does not compile.
//  * The token initializer checks MemoryLayout<T>.size against the byte size
//    of the CFNumberType, so even a mistake in this file traps on first use
//    instead of corrupting memory.
//
// What this cannot stop: code elsewhere producing a fake CFNumber with
// `x as! CFNumber` (an unchecked cast in Swift). That gives a deterministic
// "unrecognized selector" crash in CF, not memory corruption; use
// CFNumber.checked(_:) to get one from an untyped value.

// ENABLE(IMAGE_DECODER_CG_SWIFT) (wtf/PlatformEnableCocoa.h, off by default).
#if ENABLE_IMAGE_DECODER_CG_SWIFT

// The generated C++ header (WebCoreSwift-Generated.h) puts this module's types in
// namespace WebCore, next to the C++ types they mirror (DecodingOptions,
// EncodedDataStatus, ImageOrientation, ...), and with WebCore's
// -emit-clang-header-min-access internal it emits an unavailable stub class
// for every internal type, which would redefine them. So every type here that
// is not a deliberate bridge type is @_expose(!Cxx).

import CoreFoundation
import CoreGraphics

/// Proof that `CFNumberType` `type` has exactly the layout of `T`.
/// Only this file can create one.
@_expose(!Cxx)
struct CFNumberTypeToken<T: BitwiseCopyable>: Sendable {
    let type: CFNumberType

    fileprivate init(_ type: CFNumberType) {
        precondition(Self.byteSize(of: type) == MemoryLayout<T>.size, "CFNumberType \(type.rawValue) does not match \(T.self)")
        self.type = type
    }

    private static func byteSize(of type: CFNumberType) -> Int? {
        switch type {
        case .sInt8Type, .charType: 1
        case .sInt16Type, .shortType: 2
        case .sInt32Type, .intType, .float32Type, .floatType: 4
        case .sInt64Type, .longLongType, .float64Type, .doubleType: 8
        case .cfIndexType: MemoryLayout<CFIndex>.size
        case .cgFloatType: MemoryLayout<CGFloat>.size
        default: nil // long, NSInteger: platform-dependent, not offered
        }
    }
}

/// A Swift type that can be read from or stored in a CFNumber.
/// Sealed: conformances outside this file cannot produce a token.
@_expose(!Cxx)
protocol CFNumberRepresentable: BitwiseCopyable {
    static var cfNumberType: CFNumberTypeToken<Self> { get }
    static var zero: Self { get }
}

extension Int8: CFNumberRepresentable { static var cfNumberType: CFNumberTypeToken<Int8> { .init(.sInt8Type) } }
extension Int16: CFNumberRepresentable { static var cfNumberType: CFNumberTypeToken<Int16> { .init(.sInt16Type) } }
/// Equivalent to C++ `int` with kCFNumberIntType.
extension Int32: CFNumberRepresentable { static var cfNumberType: CFNumberTypeToken<Int32> { .init(.intType) } }
extension Int64: CFNumberRepresentable { static var cfNumberType: CFNumberTypeToken<Int64> { .init(.sInt64Type) } }
/// CFIndex.
extension Int: CFNumberRepresentable { static var cfNumberType: CFNumberTypeToken<Int> { .init(.cfIndexType) } }
/// Equivalent to C++ `float` with kCFNumberFloatType / kCFNumberFloat32Type.
extension Float: CFNumberRepresentable { static var cfNumberType: CFNumberTypeToken<Float> { .init(.float32Type) } }
extension Double: CFNumberRepresentable { static var cfNumberType: CFNumberTypeToken<Double> { .init(.float64Type) } }
extension CGFloat: CFNumberRepresentable { static var cfNumberType: CFNumberTypeToken<CGFloat> { .init(.cgFloatType) } }

extension CFNumber {
    /// CFNumberGetValue. `exact` is CF's return value, false for a lossy or
    /// out-of-range conversion; `value` is what CF stored either way, so the
    /// semantics are exactly the C API's.
    func value<T: CFNumberRepresentable>(as _: T.Type = T.self) -> (value: T, exact: Bool) {
        let type = T.cfNumberType.type
        var value = T.zero
        let exact = withUnsafeMutablePointer(to: &value) { unsafe CFNumberGetValue(self, type, $0) }
        return (value, exact)
    }

    /// CFNumberCreate.
    static func make<T: CFNumberRepresentable>(_ value: T) -> CFNumber {
        let type = T.cfNumberType.type
        return withUnsafePointer(to: value) { unsafe CFNumberCreate(kCFAllocatorDefault, type, $0) }
    }

    /// The value as a CFNumber if its CF type ID says it is one; nil for any
    /// other object, including CFBoolean. Swift's `as! CFNumber` does not check.
    static func checked(_ value: Any?) -> CFNumber? {
        guard let value else { return nil }
        let object = value as CFTypeRef
        return CFGetTypeID(object) == CFNumberGetTypeID() ? (object as! CFNumber) : nil
    }
}

#endif // ENABLE_IMAGE_DECODER_CG_SWIFT
