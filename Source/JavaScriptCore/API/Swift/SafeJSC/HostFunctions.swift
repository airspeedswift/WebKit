import JavaScriptCore
import CJSCKeepAlive

// MARK: - Swift functions as JS values
//
// A JSFunction is an ordinary Swift value that converts to a JS function, so
// it can be set on any object (`crypto.set("base64Encode", JSFunction { ... })`),
// passed as an argument, or returned.

public struct JSFunction: JSConvertible {
    let body: (borrowing JSArguments) throws -> JSReturn
    public init(_ body: @escaping (borrowing JSArguments) throws -> JSReturn) { self.body = body }

    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ k: (JSRef) throws -> R) throws -> R {
        let box = unsafe Unmanaged.passRetained(HostBox(body)).toOpaque()
        let fn = unsafe JSObjectMake(scope.ctx, hostClass.ref, box)!
        return try unsafe withStackRoot(fn, in: scope.ctx, k)
    }
}

/// A host call's arguments, rooted in JSC's own call frame for the whole call.
@safe public struct JSArguments: ~Escapable, ~Copyable {
    @usableFromInline let ctx: JSContextRef
    @usableFromInline let thisRaw: JSObjectRef?
    @usableFromInline let argv: UnsafePointer<JSValueRef?>?
    public let count: Int

    @unsafe @_lifetime(immortal)
    init(_ ctx: JSContextRef, _ this: JSObjectRef?, _ argv: UnsafePointer<JSValueRef?>?, _ count: Int) {
        unsafe self.ctx = ctx; unsafe self.thisRaw = this; unsafe self.argv = argv; self.count = count
    }

    public var scope: JSScope { @_lifetime(copy self) get { unsafe JSScope(ctx) } }

    /// Argument `i` (undefined past the end), closure-free: JSC's call frame
    /// roots every argument for the whole callback, so a borrow of the
    /// arguments is the real lifetime.
    public subscript(_ i: Int) -> JSRef {
        @_lifetime(borrow self) get {
            unsafe JSRef(i < count ? argv![i]! : JSValueMakeUndefined(ctx)!, ctx)
        }
    }
    /// `this` of the call.
    public var this: JSRef {
        @_lifetime(borrow self) get { unsafe JSRef(thisRaw ?? JSValueMakeUndefined(ctx)!, ctx) }
    }

    /// Argument `i`, or `undefined` past the end.
    @inlinable
    public func with<R: ~Copyable, E: Error>(_ i: Int, _ body: (JSRef) throws(E) -> R) throws(E) -> R {
        let raw = i < count ? unsafe argv![i]! : unsafe JSValueMakeUndefined(ctx)!
        return try unsafe withStackRoot(raw, in: ctx, body)
    }
    public func string(_ i: Int) -> String? { with(i) { $0.stringValue } }
    public func number(_ i: Int) -> Double? { with(i) { $0.numberValue } }
    public func bool(_ i: Int) -> Bool? { with(i) { $0.boolValue } }
    public func decode<T: JSDecodable>(_ i: Int, as: T.Type = T.self) throws -> T { try with(i) { try T(js: $0) } }
    public func root(_ i: Int) -> JSRooted { with(i) { $0.root() } }
}

/// What a host function returns. Never a bare JSRef (it would not survive the return).
public enum JSReturn: ~Copyable {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    /// Any Swift value with a JS form: arrays, dictionaries, models, functions.
    case value(any JSConvertible)
    /// Argument `i` of this call, returned as-is.
    case argument(Int)
    case rooted(JSRooted)
}

final class HostBox {
    let body: (borrowing JSArguments) throws -> JSReturn
    init(_ body: @escaping (borrowing JSArguments) throws -> JSReturn) { self.body = body }
}

@safe struct HostClass: @unchecked Sendable { let ref: JSClassRef }   // a JSClassRef is immutable after creation

let hostClass: HostClass = {
    var def = unsafe kJSClassDefinitionEmpty
    unsafe def.className = UnsafeRawPointer(("SwiftFunction" as StaticString).utf8Start).assumingMemoryBound(to: CChar.self)
    unsafe def.callAsFunction = { ctx, function, this, argc, argv, exception in
        let box = unsafe Unmanaged<HostBox>.fromOpaque(JSObjectGetPrivate(function)!).takeUnretainedValue()
        let ctx = unsafe ctx!
        // JSC dropped all locks before calling us: no enclosing SafeJSC scope holds one now.
        // (Not locked for the whole body: that measured slower, perf-bench c 53.6 vs 47.3 ns,
        // than letting the body's few C calls, or its own accesses, take it.)
        let savedOwner = unsafe jsc_scope_lock_enter_callback()
        defer { unsafe jsc_scope_lock_leave_callback(savedOwner) }
        do {
            let args = unsafe JSArguments(ctx, this, argv, argc)
            switch try box.body(args) {
            case .undefined: return unsafe JSValueMakeUndefined(ctx)
            case .null: return unsafe JSValueMakeNull(ctx)
            case .bool(let b): return unsafe JSValueMakeBoolean(ctx, b)
            case .number(let n): return unsafe JSValueMakeNumber(ctx, n)
            case .string(let s): return unsafe withJSString(s) { unsafe JSValueMakeString(ctx, $0) }
            // The raw value leaves our frame here, but JSC takes it from the
            // return register before anything can collect.
            case .value(let v): return try unsafe v.withJSValue(in: unsafe JSScope(ctx)) { unsafe $0.raw }
            case .argument(let i): return unsafe args.with(i) { unsafe $0.raw }
            case .rooted(let r): return unsafe r.with { unsafe $0.raw }
            }
        } catch {
            // An error with its own JS form (a JSConvertible error type: message, line, userInfo) is
            // thrown as that value. Like a return value, the raw pointer leaves our frame only
            // into JSC's exception slot.
            if let convertible = error as? any JSConvertible,
               let thrown = try? unsafe convertible.withJSValue(in: unsafe JSScope(ctx), { unsafe $0.raw }) {
                unsafe exception?.pointee = thrown
                return unsafe JSValueMakeUndefined(ctx)
            }
            // A real Error object, so `e instanceof Error` and `e.message` both work.
            let message = (error as? JSError)?.message ?? "\(error)"
            unsafe withJSString(message) { m in
                var arg: JSValueRef? = unsafe JSValueMakeString(ctx, m)
                unsafe exception?.pointee = JSObjectMakeError(ctx, 1, &arg, nil)
            }
            return unsafe JSValueMakeUndefined(ctx)
        }
    }
    unsafe def.finalize = { object in
        unsafe Unmanaged<HostBox>.fromOpaque(JSObjectGetPrivate(object)!).release()
    }
    return unsafe HostClass(ref: JSClassCreate(&def))
}()
