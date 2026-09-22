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

#if ENABLE_ACTION_DISABLING_DELEGATE_SWIFT

import QuartzCore

// WEBCORE_EXPORT makes the class import as a public Swift class, so the members below are
// public and the module declaring it has to be imported publicly -- the same chain as
// WebKit's WKKeyedCoder. No new modulemap entry is needed: WebCore_Private's umbrella over
// PrivateHeaders already claims this header, and adding a second claim in Modules/Internal
// just gives one header two modules.
public import WebCore_Private

@objc
@implementation
extension WebActionDisablingCALayerDelegate {
    private enum Shared {
        static let instance = WebActionDisablingCALayerDelegate()
    }

    class func shared() -> Self {
        // Replaces a NeverDestroyed<RetainPtr<>>: `static let` is likewise initialised once,
        // on first use, and never torn down.
        // Safe force-cast: the class is not subclassed anywhere in the tree.
        // swift-format-ignore: NeverForceUnwrap
        Shared.instance as! Self
    }

    // CALayerDelegate's requirement, declared by the protocol rather than by our header,
    // so the selector has to be stated explicitly.
    //
    // The NSNull is the whole contract and cannot become Optional: CoreAnimation reads a
    // returned NSNull as "this layer has no implicit animation for that key" and a returned
    // nil as "no opinion, keep looking". Swift's nil is the second, so returning nil here
    // would re-enable every implicit animation this class exists to suppress.
    @objc(actionForLayer:forKey:)
    func action(for layer: CALayer, forKey event: Swift.String) -> (any CAAction)? {
        NSNull() as any CAAction
    }
}

#endif  // ENABLE_ACTION_DISABLING_DELEGATE_SWIFT
