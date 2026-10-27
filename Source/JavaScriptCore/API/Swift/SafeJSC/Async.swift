import JavaScriptCore
import Synchronization

// Async/await. The rule: a stack-rooted value never crosses an `await`. Async
// boundaries are crossed with Swift values (decoded on the JS thread) or with
// JSHandle. The JS work itself stays synchronous: every stack-rooting API is
// `noasync`, so it runs in synchronous code on the JS thread's stack.
//
// That restriction is not an artefact of this API, and no API-side rule lifts it.
// An async function's values may live in its task-allocated async context
// whenever the compiler chooses, a task resumes on any thread in the cooperative
// pool, and JSC's conservative scan covers only the stacks of threads that took
// its lock, never task allocations. So JS access from async code is unsound
// under today's collector whatever API is used, including the C API, which gives
// no diagnostic for it. Lifting this needs the collector and the Swift runtime
// to scan the async contexts of tasks that may hold JS values.

// MARK: - The JS thread as an executor

/// Adapts a "run this block on the JS thread" scheduler into a SerialExecutor,
/// so an actor can be the JS thread: `nonisolated var unownedExecutor { executor.asUnownedSerialExecutor() }`.
/// If the client already owns the thread (for example a CFRunLoop thread),
/// pass its `schedule` and a check that the caller is on it. Create the JSVM on
/// that thread too: JSC fires its GC and finalization timers on the run loop of
/// the thread that created the VM.
public final class JSExecutor: SerialExecutor, Sendable {
    let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    let isCurrent: @Sendable () -> Bool

    public init(schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
                isCurrent: @escaping @Sendable () -> Bool) {
        self.schedule = schedule
        self.isCurrent = isCurrent
    }

    public func enqueue(_ job: UnownedJob) {
        let executor = unsafe asUnownedSerialExecutor()
        schedule { unsafe job.runSynchronously(on: executor) }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor { unsafe UnownedSerialExecutor(ordinary: self) }

    /// Lets `actor.assumeIsolated` succeed inside JSC callbacks, which arrive on
    /// this thread outside Swift's knowledge.
    public func checkIsolated() {
        precondition(isCurrent(), "not on the JS thread of this executor")
    }

    /// Run a synchronous block on the JS thread (the library settles promises with it).
    func run(_ body: @escaping @Sendable () -> Void) { schedule(body) }
}

// MARK: - JS promise -> Swift: two phases

/// A JS promise's outcome as a Swift value. Sendable: it holds only the decoded
/// result or the waiting continuation, nothing JS-valued.
public final class JSPending<T: Sendable>: Sendable {
    private enum State {
        case waiting(CheckedContinuation<T, any Error>?)
        case done(Result<T, any Error>)
    }
    private let state = Mutex(State.waiting(nil))

    init() {}

    func settle(_ result: Result<T, any Error>) {
        let continuation: CheckedContinuation<T, any Error>? = state.withLock { s in
            guard case .waiting(let k) = s else { return nil }
            s = .done(result)
            return k
        }
        continuation?.resume(with: result)
    }

    /// Suspend until the promise settles. Usable from any context.
    public var value: T {
        get async throws {
            try await withCheckedThrowingContinuation { k in
                let done: Result<T, any Error>? = state.withLock { s in
                    if case .done(let r) = s { return r }
                    s = .waiting(k)
                    return nil
                }
                if let done { k.resume(with: done) }
            }
        }
    }
}

extension JSPromise {
    /// Phase 1 (synchronous): register `then` now. The fulfilled value is decoded
    /// as T inside JSC's callback frame, on the JS thread; a rejection becomes
    /// JSError. A resolved promise's reactions run when the outermost API call
    /// returns, possibly before anyone awaits: JSPending buffers.
    /// Phase 2: `try await pending.value`, from anywhere.
    @available(*, noasync)
    public func settle<T: JSDecodable & Sendable>(as: T.Type) throws -> JSPending<T> {
        let pending = JSPending<T>()
        try then(as: T.self) { pending.settle($0) }
        return pending
    }
}

// MARK: - Swift async -> JS promise

/// A host function whose work is async. The synchronous prelude reads the
/// arguments into Swift values while JSC's frame still roots them, and returns
/// the async work. JS receives a promise; it settles on the JS thread (through
/// `executor`) when the work finishes. The promise's resolve/reject functions
/// are VM-owned roots that only the JS thread touches.
public struct JSAsyncFunction<T: JSConvertible & Sendable>: JSConvertible {
    let executor: JSExecutor
    let prelude: (borrowing JSArguments) throws -> @Sendable () async throws -> T

    public init(on executor: JSExecutor,
                _ prelude: @escaping (borrowing JSArguments) throws -> @Sendable () async throws -> T) {
        self.executor = executor
        self.prelude = prelude
    }

    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ k: (JSRef) throws -> R) throws -> R {
        let executor = self.executor, prelude = self.prelude
        let function = JSFunction { args in
            let work = try prelude(args)
            let ctx = unsafe args.ctx
            var resolve: JavaScriptCore.JSObjectRef? = nil, reject: JavaScriptCore.JSObjectRef? = nil
            let promise = try unsafe checked(in: ctx) { unsafe JSObjectMakeDeferredPromise(ctx, &resolve, &reject, $0) }!
            let settler = unsafe PromiseSettler(resolve: JSRooted(protecting: resolve!, in: ctx),
                                                reject: JSRooted(protecting: reject!, in: ctx))
            Task.detached {
                let result = await Result { try await work() }
                executor.run { settler.settle(result) }
            }
            return .rooted(unsafe JSRooted(protecting: promise, in: ctx))
        }
        return try function.withJSValue(in: scope, k)
    }
}

/// resolve/reject of a deferred promise. Created and used only on the JS thread;
/// it crosses to the Task and back without being touched there.
final class PromiseSettler: @unchecked Sendable {
    let resolve: JSRooted, reject: JSRooted
    init(resolve: consuming JSRooted, reject: consuming JSRooted) { self.resolve = resolve; self.reject = reject }

    /// On the JS thread, synchronously.
    func settle<T: JSConvertible>(_ result: Result<T, any Error>) {
        guard resolve.table.alive else { return }      // the VM is gone: nothing to settle
        do {
            switch result {
            case .success(let value):
                let resolveValue = resolve.value
                guard let f = resolveValue.function else { return }
                try f.call(value)
            case .failure(let error):
                let message = (error as? JSError)?.message ?? "\(error)"
                let rejectValue = reject.value
                guard let f = rejectValue.function else { return }
                try f.call(JSErrorValue(message: message))
            }
        } catch {
            // A throwing resolve/reject (should not happen for a deferred promise): nothing to report to.
        }
    }
}

/// A JS `Error` object with a message, as a Swift value.
public struct JSErrorValue: JSConvertible, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public func withJSValue<R: ~Copyable>(in scope: JSScope, _ body: (JSRef) throws -> R) throws -> R {
        let raw = try unsafe withJSString(message) { m throws(JSError) in
            var arg: JSValueRef? = unsafe JSValueMakeString(scope.ctx, m)
            return try unsafe checked(in: scope.ctx) { unsafe JSObjectMakeError(scope.ctx, 1, &arg, $0) }
        }!
        return try unsafe withStackRoot(raw, in: scope.ctx, body)
    }
}

// MARK: - An actor that is the JS thread

/// Conform an actor and give it the JSExecutor; its jobs then run on the JS
/// thread. (Keeps UnownedSerialExecutor, which strict memory safety treats as
/// unsafe, inside the library.)
public protocol JSThreadActor: Actor {
    nonisolated var jsExecutor: JSExecutor { get }
}
extension JSThreadActor {
    public nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe jsExecutor.asUnownedSerialExecutor() }
}
