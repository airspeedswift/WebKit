/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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

#pragma once

#import <wtf/Platform.h>

#ifdef __OBJC__

#import <Foundation/Foundation.h>

// WKKeyedCoder is an NSCoder meant to work with `encodeWithCoder:` and `initWithCoder:` for
// certain classes we need to serialize.
//
// The strategy is to accumulate an NSDictionary of key/value pairs that would normally be
// in a WebKit secure coding property list.
// The validation of this dictionary at decode time is exactly the same as for the property lists.
//
// It only supports a subset of the many encode/decode methods based on what we know is
// actually needed by the target classes.
// As we add more specific types that rely on it, we'll expand its feature-set.

// This is an implementation detail of IPC that should only be used for the SupportWKKeyedCoder
// keyword in a *.serialization.in file, and its use should only be declining.

NS_ASSUME_NONNULL_BEGIN

#if ENABLE(KEYED_CODER_SWIFT)
// Defined in WKKeyedCoder.mm, so the Swift implementation can reach
// IPC::isSerializableValue, which is a free function in a C++ namespace.
#ifdef __cplusplus
extern "C" {
#endif
bool WKKeyedCoderIsSerializableValue(id);
#ifdef __cplusplus
}
#endif
#endif

@interface WKKeyedCoder : NSCoder
- (instancetype)init;
- (instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary<NSString *, id> *)accumulatedDictionary;

#if ENABLE(KEYED_CODER_SWIFT)
// -decodeObjectOfClass:forKey: cannot be implemented in Swift: the Foundation overlay
// claims that selector for a generic decodeObject(of:forKey:) which is not overridable,
// so the Swift implementation is spelled under this name and the ObjC category in
// WKKeyedCoder.mm forwards the NSCoder selector to it.
- (nullable id)decodeObjectAllowingClass:(Class)aClass forKey:(NSString *)key;
#endif
@end

NS_ASSUME_NONNULL_END

#endif // __OBJC__
