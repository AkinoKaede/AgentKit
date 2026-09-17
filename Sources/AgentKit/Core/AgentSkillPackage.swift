import CryptoKit
import Foundation

/// Additional files and inert frontmatter belonging to an installed skill.
/// SKILL.md is rendered from AgentSkill so there is only one copy of its editable body.
public nonisolated struct AgentSkillPackage: Codable, Hashable, Sendable {
    public static let maximumFiles = 128
    public static let maximumFileBytes = 4 * 1_024 * 1_024
    public static let maximumBytes = 16 * 1_024 * 1_024
    public var frontmatter: String
    public var files: [String: Data]

    public init(frontmatter: String = "", files: [String: Data] = [:]) {
        self.frontmatter = frontmatter
        self.files = files
    }

    public static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1_024,
            !path.contains("\\"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw AgentToolError.invalidArguments("Use a relative path inside the skill package.") }
    }

    public func validate() throws {
        guard files.count <= Self.maximumFiles,
            frontmatter.utf8.count <= AgentSkill.maximumBodyBytes,
            files.values.reduce(0, { $0 + $1.count }) <= Self.maximumBytes
        else { throw AgentToolError.invalidArguments("The skill package exceeds its size limit.") }
        for (path, bytes) in files {
            try Self.validatePath(path)
            guard path != "SKILL.md", bytes.count <= Self.maximumFileBytes else {
                throw AgentToolError.invalidArguments("Invalid or oversized supporting file: \(path).")
            }
        }
    }
}

public nonisolated struct AgentSkillLibrarySnapshot: Sendable {
    public var skills: [AgentSkill]
    public let revision: String
    public let readOnlyNames: Set<String>

    public init(_ skills: [AgentSkill], readOnlyNames: Set<String> = []) {
        self.skills = skills
        self.readOnlyNames = readOnlyNames
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data =
            ((try? encoder.encode(skills)) ?? Data())
            + ((try? encoder.encode(readOnlyNames.sorted())) ?? Data())
        revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Hosts commit the entire batch and its sync intent atomically, or throw without changing the library.
public nonisolated protocol AgentSkillLibraryManaging: Sendable {
    func skillSnapshot() async throws -> AgentSkillLibrarySnapshot
    func applySkillOperations(_ operations: [AgentSkillOperation], expectedRevision: String) async throws
    func installSkill(_ skill: AgentSkill, expectedRevision: String) async throws
}

extension AgentSkillLibraryManaging {
    public func installSkill(_ skill: AgentSkill, expectedRevision: String) async throws {
        throw AgentToolError.invalidArguments("This library does not support package installation.")
    }
}

extension AgentSkillLibrarySnapshot {
    public func adding(_ skill: AgentSkill) throws -> [AgentSkill] {
        guard !readOnlyNames.contains(skill.effectiveName),
            !skills.contains(where: { $0.effectiveName == skill.effectiveName || $0.id == skill.id })
        else {
            throw AgentToolError.invalidArguments(
                "The skill name is reserved or already installed. Choose another name.")
        }
        try skill.validateForInstallation()
        return skills + [skill]
    }
}

extension AgentSkill {
    public func validateForInstallation() throws {
        guard isComplete, body.utf8.count <= Self.maximumBodyBytes,
            summary.count <= Self.maximumSummaryCharacters
        else { throw AgentToolError.invalidArguments("A skill needs a bounded description and non-empty body.") }
        try package?.validate()
        try AgentKnowledgeContentScanner.validate(body)
        try AgentKnowledgeContentScanner.validate(summary)
        if let package { try AgentKnowledgeContentScanner.validate(package.frontmatter) }
        for data in package?.files.values ?? [String: Data]().values {
            if let text = String(data: data, encoding: .utf8) { try AgentKnowledgeContentScanner.validate(text) }
        }
    }
}

public nonisolated struct AgentSkillOperation: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable {
        case create, update, patch, delete
        case setEnabled = "set_enabled"
        case writeFile = "write_file"
        case removeFile = "remove_file"
    }
    public var action: Action
    public var name: String
    public var content: String?
    public var description: String?
    public var title: String?
    public var oldText: String?
    public var path: String?
    public var enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case action, name, content, description, title, path, enabled
        case oldText = "old_text"
    }

    public init(
        action: Action, name: String, content: String? = nil, description: String? = nil,
        title: String? = nil, oldText: String? = nil, path: String? = nil, enabled: Bool? = nil
    ) {
        self.action = action
        self.name = name
        self.content = content
        self.description = description
        self.title = title
        self.oldText = oldText
        self.path = path
        self.enabled = enabled
    }

    public static func applying(
        _ operations: [Self], to original: [AgentSkill], readOnlyNames: Set<String> = []
    ) throws -> [AgentSkill] {
        guard !operations.isEmpty, operations.count <= 32 else {
            throw AgentToolError.invalidArguments("Supply between 1 and 32 skill operations.")
        }
        var skills = original
        for operation in operations {
            guard !readOnlyNames.contains(operation.name) else {
                throw AgentToolError.invalidArguments(
                    "This built-in skill is read-only. Create a skill with another name.")
            }
            guard AgentSkillNaming.isValid(operation.name) else {
                throw AgentToolError.invalidArguments("Invalid skill name: \(operation.name).")
            }
            let matches = skills.indices.filter { skills[$0].effectiveName == operation.name }
            if operation.action == .create {
                guard matches.isEmpty, let body = operation.content, let summary = operation.description else {
                    throw AgentToolError.invalidArguments("Create needs a unique name, description, and content.")
                }
                skills.append(
                    AgentSkill(name: operation.name, title: operation.title ?? "", summary: summary, body: body))
            } else {
                guard matches.count == 1, let index = matches.first else {
                    throw AgentToolError.invalidArguments("The skill name must identify exactly one installed skill.")
                }
                var skill = skills[index]
                switch operation.action {
                case .create: break
                case .delete:
                    skills.remove(at: index)
                    continue
                case .setEnabled:
                    guard let enabled = operation.enabled else {
                        throw AgentToolError.invalidArguments("enabled is required.")
                    }
                    skill.isEnabled = enabled
                case .update:
                    if let content = operation.content { skill.body = content }
                    if let summary = operation.description { skill.summary = summary }
                    if let title = operation.title { skill.title = title }
                case .patch, .writeFile, .removeFile:
                    let path = operation.path ?? "SKILL.md"
                    try AgentSkillPackage.validatePath(path)
                    if operation.action == .removeFile {
                        guard path != "SKILL.md", skill.package?.files[path] != nil else {
                            throw AgentToolError.invalidArguments(
                                "Remove an existing supporting file, or delete the skill.")
                        }
                        skill.package?.files.removeValue(forKey: path)
                    } else {
                        guard var content = operation.content else {
                            throw AgentToolError.invalidArguments("content is required.")
                        }
                        if operation.action == .patch {
                            let data =
                                path == "SKILL.md"
                                ? Data(AgentSkillDocument.render(skill).utf8) : skill.package?.files[path]
                            guard let data, let original = String(data: data, encoding: .utf8),
                                let old = operation.oldText, !old.isEmpty,
                                original.components(separatedBy: old).count == 2
                            else {
                                throw AgentToolError.invalidArguments(
                                    "old_text must match exactly once in a UTF-8 file.")
                            }
                            content = original.replacingOccurrences(of: old, with: content)
                        }
                        if path == "SKILL.md" {
                            let document = try AgentSkillDocument.parse(content)
                            guard document.name == skill.name else {
                                throw AgentToolError.invalidArguments("A saved skill's name cannot be changed.")
                            }
                            skill.summary = document.description
                            skill.body = document.body
                            var package = skill.package ?? AgentSkillPackage()
                            package.frontmatter = document.package.frontmatter
                            skill.package = package
                        } else {
                            var package = skill.package ?? AgentSkillPackage()
                            package.files[path] = Data(content.utf8)
                            skill.package = package
                        }
                    }
                }
                skill.updatedAt = .now
                skills[index] = skill
            }
        }
        for skill in skills where operations.contains(where: { $0.name == skill.name && $0.action != .delete }) {
            try skill.validateForInstallation()
        }
        return skills
    }
}
