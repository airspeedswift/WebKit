// Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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

private import CxxStdlib
import WebGPU_Internal.Buffer
import WebGPU_Private.CxxBridgingPublic

extension WebGPU.Buffer {
    func copy(from source: Span<UInt8>, offset: Int) {
        let contents = BufferContents(m_buffer)
        var destination = contents.bytes()._consumingExtracting(droppingFirst: offset)
        destination.copyMemory(from: source)
    }
}

@_expose(Cxx)
func bufferCopyFrom(_ buffer: WebGPU.Buffer, from data: WebGPU.SpanConstUInt8, offset: Int) {
    buffer.copy(from: unsafe Span<UInt8>(_unsafeCxxSpan: data), offset: offset)
}

@_expose(Cxx)
func bufferGetMappedRange(_ buffer: WebGPU.Buffer, offset: Int, size: Int) -> WebGPU.SpanUInt8 {
    unsafe buffer.getMappedRange(offset: offset, size: size)
}

extension WebGPU.SpanUInt8 {
    /// A default-constructed, zero-length span: a null base pointer that's never read through.
    ///
    /// Marked `@safe` because the empty case carries no risk.
    @safe
    fileprivate static var empty: WebGPU.SpanUInt8 {
        unsafe WebGPU.SpanUInt8()
    }
}

extension WebGPU.Buffer {
    func getMappedRange(offset: Int, size: Int) -> WebGPU.SpanUInt8 {
        if !isValid() {
            return .empty
        }

        var rangeSize = size
        if size == WGPU_WHOLE_MAP_SIZE {
            rangeSize = max(Int(currentSize()) - offset, 0)
        }

        if !validateGetMappedRange(offset, rangeSize) {
            return .empty
        }

        m_mappedRanges.add(.init(UInt(offset), UInt(offset + rangeSize)))
        m_mappedRanges.compact()

        if m_buffer.storageMode == .private || m_buffer.storageMode == .memoryless || m_buffer.length == 0 {
            return .empty
        }

        return unsafe getBufferContents().subspan(offset, rangeSize)
    }
}

/// The Metal allocation backing a `Buffer`, and the only place a raw pointer to
/// it is turned into a span.
///
/// Noncopyable so there is exactly one handle per allocation: copying this would
/// produce two wrappers over one `MTLBuffer` with no indication at the use site.
/// Metal still refcounts the allocation itself, and command buffers retain the
/// resources they use, so the uniqueness is our handle's and not the GPU
/// object's.
struct BufferContents: ~Copyable {
    private let buffer: any MTLBuffer

    init(_ buffer: any MTLBuffer) {
        self.buffer = buffer
    }

    /// The allocation's bytes, valid for as long as this value is borrowed.
    @_lifetime(borrow self)
    borrowing func bytes() -> MutableSpan<UInt8> {
        let count = buffer.length
        // SAFETY: `contents` returns the base of the allocation that `length`
        // measures, so binding `length` bytes of it stays inside the allocation.
        // Not provable today because Metal declares `contents` as `void*` with no
        // `__sized_by(length)`, leaving SafeInteropWrappers no extent to work from.
        let start = unsafe buffer.contents().bindMemory(to: UInt8.self, capacity: count)
        // SAFETY: the same extent, restated as a span over the same allocation.
        // Not provable today for the same reason.
        let span = unsafe MutableSpan<UInt8>(_unsafeStart: start, count: count)
        // SAFETY: the pointer is interior to `buffer`, which this value owns, so it
        // stays valid for as long as `self` is borrowed. `NS_RETURNS_INNER_POINTER`
        // on `contents` states this, and ARC already depends on it.
        // Not provable today because that attribute is not imported as a lifetime
        // dependency, so the span's inferred dependency is on `start` rather than on
        // the receiver. (rdar://161274084)
        return unsafe _overrideLifetime(span, borrowing: self)
    }
}
