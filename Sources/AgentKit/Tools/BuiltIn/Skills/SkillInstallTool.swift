import Foundation

/// A downloaded package, resolved to immutable source content. Nothing here writes to the user's library.
public nonisolated struct AgentResolvedSkillPackage: Sendable {
    public var document: AgentSkillDocument
    public var sourceURL: String
    public var revision: String
    public init(document: AgentSkillDocument, sourceURL: String, revision: String) {
        self.document = document
        self.sourceURL = sourceURL
        self.revision = revision
    }
}

public nonisolated protocol AgentSkillPackageResolving: Sendable {
    func resolve(sourceURL: String) async throws -> AgentResolvedSkillPackage
}

/// Construct per run. Reviewed bytes live only in this tool's bounded, in-memory staging area.
public nonisolated struct SkillInstallTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.skill_install", present: SkillManageTool.present)
    private let library: any AgentSkillLibraryManaging
    private let resolver: any AgentSkillPackageResolving
    private let staging = SkillInstallStaging()

    public init(library: any AgentSkillLibraryManaging, resolver: any AgentSkillPackageResolving) {
        self.library = library
        self.resolver = resolver
    }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "skill_install",
            "Install a complete public GitHub skill directory, including resources. Supply a GitHub directory or SKILL.md URL. Optionally choose a different name. Never overwrites existing skills. Changes are available on the next run; no scripts are executed.",
            properties: ["source_url": Self.string(max: 2_048), "name": Self.string(max: 64)],
            required: ["source_url"], target: .local, approvalPolicy: .ask,
            presentation: .init(
                symbol: "square.and.arrow.down", activity: .semanticArgument(key: "name", fallback: .skill),
                output: .json, actionKind: .write))
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let arguments = try Arguments(invocation)
        let resolved = try await resolver.resolve(sourceURL: arguments.string("source_url"))
        let name = arguments.optionalString("name") ?? resolved.document.name
        let skill = AgentSkill(
            name: name, title: name, summary: resolved.document.description, body: resolved.document.body,
            importedFrom: resolved.sourceURL, package: resolved.document.package)
        let snapshot = try await library.skillSnapshot()
        _ = try snapshot.adding(skill)
        try Task.checkCancellation()
        var reviewed = invocation
        var facts = arguments.object
        facts["name"] = .string(name)
        facts["resolved_source"] = .string(resolved.sourceURL)
        facts["commit"] = .string(resolved.revision)
        facts["description"] = .string(skill.summary)
        facts["files"] = .array(
            (["SKILL.md"] + resolved.document.package.files.keys.sorted()).map(AgentJSONValue.string))
        facts["bytes"] = .number(
            Double(
                AgentSkillDocument.render(skill).utf8.count
                    + resolved.document.package.files.values.reduce(0) { $0 + $1.count }))
        facts["warnings"] = .array(resolved.document.warnings.map(AgentJSONValue.string))
        reviewed.call.arguments = .object(facts)
        let token = try await staging.insert(skill: skill, invocation: reviewed, revision: snapshot.revision)
        return AgentToolPreflight(
            invocation: reviewed, approvalPolicy: .ask,
            executionMetadata: ["skill_install_token": .string(token)])
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        guard let token = context.preflightMetadata["skill_install_token"]?.stringValue,
            let draft = await staging.take(token: token, invocation: invocation)
        else { throw AgentToolError.invalidArguments("The reviewed package expired. Request installation again.") }
        try Task.checkCancellation()
        try await library.installSkill(draft.skill, expectedRevision: draft.revision)
        return Self.result(
            invocation,
            .object([
                "saved": .bool(true), "name": .string(draft.skill.name), "source": .string(draft.skill.importedFrom),
                "available": .string("next_run"),
            ]))
    }
}

private actor SkillInstallStaging {
    struct Draft: Sendable {
        var skill: AgentSkill
        var invocation: AgentToolInvocation
        var revision: String
    }
    private var drafts: [(String, Draft)] = []
    func insert(skill: AgentSkill, invocation: AgentToolInvocation, revision: String) throws -> String {
        // Denied calls never execute. Bound their lifetime to this run and cap retained bytes.
        let bytes = drafts.reduce(0) { $0 + Self.byteCount($1.1.skill) } + Self.byteCount(skill)
        guard drafts.count < 32, bytes <= 64 * 1_024 * 1_024 else {
            throw AgentToolError.invalidArguments(
                "Too many packages await approval in this run. Finish this run and retry.")
        }
        let token = UUID().uuidString
        drafts.append((token, Draft(skill: skill, invocation: invocation, revision: revision)))
        return token
    }
    private static func byteCount(_ skill: AgentSkill) -> Int {
        AgentSkillDocument.render(skill).utf8.count + (skill.package?.files.values.reduce(0) { $0 + $1.count } ?? 0)
    }
    func take(token: String, invocation: AgentToolInvocation) -> Draft? {
        guard let index = drafts.firstIndex(where: { $0.0 == token }) else { return nil }
        let draft = drafts.remove(at: index).1
        return draft.invocation == invocation ? draft : nil
    }
}
