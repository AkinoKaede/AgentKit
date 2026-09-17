import CryptoKit
import Foundation
import Testing

@testable import AgentKit

@Suite struct SkillInstallationTests {
    private let commit = String(repeating: "a", count: 40)
    private let rootTree = String(repeating: "b", count: 40)
    private let skillTree = String(repeating: "c", count: 40)
    private let document = "---\nname: example\ndescription: Example procedure\n---\n# Example\nInspect inputs."

    @Test(arguments: [
        "https://github.com/owner/repo/tree/main/example",
        "https://github.com/owner/repo/blob/main/example/SKILL.md",
        "https://raw.githubusercontent.com/owner/repo/refs/heads/main/example/SKILL.md",
    ]) func completePackagesResolveToOneCommit(_ source: String) async throws {
        let network = try fixture()
        let resolved = try await GitHubSkillPackageResolver(transport: network).resolve(sourceURL: source)
        #expect(resolved.revision == commit)
        #expect(resolved.sourceURL == "https://github.com/owner/repo/tree/\(commit)/example")
        #expect(resolved.document.package.files["image.bin"] == Data([0, 255, 1]))
        let requests = await network.requests
        #expect(requests.filter { $0.host == "raw.githubusercontent.com" }.allSatisfy { $0.path.contains(commit) })
    }

    @Test(arguments: ["120000", "160000"])
    func linksAndSubmodulesAreRejectedBeforeContentDownload(_ mode: String) async throws {
        let network = try fixture(mode: mode)
        await #expect(throws: (any Error).self) {
            try await GitHubSkillPackageResolver(transport: network).resolve(
                sourceURL: "https://github.com/owner/repo/tree/main/example")
        }
        #expect(await network.requests.allSatisfy { $0.host != "raw.githubusercontent.com" })
    }

    @Test(arguments: ["../escape", "/absolute", "bad\\name", "nested/file"])
    func invalidTreePathsAreRejected(_ path: String) async throws {
        let network = try fixture(resourcePath: path)
        await #expect(throws: (any Error).self) {
            try await GitHubSkillPackageResolver(transport: network).resolve(
                sourceURL: "https://github.com/owner/repo/tree/main/example")
        }
    }

    @Test func missingOrChangedBytesAndOversizedPackagesFail() async throws {
        for status in [404, 429, 200] {
            let network = try fixture()
            await network.set(
                "https://raw.githubusercontent.com/owner/repo/\(commit)/example/image.bin",
                data: Data([9, 9, 9]), status: status)
            await #expect(throws: (any Error).self) {
                try await GitHubSkillPackageResolver(transport: network).resolve(
                    sourceURL: "https://github.com/owner/repo/tree/main/example")
            }
        }
        for count in [AgentSkillPackage.maximumFileBytes + 1, -1] {
            let network = try fixture(resourceSize: count)
            await #expect(throws: (any Error).self) {
                try await GitHubSkillPackageResolver(transport: network).resolve(
                    sourceURL: "https://github.com/owner/repo/tree/main/example")
            }
        }
    }

    @Test(arguments: [
        "http://github.com/owner/repo", "https://github.com.evil.invalid/owner/repo",
        "https://user:secret@github.com/owner/repo", "https://127.0.0.1/owner/repo",
        "https://github.com/owner/repo/archive/main.zip", "https://github.com/owner/repo?token=abc",
        "https://raw.githubusercontent.com/owner/repo/main/not-a-skill.md",
    ]) func unsupportedSourcesNeverReachTheNetwork(_ source: String) async throws {
        let network = PackageFixtureNetwork()
        await #expect(throws: (any Error).self) {
            try await GitHubSkillPackageResolver(transport: network).resolve(sourceURL: source)
        }
        #expect(await network.requests.isEmpty)
    }

    @Test func readOnlySkillsRejectEveryMutationAndShadowing() throws {
        let skill = AgentSkill(name: "skill-creator", summary: "Create", body: "Instructions")
        for action in [
            AgentSkillOperation.Action.create, .update, .patch, .delete, .setEnabled, .writeFile, .removeFile,
        ] {
            #expect(throws: (any Error).self) {
                try AgentSkillOperation.applying(
                    [
                        .init(
                            action: action, name: skill.name, content: "Changed", description: "Changed", enabled: false
                        )
                    ],
                    to: [skill], readOnlyNames: [skill.name])
            }
        }
        #expect(throws: (any Error).self) {
            try AgentSkillLibrarySnapshot([], readOnlyNames: [skill.name]).adding(skill)
        }
        #expect(
            AgentSkillLibrarySnapshot([skill]).revision
                != AgentSkillLibrarySnapshot([skill], readOnlyNames: [skill.name]).revision)
    }

    @Test func installationUsesReviewedBytesAndCannotReplay() async throws {
        let library = InstallationLibrary()
        let resolver = MutablePackageResolver(package: try package())
        let tool = SkillInstallTool(library: library, resolver: resolver)
        let reviewed = try await tool.preflight(invocation())
        #expect(reviewed.approvalPolicy == .ask)
        #expect(await library.skillSnapshot().skills.isEmpty)
        #expect(reviewed.invocation.call.arguments.objectValue?["commit"]?.stringValue == commit)
        await resolver.replaceBody("Changed remotely after review")
        _ = try await tool.execute(reviewed.invocation, context: context(reviewed))
        let saved = await library.skillSnapshot().skills
        #expect(saved.count == 1)
        #expect(saved[0].body.contains("Inspect inputs"))
        #expect(saved[0].package?.files["image.bin"] == Data([0, 255, 1]))
        await #expect(throws: (any Error).self) {
            try await tool.execute(reviewed.invocation, context: context(reviewed))
        }
    }

    @Test func changedLibraryAndFailedPersistenceNeverPartiallyInstall() async throws {
        for failsSave in [false, true] {
            let library = InstallationLibrary()
            let tool = SkillInstallTool(library: library, resolver: MutablePackageResolver(package: try package()))
            let reviewed = try await tool.preflight(invocation())
            if failsSave { await library.failSaves() } else { await library.addOtherSkill() }
            await #expect(throws: (any Error).self) {
                try await tool.execute(reviewed.invocation, context: context(reviewed))
            }
            #expect(await library.skillSnapshot().skills.allSatisfy { $0.name != "example" })
        }
    }

    @Test func missingReviewTamperingAndCancellationNeverInstall() async throws {
        let library = InstallationLibrary()
        let tool = SkillInstallTool(library: library, resolver: MutablePackageResolver(package: try package()))
        let reviewed = try await tool.preflight(invocation())
        var changed = reviewed.invocation
        changed.call.arguments = .object(["name": .string("changed")])
        await #expect(throws: (any Error).self) {
            try await tool.execute(changed, context: context(reviewed))
        }
        let second = try await tool.preflight(invocation())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tool.execute(second.invocation, context: context(second))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await library.skillSnapshot().skills.isEmpty)
    }

    @Test func installerIsOptInAndActingOnly() throws {
        let library = InstallationLibrary()
        let configured = AgentToolCatalog.registry(
            builtIn: .init(
                groups: [.skills], skillPackageResolver: MutablePackageResolver(package: try package()),
                skillLibrary: library))
        #expect(configured.available(in: .planning)["skill_install"] == nil)
        #expect(configured.available(in: .acting)["skill_install"] != nil)
        #expect(
            AgentToolCatalog.registry(builtIn: .init(groups: [.skills], skillLibrary: library))["skill_install"] == nil)
    }

    @Test func deniedInstallationNeverWritesTheLibrary() async throws {
        let library = InstallationLibrary()
        let tool = SkillInstallTool(library: library, resolver: MutablePackageResolver(package: try package()))
        let executor = AgentToolExecutor(
            tools: AgentToolRegistry([AnyAgentTool(tool)]),
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .deny("Declined") }),
            hooks: AgentLoopHooks([]), channel: AgentEventChannel(repository: InMemoryAgentRunRepository()),
            secretBroker: SecretBroker(), userInteraction: UnavailableAgentUserInteraction(), runID: UUID(),
            permissionMode: .askForApproval, userIntent: "Install the skill")
        let result = await executor.execute(executor.plan(invocation().call))
        #expect(result.isError)
        #expect(await library.skillSnapshot().skills.isEmpty)
    }

    @Test func truncatedTreesAndMissingRootFailBeforeDownloadingFiles() async throws {
        for truncated in [false, true] {
            let network = try fixture()
            let data = try JSONSerialization.data(withJSONObject: ["truncated": truncated, "tree": []])
            await network.set("https://api.github.com/repos/owner/repo/git/trees/" + skillTree, data: data, status: 200)
            await #expect(throws: (any Error).self) {
                try await GitHubSkillPackageResolver(transport: network).resolve(
                    sourceURL: "https://github.com/owner/repo/tree/main/example")
            }
            #expect(await network.requests.allSatisfy { $0.host != "raw.githubusercontent.com" })
        }
    }

    private func package() throws -> AgentResolvedSkillPackage {
        var parsed = try AgentSkillDocument.parse(document)
        parsed.package.files["image.bin"] = Data([0, 255, 1])
        return .init(
            document: parsed, sourceURL: "https://github.com/owner/repo/tree/\(commit)/example", revision: commit)
    }
    private func invocation() -> AgentToolInvocation {
        .init(
            runID: UUID(),
            call: .init(
                id: UUID().uuidString, name: "skill_install",
                arguments: .object([
                    "source_url": .string("https://github.com/owner/repo/tree/main/example")
                ])))
    }
    private func context(_ preflight: AgentToolPreflight) -> AgentToolExecutionContext {
        .init(
            runID: preflight.invocation.runID, userIntent: "Install", secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: preflight.executionMetadata,
            authorize: { _ in .allow })
    }
    private func fixture(mode: String = "100644", resourcePath: String = "image.bin", resourceSize: Int = 3) throws
        -> PackageFixtureNetwork
    {
        let doc = Data(document.utf8)
        let image = Data([0, 255, 1])
        func blob(_ bytes: Data) -> String {
            Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes).map { String(format: "%02x", $0) }
                .joined()
        }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let api = "https://api.github.com/repos/owner/repo"
        return try PackageFixtureNetwork(responses: [
            api + "/commits/main": json(["sha": commit, "commit": ["tree": ["sha": rootTree]]]),
            api + "/git/trees/" + rootTree: json([
                "truncated": false,
                "tree": [
                    ["path": "example", "mode": "040000", "type": "tree", "sha": skillTree]
                ],
            ]),
            api + "/git/trees/" + skillTree: json([
                "truncated": false,
                "tree": [
                    ["path": "SKILL.md", "mode": "100644", "type": "blob", "sha": blob(doc), "size": doc.count],
                    [
                        "path": resourcePath, "mode": mode, "type": mode == "160000" ? "commit" : "blob",
                        "sha": blob(image), "size": resourceSize,
                    ],
                ],
            ]),
            "https://raw.githubusercontent.com/owner/repo/\(commit)/example/SKILL.md": doc,
            "https://raw.githubusercontent.com/owner/repo/\(commit)/example/image.bin": image,
        ])
    }
}

private actor PackageFixtureNetwork: SkillPackageHTTPTransport {
    var requests: [URL] = []
    var responses: [String: Data]
    var statuses: [String: Int] = [:]
    init(responses: [String: Data] = [:]) { self.responses = responses }
    func set(_ url: String, data: Data, status: Int) {
        responses[url] = data
        statuses[url] = status
    }
    func get(_ url: URL, maximumBytes: Int) throws -> Data {
        requests.append(url)
        let status = statuses[url.absoluteString] ?? (responses[url.absoluteString] == nil ? 404 : 200)
        guard status == 200 else { throw SkillPackageHTTPError(status: status) }
        let data = responses[url.absoluteString] ?? Data()
        guard data.count <= maximumBytes else { throw AgentSkillImportError.tooLarge }
        return data
    }
}
private actor MutablePackageResolver: AgentSkillPackageResolving {
    var package: AgentResolvedSkillPackage
    init(package: AgentResolvedSkillPackage) { self.package = package }
    func resolve(sourceURL: String) -> AgentResolvedSkillPackage { package }
    func replaceBody(_ body: String) { package.document.body = body }
}
private actor InstallationLibrary: AgentSkillLibraryManaging {
    var skills: [AgentSkill] = []
    var fails = false
    func skillSnapshot() -> AgentSkillLibrarySnapshot { .init(skills) }
    func applySkillOperations(_ operations: [AgentSkillOperation], expectedRevision: String) throws {}
    func failSaves() { fails = true }
    func addOtherSkill() { skills.append(.init(name: "other", summary: "Other", body: "Other")) }
    func installSkill(_ skill: AgentSkill, expectedRevision: String) throws {
        guard !fails, expectedRevision == skillSnapshot().revision else { throw CocoaError(.fileWriteUnknown) }
        skills = try skillSnapshot().adding(skill)
    }
}
