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

/// The command encoders reading one resource, by identifier.
///
/// `Buffer`, `Texture`, `TextureView`, `QuerySet` and `ExternalTexture` each hold
/// one of these, and `Buffer` holds a second for the encoders whose index
/// validation it skipped. `CommandEncoder` adds itself to a resource's set when it
/// first reads that resource and removes itself when it clears its tracking.
///
/// Identifiers rather than encoders: an encoder outlives the set only through
/// `Device`, which is where the identifier is resolved, so holding the number
/// keeps nothing alive and there is no cycle to break.
///
/// A class, not a value, because the set is written through whichever holder
/// reaches the resource — `CommandEncoder` adding itself, the resource's own
/// operations removing stale entries — and each must see the others' writes.
@_expose(Cxx)
final class TrackedEncoders {
    private var identifiers: Set<UInt64> = []

    init() {}

    /// Whether the encoder was not already in the set.
    func add(_ identifier: UInt64) -> Bool {
        identifiers.insert(identifier).inserted
    }

    func remove(_ identifier: UInt64) {
        identifiers.remove(identifier)
    }

    func clear() {
        identifiers.removeAll()
    }

    var count: Int {
        identifiers.count
    }

    var first: UInt64 {
        // The callers that act on a single encoder have already established that the
        // set holds exactly one, by checking `count`. Zero is not an identifier, so
        // it reports the empty set without an optional crossing the boundary.
        identifiers.first ?? 0
    }

    /// Every identifier in the set, in an order the set does not define.
    ///
    /// A caller acting on each encoder resolves the identifiers itself, through the
    /// `Device` it already holds. Returning them rather than taking a callback is
    /// what makes this member crossable: a C++ template over a callable does not
    /// cross, and neither does `WTF::Function`.
    func allIdentifiers() -> [UInt64] {
        Array(identifiers)
    }

    /// Leaves the set empty, so a caller acting on every encoder cannot act on one
    /// twice.
    func takeAllIdentifiers() -> [UInt64] {
        let taken = Array(identifiers)
        identifiers.removeAll()
        return taken
    }

    /// Drops the identifiers in `stale` and reports how many remain.
    ///
    /// The caller resolves each identifier against its `Device` and passes back the
    /// ones that no longer name a live encoder. Splitting it this way keeps the
    /// resolution on the C++ side, where the callers hold their `Device` as a
    /// `const&`: a `SWIFT_SHARED_REFERENCE` type has no const spelling across
    /// `@_expose(Cxx)`, so a `Device` cannot cross from a const caller at all.
    func removeStaleAndCount(_ stale: [UInt64]) -> Int {
        for identifier in stale {
            identifiers.remove(identifier)
        }
        return identifiers.count
    }
}
