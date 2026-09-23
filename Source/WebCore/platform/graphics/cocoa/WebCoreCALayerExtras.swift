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

// The CALayer (WebCoreCALayerExtras) category of WebCoreCALayerExtras.h, in Swift. The
// hit-testing free functions declared by the same header stay in WebCoreCALayerExtras.mm and
// reach -_web_maskContainsPoint: here by message send.
//
// @objc @implementation takes a category whole, so every method the header declares is
// implemented here, each under the selector the header spells.
//
// The gate has no parentheses on purpose: generate-platform-args passes
// -DENABLE_CALAYER_EXTRAS_SWIFT to swiftc for a truthy ENABLE() macro, so the Swift spelling
// of the same gate is a bare identifier.

#if ENABLE_CALAYER_EXTRAS_SWIFT

internal import QuartzCore
// CALayerHost, and CALayer's contentsOpaque, are declared by this SPI header.
internal import pal.spi.cocoa.QuartzCoreSPI
// WTFLogAlwaysV, which is how the variadic WTFLogAlways is reached from Swift.
internal import wtf.Assertions
// ASSERT_ENABLED, which PlatformEnable.h derives from NDEBUG.
internal import wtf.Platform

// The category's header is in WebCore_Private's umbrella over PrivateHeaders, which is what
// @implementation matches this extension against. Unlike WebActionDisablingCALayerDelegate.swift,
// the class extended comes from QuartzCore, not from WebCore_Private, and the members stay at the
// access level the header gives them, so no import here has to be public.
internal import WebCore_Private

#if ENABLE_RE_DYNAMIC_CONTENT_SCALING
// DynamicContentScalingTypes.h spells these as NSString-literal macros, which Swift does not
// import, so they are restated.
private enum DynamicContentScalingKey {
    static let enabled = "separatedOptions.enableContext"
    static let bifurcationEnabled = "separatedOptions.enableBifurcation"
    static let contents = "separatedOptions.contextData"
    static let ports = "separatedOptions.ports"
}
#endif

// Stands in for the `#ifndef NDEBUG` in WebCoreCALayerExtras.mm's Objective-C arm. Swift has no condition for NDEBUG, but swiftc's
// ClangImporter is passed the same -DNDEBUG as the C++, and PlatformEnable.h defines
// ASSERT_ENABLED to 1 exactly when NDEBUG is undefined. A computed property rather than an
// inline comparison, so a build with NDEBUG does not warn that the debug-only statement will
// never be executed.
nonisolated private var assertionsEnabled: Bool { ASSERT_ENABLED != 0 }

@objc(WebCoreCALayerExtras)
@implementation
extension CALayer {
    @objc(web_disableAllActions)
    func web_disableAllActions() {
        let nullValue = NSNull()
        style = [
            "actions": [
                "anchorPoint": nullValue,
                "anchorPointZ": nullValue,
                "backgroundColor": nullValue,
                "borderColor": nullValue,
                "borderWidth": nullValue,
                "bounds": nullValue,
                "contents": nullValue,
                "contentsRect": nullValue,
                "contentsScale": nullValue,
                "cornerRadius": nullValue,
                "opacity": nullValue,
                "position": nullValue,
                "shadowColor": nullValue,
                "sublayerTransform": nullValue,
                "sublayers": nullValue,
                "transform": nullValue,
                "zPosition": nullValue,
            ]
        ]
    }

    @objc(_web_setLayerBoundsOrigin:)
    func _web_setLayerBoundsOrigin(_ origin: CGPoint) {
        var bounds = self.bounds
        bounds.origin = origin
        self.bounds = bounds
    }

    @objc(_web_setLayerTopLeftPosition:)
    func _web_setLayerTopLeftPosition(_ position: CGPoint) {
        let layerSize = bounds.size
        let anchorPoint = self.anchorPoint
        let newPosition = CGPoint(
            x: position.x + anchorPoint.x * layerSize.width,
            y: position.y + anchorPoint.y * layerSize.height
        )
        if newPosition.x.isNaN || newPosition.y.isNaN {
            let arguments: [any CVarArg] = [
                newPosition.x, newPosition.y, position.x, position.y, anchorPoint.x, anchorPoint.y,
            ]
            // SAFETY: the va_list is used only inside the closure, which is where withVaList keeps
            // it alive, and it holds the six CGFloat (Double) values of `arguments`.
            unsafe withVaList(arguments) { vaList in
                // SAFETY: the format is a string literal, NUL-terminated and alive for the call,
                // and its six %f conversions match the six Doubles the va_list holds.
                unsafe WTFLogAlwaysV(
                    "Attempt to call [CALayer setPosition] with NaN: newPosition=(%f, %f) position=(%f, %f) anchorPoint=(%f, %f)",
                    vaList
                )
            }
            // ASSERT_NOT_REACHED(): traps in builds that check assertions, falls through to the
            // return otherwise.
            assertionFailure()
            return
        }

        self.position = newPosition
    }

    @objc(_web_renderLayerWithContextID:shouldPreserveFlip:)
    class func _web_renderLayer(
        withContextID contextID: UInt32,
        shouldPreserveFlip preservesFlip: Bool
    ) -> CALayer? {
        // The header has no nullability annotations, so the return type is Optional; the
        // layer returned is never nil.
        let layerHost = CALayerHost()
        if assertionsEnabled {
            layerHost.name = "Hosting layer"
        }
        layerHost.contextId = contextID
        layerHost.preservesFlip = preservesFlip
        return layerHost
    }

    @objc(_web_maskContainsPoint:)
    func _web_maskContains(_ point: CGPoint) -> Bool {
        guard let mask else {
            return false
        }

        let pointInMask = mask.convert(point, from: self)
        if let shapeMask = mask as? CAShapeLayer {
            // CGPathContainsPoint of a NULL path is false.
            guard let path = shapeMask.path else {
                return false
            }
            let isEvenOddFill = shapeMask.fillRule == .evenOdd
            return path.contains(pointInMask, using: isEvenOddFill ? .evenOdd : .winding)
        }

        return mask.contains(pointInMask)
    }

    @objc(_web_maskMayIntersectRect:)
    func _web_maskMayIntersect(_ rect: CGRect) -> Bool {
        guard let mask else {
            return false
        }

        let rectInMask = mask.convert(rect, from: self)
        if let shapeMask = mask as? CAShapeLayer {
            // CGPathGetPathBoundingBox of a NULL path is CGRectNull, which intersects nothing.
            guard let path = shapeMask.path else {
                return false
            }
            return path.boundingBoxOfPath.intersects(rectInMask)
        }

        return mask.bounds.intersects(rectInMask)
    }

    @objc(_web_clearContents)
    func _web_clearContents() {
        contents = nil
        contentsOpaque = false

        #if ENABLE_RE_DYNAMIC_CONTENT_SCALING
        _web_clearDynamicContentScalingDisplayListIfNeeded()
        #endif

        #if HAVE_SUPPORT_HDR_DISPLAY_APIS
        contentsHeadroom = 0
        #endif
    }

    #if ENABLE_RE_DYNAMIC_CONTENT_SCALING
    @objc(_web_clearDynamicContentScalingDisplayListIfNeeded)
    func _web_clearDynamicContentScalingDisplayListIfNeeded() {
        if value(forKeyPath: DynamicContentScalingKey.contents) == nil {
            return
        }
        setValue(nil, forKeyPath: DynamicContentScalingKey.contents)
        setValue(nil, forKeyPath: DynamicContentScalingKey.ports)
        setValue(NSNumber(value: false), forKeyPath: DynamicContentScalingKey.enabled)
        setValue(NSNumber(value: false), forKeyPath: DynamicContentScalingKey.bifurcationEnabled)
    }
    #endif
}

#endif  // ENABLE_CALAYER_EXTRAS_SWIFT
