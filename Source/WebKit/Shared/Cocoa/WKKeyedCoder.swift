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

#if ENABLE_KEYED_CODER_SWIFT

import Foundation

// Imported publicly because the members below override public Foundation declarations,
// which Swift requires to be public, and a public member cannot mention WKKeyedCoder unless
// the module declaring it is imported publicly. WebKit_KeyedCoder exists for that reason:
// importing WebKit_Internal publicly would put every header in it into WebKit's public
// Swift interface, which breaks the _WebKit_SwiftUI target.
public import WebKit_KeyedCoder

// String is spelled Swift.String throughout: WebKit's Shared/Foundation+Extras.swift declares
// an internal `typealias String`, which shadows Swift.String and cannot appear in the public
// signatures the overrides below require.

/// Holds the coder's state. `@objc @implementation` does not accept stored properties whose
/// size can change under Library Evolution, so the state lives in this class and the
/// extension stores a single boxed reference to it.
private final class KeyedCoderStorage {
    var dictionary: [Swift.String: Any] = [:]
    var failedDecoding = false
}

@objc
@implementation
extension WKKeyedCoder {
    // Do not use this property directly; see KeyedCoderStorage.
    @nonobjc
    private var backingStorage: Any

    @nonobjc
    final private var storage: KeyedCoderStorage {
        // Safe force-unwrap: `backingStorage` is only ever set from an initializer, with a known type.
        // swift-format-ignore: NeverForceUnwrap
        backingStorage as! KeyedCoderStorage
    }

    public override init() {
        self.backingStorage = KeyedCoderStorage()
        super.init()
    }

    public init(dictionary: [Swift.String: Any]) {
        let storage = KeyedCoderStorage()
        storage.dictionary = dictionary
        self.backingStorage = storage
        super.init()
    }

    public override var allowsKeyedCoding: Bool { true }

    public override var requiresSecureCoding: Bool { true }

    public override func encode(_ object: Any?, forKey key: Swift.String) {
        guard let object else {
            return
        }
        guard WKKeyedCoderIsSerializableValue(object) else {
            assertionFailure("WKKeyedCoder attempt to encode object of unsupported type \(type(of: object))")
            return
        }
        storage.dictionary[key] = object
    }

    public override func containsValue(forKey key: Swift.String) -> Bool {
        storage.dictionary[key] != nil
    }

    /// Implements -decodeObjectOfClass:forKey:, which the category in WKKeyedCoder.mm forwards here.
    @objc(decodeObjectAllowingClass:forKey:)
    public func decodeObjectAllowing(_ aClass: AnyClass, forKey key: Swift.String) -> Any? {
        guard !storage.failedDecoding else {
            return nil
        }
        guard let object = storage.dictionary[key] else {
            return nil
        }
        guard (object as AnyObject).isKind(of: aClass) else {
            storage.failedDecoding = true
            return nil
        }
        return object
    }

    public override func __decodeObject(ofClasses classes: Set<AnyHashable>?, forKey key: Swift.String) -> Any? {
        guard !storage.failedDecoding else {
            return nil
        }
        guard let object = storage.dictionary[key] else {
            return nil
        }
        for case let aClass as AnyClass in classes ?? [] where (object as AnyObject).isKind(of: aClass) {
            return object
        }
        storage.failedDecoding = true
        return nil
    }

    public override func decodeObject(forKey key: Swift.String) -> Any? {
        storage.dictionary[key]
    }

    public override func encode(_ value: Bool, forKey key: Swift.String) {
        encode(NSNumber(value: value), forKey: key)
    }

    public override func decodeBool(forKey key: Swift.String) -> Bool {
        (decodeObjectAllowing(NSNumber.self, forKey: key) as? NSNumber)?.boolValue ?? false
    }

    public override func encode(_ value: Int64, forKey key: Swift.String) {
        encode(NSNumber(value: value), forKey: key)
    }

    public override func decodeInt64(forKey key: Swift.String) -> Int64 {
        (decodeObjectAllowing(NSNumber.self, forKey: key) as? NSNumber)?.int64Value ?? 0
    }

    public override func encode(_ value: Int, forKey key: Swift.String) {
        encode(NSNumber(value: value), forKey: key)
    }

    public override func decodeInteger(forKey key: Swift.String) -> Int {
        (decodeObjectAllowing(NSNumber.self, forKey: key) as? NSNumber)?.intValue ?? 0
    }

    public func accumulatedDictionary() -> [Swift.String: Any] {
        storage.dictionary
    }
}

#endif  // ENABLE_KEYED_CODER_SWIFT
