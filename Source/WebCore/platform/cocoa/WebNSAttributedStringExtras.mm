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

#import "config.h"
#import "WebNSAttributedStringExtras.h"

#if !ENABLE(ATTRIBUTED_STRING_SWIFT)
#if PLATFORM(IOS_FAMILY)
#import <UIKit/NSTextAttachment.h>
#else
#import <AppKit/NSTextAttachment.h>
#endif
#endif

namespace WebCore {

#if ENABLE(ATTRIBUTED_STRING_SWIFT)

// Implemented in WebNSAttributedStringExtras.swift. WebCore sets SWIFT_INSTALL_OBJC_HEADER = NO
// and declares no SWIFT_OBJC_INTERFACE_HEADER_NAME, so there is no generated Swift interface
// header to include and no way for C++ to name a Swift declaration. The boundary is therefore
// @_cdecl, and nothing checks this declaration against the Swift definition -- not the symbol
// name, not the return type, not the convention. The two are kept in sync by hand.
//
// Ownership, since this is the first OBJECT to cross that boundary rather than a scalar or a
// pointer into static storage. The argument crosses at +0: @_cdecl takes a class parameter as a
// guaranteed unretained reference, which is what passing it straight through relies on. The
// result crosses at +1, spelled Unmanaged.passRetained(...).toOpaque() on the Swift side, and
// the adoptNS below is what consumes that retain. The NS_RETURNS_RETAINED is documentation and
// nothing more: this file is @nonARC (SourcesCocoa.txt), where the attribute has no codegen
// effect, and its one consumer -- clang's retain-count checker -- cannot see a Swift definition
// in any case. The correctness lives in the adoptNS.
//
// A null return means "unchanged", not "no result". The C++ this replaces returned its argument
// untouched when there was nothing to strip; returning the argument here, rather than a
// retained-and-autoreleased copy of it, keeps that exactly, so the common path still needs no
// autorelease pool. It folds in nil-in-nil-out as the same branch. The exported contract is
// therefore unchanged, which matters: this is WEBCORE_EXPORT, the three in-tree callers assign
// into a RetainPtr, and out-of-tree callers were not enumerated.
extern "C" NSAttributedString *WebCoreAttributedStringByStrippingAttachmentCharacters(NSAttributedString *) NS_RETURNS_RETAINED;

NSAttributedString *attributedStringByStrippingAttachmentCharacters(NSAttributedString *attributedString)
{
    if (RetainPtr strippedString = adoptNS(WebCoreAttributedStringByStrippingAttachmentCharacters(attributedString)))
        return strippedString.autorelease();
    return attributedString;
}

#else

NSAttributedString *attributedStringByStrippingAttachmentCharacters(NSAttributedString *attributedString)
{
    NSRange attachmentRange;
    RetainPtr<NSString> originalString = [attributedString string];
    static NeverDestroyed attachmentCharString = [] {
        unichar chars[2] = { NSAttachmentCharacter, 0 };
        return adoptNS([[NSString alloc] initWithCharacters:chars length:1]);
    }();

    attachmentRange = [originalString rangeOfString:attachmentCharString.get().get()];
    if (attachmentRange.location != NSNotFound && attachmentRange.length > 0) {
        auto newAttributedString = adoptNS([attributedString mutableCopy]);

        while (attachmentRange.location != NSNotFound && attachmentRange.length > 0) {
            [newAttributedString replaceCharactersInRange:attachmentRange withString:@""];
            attachmentRange = [retainPtr([newAttributedString string]) rangeOfString:attachmentCharString.get().get()];
        }
        return newAttributedString.autorelease();
    }

    return attributedString;
}

#endif // ENABLE(ATTRIBUTED_STRING_SWIFT)

}
