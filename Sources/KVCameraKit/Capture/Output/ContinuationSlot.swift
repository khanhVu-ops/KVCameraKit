import Foundation

/// One pending continuation, guarded.
///
/// Delegate callbacks arrive on a queue AVFoundation owns, while the continuation is
/// installed from `sessionQueue`. Two queues touching the same slot is a data race with
/// two visible outcomes: a continuation resumed twice (crash) or one dropped (a `Task`
/// that never finishes).
///
/// The slot doubles as the one-at-a-time guard — `install` refusing is how a second
/// shutter tap gets dropped instead of overwriting the first frame's continuation.
///
/// Generic because photo and video need exactly this twice. They used to share a single
/// `NSLock` over two unrelated slots, which coupled a capture to a recording for no
/// reason; one lock each is both simpler and less contended.
final class ContinuationSlot<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var pending: CheckedContinuation<Value, Error>?

    /// `true` when the slot was free and the continuation now owns the operation.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pending == nil else { return false }
        pending = continuation
        return true
    }

    /// Takes the continuation out, so it can only ever be resumed once.
    func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = pending
        pending = nil
        return taken
    }
}
