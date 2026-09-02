import Foundation

/// Says that the user has interjected and is waiting for a model boundary.
///
/// Broadcast and re-armable, unlike `AgentCompletionSignal`: a run has many
/// boundaries and a user may interject at any of them, so every waiter is
/// released and the next waiter waits again for the next one.
///
/// This exists so a tool whose whole job is waiting can stop. It is offered to
/// tools rather than done to them, because whether an interruption is free
/// depends entirely on what is being interrupted: giving up on a tool that is
/// only watching costs nothing — the work runs on, its handle stays valid —
/// while giving up on one that dispatched work elsewhere would strand it.
public nonisolated final class AgentInterjectionSignal: @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var isPending = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Something is queued for the next boundary. Stateful rather than a pure
    /// broadcast, because a wait that began a moment *after* the user typed
    /// would otherwise sit through its whole deadline with a message already
    /// waiting behind it.
    public func arm() {
        let released = lock.withLock {
            isPending = true
            defer { waiters.removeAll() }
            return waiters.values
        }
        for waiter in released { waiter.resume() }
    }

    /// The queue has been drained into the turn about to start, so there is
    /// nothing left to hurry for.
    public func disarm() { lock.withLock { isPending = false } }

    public func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let armed: Bool = lock.withLock {
                    if isPending { return true }
                    waiters[id] = continuation
                    return false
                }
                if armed { continuation.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }
}
