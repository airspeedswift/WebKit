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

import Foundation
import WebGPU_Private.WebGPU

/// A `Device`'s stack of error scopes, and the rule that decides which scope --
/// if any -- captures a generated error.
///
/// https://gpuweb.github.io/gpuweb/#error-scopes
///
/// `Device` owns this and nothing else reaches it. Ownership runs one way: there
/// is no pointer back to the `Device`, so no cycle to break and no weak
/// reference to hold. The two `Device` facts these operations need are passed in
/// rather than reached back for -- `validatePop(isLost:)` takes the lost flag as
/// an argument, and `recordError` reports whether a scope captured the error so
/// that `Device` can run its uncaptured-error callback itself. That callback is a
/// `WTF::Function`, which has no representation across `@_expose(Cxx)` and so
/// stays where it is declared.
///
/// A class rather than a value: `Device.h` can only name this as a forward
/// declaration -- the header that completes it is generated from Swift that
/// imports `Device.h` -- and an incomplete type can be held by pointer but not
/// by value. `Buffer`'s `BufferState` is held for the same reason.
///
/// The message is kept as an `NSString`, which crosses the boundary directly,
/// where C++ has a `WTF::String`. A captured error's message is read exactly
/// once, when the scope is popped and handed to the page.
@_expose(Cxx)
final class DeviceErrorScopes {
    /// One pushed scope: the filter it was pushed with, and the first error it
    /// captured, if any.
    private struct Scope {
        let filter: WGPUErrorFilter
        var errorType: WGPUErrorType?
        var errorMessage: NSString?
    }

    private var scopes: [Scope] = []

    /// Declared rather than left implicit, so that the generated header carries it:
    /// Device.mm is the only caller, and constructs one per Device.
    init() {
    }

    /// Pushes a scope that captures errors matching `filter`.
    ///
    /// https://gpuweb.github.io/gpuweb/#dom-gpudevice-pusherrorscope
    func push(_ filter: WGPUErrorFilter) {
        scopes.append(Scope(filter: filter, errorType: nil, errorMessage: nil))
    }

    /// Records `type` with `message` in the current error scope for that type,
    /// and reports whether there was one.
    ///
    /// A scope keeps the first error it captures and ignores later ones, so a
    /// `false` return is the caller's signal to report the error as uncaptured.
    ///
    /// https://gpuweb.github.io/gpuweb/#abstract-opdef-generate-a-validation-error
    func recordError(_ type: WGPUErrorType, message: NSString?) -> Bool {
        guard let filter = filter(capturing: type) else {
            return false
        }
        // https://gpuweb.github.io/gpuweb/#abstract-opdef-current-error-scope
        guard let index = scopes.lastIndex(where: { $0.filter == filter }) else {
            return false
        }
        if scopes[index].errorType == nil {
            scopes[index].errorType = type
            scopes[index].errorMessage = message
        }
        return true
    }

    /// Which filter captures `type`, or nothing for the error types no filter
    /// names: `NoError`, `Unknown` and `DeviceLost` are reported rather than
    /// captured.
    private func filter(capturing type: WGPUErrorType) -> WGPUErrorFilter? {
        switch type {
        case WGPUErrorType_Validation:
            return WGPUErrorFilter_Validation
        case WGPUErrorType_OutOfMemory:
            return WGPUErrorFilter_OutOfMemory
        case WGPUErrorType_Internal:
            return WGPUErrorFilter_Internal
        default:
            return nil
        }
    }

    /// What `popErrorScope` reports without popping: `NoError` when the device is
    /// lost, `Unknown` when there is no scope to pop, and `Force32` when the pop
    /// proceeds. `Force32` is not a type any error takes, and stands in for the
    /// `std::nullopt` that a `std::optional` return cannot carry across
    /// `@_expose(Cxx)`; Device.mm turns it back into the optional and
    /// static_asserts the correspondence.
    ///
    /// `isLost` is a parameter rather than a field: the lost flag is `Device`'s,
    /// set by `loseTheDevice` alongside the Metal device and the default queue,
    /// and passing it is what keeps this type free of a route back.
    ///
    /// https://gpuweb.github.io/gpuweb/#dom-gpudevice-poperrorscope
    func validatePop(isLost: Bool) -> WGPUErrorType {
        if isLost {
            return WGPUErrorType_NoError
        }
        if scopes.isEmpty {
            return WGPUErrorType_Unknown
        }
        return WGPUErrorType_Force32
    }

    /// The error the innermost scope captured, without popping it: the type, and
    /// the message read separately. `NoError` for a scope that captured none.
    var innermostErrorType: WGPUErrorType {
        scopes.last?.errorType ?? WGPUErrorType_NoError
    }

    var innermostErrorMessage: NSString? {
        scopes.last?.errorMessage
    }

    /// Discards the innermost scope. Called after its error has been read.
    func removeInnermost() {
        if !scopes.isEmpty {
            scopes.removeLast()
        }
    }
}
