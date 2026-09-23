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

#if ENABLE_FULLSCREEN_WINDOW_SWIFT

internal import AppKit

// WEBCORE_EXPORT makes the class import as a public Swift class, so the members below are
// public and the module declaring it has to be imported publicly -- the same chain as
// WebActionDisablingCALayerDelegate. WebCore_Private's umbrella over PrivateHeaders already
// claims this header, so no new modulemap entry is needed.
public import WebCore_Private

@objc
@implementation
extension WebCoreFullScreenWindow {
    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hasShadow = false
    }

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    public override var canBecomeMain: Bool {
        false
    }

    public override var canBecomeKey: Bool {
        true
    }

    public override func keyDown(with event: NSEvent) {
        // U+001B is the character the Escape key produces.
        if event.charactersIgnoringModifiers == "\u{1B}" {
            cancelOperation(self)
        } else {
            super.keyDown(with: event)
        }
    }

    public override func cancelOperation(_ sender: Any?) {
        windowController?.cancelOperation(sender)
    }

    public override func performClose(_ sender: Any?) {
        // NSWindowController declares no -performClose:; the subclass that uses this window is
        // expected to implement it. Sending the selector through -performSelector:withObject:
        // keeps the Objective-C behaviour exactly: a controller that does not implement it
        // raises "unrecognized selector", where an `AnyObject` optional call (`?(sender)`)
        // would skip the call silently. WebVideoFullscreenController is one such controller.
        //
        // SAFETY: the only unsafe construct is the Unmanaged<AnyObject> result, which is
        // discarded without being read, retained or released; -performClose: returns void.
        _ = unsafe windowController?.perform(#selector(NSWindow.performClose(_:)), with: sender)
    }

    public override var styleMask: NSWindow.StyleMask {
        get {
            super.styleMask
        }
        set {
            // Changing the styleMask of a NSWindow can reset the firstResponder if the frame view
            // changes, so save off the existing one, and restore it if necessary afterwards.
            let savedFirstResponder = firstResponder

            super.styleMask = newValue

            if firstResponder !== savedFirstResponder,
                let savedView = savedFirstResponder as? NSView,
                let contentView,
                savedView.isDescendant(of: contentView)
            {
                makeFirstResponder(savedView)
            }
        }
    }
}

#endif // ENABLE_FULLSCREEN_WINDOW_SWIFT
