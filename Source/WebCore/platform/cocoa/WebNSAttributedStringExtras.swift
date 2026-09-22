/*
 * Copyright (C) 2005-2024 Apple Inc. All rights reserved.
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

// WebCore::attributedStringByStrippingAttachmentCharacters, in Swift.
//
// The gate has no parentheses on purpose: generate-platform-args passes
// -DENABLE_ATTRIBUTED_STRING_SWIFT to swiftc for a truthy ENABLE() macro, so the
// Swift spelling of the same gate is a bare identifier.

#if ENABLE_ATTRIBUTED_STRING_SWIFT

import Foundation

/// U+FFFC OBJECT REPLACEMENT CHARACTER, which is what AppKit and UIKit spell
/// `NSAttachmentCharacter`.
///
/// Written as a literal rather than read from either framework: the constant is a fixed
/// Unicode code point, and naming it here keeps this file's imports to Foundation instead
/// of pulling in a platform UI framework for one integer.
private let attachmentCharacter = "\u{FFFC}"

/// Returns a copy of `attributedString` with every attachment character removed, or null when
/// there was nothing to strip and the caller should keep the string it already has.
///
/// The result is RETAINED (+1) when it is non-null. WebCore sets SWIFT_INSTALL_OBJC_HEADER = NO
/// and declares no SWIFT_OBJC_INTERFACE_HEADER_NAME, so C++ cannot name a Swift declaration and
/// the only boundary available is `@_cdecl` -- a plain C function, whose signature says nothing
/// about who owns a returned object. Rather than depend on whichever convention the emitted
/// thunk picks, this returns an explicitly retained reference as an opaque pointer, and the C++
/// wrapper in WebNSAttributedStringExtras.mm adopts it and autoreleases.
///
/// Null means UNCHANGED, and covers both the no-attachment case and a nil argument. The C++
/// this replaces returned its argument untouched in both, so signalling "unchanged" instead of
/// handing back a retained copy of the input keeps the old behaviour exactly, and keeps the
/// common path off the autorelease pool.
///
/// Internal rather than public, unlike the `@_cdecl` functions in KeyEventCocoa.swift: those
/// take and return only stdlib types, while this one names `NSAttributedString`, which arrives
/// through an internal `import Foundation`. A public function cannot mention it. `@_cdecl`
/// exports the C symbol regardless of Swift access level, so nothing is lost.
@_cdecl("WebCoreAttributedStringByStrippingAttachmentCharacters")
func webCoreAttributedStringByStrippingAttachmentCharacters(
    _ attributedString: NSAttributedString?
) -> Swift.UnsafeMutableRawPointer? {
    guard let attributedString else {
        return nil
    }

    // NSString rather than Swift.String throughout, because the ranges being replaced are the
    // UTF-16 offsets NSMutableAttributedString wants, not String indices. This first search is
    // the one place a bridge is unavoidable -- an immutable NSAttributedString vends no
    // NSString-typed accessor -- and it happens once per call.
    var attachmentRange = (attributedString.string as NSString).range(of: attachmentCharacter)
    if attachmentRange.location == NSNotFound || attachmentRange.length == 0 {
        return nil
    }

    // `mutableCopy()` rather than `NSMutableAttributedString(attributedString:)`, which would
    // be equivalent for every in-tree caller but is not the same message: a subclass
    // overriding `mutableCopyWithZone:` would take a different path. The C++ this replaces
    // sent `mutableCopy`, and the function is WEBCORE_EXPORT.
    // swift-format-ignore: NeverForceUnwrap
    let strippedString = attributedString.mutableCopy() as! NSMutableAttributedString
    while attachmentRange.location != NSNotFound && attachmentRange.length > 0 {
        strippedString.replaceCharacters(in: attachmentRange, with: "")
        // `mutableString` is NSMutableString-typed, so searching it bridges nothing. Going
        // through `.string` here instead would transcode the whole document on every
        // iteration, and would make these UTF-16 offsets depend on Swift.String's bridging
        // round-tripping ill-formed text -- the unpaired-surrogate hazard the key-event
        // tables were shaped to avoid.
        attachmentRange = strippedString.mutableString.range(of: attachmentCharacter)
    }
    return unsafe retainedResult(strippedString)
}

/// Hands a +1 reference out as an opaque pointer.
///
/// It is unavoidable, because `@_cdecl` cannot carry an ARC-managed return whose ownership is
/// stated rather than implied. What it asserts is only that the caller balances the retain,
/// which the single caller does on the next line of C++, with `adoptNS`. Its call site needs
/// an `unsafe` of its own: `UnsafeMutableRawPointer` is itself an unsafe type, so naming it in
/// a signature makes calling the function unsafe, not just writing its body.
private func retainedResult(_ attributedString: NSAttributedString) -> Swift.UnsafeMutableRawPointer {
    unsafe Unmanaged.passRetained(attributedString).toOpaque()
}

#endif // ENABLE_ATTRIBUTED_STRING_SWIFT
