/*
 * Copyright (c) 2021-2023 Apple Inc. All rights reserved.
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

#import "config.h"
#import "Buffer.h"

#import "APIConversions.h"
#import "CommandBuffer.h"
#import "Device.h"

#import <wtf/Borrow.h>
#import <wtf/CheckedArithmetic.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WGPUTextureImpl.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU {

template <typename T>
static inline auto span(id<MTLBuffer> buffer)
{
    return unsafeMakeSpan(static_cast<T*>(buffer.contents), buffer.length / sizeof(T));
}

template <typename T>
static inline auto span(id<MTLBuffer> buffer, uint64_t byteOffset)
{
    auto byteSpan = span<uint8_t>(buffer).subspan(byteOffset);
    return unsafeMakeSpan(static_cast<T*>(static_cast<void*>(byteSpan.data())), (byteOffset < buffer.length) ? (buffer.length - byteOffset) / sizeof(T) : 0);
}

static bool NODELETE validateDescriptor(const Device& device, const WGPUBufferDescriptor& descriptor)
{
    UNUSED_PARAM(device);

    // https://gpuweb.github.io/gpuweb/#abstract-opdef-validating-gpubufferdescriptor

    if (device.isLost())
        return false;

    // FIXME: "If any of the bits of descriptor’s usage aren’t present in this device’s [[allowed buffer usages]] return false."

    if ((descriptor.usage & WGPUBufferUsage_MapRead) && (descriptor.usage & WGPUBufferUsage_MapWrite))
        return false;

    return true;
}

static bool NODELETE validateCreateBuffer(const Device& device, const WGPUBufferDescriptor& descriptor)
{
    if (!device.isValid())
        return false;

    if (!validateDescriptor(device, descriptor))
        return false;

    auto usage = descriptor.usage;
    if (!usage)
        return false;

    constexpr auto allUsages = (WGPUBufferUsage_MapRead | WGPUBufferUsage_MapWrite | WGPUBufferUsage_CopySrc | WGPUBufferUsage_CopyDst | WGPUBufferUsage_Index | WGPUBufferUsage_Vertex | WGPUBufferUsage_Uniform | WGPUBufferUsage_Storage | WGPUBufferUsage_Indirect | WGPUBufferUsage_QueryResolve);
    if (!(usage & allUsages) || usage > allUsages)
        return false;

    if ((usage & WGPUBufferUsage_MapRead) && (usage & ~WGPUBufferUsage_CopyDst & ~WGPUBufferUsage_MapRead))
        return false;

    if ((usage & WGPUBufferUsage_MapWrite) && (usage & ~WGPUBufferUsage_CopySrc & ~WGPUBufferUsage_MapWrite))
        return false;

    if (descriptor.mappedAtCreation && (descriptor.size % 4))
        return false;

    if (descriptor.size > device.limits().maxBufferSize)
        return false;

    return true;
}

static MTLStorageMode NODELETE storageMode(bool deviceHasUnifiedMemory, WGPUBufferUsageFlags usage, bool mappedAtCreation)
{
    if (deviceHasUnifiedMemory)
        return MTLStorageModeShared;
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    if (usage & (WGPUBufferUsage_MapRead | WGPUBufferUsage_MapWrite | WGPUBufferUsage_Index))
        return MTLStorageModeManaged;
    if (mappedAtCreation)
        return MTLStorageModeManaged;
    ALLOW_DEPRECATED_DECLARATIONS_END
#else
    UNUSED_PARAM(mappedAtCreation);
    UNUSED_PARAM(usage);
#endif
    return MTLStorageModePrivate;
}

id<MTLBuffer> Device::safeCreateBuffer(NSUInteger length, MTLStorageMode storageMode, bool skipAttribution, MTLCPUCacheMode cpuCacheMode, MTLHazardTrackingMode hazardTrackingMode) const
{
    MTLResourceOptions resourceOptions = (cpuCacheMode << MTLResourceCPUCacheModeShift) | (storageMode << MTLResourceStorageModeShift) | (hazardTrackingMode << MTLResourceHazardTrackingModeShift);
    id<MTLBuffer> buffer = [m_device newBufferWithLength:std::max<NSUInteger>(1, length) options:resourceOptions];
    if (!skipAttribution)
        setOwnerWithIdentity(buffer);
    return buffer;
}

id<MTLBuffer> Device::safeCreateBuffer(NSUInteger length, bool skipAttribution) const
{
    return safeCreateBuffer(length, MTLStorageModeShared, skipAttribution);
}

Ref<Buffer> Device::createBuffer(const WGPUBufferDescriptor& descriptor)
{
    if (!isValid())
        return Buffer::createInvalid(*this);

    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-createbuffer

    if (!validateCreateBuffer(*this, descriptor)) {
        generateAValidationError("Validation failure."_s);

        return Buffer::createInvalid(*this);
    }

    // FIXME(PERFORMANCE): Consider write-combining CPU cache mode.
    // FIXME(PERFORMANCE): Consider implementing hazard tracking ourself.
    MTLStorageMode storageMode = WebGPU::storageMode(hasUnifiedMemory(), descriptor.usage, descriptor.mappedAtCreation);
    auto buffer = safeCreateBuffer(static_cast<NSUInteger>(descriptor.size), storageMode);
    if (!buffer) {
        generateAnOutOfMemoryError("Allocation failure."_s);

        return Buffer::createInvalid(*this);
    }

    buffer.label = fromAPI(descriptor.label).createNSString().get();

    auto initialMapState = Buffer::State::Unmapped;
    auto initialMappingRange = Buffer::MappingRange {
        .beginOffset = static_cast<size_t>(0),
        .endOffset = static_cast<size_t>(0)
    };
    if (descriptor.mappedAtCreation) {
        initialMapState = Buffer::State::MappedAtCreation;
        initialMappingRange = Buffer::MappingRange {
            .beginOffset = static_cast<size_t>(0),
            .endOffset = static_cast<size_t>(descriptor.size)
        };
    }

    auto apiBuffer = Buffer::create(buffer, descriptor.size, descriptor.usage, initialMapState, initialMappingRange, *this);
    m_bufferMap.add(buffer.gpuAddress, apiBuffer.ptr());
    return apiBuffer;
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(Buffer);

// Used by members defined in both configurations of the condition below.

static size_t NODELETE computeRangeSize(uint64_t size, size_t offset)
{
    auto result = checkedDifference<uint64_t>(size, offset);
    if (result.hasOverflowed())
        return 0;
    return result.value();
}

static DrawIndexCacheContainerKey makeKey(uint32_t firstIndex, uint32_t indexCount, MTLIndexType indexType, uint32_t primitiveOffset, id<MTLIndirectCommandBuffer> icb)
{
    return { firstIndex, indexCount, primitiveOffset | static_cast<uint32_t>(indexType << 1), static_cast<uint32_t>(icb.gpuResourceID._impl & 0xffffffff), static_cast<uint32_t>((icb.gpuResourceID._impl >> 32) & 0xffffffff) };
}

template <typename T>
static bool verifyIndexBufferData(id<MTLBuffer> buffer, uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, uint32_t primitiveRestart, uint32_t indexBufferOffsetInBytes = 0)
{
    auto indexData = span<T>(buffer, indexBufferOffsetInBytes);
    if (firstIndex + indexCount > indexData.size())
        return false;
    for (size_t index = firstIndex; index < firstIndex + indexCount; ++index) {
        T vertexIndex = primitiveRestart + indexData[index];
        if (vertexIndex >= vertexCount + primitiveRestart)
            return false;
    }

    return true;
}

static size_t computeSize(HashSet<uint64_t, DefaultHash<uint64_t>, WTF::UnsignedWithZeroKeyHashTraits<uint64_t>>& encoders, Device& device)
{
    encoders.removeIf([&](uint64_t encoderId) {
        return !device.commandEncoderFromIdentifier(encoderId);
    });
    return encoders.size();
}

#if ENABLE(WEBGPU_SWIFT)

// BufferState holds Buffer::State as its underlying value. Buffer.swift mirrors
// this order; these are what it mirrors.
static_assert(static_cast<uint8_t>(Buffer::State::Mapped) == 0);
static_assert(static_cast<uint8_t>(Buffer::State::MappedAtCreation) == 1);
static_assert(static_cast<uint8_t>(Buffer::State::MappingPending) == 2);
static_assert(static_cast<uint8_t>(Buffer::State::Unmapped) == 3);
static_assert(static_cast<uint8_t>(Buffer::State::Destroyed) == 4);

// The storage accessors over BufferState. Out of line because Buffer.h may not
// include the generated header that completes BufferState: that header names
// WebGPU::Buffer. The !ENABLE(WEBGPU_SWIFT) counterparts are inline in Buffer.h.

id<MTLBuffer> Buffer::buffer() const
{
    return m_storage->getMetalBuffer();
}

uint64_t Buffer::initialSize() const
{
    return m_storage->getInitialSize();
}

uint64_t Buffer::currentSize() const
{
    return m_storage->getCurrentSize();
}

WGPUBufferUsageFlags Buffer::usage() const
{
    return m_storage->getUsage();
}

Buffer::State Buffer::state() const
{
    return static_cast<State>(m_storage->getRawState());
}

bool Buffer::isValid() const
{
    return m_storage->isValid();
}

uint64_t Buffer::contentsGeneration() const
{
    return m_storage->getContentsGeneration();
}

uint64_t Buffer::indexContentsGeneration() const
{
    return m_storage->getIndexContentsGeneration();
}

bool Buffer::mustTakeSlowIndexValidationPath() const
{
    return m_storage->getMustTakeSlowIndexValidationPath();
}

void Buffer::replaceAllocation(id<MTLBuffer> buffer)
{
    m_storage->replaceAllocation(buffer);
}

void Buffer::setMapMode(WGPUMapModeFlags mode)
{
    m_storage->setMapMode(mode);
}

void Buffer::setMappingRange(size_t beginOffset, size_t endOffset)
{
    m_storage->setMappingBeginOffset(static_cast<swift::Int>(beginOffset));
    m_storage->setMappingEndOffset(static_cast<swift::Int>(endOffset));
}

void Buffer::clearMappedRanges()
{
    m_storage->clearMappedRanges();
}

void Buffer::setMustTakeSlowIndexValidationPath(bool value)
{
    m_storage->setMustTakeSlowIndexValidationPath(value);
}

void Buffer::setState(State state)
{
    m_storage->setStateUnlessDestroyed(static_cast<uint8_t>(state));
}

bool Buffer::allIndexValuesBelow(MTLIndexType indexType, uint32_t vertexCount) const
{
    return m_storage->allIndexValuesBelow(indexType == MTLIndexTypeUInt16, vertexCount);
}

void Buffer::indexBufferContentsModified(uint32_t maxUintValue, uint16_t maxUshortValue)
{
    m_storage->indexBufferContentsModified(maxUintValue, maxUshortValue);
}

bool Buffer::needsIndexValidation(uint32_t maxUnsignedIndex, uint16_t maxUshortIndex)
{
    return m_storage->needsIndexValidation(maxUnsignedIndex, maxUshortIndex);
}

void Buffer::resetMaxIndices()
{
    m_storage->resetMaxIndices();
}

void Buffer::recordValidatedIndices()
{
    m_storage->recordValidatedIndices();
}

void Buffer::invalidateIndexValidation()
{
    m_storage->invalidateIndexValidation();
}

#else // !ENABLE(WEBGPU_SWIFT)

bool Buffer::validateGetMappedRange(size_t offset, size_t rangeSize) const
{
    if (m_state == State::Destroyed)
        return false;

    if (m_state != State::Mapped && m_state != State::MappedAtCreation)
        return false;

    if (offset % 8)
        return false;

    if (rangeSize % 4)
        return false;

    if (offset < m_mappingRange.beginOffset)
        return false;

    auto endOffset = checkedSum<size_t>(offset, rangeSize);
    if (endOffset.hasOverflowed() || endOffset.value() > m_mappingRange.endOffset)
        return false;

    if (m_mappedRanges.overlaps({ offset, endOffset }))
        return false;

    return true;
}

#endif // ENABLE(WEBGPU_SWIFT)

Ref<Buffer> Buffer::create(id<MTLBuffer> buffer, uint64_t initialSize, WGPUBufferUsageFlags usage, State initialState, MappingRange initialMappingRange, Device& device)
{
    return adoptRef(*new Buffer(buffer, initialSize, usage, initialState, initialMappingRange, device));
}

Ref<Buffer> Buffer::createInvalid(Device& device)
{
    return adoptRef(*new Buffer(device));
}

Buffer::Buffer(id<MTLBuffer> buffer, uint64_t initialSize, WGPUBufferUsageFlags usage, State initialState, MappingRange initialMappingRange, Device& device)
#if ENABLE(WEBGPU_SWIFT)
    : m_storage(makeUniqueWithoutFastMallocCheck<BufferState>(BufferState::init(buffer, initialSize, usage, static_cast<uint8_t>(initialState), static_cast<swift::Int>(initialMappingRange.beginOffset), static_cast<swift::Int>(initialMappingRange.endOffset))))
#else
    : m_buffer(buffer)
    , m_initialSize(initialSize)
    , m_usage(usage)
    , m_state(initialState)
    , m_mappingRange(initialMappingRange)
#endif
    , m_device(device)
#if CPU(X86_64) && (PLATFORM(MAC) || PLATFORM(MACCATALYST))
    , m_mappedAtCreation(initialState == State::MappedAtCreation)
#endif
{
}

Buffer::Buffer(Device& device)
#if ENABLE(WEBGPU_SWIFT)
    : m_storage(makeUniqueWithoutFastMallocCheck<BufferState>(BufferState::init(nil, 0, 0, static_cast<uint8_t>(State::Unmapped), 0, 0)))
    , m_device(device)
#else
    : m_device(device)
#endif
{
}

Buffer::~Buffer()
{
    m_device->removeBufferFromCache(buffer().gpuAddress);
}

void Buffer::incrementBufferMapCount()
{
    for (auto commandEncoder : m_commandEncoders) {
        if (RefPtr ptr = m_device->commandEncoderFromIdentifier(commandEncoder))
            ptr->incrementBufferMapCount();
    }
}

void Buffer::decrementBufferMapCount()
{
    for (auto commandEncoder : m_commandEncoders) {
        if (RefPtr ptr = m_device->commandEncoderFromIdentifier(commandEncoder))
            ptr->decrementBufferMapCount();
    }
}

void Buffer::setCommandEncoder(CommandEncoder& commandEncoder, bool mayModifyBuffer) const
{
    UNUSED_PARAM(mayModifyBuffer);
    bool isNewEntry = commandEncoder.trackEncoderForBuffer(*this, m_commandEncoders);
#if !CPU(X86_64)
    if (m_device->isShaderValidationEnabled())
#endif
        commandEncoder.addBuffer(buffer());

    if (state() != State::Unmapped && isNewEntry)
        commandEncoder.incrementBufferMapCount();
    if (isDestroyed())
        commandEncoder.makeSubmitInvalid();
}

void Buffer::destroy()
{
    crashIfBorrowed();

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-destroy

    if (state() != State::Unmapped && state() != State::Destroyed) {
        // FIXME: ASSERT() that this call doesn't fail.
        unmap();
    }

    setState(State::Destroyed);
    m_device->makeSubmitInvalidClearingEncoders(m_commandEncoders);
    m_device->removeBufferFromCache(buffer().gpuAddress);
    replaceAllocation(m_device->placeholderBuffer());
}

std::span<uint8_t> Buffer::getMappedRange(size_t offset, size_t size)
{
#if ENABLE(WEBGPU_SWIFT)
    return m_storage->getMappedRange(static_cast<swift::Int>(offset), static_cast<swift::Int>(size));
#else
    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-getmappedrange
    if (!isValid())
        return std::span<uint8_t> { };

    auto rangeSize = size;
    if (size == WGPU_WHOLE_MAP_SIZE)
        rangeSize = computeRangeSize(this->currentSize(), offset);

    if (!validateGetMappedRange(offset, rangeSize))
        return std::span<uint8_t> { };

    m_mappedRanges.add({ offset, offset + rangeSize });
    m_mappedRanges.compact();

    if (!m_buffer.contents)
        return { };
    return getBufferContents().subspan(offset);
#endif
}

std::span<uint8_t> Buffer::getBufferContents()
{
    return span<uint8_t>(buffer());
}

void Buffer::bufferCopy(std::span<const uint8_t> data, size_t offset)
{
#if ENABLE(WEBGPU_SWIFT)
    m_storage->copy(data, static_cast<swift::Int>(offset));
#else
    UNUSED_PARAM(data);
    UNUSED_PARAM(offset);
#endif
}

NSString *Buffer::errorValidatingMapAsync(WGPUMapModeFlags mode, size_t offset, size_t rangeSize) const
{
#define ERROR_STRING(x) (@"GPUBuffer.mapAsync: " x)
    if (!isValid())
        return ERROR_STRING(@"Buffer is not valid");

    if (offset % 8)
        return ERROR_STRING(@"Offset is not divisible by 8");

    if (rangeSize % 4)
        return ERROR_STRING(@"range size is not divisible by 4");

    auto end = checkedSum<uint64_t>(offset, rangeSize);
    if (end.hasOverflowed() || end.value() > currentSize())
        return ERROR_STRING(@"offset and rangeSize overflowed");

    if (state() != State::Unmapped)
        return ERROR_STRING(@"state != Unmapped");

    auto readWriteModeFlags = mode & (WGPUMapMode_Read | WGPUMapMode_Write);
    if (readWriteModeFlags != WGPUMapMode_Read && readWriteModeFlags != WGPUMapMode_Write)
        return ERROR_STRING(@"readWriteModeFlags != Read && readWriteModeFlags != Write");

    if ((mode & WGPUMapMode_Read) && !(usage() & WGPUBufferUsage_MapRead))
        return ERROR_STRING(@"(mode & Read) && !(usage & Read)");

    if ((mode & WGPUMapMode_Write) && !(usage() & WGPUBufferUsage_MapWrite))
        return ERROR_STRING(@"(mode & Write) && !(usage & Write)");

#undef ERROR_STRING
    return nil;
}

void Buffer::mapAsync(WGPUMapModeFlags mode, size_t offset, size_t size, CompletionHandler<void(WGPUBufferMapAsyncStatus)>&& callback)
{
    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-mapasync

    auto rangeSize = size;
    if (size == WGPU_WHOLE_MAP_SIZE)
        rangeSize = computeRangeSize(currentSize(), offset);

    Ref device = m_device;

    if (NSString* error = errorValidatingMapAsync(mode, offset, rangeSize)) {
        device->generateAValidationError(error);

        callback(WGPUBufferMapAsyncStatus_ValidationError);
        return;
    }

    setState(State::MappingPending);
    incrementBufferMapCount();

    setMapMode(mode);

    device->getQueue()->onSubmittedWorkDone([protectedThis = protect(*this), offset, rangeSize, callback = WTF::move(callback)](WGPUQueueWorkDoneStatus status) mutable {
        if (protectedThis->state() == State::MappingPending) {
            protectedThis->setState(State::Mapped);

            protectedThis->setMappingRange(offset, offset + rangeSize);

            protectedThis->clearMappedRanges();
        }

        switch (status) {
        case WGPUQueueWorkDoneStatus_Success:
            callback(WGPUBufferMapAsyncStatus_Success);
            return;
        case WGPUQueueWorkDoneStatus_Error:
            callback(WGPUBufferMapAsyncStatus_ValidationError);
            return;
        case WGPUQueueWorkDoneStatus_Unknown:
            callback(WGPUBufferMapAsyncStatus_Unknown);
            return;
        case WGPUQueueWorkDoneStatus_DeviceLost:
            callback(WGPUBufferMapAsyncStatus_DeviceLost);
            return;
        case WGPUQueueWorkDoneStatus_Force32:
            ASSERT_NOT_REACHED();
            callback(WGPUBufferMapAsyncStatus_ValidationError);
            return;
        }
    });
}

bool Buffer::validateUnmap() const
{
    return true;
}

void Buffer::unmap()
{
    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-unmap

    if (!validateUnmap() && !m_device->isValid())
        return;

    decrementBufferMapCount();
    resetMaxIndices();
    indirectBufferInvalidated();

#if CPU(X86_64) && (PLATFORM(MAC) || PLATFORM(MACCATALYST))
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    id<MTLBuffer> metalBuffer = buffer();
    if (metalBuffer.storageMode == MTLStorageModeManaged) {
        if (m_mappedAtCreation)
            [metalBuffer didModifyRange:NSMakeRange(0, metalBuffer.length)];
        else {
            // The mapped ranges are iterated differently in each configuration:
            // RangeSet is a container of ranges, while BufferState hands out
            // merged begin/end pairs by index.
#if ENABLE(WEBGPU_SWIFT)
            for (swift::Int i = 0, count = m_storage->compactMappedRanges(); i < count; ++i) {
                auto begin = m_storage->mappedRangeBegin(i);
                [metalBuffer didModifyRange:NSMakeRange(static_cast<NSUInteger>(begin), static_cast<NSUInteger>(m_storage->mappedRangeEnd(i) - begin))];
            }
#else
            for (const auto& mappedRange : m_mappedRanges)
                [metalBuffer didModifyRange:NSMakeRange(static_cast<NSUInteger>(mappedRange.begin()), static_cast<NSUInteger>(mappedRange.end() - mappedRange.begin()))];
#endif
        }
    }
    ALLOW_DEPRECATED_DECLARATIONS_END
#endif

    setState(State::Unmapped);
    clearMappedRanges();
}

void Buffer::setLabel(String&& label)
{
    buffer().label = label.createNSString().get();
}

void Buffer::generateAValidationError(String&& message)
{
    m_device->generateAValidationError(WTF::move(message));
}

std::optional<DrawIndexCacheContainerIterator> Buffer::canSkipDrawIndexedValidation(uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, MTLIndexType indexType, uint32_t primitiveOffset, id<MTLIndirectCommandBuffer> icb) const
{
    auto containerIt = m_drawIndexedCache.find(makeKey(firstIndex, indexCount, indexType, primitiveOffset, icb));
    if (containerIt != m_drawIndexedCache.end() && containerIt->value.indexContentsGeneration == indexContentsGeneration() && containerIt->value.vertexCount <= vertexCount)
        return containerIt;

    return std::nullopt;
}

void Buffer::drawIndexedValidated(uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, MTLIndexType indexType, uint32_t primitiveOffset, uint64_t validationGeneration, id<MTLIndirectCommandBuffer> icb)
{
    constexpr auto maxCacheSize = 1000000;
    if (m_drawIndexedCache.size() > maxCacheSize)
        m_drawIndexedCache.clear();

    m_drawIndexedCache.set(makeKey(firstIndex, indexCount, indexType, primitiveOffset, icb), DrawIndexValidationCacheEntry { vertexCount, validationGeneration });

    recordValidatedIndices();
}

void Buffer::takeSlowIndexValidationPath(CommandBuffer& commandBuffer, uint32_t firstIndex, uint32_t indexCount, MTLIndexType indexType, uint32_t primitiveOffset, uint32_t vertexCount)
{
    WTFLogAlways("WARNING: Severe performance penalty due to encoding drawIndexed calls out of order with submission"); // NOLINT
    Ref queue = m_device->getQueue();
    id<MTLBuffer> metalBuffer = buffer();
    queue->waitForAllCommitedWorkToComplete();
    queue->synchronizeResourceAndWait(metalBuffer);
    bool verified = false;
    if (indexType == MTLIndexTypeUInt16)
        verified = verifyIndexBufferData<uint16_t>(metalBuffer, firstIndex, indexCount, vertexCount, primitiveOffset);
    else
        verified = verifyIndexBufferData<uint32_t>(metalBuffer, firstIndex, indexCount, vertexCount, primitiveOffset);

    if (!verified) {
        SUPPRESS_UNCOUNTED_ARG Vector<uint8_t> priorData = borrow(*this)->getBufferContents();

        queue->clearBuffer(metalBuffer);
        queue->finalizeBlitCommandEncoder();
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
        ALLOW_DEPRECATED_DECLARATIONS_BEGIN
        if (metalBuffer.storageMode == MTLStorageModeManaged)
            [metalBuffer didModifyRange:NSMakeRange(0, metalBuffer.length)];
        ALLOW_DEPRECATED_DECLARATIONS_END
#endif
        commandBuffer.addPostCommitHandler([queue, priorData = WTF::move(priorData), protectedThis = protect(*this)](id<MTLCommandBuffer> mtlCommandBuffer) mutable {
            [mtlCommandBuffer waitUntilCompleted];
            queue->writeBuffer(*protectedThis.ptr(), 0, priorData.mutableSpan());
        });
    }
}

void Buffer::skippedDrawIndexedValidation(CommandEncoder& commandEncoder, DrawIndexCacheContainerIterator it)
{
    CommandEncoder::trackEncoder(commandEncoder, m_skippedValidationCommandEncoders);
    commandEncoder.skippedDrawIndexedValidation(buffer().gpuAddress, it);
}

bool Buffer::didReadOOB(id<MTLIndirectCommandBuffer> icb) const
{
    auto it = m_didReadOOB.find(icb.gpuResourceID._impl);
    return it == m_didReadOOB.end() ? false : it->value;
}

void Buffer::didReadOOB(uint32_t v, id<MTLIndirectCommandBuffer> icb)
{
    m_didReadOOB.set(icb.gpuResourceID._impl, !!v || didReadOOB(icb));
}

void Buffer::indirectBufferInvalidated(CommandEncoder& commandEncoder)
{
    resetMaxIndices();
    indirectBufferInvalidated();

    commandEncoder.addOnCommitHandler([weakThis = ThreadSafeWeakPtr { *this }, weakCommandEncoder = WeakPtr { commandEncoder }](CommandBuffer&, CommandEncoder&) {
        if (!weakThis.get() || !weakCommandEncoder)
            return true;

        RefPtr protectedThis = weakThis.get();
        protectedThis->resetMaxIndices();
        RefPtr commandEncoder = weakCommandEncoder.get();
        protectedThis->indirectBufferInvalidated(commandEncoder.get());
        return true;
    });
}

void Buffer::indirectBufferInvalidated(CommandEncoder* commandEncoder)
{
    if (!(usage() & (WGPUBufferUsage_Indirect | WGPUBufferUsage_Index)))
        return;

    if (auto currentSize = computeSize(m_skippedValidationCommandEncoders, m_device.get())) {
        bool validationNotNeeded = currentSize == 1 && commandEncoder && commandEncoder == m_device->commandEncoderFromIdentifier(*m_skippedValidationCommandEncoders.begin().get());
        if (!validationNotNeeded)
            setMustTakeSlowIndexValidationPath(true);
    }

    m_gpuResourceMap.clear();
    m_drawIndexedCache.clear();
    invalidateIndexValidation();
}

void Buffer::removeSkippedValidationCommandEncoder(uint64_t uniqueId)
{
    m_skippedValidationCommandEncoders.remove(uniqueId);
}

void Buffer::clearMustTakeSlowIndexValidationPath()
{
    if (computeSize(m_skippedValidationCommandEncoders, m_device.get()))
        return;
    setMustTakeSlowIndexValidationPath(false);
}


} // namespace WebGPU

#pragma mark WGPU Stubs

void NODELETE wgpuBufferReference(WGPUBuffer buffer)
{
    WebGPU::fromAPI(buffer).ref();
}

void wgpuBufferRelease(WGPUBuffer buffer)
{
    WebGPU::fromAPI(buffer).deref();
}

void wgpuBufferDestroy(WGPUBuffer buffer)
{
    protect(WebGPU::fromAPI(buffer))->destroy();
}

WGPUBufferMapState wgpuBufferGetMapState(WGPUBuffer buffer)
{
    switch (protect(WebGPU::fromAPI(buffer))->state()) {
    case WebGPU::Buffer::State::Mapped:
        return WGPUBufferMapState_Mapped;
    case WebGPU::Buffer::State::MappedAtCreation:
        return WGPUBufferMapState_Mapped;
    case WebGPU::Buffer::State::MappingPending:
        return WGPUBufferMapState_Pending;
    case WebGPU::Buffer::State::Unmapped:
        return WGPUBufferMapState_Unmapped;
    case WebGPU::Buffer::State::Destroyed:
        return WGPUBufferMapState_Unmapped;
    }
}

std::span<uint8_t> wgpuBufferGetMappedRange(WGPUBuffer buffer, size_t offset, size_t size)
{
    return protect(WebGPU::fromAPI(buffer))->getMappedRange(offset, size);
}

std::span<uint8_t> wgpuBufferGetBufferContents(WGPUBuffer buffer)
{
    return protect(WebGPU::fromAPI(buffer))->getBufferContents();
}

uint64_t wgpuBufferGetInitialSize(WGPUBuffer buffer)
{
    return WebGPU::fromAPI(buffer).initialSize();
}

uint64_t wgpuBufferGetCurrentSize(WGPUBuffer buffer)
{
    return protect(WebGPU::fromAPI(buffer))->currentSize();
}

void wgpuBufferMapAsync(WGPUBuffer buffer, WGPUMapModeFlags mode, size_t offset, size_t size, WGPUBufferMapCallback callback, void* userdata)
{
    protect(WebGPU::fromAPI(buffer))->mapAsync(mode, offset, size, [callback, userdata](WGPUBufferMapAsyncStatus status) {
        callback(status, userdata);
    });
}

void wgpuBufferMapAsyncWithBlock(WGPUBuffer buffer, WGPUMapModeFlags mode, size_t offset, size_t size, WGPUBufferMapBlockCallback callback)
{
    protect(WebGPU::fromAPI(buffer))->mapAsync(mode, offset, size, [callback = WebGPU::fromAPI(WTF::move(callback))](WGPUBufferMapAsyncStatus status) {
        callback(status);
    });
}

void wgpuBufferUnmap(WGPUBuffer buffer)
{
    protect(WebGPU::fromAPI(buffer))->unmap();
}

void wgpuBufferGenerateAValidationError(WGPUBuffer buffer)
{
    protect(WebGPU::fromAPI(buffer))->generateAValidationError("Buffer state was not unmapped"_s);
}

void wgpuBufferSetLabel(WGPUBuffer buffer, const char* label)
{
    protect(WebGPU::fromAPI(buffer))->setLabel(WebGPU::fromAPI(label));
}

WGPUBufferUsageFlags wgpuBufferGetUsage(WGPUBuffer buffer)
{
    return WebGPU::fromAPI(buffer).usage();
}

void NODELETE wgpuBufferCopy(WGPUBuffer buffer, std::span<const uint8_t> data, size_t offset)
{
#if ENABLE(WEBGPU_SWIFT)
    protect(WebGPU::fromAPI(buffer))->bufferCopy(data, offset);
#else
    UNUSED_PARAM(buffer);
    UNUSED_PARAM(data);
    UNUSED_PARAM(offset);

#endif
}
