import Darwin
import Foundation

/// Centralized clearing for short-lived buffers that temporarily contain secrets.
nonisolated enum SecretMemory {
    static func clear(_ bytes: inout Data) {
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
        bytes.removeAll(keepingCapacity: false)
    }
}

public nonisolated enum AgentSecretError: Error, Sendable, Equatable {
    case consumed
}

/// One-shot, explicitly wipeable storage for a user-supplied secret.
///
/// The secret is copied out of a freshly created UTF-8 `Data` value into an
/// exclusively owned allocation. Ownership can move without copying through
/// `SecretBroker`; consuming or clearing an instance makes that instance
/// unreadable, and every owned allocation is overwritten before release.
public nonisolated final class AgentSecret: @unchecked Sendable, Hashable {
    private struct Storage {
        var pointer: UnsafeMutableRawPointer
        var count: Int

        func clearAndDeallocate() {
            _ = memset_s(pointer, count, 0, count)
            pointer.deallocate()
        }
    }

    private let lock = NSLock()
    private var storage: Storage?

    public init(consumingUTF8 bytes: inout Data) {
        let count = bytes.count
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: max(count, 1),
            alignment: MemoryLayout<UInt8>.alignment
        )
        if count > 0 {
            bytes.withUnsafeBytes { raw in
                guard let source = raw.baseAddress else { return }
                pointer.copyMemory(from: source, byteCount: count)
            }
        }
        SecretMemory.clear(&bytes)
        storage = Storage(pointer: pointer, count: count)
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    deinit { clear() }

    public var isConsumed: Bool {
        lock.withLock { storage == nil }
    }

    /// Borrows the bytes synchronously without creating another plaintext owner.
    public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) throws -> Result {
        try lock.withLock {
            guard let storage else { throw AgentSecretError.consumed }
            return try body(
                UnsafeRawBufferPointer(start: storage.pointer, count: storage.count)
            )
        }
    }

    public func clear() {
        guard let storage = takeStorage() else { return }
        storage.clearAndDeallocate()
    }

    public static func == (lhs: AgentSecret, rhs: AgentSecret) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func transferringOwnership() throws -> AgentSecret {
        guard let storage = takeStorage() else { throw AgentSecretError.consumed }
        return AgentSecret(storage: storage)
    }

    private func takeStorage() -> Storage? {
        lock.withLock {
            let value = storage
            storage = nil
            return value
        }
    }
}
