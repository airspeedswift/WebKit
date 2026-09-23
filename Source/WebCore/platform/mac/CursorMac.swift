/*
 * Copyright (C) 2004-2026 Apple Inc. All rights reserved.
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

// The Mac cursor table of CursorMac.mm, in Swift: the NSCursor for every PlatformCursorType
// except Custom, and WebCustomCursor, the NSCursor subclass that names a system cursor AppKit
// has no public accessor for.
//
// The table is checked against the C++ it replaces case label by case label, through the
// CoreCursorType each one resolves to.
//
// The gate has no parentheses on purpose: generate-platform-args passes
// -DENABLE_CURSOR_MAC_SWIFT to swiftc for a truthy ENABLE() macro, so the
// Swift spelling of the same gate is a bare identifier.

#if ENABLE_CURSOR_MAC_SWIFT

internal import AppKit
// CoreCursorType is a CF_ENUM in HIServicesSPI.h, so its kCoreCursor* enumerators arrive as
// the cases of a Swift enum with the common prefix dropped: kCoreCursorWindowMove is
// `.windowMove`.
internal import pal.spi.mac.HIServicesSPI

/// An NSCursor that AppKit draws as the system cursor `cursorType`.
///
/// AppKit asks a cursor for `_coreCursorType` and draws the system cursor it names instead of
/// an image. NSCursor implements that method privately but declares it in neither the SDK nor
/// PAL, so to Swift this is a new method, not an `override`: it replaces NSCursor's by selector
/// at run time, which is why the `@objc` name is spelled out. The Objective-C class name is
/// kept as `WebCustomCursor` too, so the runtime sees the same class it always has.
@objc(WebCustomCursor)
private final class WebCustomCursor: AppKit.NSCursor {
    private let cursorType: CoreCursorType

    init(type cursorType: CoreCursorType) {
        self.cursorType = cursorType
        super.init()
    }

    // NSCursor conforms to NSCoding, so a designated initializer requires this one. Nothing
    // archives a WebCustomCursor.
    required init(coder: Foundation.NSCoder) {
        fatalError("WebCustomCursor does not support NSCoding")
    }

    @objc(_coreCursorType)
    func coreCursorType() -> Swift.Int {
        Swift.Int(cursorType.rawValue)
    }
}

/// A new cursor that AppKit draws as the system cursor `cursorType`.
///
/// Each call makes a new object; nothing is cached here. `Cursor` keeps the result in its
/// `m_platformCursor`, so each `Cursor` asks at most once.
private func cursor(_ cursorType: CoreCursorType) -> AppKit.NSCursor {
    WebCustomCursor(type: cursorType)
}

/// PlatformCursorType from Source/WebCore/platform/Cursor.h, by raw value.
///
/// Spelled out rather than imported: the C++ enum lives in a header Swift does not otherwise
/// need, and the boundary carries the raw `uint8_t` in any case. Every raw value is written
/// explicitly so that a reordering in Cursor.h cannot silently shift this table; the two are
/// kept in sync by hand.
private enum PlatformCursorType: Swift.UInt8 {
    case invalid = 0
    case pointer = 1
    case cross = 2
    case hand = 3
    case iBeam = 4
    case wait = 5
    case help = 6
    case eastResize = 7
    case northResize = 8
    case northEastResize = 9
    case northWestResize = 10
    case southResize = 11
    case southEastResize = 12
    case southWestResize = 13
    case westResize = 14
    case northSouthResize = 15
    case eastWestResize = 16
    case northEastSouthWestResize = 17
    case northWestSouthEastResize = 18
    case columnResize = 19
    case rowResize = 20
    case middlePanning = 21
    case eastPanning = 22
    case northPanning = 23
    case northEastPanning = 24
    case northWestPanning = 25
    case southPanning = 26
    case southEastPanning = 27
    case southWestPanning = 28
    case westPanning = 29
    case move = 30
    case verticalText = 31
    case cell = 32
    case contextMenu = 33
    case alias = 34
    case progress = 35
    case noDrop = 36
    case copy = 37
    case none = 38
    case notAllowed = 39
    case zoomIn = 40
    case zoomOut = 41
    case grab = 42
    case grabbing = 43
    case custom = 44
}

/// The NSCursor for `type`, or nil for `.invalid` and `.custom`, which have none here.
private func platformCursor(for type: PlatformCursorType) -> AppKit.NSCursor? {
    switch type {
    case .pointer:
        return AppKit.NSCursor.arrow
    case .cross:
        return AppKit.NSCursor.crosshair
    case .hand:
        return AppKit.NSCursor.pointingHand
    case .iBeam:
        return AppKit.NSCursor.iBeam
    case .wait:
        return cursor(.busyButClickable)
    case .help:
        return cursor(.help)
    case .move, .middlePanning:
        return cursor(.windowMove)
    case .eastResize, .eastPanning:
        return cursor(.windowResizeEast)
    case .northResize, .northPanning:
        return cursor(.windowResizeNorth)
    case .northEastResize, .northEastPanning:
        return cursor(.windowResizeNorthEast)
    case .northWestResize, .northWestPanning:
        return cursor(.windowResizeNorthWest)
    case .southResize, .southPanning:
        return cursor(.windowResizeSouth)
    case .southEastResize, .southEastPanning:
        return cursor(.windowResizeSouthEast)
    case .southWestResize, .southWestPanning:
        return cursor(.windowResizeSouthWest)
    case .westResize, .westPanning:
        return cursor(.windowResizeWest)
    case .northSouthResize:
        return cursor(.windowResizeNorthSouth)
    case .eastWestResize:
        return cursor(.windowResizeEastWest)
    case .northEastSouthWestResize:
        return cursor(.windowResizeNorthEastSouthWest)
    case .northWestSouthEastResize:
        return cursor(.windowResizeNorthWestSouthEast)
    case .columnResize:
        return AppKit.NSCursor.resizeLeftRight
    case .rowResize:
        return AppKit.NSCursor.resizeUpDown
    case .verticalText:
        return AppKit.NSCursor.iBeamCursorForVerticalLayout
    case .cell:
        return cursor(.cell)
    case .contextMenu:
        return AppKit.NSCursor.contextualMenu
    case .alias:
        return cursor(.makeAlias)
    case .progress:
        return cursor(.busyButClickable)
    case .noDrop:
        return AppKit.NSCursor.operationNotAllowed
    case .copy:
        return AppKit.NSCursor.dragCopy
    case .none:
        #if ENABLE_CUSTOM_CURSOR_SUPPORT
        // A cursor with a 1x1 transparent image, so nothing is drawn.
        return AppKit.NSCursor(image: AppKit.NSImage(size: Foundation.NSSize(width: 1, height: 1)), hotSpot: .zero)
        #else
        return AppKit.NSCursor.arrow
        #endif
    case .notAllowed:
        return AppKit.NSCursor.operationNotAllowed
    case .zoomIn:
        return cursor(.zoomIn)
    case .zoomOut:
        return cursor(.zoomOut)
    case .grab:
        return AppKit.NSCursor.openHand
    case .grabbing:
        return AppKit.NSCursor.closedHand
    case .custom:
        // A custom cursor is made from the Cursor's image, which does not cross this boundary;
        // Cursor::ensurePlatformCursor handles it before calling here.
        Swift.assertionFailure("a custom cursor has no NSCursor in this table")
        return nil
    case .invalid:
        Swift.assertionFailure("an invalid cursor has no NSCursor")
        return nil
    }
}

/// The NSCursor for the PlatformCursorType whose raw value is `type`, at +0, or nil.
///
/// WebCore sets SWIFT_INSTALL_OBJC_HEADER = NO and declares no
/// SWIFT_OBJC_INTERFACE_HEADER_NAME, so C++ cannot name a Swift declaration and the only
/// boundary available is `@_cdecl`, which cannot carry a C++ enum class; the cursor type
/// crosses as its `uint8_t` raw value.
///
/// The result is autoreleased, as an Objective-C method returning an object would be: the
/// thunk returns through `objc_autoreleaseReturnValue`. For a shared AppKit cursor that hands
/// back an object AppKit keeps alive anyway; for a new WebCustomCursor, or the blank cursor
/// for `.none`, the autorelease pool holds the only reference until the caller retains it. The
/// one caller, Cursor::ensurePlatformCursor, assigns the result straight into a `RetainPtr`.
///
/// `.custom`, `.invalid` and a raw value outside the enum are programming errors: they assert
/// in debug builds and return nil otherwise, leaving `m_platformCursor` null exactly as the C++
/// `ASSERT_NOT_REACHED()` default does. Nil rather than a precondition, so a release build
/// that reaches one keeps the behaviour it has always had instead of crashing.
///
/// Internal rather than public because it names `NSCursor`, which arrives through an internal
/// import. `@_cdecl` exports the C symbol regardless of access level.
@_cdecl("WebCoreCursorMacPlatformCursor")
func webCoreCursorMacPlatformCursor(_ type: Swift.UInt8) -> AppKit.NSCursor? {
    guard let type = PlatformCursorType(rawValue: type) else {
        Swift.assertionFailure("not a PlatformCursorType")
        return nil
    }
    return platformCursor(for: type)
}

#endif // ENABLE_CURSOR_MAC_SWIFT
