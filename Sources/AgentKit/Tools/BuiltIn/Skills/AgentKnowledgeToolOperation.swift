import Foundation

nonisolated extension SkillsListTool {
    static func operation(_ arguments: [String: AgentJSONValue]) -> AgentToolOperation {
        .init(action: .list, activity: .skills)
    }
}

nonisolated extension SkillReadFileTool {
    static func operation(_ arguments: [String: AgentJSONValue]) -> AgentToolOperation {
        let path = AgentToolDetailFormatting.nonempty(arguments["path"]?.stringValue) ?? "SKILL.md"
        let listing = path == "."
        let name = AgentToolDetailFormatting.nonempty(arguments["name"]?.stringValue)
        return .init(
            action: listing ? .list : .read, activity: listing ? .init("skillFiles") : .skill,
            batchActivity: .skills, argument: name.map { listing ? $0 : "\($0) / \(path)" })
    }
}

nonisolated extension SkillManageTool {
    static func operation(_ arguments: [String: AgentJSONValue]) -> AgentToolOperation {
        let operations = arguments["operations"]?.arrayValue ?? []
        let names = Set(
            operations.compactMap {
                AgentToolDetailFormatting.nonempty($0.objectValue?["name"]?.stringValue)
            })
        return .init(
            action: .update, activity: .skills, argument: names.count == 1 ? names.first : nil,
            operationCount: operations.count)
    }
}

nonisolated extension SkillInstallTool {
    static func operation(_ arguments: [String: AgentJSONValue]) -> AgentToolOperation {
        .init(
            action: .install, activity: .skill, batchActivity: .skills,
            argument: AgentToolDetailFormatting.nonempty(arguments["name"]?.stringValue))
    }
}

nonisolated extension MemoryTool {
    static func operation(_ arguments: [String: AgentJSONValue]) -> AgentToolOperation {
        let operations = arguments["operations"]?.arrayValue
        // Empty operations were a read in historical calls; they are not executable mutations today.
        return .init(
            action: operations?.isEmpty == true ? .read : .update, activity: .memory,
            operationCount: operations?.count)
    }
}

nonisolated extension MemorySearchTool {
    static func operation(_ arguments: [String: AgentJSONValue]) -> AgentToolOperation {
        .init(
            action: .search, activity: .memory,
            argument: AgentToolDetailFormatting.nonempty(arguments["query"]?.stringValue),
            searchScope: arguments["target"]?.stringValue == "user" ? .init("userProfile") : .memory)
    }
}

nonisolated extension SessionSearchTool {
    static func operation(_ arguments: [String: AgentJSONValue]) -> AgentToolOperation {
        let query = AgentToolDetailFormatting.nonempty(arguments["query"]?.stringValue)
        let reading = AgentToolDetailFormatting.nonempty(arguments["conversation_id"]?.stringValue) != nil
        return .init(
            action: query != nil ? .search : reading ? .read : .list, activity: .sessions,
            argument: query, searchScope: query == nil ? nil : .chats)
    }
}
