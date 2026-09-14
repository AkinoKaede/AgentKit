import Foundation

/// The resolved tool set for one run, with the name collisions already settled.
public nonisolated struct AgentToolRegistry: Sendable {
    private let registrations: [AnyAgentTool]

    /// First registration wins within each run mode.
    ///
    /// The same qualified name may be registered again for disjoint modes with
    /// a different schema, preflight, or implementation. An overlapping later
    /// registration loses only the modes already claimed, preserving the
    /// built-in-before-remote shadowing boundary.
    public init(_ tools: [AnyAgentTool]) {
        var claimed: [String: Set<AgentRunMode>] = [:]
        var accepted: [AnyAgentTool] = []
        for tool in tools {
            let name = tool.descriptor.qualifiedName
            let remaining = tool.availableIn.subtracting(claimed[name] ?? [])
            guard !remaining.isEmpty else { continue }
            accepted.append(tool.restricting(to: remaining))
            claimed[name, default: []].formUnion(remaining)
        }
        registrations = accepted
    }

    public subscript(name: String) -> AnyAgentTool? {
        registrations.first { $0.descriptor.qualifiedName == name }
    }

    public func filtering(
        _ isIncluded: (AgentToolDescriptor) -> Bool
    ) -> AgentToolRegistry {
        AgentToolRegistry(registrations.filter { isIncluded($0.descriptor) })
    }

    /// The definitions advertised and executable for one run posture.
    ///
    /// A new registry, rather than a descriptor-only projection, keeps the
    /// model-facing schema and the executor's lookup on the same capability set.
    public func available(in mode: AgentRunMode) -> AgentToolRegistry {
        AgentToolRegistry(
            registrations.compactMap { tool in
                tool.availableIn.contains(mode) ? tool.restricting(to: [mode]) : nil
            }
        )
    }

    /// Sorted, because the tool list is part of the request's cacheable prefix
    /// and a dictionary's iteration order is not stable across launches.
    public var descriptors: [AgentToolDescriptor] {
        var seen = Set<String>()
        return registrations.map(\.descriptor)
            .filter { seen.insert($0.qualifiedName).inserted }
            .sorted { $0.qualifiedName < $1.qualifiedName }
    }

    /// Primarily useful to focused tests and secondary export surfaces that
    /// need to execute the same catalog-resolved definitions.
    public var registeredTools: [AnyAgentTool] {
        registrations.enumerated().sorted {
            let left = $0.element.descriptor.qualifiedName
            let right = $1.element.descriptor.qualifiedName
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
}
