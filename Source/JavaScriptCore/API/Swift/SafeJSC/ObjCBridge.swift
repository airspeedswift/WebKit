import JavaScriptCore

// Sharing one JS context with ObjC-API code.
//
// A client adopting SafeJSC incrementally keeps a JSContext for everything it has not moved
// yet (JSExport natives, its own value conversions, other dependencies). Adopting SafeJSC
// one path at a time needs values to cross between the two APIs inside the same context,
// without the client ever handling a raw JSValueRef.
//
// Both directions are sound without stack rooting: a JSValue holds its own precise root
// (JSValueProtect, released when the JSValue deinits), so a JSValue kept alive across a
// closure roots the value the closure sees, and a JSValue made from a stack-rooted JSRef
// protects it before the JSRef's frame can end.

extension JSVM {
    /// A VM over an existing ObjC-API context: both APIs then work on the same global object.
    /// Retains the context's global context; create it on the context's thread.
    public convenience init(context: JSContext) {
        let ctx = unsafe JSGlobalContextRetain(context.jsGlobalContextRef)!
        unsafe self.init(adopting: ctx)
    }

    /// The ObjC-API wrapper for this VM's context (the existing one, if the client made it).
    public var context: JSContext { unsafe JSContext(jsGlobalContextRef: ctx) }
}

extension JSScope {
    /// The ObjC-API wrapper for the context a value is being made in, for a conversion that
    /// delegates to ObjC-API code (a client conversion that makes a JSValue in a JSContext).
    public var context: JSContext { unsafe JSContext(jsGlobalContextRef: JSContextGetGlobalContext(ctx)!) }
}

extension JSArguments {
    /// The ObjC-API wrapper for the calling context.
    public var context: JSContext { scope.context }
}

extension JSRef {
    /// This value as an ObjC-API JSValue (which protects it for as long as the JSValue lives).
    public var objcValue: JSValue {
        unsafe JSValue(jsValueRef: raw, in: JSContext(jsGlobalContextRef: JSContextGetGlobalContext(ctx)!))
    }
}

extension JSTyped where Self: ~Escapable {
    /// This value as an ObjC-API JSValue.
    public var objcValue: JSValue { ref.objcValue }
}

/// An ObjC-API value passed to SafeJSC: rooted by the JSValue itself for the closure's extent.
extension JSValue: JSConvertible {
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        let mine = unsafe JSContextGetGroup(context.jsGlobalContextRef)
        let theirs = unsafe JSContextGetGroup(scope.ctx)
        precondition(unsafe mine == theirs, "a JSValue from another virtual machine")
        return try withExtendedLifetime(self) {
            try body(unsafe JSRef(jsValueRef, scope.ctx))
        }
    }
}

// MARK: - Property enumeration

extension JSObject {
    /// Calls `body` with each own enumerable property (`Object.keys` order), the value rooted
    /// by this frame for the call. A throwing getter's exception is thrown.
    @available(*, noasync)
    public func forEachProperty(_ body: (String, JSRef) throws -> Void) throws {
        let names = unsafe JSObjectCopyPropertyNames(ctx, raw)!
        defer { unsafe JSPropertyNameArrayRelease(names) }
        let n = unsafe JSPropertyNameArrayGetCount(names)
        for i in 0..<n {
            let name = unsafe JSPropertyNameArrayGetNameAtIndex(names, i)!
            let value = try unsafe checked(in: ctx) { unsafe JSObjectGetProperty(ctx, raw, name, $0) }!
            let key = unsafe JSStringCopyCFString(nil, name) as String
            try unsafe withStackRoot(value, in: ctx) { try body(key, $0) }
        }
    }

    /// Own enumerable property names, in `Object.keys` order.
    public var propertyNames: [String] {
        let names = unsafe JSObjectCopyPropertyNames(ctx, raw)!
        defer { unsafe JSPropertyNameArrayRelease(names) }
        let n = unsafe JSPropertyNameArrayGetCount(names)
        return (0..<n).map { unsafe JSStringCopyCFString(nil, JSPropertyNameArrayGetNameAtIndex(names, $0)!) as String }
    }

    /// `key in self` (prototype chain included), without reading the value.
    public func has(_ key: some JSKey) -> Bool {
        unsafe key.withJSString { unsafe JSObjectHasProperty(ctx, raw, $0) }
    }
}

extension JSRef {
    /// Whether the value is a Date (`instanceof Date`).
    public var isDate: Bool { unsafe JSValueIsDate(ctx, raw) }
    /// Whether the value is a Symbol.
    public var isSymbol: Bool { unsafe JSValueGetType(ctx, raw) == kJSTypeSymbol }
    /// JS truthiness (`!!value`), which runs no user code.
    public var isTruthy: Bool { unsafe JSValueToBoolean(ctx, raw) }
}

extension JSContext {
    /// A scope for making SafeJSC values in this context, for ObjC-API code that has a JSContext
    /// and a JSConvertible (a client's ObjC-API conversion implemented over a SafeJSC
    /// conversion). Make the result an ObjC value (`objcValue`) before the closure returns.
    @available(*, noasync)
    public func withScope<R: ~Copyable, E: Error>(_ body: (JSScope) throws(E) -> R) throws(E) -> R {
        try withExtendedLifetime(self) { () throws(E) -> R in try body(unsafe JSScope(jsGlobalContextRef)) }
    }
}

extension JSObject {
    /// The object's identity (its address), for cycle detection in a walk. Stable while the
    /// object is alive; meaningless once it is not. Never turned back into a value.
    public var identity: UInt { UInt(bitPattern: unsafe UnsafeRawPointer(raw)) }
}

// MARK: - Bulk reads (one C call per value)

/// A value's JS type, from one `JSValueGetType` call: dispatch on it instead of asking
/// `isString`, `isNumber`, ... in turn when walking many values (each is a C call and a lock).
public enum JSKind: Sendable {
    case undefined, null, boolean, number, string, object, symbol, bigint
}

extension JSRef {
    public var kind: JSKind {
        switch unsafe JSValueGetType(ctx, raw) {
        case kJSTypeUndefined: .undefined
        case kJSTypeNull: .null
        case kJSTypeBoolean: .boolean
        case kJSTypeNumber: .number
        case kJSTypeString: .string
        case kJSTypeObject: .object
        case kJSTypeSymbol: .symbol
        default: .bigint
        }
    }

    /// A string value as a Foundation string, without a round trip through Swift's String
    /// (for Foundation-backed results: JSONObject's NSString leaves).
    public var foundationString: NSString? {
        guard isString, let s = unsafe JSValueToStringCopy(ctx, raw, nil) else { return nil }
        defer { unsafe JSStringRelease(s) }
        return unsafe JSStringCopyCFString(nil, s) as NSString
    }

    /// JS `ToNumber`, unchecked: one C call where `numberValue` makes two. For a value whose
    /// `kind` is `.number` no user code runs; for an object it may call `valueOf` (an exception
    /// gives NaN).
    public var toNumber: Double { unsafe JSValueToNumber(ctx, raw, nil) }

    /// JS `ToString`, unchecked (`description`, as a Foundation string).
    public var toFoundationString: NSString {
        guard let s = unsafe JSValueToStringCopy(ctx, raw, nil) else { return "" }
        defer { unsafe JSStringRelease(s) }
        return unsafe JSStringCopyCFString(nil, s) as NSString
    }
}

extension JSObject {
    /// `forEachProperty` with Foundation-string keys, for Foundation-backed results.
    @available(*, noasync)
    public func forEachPropertyNSString(_ body: (NSString, JSRef) throws -> Void) throws {
        let names = unsafe JSObjectCopyPropertyNames(ctx, raw)!
        defer { unsafe JSPropertyNameArrayRelease(names) }
        let n = unsafe JSPropertyNameArrayGetCount(names)
        for i in 0..<n {
            let name = unsafe JSPropertyNameArrayGetNameAtIndex(names, i)!
            let value = try unsafe checked(in: ctx) { unsafe JSObjectGetProperty(ctx, raw, name, $0) }!
            let key = unsafe JSStringCopyCFString(nil, name) as NSString
            try unsafe withStackRoot(value, in: ctx) { try body(key, $0) }
        }
    }
}

// MARK: - JSON

extension JSRef {
    /// `JSON.stringify(self)` as UTF-16 data (a copy, so it outlives the JS string), for a
    /// Foundation parse (`JSONSerialization`). nil when the value has no JSON form (`undefined`,
    /// a function) or stringifying throws (a cycle, a throwing `toJSON`); the exception is
    /// discarded, not reported to the VM's exception mapper (as `JSValueCreateJSONString` with
    /// no exception slot, as classic ObjC-API bridging uses it).
    @available(*, noasync)
    public func jsonUTF16Data() -> Data? {
        guard let json = unsafe JSValueCreateJSONString(ctx, raw, 0, nil) else { return nil }
        defer { unsafe JSStringRelease(json) }
        let count = unsafe JSStringGetLength(json)
        guard count > 0, let characters = unsafe JSStringGetCharactersPtr(json) else { return Data() }
        return unsafe Data(bytes: characters, count: count * MemoryLayout<JSChar>.size)
    }
}
