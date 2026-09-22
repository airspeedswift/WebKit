/*
 * Copyright (C) 2012 Apple Inc. All rights reserved.
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

#if (PLATFORM(IOS_FAMILY) || (PLATFORM(MAC) && ENABLE(VIDEO_PRESENTATION_MODE))) && ENABLE(VIDEO)
#import "TextTrackRepresentationCocoa.h"

#import "FloatRect.h"
#import "GraphicsContextCG.h"
#import "IntRect.h"
#import "NativeImage.h"

#if PLATFORM(IOS_FAMILY)
#import "WebCoreThread.h"
#import "WebCoreThreadRun.h"
#endif

#import "WebActionDisablingCALayerDelegate.h"
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <wtf/BlockPtr.h>
#import <wtf/TZoneMallocInlines.h>


namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(TextTrackRepresentationCocoa);

std::unique_ptr<TextTrackRepresentation> TextTrackRepresentation::create(TextTrackRepresentationClient& client, HTMLMediaElement& mediaElement)
{
    if (TextTrackRepresentationCocoa::representationFactory())
        return TextTrackRepresentationCocoa::representationFactory()(client, mediaElement);
    return makeUnique<TextTrackRepresentationCocoa>(client);
}

TextTrackRepresentationCocoa::TextTrackRepresentationFactory& TextTrackRepresentationCocoa::representationFactory()
{
    static NeverDestroyed<TextTrackRepresentationFactory> factory;
    return factory.get();
}

TextTrackRepresentationCocoa::TextTrackRepresentationCocoa(TextTrackRepresentationClient& client)
    : m_client(client)
    , m_layer(adoptNS([[CALayer alloc] init]))
{
    // Disables every implicit CALayer action on this layer. Was a bespoke delegate whose only
    // other job was a back-pointer for a KVO observation that no longer exists.
    [m_layer setDelegate:[WebActionDisablingCALayerDelegate shared]];
    [m_layer setContentsGravity:kCAGravityBottom];

    [m_layer setName:@"TextTrackRepresentation"];
}

TextTrackRepresentationCocoa::~TextTrackRepresentationCocoa()
{
    [m_layer setDelegate:nil];
}

void TextTrackRepresentationCocoa::update()
{
    if (auto representation = m_client.createTextTrackRepresentationImage())
        [m_layer setContents:(__bridge id)representation->platformImage().get()];
}

void TextTrackRepresentationCocoa::setContentScale(float scale)
{
    [m_layer setContentsScale:scale];
}

void TextTrackRepresentationCocoa::setHidden(bool hidden) const
{
    [m_layer setHidden:hidden];
}

void TextTrackRepresentationCocoa::setBounds(const IntRect& bounds)
{
    if (this->bounds() == bounds)
        return;

    [m_layer setBounds:FloatRect(bounds)];
    boundsChanged();
}

IntRect TextTrackRepresentationCocoa::bounds() const
{
    return enclosingIntRect(FloatRect([m_layer bounds]));
}

void TextTrackRepresentationCocoa::boundsChanged()
{
    // A raw pointer, not a CheckedPtr: textTrackRepresentationBoundsChanged() can destroy this
    // object -- MediaControlTextTrackContainerElement clears its representation from that handler
    // -- and on iOS this lambda runs inline, because WebThreadRun() calls the block directly when
    // the WebThread is disabled. A CheckedPtr outstanding across that destruction would take the
    // zombie branch and then crash in crashDueToCheckedPtrToDeadObject().
    auto notifyClient = [weakThis = WeakPtr { *this }] {
        if (auto* protectedThis = weakThis.get())
            protectedThis->client().textTrackRepresentationBoundsChanged(protectedThis->bounds());
    };

#if PLATFORM(IOS_FAMILY)
    WebThreadRun(makeBlockPtr(WTF::move(notifyClient)).get());
#else
    callOnMainThread(WTF::move(notifyClient));
#endif
}

} // namespace WebCore

#endif // (PLATFORM(IOS_FAMILY) || (PLATFORM(MAC) && ENABLE(VIDEO_PRESENTATION_MODE))) && ENABLE(VIDEO)
