import Foundation

/// Reversible names for providers whose tool protocols have no namespace field.
public nonisolated struct AgentProviderToolNameMap: Sendable {
    public init(
        qualifiedToWire: [String: String],
        wireToQualified: [String: String]
    ) {
        self.qualifiedToWire = qualifiedToWire
        self.wireToQualified = wireToQualified
    }

    public var qualifiedToWire: [String: String]
    public var wireToQualified: [String: String]

    public static func flat(_ descriptors: [AgentToolDescriptor]) -> Self {
        var qualifiedToWire: [String: String] = [:]
        var wireToQualified: [String: String] = [:]
        var taken = Set<String>()
        let builtIns = descriptors.filter { $0.namespace == nil }
            .sorted { $0.name < $1.name }
        for descriptor in builtIns {
            taken.insert(descriptor.name)
            qualifiedToWire[descriptor.qualifiedName] = descriptor.name
            wireToQualified[descriptor.name] = descriptor.qualifiedName
        }
        let namespaced = descriptors.filter { $0.namespace != nil }
            .sorted { $0.qualifiedName < $1.qualifiedName }
        for descriptor in namespaced {
            let base = "mcp__\(descriptor.namespace!)__\(descriptor.name)"
            var wire = base
            var suffix = 2
            while taken.contains(wire) {
                wire = "\(base)_\(suffix)"
                suffix += 1
            }
            taken.insert(wire)
            qualifiedToWire[descriptor.qualifiedName] = wire
            wireToQualified[wire] = descriptor.qualifiedName
        }
        return Self(qualifiedToWire: qualifiedToWire, wireToQualified: wireToQualified)
    }

    public func wireName(for qualifiedName: String) -> String {
        if let wire = qualifiedToWire[qualifiedName] { return wire }
        guard let separator = qualifiedName.firstIndex(of: ".") else {
            return qualifiedName
        }
        let namespace = qualifiedName[..<separator]
        let name = qualifiedName[qualifiedName.index(after: separator)...]
        return "mcp__\(namespace)__\(name)"
    }

    public func qualifiedName(for wireName: String) -> String {
        wireToQualified[wireName] ?? wireName
    }
}
