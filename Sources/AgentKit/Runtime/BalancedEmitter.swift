import Foundation

/// Smooths a burst of streamed text into a bounded number of ordered updates.
///
/// Adapted from `BalancedEmitter` in LanguageModelChatUI by Lakr233. The
/// original project is distributed under the MIT License.
public actor BalancedEmitter {
    public nonisolated struct Configuration: Equatable, Sendable {
        public var duration: Duration
        public var frequency: Int

        public init(duration: Duration, frequency: Int) {
            precondition(duration > .zero)
            precondition(frequency > 0)
            self.duration = duration
            self.frequency = frequency
        }
    }

    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Emit = @Sendable (String) async -> Void

    private var buffer = ""
    private var configuration: Configuration
    private var batchSize = 1
    private var drainTask: Task<Void, Never>?
    private var generation = 0
    private let sleep: Sleep
    private let onEmit: Emit

    public init(
        configuration: Configuration,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        onEmit: @escaping Emit
    ) {
        self.configuration = configuration
        self.sleep = sleep
        self.onEmit = onEmit
    }

    public func update(_ configuration: Configuration) {
        self.configuration = configuration
        recalculateBatchSize()
    }

    public func add(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        buffer += chunk
        recalculateBatchSize()
        dispatchLoopIfRequired()
    }

    public func wait() async throws {
        try await withTaskCancellationHandler {
            await drainTask?.value
            try Task.checkCancellation()
        } onCancel: { [weak self] in
            Task { await self?.cancel() }
        }
    }

    public func cancel() {
        buffer = ""
        generation += 1
        drainTask?.cancel()
        drainTask = nil
    }

    private func recalculateBatchSize() {
        batchSize = max(1, Int(ceil(Double(buffer.count) / Double(configuration.frequency))))
    }

    private func dispatchLoopIfRequired() {
        guard drainTask == nil else { return }
        let generation = generation
        drainTask = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drain(generation: Int) async {
        defer {
            if self.generation == generation { drainTask = nil }
        }

        while !Task.isCancelled, self.generation == generation, !buffer.isEmpty {
            let emitCount = min(batchSize, buffer.count)
            let emitted = String(buffer.prefix(emitCount))
            buffer.removeFirst(emitted.count)
            await onEmit(emitted)

            guard !buffer.isEmpty else { break }
            let delay = configuration.duration / configuration.frequency
            do {
                try await sleep(delay)
            } catch {
                break
            }
        }
    }
}
