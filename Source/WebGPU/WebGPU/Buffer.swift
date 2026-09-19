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
import Metal
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

/// A set of half-open byte ranges, held sorted and non-overlapping.
///
/// `Buffer` records each range it hands out through `getMappedRange`, so that a
/// later call asking for an overlapping range fails validation, and so that
/// `unmap` can tell Metal which bytes of a managed allocation were modified.
///
/// Ranges accumulate unsorted and are merged on the next query, matching the
/// `RangeSet` this replaces: adding is the common operation and reading is not.
struct MappedRanges {
    private var ranges: [Range<Int>] = []
    private var isCompact = true

    /// Records `range`. Empty ranges are not recorded.
    mutating func add(_ range: Range<Int>) {
        if range.isEmpty {
            return
        }
        if let last = ranges.last, last.lowerBound <= range.lowerBound, last.upperBound >= range.upperBound {
            return
        }
        ranges.append(range)
        isCompact = false
    }

    /// Whether any recorded range shares a byte with `range`.
    mutating func overlaps(_ range: Range<Int>) -> Bool {
        if range.isEmpty {
            return false
        }
        compact()
        return ranges.contains { $0.lowerBound < range.upperBound && range.lowerBound < $0.upperBound }
    }

    mutating func removeAll() {
        ranges.removeAll()
        isCompact = true
    }

    /// The recorded ranges, sorted and with touching or overlapping ones merged.
    mutating func compacted() -> [Range<Int>] {
        compact()
        return ranges
    }

    private mutating func compact() {
        if isCompact {
            return
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        ranges = merged
        isCompact = true
    }
}

/// The storage a `Buffer` owns: its Metal allocation, the size and usage fixed
/// when it was created, the mapping state, and the memo that lets a repeated
/// indexed draw skip revalidating the same index data.
///
/// Two things a `Buffer` has are deliberately not here. Its `Device` is a C++
/// `Ref`, and the set of command encoders reading it lives in `TrackedResource`,
/// a base shared with `Texture`, `TextureView`, `QuerySet` and `ExternalTexture`
/// and written against by `CommandEncoder`; neither is this type's to hold.
///
/// A class, not a value, because the mapping and memo state is mutated through
/// whichever of several holders reaches the buffer first and the others must see
/// it: `RenderBundleEncoder` keeps a `RefPtr<Buffer>` while `CommandEncoder`
/// takes a `Buffer&`, and the buffer crosses threads.
@_expose(Cxx)
final class BufferState {
    /// The Metal allocation. Held as the handle rather than as a `BufferContents`
    /// because a `BufferContents` is noncopyable and a class stored property
    /// cannot be borrowed out of; `contents()` wraps it at the point the bytes
    /// are read, which is the only place the raw pointer is turned into a span.
    private var allocation: (any MTLBuffer)?

    // https://gpuweb.github.io/gpuweb/#buffer-interface
    let initialSize: UInt64
    let usage: WGPUBufferUsageFlags

    /// The `Buffer.State` this buffer is in, as its underlying value: the
    /// enumeration is part of the interface `Buffer` presents to C++ and stays
    /// declared there.
    var rawState: UInt8
    var mapMode: WGPUMapModeFlags
    var mappingBeginOffset: Int
    var mappingEndOffset: Int
    private var mappedRanges = MappedRanges()

    var maxUnsignedIndex: UInt32 = 0
    var maxUshortIndex: UInt16 = 0
    var maxValidatedUnsignedIndex: UInt32 = 0
    var maxValidatedUshortIndex: UInt16 = 0
    var mustTakeSlowIndexValidationPath = false
    /// Bumped whenever the contents change in a way that invalidates a previously
    /// GPU-encoded indirect draw.
    var contentsGeneration: UInt64 = 0
    var indexContentsGeneration: UInt64 = 0
    var indexValueUpperBoundUint: UInt32 = 0
    var indexValueUpperBoundUshort: UInt16 = 0

    init(
        allocation: (any MTLBuffer)?,
        initialSize: UInt64,
        usage: WGPUBufferUsageFlags,
        rawState: UInt8,
        mappingBeginOffset: Int,
        mappingEndOffset: Int
    ) {
        self.allocation = allocation
        self.initialSize = initialSize
        self.usage = usage
        self.rawState = rawState
        self.mapMode = WGPUMapModeFlags(WGPUMapMode_None.rawValue)
        self.mappingBeginOffset = mappingBeginOffset
        self.mappingEndOffset = mappingEndOffset
    }

    /// Whether this buffer has an allocation at all. A buffer created invalid has
    /// none.
    var hasAllocation: Bool {
        allocation != nil
    }

    /// The length of the current allocation, which is what the buffer reports as
    /// its current size.
    var currentSize: UInt64 {
        UInt64(allocation?.length ?? 0)
    }

    var metalBuffer: (any MTLBuffer)? {
        allocation
    }

    /// A handle to the allocation's bytes, for as long as the returned value
    /// lives.
    func contents() -> BufferContents? {
        guard let allocation else {
            return nil
        }
        return BufferContents(allocation)
    }

    /// Takes on `buffer` as the allocation, releasing the previous one. `destroy`
    /// uses this to swap in the device's placeholder.
    func replaceAllocation(with buffer: (any MTLBuffer)?) {
        allocation = buffer
    }

    func mappedRangesOverlap(begin: Int, end: Int) -> Bool {
        mappedRanges.overlaps(begin..<end)
    }

    func addMappedRange(begin: Int, end: Int) {
        mappedRanges.add(begin..<end)
    }

    func clearMappedRanges() {
        mappedRanges.removeAll()
    }

    /// The recorded mapped ranges, merged, as begin/end pairs read by index:
    /// `unmap` walks them to tell Metal which bytes of a managed allocation
    /// changed.
    func compactMappedRanges() -> Int {
        mappedRanges.compacted().count
    }

    func mappedRangeBegin(_ index: Int) -> Int {
        mappedRanges.compacted()[index].lowerBound
    }

    func mappedRangeEnd(_ index: Int) -> Int {
        mappedRanges.compacted()[index].upperBound
    }

    func indexBufferContentsModified(maxUintValue: UInt32, maxUshortValue: UInt16) {
        indexContentsGeneration += 1
        indexValueUpperBoundUint = max(indexValueUpperBoundUint, maxUintValue)
        indexValueUpperBoundUshort = UInt16(max(UInt32(indexValueUpperBoundUshort), UInt32(maxUshortValue)))
    }

    func allIndexValuesBelow(ushortIndices: Bool, vertexCount: UInt32) -> Bool {
        (ushortIndices ? UInt32(indexValueUpperBoundUshort) : indexValueUpperBoundUint) < vertexCount
    }
}
