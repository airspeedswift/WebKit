/*
 * Copyright (c) 2021-2022 Apple Inc. All rights reserved.
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

#pragma once

#import "BindableResource.h"
#import "Device.h"
#import "Instance.h"
#import <Metal/Metal.h>
#import <WebGPU/WGPUBufferImpl.h>
#import <WebGPU/WebGPU.h>
#import <WebGPU/WebGPUExt.h>
#import <memory>
#import <utility>
#import <wtf/CanBorrow.h>
#import <wtf/Compiler.h>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/Range.h>
#import <wtf/RangeSet.h>
#import <wtf/Ref.h>
#import <wtf/RefCountedAndCanMakeWeakPtr.h>
#import <wtf/SwiftBridging.h>
#import <wtf/SwiftCXXThunk.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/WeakPtr.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

namespace WebGPU {

class CommandBuffer;
class CommandEncoder;
class Device;

#if ENABLE(WEBGPU_SWIFT)
// Defined in Buffer.swift and reached through WebGPUSwift-Generated.h, which this
// header cannot include: that header names WebGPU::Buffer in the signatures of the
// island's thunks.
class BufferState;
#endif

// https://gpuweb.github.io/gpuweb/#gpubuffer
//
// Under ENABLE(WEBGPU_SWIFT) the storage lives in Swift, in BufferState, and this
// class holds it. It is a C++ class either way because a Swift class cannot inherit
// from a C++ class, and every holder of a Buffer relies on four C++ bases: the
// WGPUBufferImpl the C API hands out, the thread-safe refcount and weak pointer,
// CanBorrow, and the TrackedResource that CommandEncoder writes the encoder set
// through (rdar://163102366).
//
// The member declarations below are the same in both configurations. Only the
// storage fields and the private accessors that reach them are selected by the
// gate; every member body is written once, against those accessors.
class Buffer : public WGPUBufferImpl, public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<Buffer>, public CanBorrow, public TrackedResource {
    WTF_MAKE_TZONE_ALLOCATED(Buffer);
public:
    enum class State : uint8_t;
    struct MappingRange {
        size_t beginOffset; // Inclusive
        size_t endOffset; // Exclusive
    };

    static Ref<Buffer> create(id<MTLBuffer>, uint64_t initialSize, WGPUBufferUsageFlags, State initialState, MappingRange initialMappingRange, Device&);
    static Ref<Buffer> createInvalid(Device&);

    // Declared here and defined in Buffer.mm: under ENABLE(WEBGPU_SWIFT) destroying
    // the unique_ptr needs a complete BufferState, which only the generated header
    // provides.
    ~Buffer();

    void destroy();
    std::span<uint8_t> getMappedRange(size_t offset, size_t);
    void bufferCopy(std::span<const uint8_t>, size_t offset);
    void mapAsync(WGPUMapModeFlags, size_t offset, size_t, CompletionHandler<void(WGPUBufferMapAsyncStatus)>&& callback);
    void unmap();
    void setLabel(String&&);
    void generateAValidationError(String&&);

    bool NODELETE isValid() const;

    // https://gpuweb.github.io/gpuweb/#buffer-state
    enum class State : uint8_t {
        Mapped,
        MappedAtCreation,
        MappingPending,
        Unmapped,
        Destroyed,
    };

    id<MTLBuffer> buffer() const;

    uint64_t NODELETE initialSize() const;
    uint64_t currentSize() const;
    WGPUBufferUsageFlags usage() const;
    State state() const;

    Device& device() const { return m_device; }
    bool isDestroyed() const { return state() == State::Destroyed; }

#if ENABLE(WEBGPU_SWIFT)
    // Handed to the Swift thunks alongside the buffer, so the Swift side reads the
    // storage's fields directly instead of through the accessors above, which each
    // forward to this same object.
    BufferState& storage() const;
#endif

    void setCommandEncoder(CommandEncoder&, bool mayModifyBuffer = false) const;
    std::span<uint8_t> getBufferContents();

    std::optional<DrawIndexCacheContainerIterator> canSkipDrawIndexedValidation(uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, MTLIndexType, uint32_t primitiveOffset, id<MTLIndirectCommandBuffer> = nil) const;
    void drawIndexedValidated(uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, MTLIndexType, uint32_t primitiveOffset, uint64_t validationGeneration, id<MTLIndirectCommandBuffer> = nil);
    void skippedDrawIndexedValidation(CommandEncoder&, DrawIndexCacheContainerIterator);

    bool didReadOOB(id<MTLIndirectCommandBuffer> = nil) const;
    void didReadOOB(uint32_t v, id<MTLIndirectCommandBuffer> = nil);

    void indirectBufferInvalidated(CommandEncoder* = nullptr);
    void indirectBufferInvalidated(CommandEncoder&);
    // Bumped whenever the contents change in a way that invalidates a previously GPU-encoded indirect draw.
    uint64_t contentsGeneration() const;
    uint64_t indexContentsGeneration() const;
    void indexBufferContentsModified(uint32_t maxUintValue, uint16_t maxUshortValue);
    bool allIndexValuesBelow(MTLIndexType, uint32_t vertexCount) const;
    void removeSkippedValidationCommandEncoder(uint64_t);
    bool mustTakeSlowIndexValidationPath() const;
    void clearMustTakeSlowIndexValidationPath();
    void takeSlowIndexValidationPath(CommandBuffer&, uint32_t firstIndex, uint32_t indexCount, MTLIndexType, uint32_t primitiveOffset, uint32_t vertexCount);
    bool needsIndexValidation(uint32_t, uint16_t);

private:
    Buffer(id<MTLBuffer>, uint64_t initialSize, WGPUBufferUsageFlags, State initialState, MappingRange initialMappingRange, Device&);
    Buffer(Device&);

    NSString * _Nullable errorValidatingMapAsync(WGPUMapModeFlags, size_t offset, size_t rangeSize) const;
    bool NODELETE validateUnmap() const;
    void incrementBufferMapCount();
    void decrementBufferMapCount();

    // The storage accessors. These are the whole of what the gate selects: every
    // member body above is written against them and against nothing else that
    // moved to Swift.
    void NODELETE setState(State);
    void replaceAllocation(id<MTLBuffer>);
    void setMapMode(WGPUMapModeFlags);
    void setMappingRange(size_t beginOffset, size_t endOffset);
    void clearMappedRanges();
    void resetMaxIndices();
    void recordValidatedIndices();
    void setMustTakeSlowIndexValidationPath(bool);
    void invalidateIndexValidation();

#if ENABLE(WEBGPU_SWIFT)
    const std::unique_ptr<BufferState> m_storage;
#else
    // Only the C++ arm declares this: under ENABLE(WEBGPU_SWIFT) the mapped-range
    // validation is part of BufferState::getMappedRange, which owns the ranges it
    // validates against.
    bool validateGetMappedRange(size_t offset, size_t rangeSize) const;

    id<MTLBuffer> m_buffer { nil };

    // https://gpuweb.github.io/gpuweb/#buffer-interface

    const uint64_t m_initialSize { 0 };
    const WGPUBufferUsageFlags m_usage { 0 };
    State m_state { State::Unmapped };
    // [[mapping]] is unnecessary; we can just use m_device.contents.
    MappingRange m_mappingRange { 0, 0 };
    using MappedRanges = RangeSet<Range<size_t>>;
    MappedRanges m_mappedRanges;
    WGPUMapModeFlags m_mapMode { WGPUMapMode_None };
    uint32_t m_maxUnsignedIndex { 0 };
    uint16_t m_maxUshortIndex { 0 };
    uint32_t m_maxValidatedUnsignedIndex { 0 };
    uint16_t m_maxValidatedUshortIndex { 0 };
    bool m_mustTakeSlowIndexValidationPath { false };
    uint64_t m_contentsGeneration { 0 }; // NOLINT
    uint64_t m_indexContentsGeneration { 0 }; // NOLINT
    uint32_t m_indexValueUpperBoundUint { 0 }; // NOLINT
    uint16_t m_indexValueUpperBoundUshort { 0 }; // NOLINT
#endif

    const Ref<Device> m_device;

    // Keyed by command encoder or indirect command buffer rather than by anything
    // of the buffer's own, so these belong with the encoder tracking in
    // TrackedResource and not with the storage.
    DrawIndexCacheContainer m_drawIndexedCache;
    mutable HashMap<uint64_t, uint32_t, DefaultHash<uint64_t>, WTF::UnsignedWithZeroKeyHashTraits<uint64_t>> m_gpuResourceMap;
    HashSet<uint64_t, DefaultHash<uint64_t>, WTF::UnsignedWithZeroKeyHashTraits<uint64_t>> m_skippedValidationCommandEncoders;
    HashMap<uint64_t, bool, DefaultHash<uint64_t>, WTF::UnsignedWithZeroKeyHashTraits<uint64_t>> m_didReadOOB;
#if CPU(X86_64) && (PLATFORM(MAC) || PLATFORM(MACCATALYST))
    bool m_mappedAtCreation { false };
#endif
} SWIFT_SHARED_REFERENCE(refBuffer, derefBuffer) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT;

#if !ENABLE(WEBGPU_SWIFT)

// The storage accessors over Buffer's own C++ fields. Defined here rather than in
// the class body so that the declarations above read the same in both
// configurations; inline so that the field reads stay as cheap as the direct
// reads they replace. The ENABLE(WEBGPU_SWIFT) counterparts are in Buffer.mm,
// where BufferState is a complete type.

inline id<MTLBuffer> Buffer::buffer() const { return m_buffer; }
inline uint64_t Buffer::initialSize() const { return m_initialSize; }
inline uint64_t Buffer::currentSize() const { return m_buffer.length; }
inline WGPUBufferUsageFlags Buffer::usage() const { return m_usage; }
inline Buffer::State Buffer::state() const { return m_state; }
inline bool Buffer::isValid() const { return isDestroyed() || m_buffer; }
inline uint64_t Buffer::contentsGeneration() const { return m_contentsGeneration; }
inline uint64_t Buffer::indexContentsGeneration() const { return m_indexContentsGeneration; }
inline bool Buffer::mustTakeSlowIndexValidationPath() const { return m_mustTakeSlowIndexValidationPath; }
inline void Buffer::replaceAllocation(id<MTLBuffer> buffer) { m_buffer = buffer; }
inline void Buffer::setMapMode(WGPUMapModeFlags mode) { m_mapMode = mode; }
inline void Buffer::setMappingRange(size_t beginOffset, size_t endOffset) { m_mappingRange = { beginOffset, endOffset }; }
inline void Buffer::clearMappedRanges() { m_mappedRanges = MappedRanges(); }
inline void Buffer::setMustTakeSlowIndexValidationPath(bool value) { m_mustTakeSlowIndexValidationPath = value; }

inline void Buffer::setState(State state)
{
    if (m_state != State::Destroyed)
        m_state = state;
}

inline bool Buffer::allIndexValuesBelow(MTLIndexType indexType, uint32_t vertexCount) const
{
    return (indexType == MTLIndexTypeUInt16 ? m_indexValueUpperBoundUshort : m_indexValueUpperBoundUint) < vertexCount;
}

inline void Buffer::indexBufferContentsModified(uint32_t maxUintValue, uint16_t maxUshortValue)
{
    ++m_indexContentsGeneration;
    m_indexValueUpperBoundUint = std::max(m_indexValueUpperBoundUint, maxUintValue);
    m_indexValueUpperBoundUshort = std::max<uint32_t>(m_indexValueUpperBoundUshort, maxUshortValue);
}

inline bool Buffer::needsIndexValidation(uint32_t maxUnsignedIndex, uint16_t maxUshortIndex)
{
    const bool needsUpdate = maxUnsignedIndex > m_maxValidatedUnsignedIndex || maxUshortIndex > m_maxValidatedUshortIndex;
    // Track the current write's max so we can update the validated
    // threshold after a successful clamp-shader pass.
    m_maxUnsignedIndex = maxUnsignedIndex;
    m_maxUshortIndex = maxUshortIndex;

    return needsUpdate;
}

inline void Buffer::resetMaxIndices()
{
    m_maxUnsignedIndex = m_maxUshortIndex = 0;
}

inline void Buffer::recordValidatedIndices()
{
    // Update the validated high-water marks so future writeBuffer calls
    // with indices at or below these values don't need to invalidate.
    m_maxValidatedUnsignedIndex = std::max(m_maxValidatedUnsignedIndex, m_maxUnsignedIndex);
    m_maxValidatedUshortIndex = std::max(m_maxValidatedUshortIndex, m_maxUshortIndex);
}

inline void Buffer::invalidateIndexValidation()
{
    ++m_contentsGeneration;
    ++m_indexContentsGeneration;
    m_indexValueUpperBoundUint = UINT32_MAX;
    m_indexValueUpperBoundUshort = UINT16_MAX;
    m_maxValidatedUnsignedIndex = 0;
    m_maxValidatedUshortIndex = 0;
}

#endif // !ENABLE(WEBGPU_SWIFT)


} // namespace WebGPU

inline void refBuffer(WebGPU::Buffer* obj)
{
    obj->ref();
}

inline void derefBuffer(WebGPU::Buffer* obj)
{
    obj->deref();
}

IGNORE_CLANG_WARNINGS_END
