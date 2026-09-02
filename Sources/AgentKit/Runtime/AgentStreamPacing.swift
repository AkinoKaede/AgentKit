import Foundation

/// How fast streamed text is handed to the reader, if it is paced at all.
///
/// Off by default, and that is the honest default: pacing is a property of the
/// surface, not of the agent. A terminal printing deltas, a server writing SSE
/// to its own client, or a test collecting events all want every delta the
/// moment it arrives, and a paced stream would only add latency they cannot use.
/// A view that animates text is the case that wants this — providers deliver in
/// uneven bursts, and drawing those bursts directly reads as stuttering.
///
/// Pacing never changes what the model produced. Deltas are buffered and
/// re-emitted in order, and `messageFinished` carries the whole message however
/// the deltas were spaced — see `AgentTurnDriver`.
public nonisolated struct AgentStreamPacing: Equatable, Sendable {
    /// One widening of the text cadence once a reply has passed a length.
    ///
    /// A long answer arrives faster than anyone reads it, so holding the early
    /// cadence would only build a backlog that finishes long after the model
    /// did. Steps are checked in order and the last one whose threshold has been
    /// passed wins.
    public nonisolated struct Step: Equatable, Sendable {
        public var afterCharacters: Int
        public var configuration: BalancedEmitter.Configuration

        public init(afterCharacters: Int, configuration: BalancedEmitter.Configuration) {
            self.afterCharacters = afterCharacters
            self.configuration = configuration
        }
    }

    public var reasoning: BalancedEmitter.Configuration
    public var text: BalancedEmitter.Configuration
    public var textSteps: [Step]

    public init(
        reasoning: BalancedEmitter.Configuration,
        text: BalancedEmitter.Configuration,
        textSteps: [Step] = []
    ) {
        self.reasoning = reasoning
        self.text = text
        self.textSteps = textSteps
    }

    /// What a chat view wants: reasoning at a steady thirty updates a second,
    /// answer text starting brisk and widening as the reply grows.
    public static let animated = AgentStreamPacing(
        reasoning: .init(duration: .seconds(1), frequency: 30),
        text: .init(duration: .milliseconds(500), frequency: 20),
        textSteps: [
            .init(
                afterCharacters: 1_000,
                configuration: .init(duration: .milliseconds(500), frequency: 15)
            ),
            .init(
                afterCharacters: 2_000,
                configuration: .init(duration: .seconds(1), frequency: 9)
            ),
            .init(
                afterCharacters: 5_000,
                configuration: .init(duration: .seconds(1), frequency: 3)
            ),
        ]
    )

    /// The cadence for a reply of this length, or `nil` while the initial one
    /// still applies.
    func step(atCharacters count: Int) -> BalancedEmitter.Configuration? {
        textSteps.last { count >= $0.afterCharacters }?.configuration
    }
}

/// The one path a delta takes to the channel, paced or not.
///
/// Its whole purpose is that `AgentTurnDriver` reads the same either way: no
/// `if let emitter` around every `add`, and no second code path to keep
/// consistent. When pacing is off, `add` emits synchronously and `wait` returns
/// immediately, which is exactly what an unpaced stream means.
actor AgentDeltaEmitter {
    private let emitter: BalancedEmitter?
    private let direct: @Sendable (String) -> Void

    init(
        configuration: BalancedEmitter.Configuration?,
        emit: @escaping @Sendable (String) -> Void
    ) {
        direct = emit
        emitter = configuration.map { configuration in
            BalancedEmitter(configuration: configuration) { text in emit(text) }
        }
    }

    func add(_ text: String) async {
        guard let emitter else { return direct(text) }
        await emitter.add(text)
    }

    func update(_ configuration: BalancedEmitter.Configuration) async {
        await emitter?.update(configuration)
    }

    /// Drains whatever is buffered, so an ordering guarantee the caller needs —
    /// reasoning before answer text, both before a tool call — holds.
    func wait() async throws {
        try await emitter?.wait()
    }

    func cancel() async {
        await emitter?.cancel()
    }
}
