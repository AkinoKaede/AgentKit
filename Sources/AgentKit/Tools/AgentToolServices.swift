import Foundation

/// Names one host-owned service and the type it hands back.
///
/// A key rather than a protocol requirement because the runtime has no opinion
/// about what is in the bag. `id` is the whole identity, so two hosts that both
/// want "the credential prompt" agree by writing the same string than by sharing
/// a type.
public nonisolated struct AgentToolServiceKey<Service: Sendable>: Hashable, Sendable {
    public let id: String

    public init(_ id: String) { self.id = id }
}

/// What a host lends to the tools it registered.
///
/// The runtime's own tools never read this. It exists so a tool an application
/// adds can reach something that application owns — a credential prompt, a
/// database handle, a device — without that thing having to appear in a runtime
/// protocol that every other adopter would then inherit. `AgentToolExecutor`
/// carries the bag and hands it to each call; nothing in it is persisted, sent
/// to a model, or shown in an approval.
///
/// Values are stored under `AgentToolServiceKey`, so a host that stores the
/// wrong type for a key cannot compile rather than failing at the call.
public nonisolated struct AgentToolServices: Sendable {
    private var storage: [String: any Sendable] = [:]

    public init() {}

    public subscript<Service: Sendable>(key: AgentToolServiceKey<Service>) -> Service? {
        get { storage[key.id] as? Service }
        set { storage[key.id] = newValue }
    }

    /// The chaining form, so a caller can build the bag in the argument list it
    /// is passing rather than needing a `var` and three statements.
    public func setting<Service: Sendable>(
        _ service: Service, for key: AgentToolServiceKey<Service>
    ) -> AgentToolServices {
        var copy = self
        copy[key] = service
        return copy
    }
}
