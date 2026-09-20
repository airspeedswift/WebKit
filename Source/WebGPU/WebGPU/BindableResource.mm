/*
 * Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "BindableResource.h"

#if ENABLE(WEBGPU_SWIFT)

#import "CxxBridging.h"
#import "Buffer.h"
#import "QuerySet.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WGPUTextureImpl.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"

namespace WebGPU {

// The accessors over TrackedEncoders. Out of line because BindableResource.h may
// not include the generated header that completes TrackedEncoders: that header
// names this directory's types. The !ENABLE(WEBGPU_SWIFT) counterparts are inline
// in BindableResource.h.

TrackedEncoderSet::TrackedEncoderSet()
    : m_encoders(makeUniqueWithoutFastMallocCheck<TrackedEncoders>(TrackedEncoders::init()))
{
}

TrackedEncoderSet::~TrackedEncoderSet() = default;

bool TrackedEncoderSet::addEncoder(uint64_t identifier) const
{
    return m_encoders->add(identifier);
}

void TrackedEncoderSet::removeEncoder(uint64_t identifier) const
{
    m_encoders->remove(identifier);
}

void TrackedEncoderSet::clearEncoders() const
{
    m_encoders->clear();
}

static TrackedResourceContainer asContainer(const swift::Array<uint64_t>& identifiers)
{
    TrackedResourceContainer result;
    for (swift::Int index = 0; index < identifiers.getCount(); ++index)
        result.add(identifiers[index]);
    return result;
}

TrackedResourceContainer TrackedEncoderSet::takeEncoders() const
{
    return asContainer(m_encoders->takeAllIdentifiers());
}

std::optional<uint64_t> TrackedEncoderSet::firstEncoder() const
{
    // Zero is not a command encoder identifier, which is how the Swift side reports
    // the empty set without an optional crossing the boundary.
    if (!m_encoders->getCount())
        return std::nullopt;
    return m_encoders->getFirst();
}

TrackedResourceContainer TrackedEncoderSet::encoderIdentifiers() const
{
    return asContainer(m_encoders->allIdentifiers());
}

size_t TrackedEncoderSet::removeStaleEncodersAndCount(const TrackedResourceContainer& stale) const
{
    auto identifiers = swift::Array<uint64_t>::init();
    for (auto identifier : stale)
        identifiers.append(identifier);
    return m_encoders->removeStaleAndCount(identifiers);
}

} // namespace WebGPU

#endif // ENABLE(WEBGPU_SWIFT)
