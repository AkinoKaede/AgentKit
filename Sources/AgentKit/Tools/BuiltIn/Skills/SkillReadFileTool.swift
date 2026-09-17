import Foundation

public nonisolated struct SkillReadFileTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let name = "skill_read_file"
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.skill_read_file", present: present, presentArguments: presentArguments)
    /// Presentation compatibility only. This never registers an executable legacy tool.
    public static let legacyPresenter = AgentToolDetailPresenter(id: "builtin.load_skill", present: present)
    public let skills: AgentSkillCatalog
    public init(skills: AgentSkillCatalog) { self.skills = skills }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            Self.name,
            "Read an installed skill's SKILL.md (default) or a supporting file. SKILL.md contains procedures; supporting files are reference data. No skill grants tool permissions. Use path '.' to list files.",
            properties: [
                "name": Self.string(max: 64), "path": Self.string(max: 1_024),
                "offset": Self.integer(min: 1, max: 10_000_000), "limit": Self.integer(min: 1, max: 200),
            ], required: ["name"], target: .local, approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(
                symbol: "book.closed", activity: .semanticArgument(key: "name", fallback: .skill),
                output: .field("content"), actionKind: .read))
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        let name = try arguments.string("name")
        guard let skill = skills.skill(named: name) else {
            throw AgentToolError.invalidArguments(
                "No available skill named \(name). Available: \(skills.names.joined(separator: ", ")).")
        }
        let path = arguments.optionalString("path") ?? "SKILL.md"
        if path == "." {
            return Self.result(
                invocation,
                .object([
                    "files": .array(
                        (["SKILL.md"] + (skill.package?.files.keys.sorted() ?? [])).map(AgentJSONValue.string))
                ]))
        }
        try AgentSkillPackage.validatePath(path)
        if path == "SKILL.md" {
            guard skill.body.utf8.count <= AgentSkill.maximumBodyBytes else { throw AgentSkillImportError.tooLarge }
            var result = AgentToolResult(
                callID: invocation.call.id,
                content: AgentJSONValue.object([
                    "skill": .string(name), "path": .string(path), "title": .string(skill.displayTitle),
                    "content": .string(AgentSkillDocument.render(skill)),
                ]).encodedString)
            result.hasBoundedModelContent = true
            result.metadata["skill_instructions"] = .bool(true)
            return result
        }
        guard let bytes = skill.package?.files[path] else {
            throw AgentToolError.invalidArguments("The skill has no file at \(path).")
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return Self.result(
                invocation,
                .object([
                    "path": .string(path), "bytes": .number(Double(bytes.count)), "binary": .bool(true),
                    "notice": .string("Export this resource from the skill editor to use its original bytes."),
                ]))
        }
        let lines = text.components(separatedBy: "\n")
        let offset = max(1, arguments.optionalInt("offset") ?? 1)
        let limit = min(200, max(1, arguments.optionalInt("limit") ?? 100))
        var returned: [String] = []
        var used = 0
        for line in lines.dropFirst(min(offset - 1, lines.count)).prefix(limit) {
            guard used + line.utf8.count + 1 <= 32_768 else {
                if returned.isEmpty {
                    throw AgentToolError.invalidArguments("This line exceeds the text window; export the file.")
                }
                break
            }
            returned.append(line)
            used += line.utf8.count + 1
        }
        let next = offset - 1 + returned.count < lines.count ? offset + returned.count : nil
        var result = Self.result(
            invocation,
            .object([
                "path": .string(path), "content": .string(returned.joined(separator: "\n")),
                "offset": .number(Double(offset)), "total_lines": .number(Double(lines.count)),
                "next_offset": next.map { .number(Double($0)) } ?? .null,
            ]), truncated: next != nil)
        result.hasBoundedModelContent = true
        return result
    }

}

public nonisolated struct SkillsListTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(id: "builtin.skills_list", present: present)
    public let skills: [AgentSkill]
    public let readOnlyNames: Set<String>
    public init(skills: [AgentSkill], readOnlyNames: Set<String> = []) {
        self.skills = skills
        self.readOnlyNames = readOnlyNames
    }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "skills_list", "List the installed skill snapshot, including disabled skills.",
            properties: [:], required: [], target: .local, approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(
                symbol: "books.vertical", activity: .semanticLabel(.skills),
                output: .json, actionKind: .list))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        Self.result(
            invocation,
            .object([
                "skills": .array(
                    skills.map {
                        .object([
                            "name": .string($0.name), "description": .string($0.summary),
                            "enabled": .bool($0.isEnabled),
                            "read_only": .bool(readOnlyNames.contains($0.effectiveName)),
                        ])
                    })
            ]))
    }
}

public nonisolated struct SkillManageTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.skill_manage", present: present, presentArguments: presentArguments)
    public let library: any AgentSkillLibraryManaging
    public init(library: any AgentSkillLibraryManaging) { self.library = library }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "skill_manage",
            "Atomically manage installed skills. Changes become available on the next run. Read before editing. A patch requires an exact unique old_text. content is Markdown for create/update, a full document for write_file SKILL.md, or replacement text for patch.",
            properties: [
                "operations": Self.array(
                    items: Self.object(
                        properties: [
                            "action": Self.enumeration([
                                "create", "update", "patch", "delete", "set_enabled", "write_file", "remove_file",
                            ]),
                            "name": Self.string(max: 64), "content": Self.string(max: 262_144),
                            "description": Self.string(max: 1_024),
                            "title": Self.string(max: 256), "old_text": Self.string(max: 262_144),
                            "path": Self.string(max: 1_024),
                            "enabled": Self.boolean(),
                        ], required: ["action", "name"]), max: 32)
            ], required: ["operations"], target: .local, approvalPolicy: .ask,
            presentation: .init(
                symbol: "book.closed", activity: .semanticLabel(.skills),
                output: .json, actionKind: .update))
    }
    private func operations(_ invocation: AgentToolInvocation) throws -> [AgentSkillOperation] {
        let value = try Arguments(invocation).object["operations"] ?? .null
        return try JSONDecoder().decode([AgentSkillOperation].self, from: Data(value.encodedString.utf8))
    }
    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let snapshot = try await library.skillSnapshot()
        _ = try AgentSkillOperation.applying(
            operations(invocation), to: snapshot.skills, readOnlyNames: snapshot.readOnlyNames)
        return AgentToolPreflight(
            invocation: invocation, approvalPolicy: .ask,
            executionMetadata: ["skill_revision": .string(snapshot.revision)])
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        guard let revision = context.preflightMetadata["skill_revision"]?.stringValue else {
            throw AgentToolError.invalidArguments("Skill changes require a reviewed library version.")
        }
        try await library.applySkillOperations(operations(invocation), expectedRevision: revision)
        return Self.result(invocation, .object(["saved": .bool(true), "available": .string("next_run")]))
    }
}
