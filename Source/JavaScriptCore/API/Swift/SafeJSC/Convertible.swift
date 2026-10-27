import JavaScriptCore
import CJSCKeepAlive

// MARK: - Swift -> JS: custom value conversion, in CPS form
//
// The requirement cannot RETURN a JS value (it would be unrooted), so it takes
// the continuation. Construction is top-down: the parent exists first and each
// child is converted inside its own scope while being written into it, which
// keeps composite conversions flat.

public protocol JSConvertible {
    func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R
}

/// Most model types: an object filled in property by property.
/// `func fill(_ o: JSObject) throws { try o.set("term", term) }`
/// (A JSObject, not a JSRef: the object is known to be one, so no `set` re-checks it.)
public protocol JSObjectConvertible: JSConvertible {
    func fill(_ object: JSObject) throws
}
extension JSObjectConvertible {
    @inlinable
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        var lock = unsafe jsc_scope_lock(scope.ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        let raw = unsafe jsc_make_object(scope.ctx)
        defer { unsafe keepAlive(raw) }
        let o = unsafe JSObject(unchecked: JSRef(raw, scope.ctx))
        try fill(o)
        return try body(o.ref)
    }
}

extension String: JSConvertible {
    @inlinable
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        try unsafe withStackRoot(makeJSString(scope.ctx, self), in: scope.ctx, body)
    }
}
extension Double: JSConvertible {
    @inlinable
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        try unsafe withStackRoot(JSValueMakeNumber(scope.ctx, self)!, in: scope.ctx, body)
    }
}
extension Int: JSConvertible {
    @inlinable
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        try Double(self).withJSValue(in: scope, body)
    }
}
extension Bool: JSConvertible {
    @inlinable
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        try unsafe withStackRoot(JSValueMakeBoolean(scope.ctx, self)!, in: scope.ctx, body)
    }
}
/// JS `null`. (A Swift `nil` Optional converts to `undefined`.)
public struct JSNull: JSConvertible {
    public init() {}
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        try unsafe withStackRoot(JSValueMakeNull(scope.ctx)!, in: scope.ctx, body)
    }
}
public struct JSUndefined: JSConvertible {
    public init() {}
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        try unsafe withStackRoot(JSValueMakeUndefined(scope.ctx)!, in: scope.ctx, body)
    }
}
extension Optional: JSConvertible where Wrapped: JSConvertible {
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        switch self {
        case .none: try JSUndefined().withJSValue(in: scope, body)
        case .some(let w): try w.withJSValue(in: scope, body)
        }
    }
}
extension Array: JSConvertible where Element: JSConvertible {
    @inlinable
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        let ctx = unsafe scope.ctx
        var lock = unsafe jsc_scope_lock(ctx)
        defer { unsafe jsc_scope_unlock(&lock) }
        // Numbers and booleans are not heap cells, so the elements need no rooting while
        // JSObjectMakeArray allocates: make them all and the array in one C call.
        if Element.self == Double.self || Element.self == Int.self || Element.self == Bool.self {
            let raw = try unsafe withUnsafeTemporaryAllocation(of: JSValueRef?.self, capacity: count) { buffer throws(JSError) in
                for (i, e) in enumerated() { unsafe buffer.initializeElement(at: i, to: rawLeaf(ctx, e)) }
                return try unsafe checked(in: ctx) { unsafe JSObjectMakeArray(ctx, count, buffer.baseAddress, $0) }!
            }
            return try unsafe withStackRoot(raw, in: ctx, body)
        }
        let raw = unsafe JSObjectMakeArray(ctx, 0, nil, nil)!
        defer { unsafe keepAlive(raw) }
        for (i, e) in enumerated() { try unsafe rawSet(ctx, raw, i, convertible: e) }
        return try body(unsafe JSRef(raw, ctx))
    }
}
extension Dictionary: JSConvertible where Key == String, Value: JSConvertible {
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        try scope.makeObject { o in
            for (k, v) in self { try o.set(k, v) }
            return try body(o)
        }
    }
}

// MARK: - JS -> Swift

/// A Swift value decoded from JS, read straight from a scoped JSRef.
public protocol JSDecodable { init(js: JSRef) throws }

/// Most models decode from an object: write `init(js o: JSObject)`, and the
/// JSDecodable init comes for free (JSTypeError for anything but an object).
public protocol JSObjectDecodable: JSDecodable { init(js o: JSObject) throws }
extension JSObjectDecodable {
    @inlinable
    public init(js v: JSRef) throws {
        guard let o = v.object else { throw JSTypeError(expected: "object", got: v.description) }
        try self.init(js: o)
    }
}

public struct JSTypeError: Error, CustomStringConvertible, Sendable {
    public let expected: String, got: String
    @inlinable public init(expected: String, got: String) { self.expected = expected; self.got = got }
    public var description: String { "expected \(expected), got \(got)" }
}
extension String: JSDecodable {
    @inlinable public init(js: JSRef) throws {
        guard let s = js.stringValue else { throw JSTypeError(expected: "string", got: js.description) }
        self = s
    }
}
extension Double: JSDecodable {
    @inlinable public init(js: JSRef) throws {
        guard let d = js.numberValue else { throw JSTypeError(expected: "number", got: js.description) }
        self = d
    }
}
extension Bool: JSDecodable {
    @inlinable public init(js: JSRef) throws {
        guard let b = js.boolValue else { throw JSTypeError(expected: "boolean", got: js.description) }
        self = b
    }
}
extension Optional: JSDecodable where Wrapped: JSDecodable {
    public init(js: JSRef) throws { self = js.isNullish ? nil : try Wrapped(js: js) }
}
extension Array: JSDecodable where Element: JSDecodable {
    public init(js: JSRef) throws {
        guard let a = try js.decodeElements(as: Element.self) else { throw JSTypeError(expected: "array", got: js.description) }
        self = a
    }
}
