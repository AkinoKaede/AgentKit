import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentSecretTests {
    @Test
    func sourceBytesAreClearedAndOwnedUntilExplicitlyCleared() throws {
        var source = Data("swordfish".utf8)
        let secret = AgentSecret(consumingUTF8: &source)

        #expect(source.isEmpty)
        #expect(try bytes(secret) == Array("swordfish".utf8))
        #expect(!secret.isConsumed)

        secret.clear()
        #expect(secret.isConsumed)
        #expect(throws: AgentSecretError.consumed) { try bytes(secret) }
        secret.clear()
    }

    @Test
    func brokerMovesOwnershipAndConsumesOnlyOnce() async throws {
        let broker = SecretBroker()
        var source = Data("one-use".utf8)
        let submitted = AgentSecret(consumingUTF8: &source)
        let handle = try await broker.issue(submitted)
        #expect(submitted.isConsumed)
        await #expect(throws: SecretBrokerError.notFound) {
            try await SecretBroker().consume(handle)
        }

        let consumed = try await broker.consume(handle)
        defer { consumed.clear() }
        #expect(try bytes(consumed) == Array("one-use".utf8))
        await #expect(throws: SecretBrokerError.notFound) {
            try await broker.consume(handle)
        }
    }

    @Test
    func discardingASecretRemovesItsHandle() async throws {
        let broker = SecretBroker()
        var source = Data("discard-me".utf8)
        let handle = try await broker.issue(
            AgentSecret(consumingUTF8: &source)
        )

        await broker.discardAll()
        #expect(await broker.count == 0)
        await #expect(throws: SecretBrokerError.notFound) {
            try await broker.consume(handle)
        }
    }

    @Test
    func concurrentConsumersCannotSpendTheSameHandleTwice() async throws {
        let broker = SecretBroker()
        var source = Data("once".utf8)
        let handle = try await broker.issue(AgentSecret(consumingUTF8: &source))
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let secret = try? await broker.consume(handle) else { return false }
                    secret.clear()
                    return true
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(successes == 1)
    }

    @Test
    func secretToolRequestsNoConsumerBindingAndReturnsNoPlaintext() async throws {
        let tool = RequestUserSecretTool()
        let arguments: [String: AgentJSONValue] = [
            "prompt": .string("API key"), "purpose": .string("Access the requested service"),
        ]
        try AgentJSONSchemaValidator.validate(.object(arguments), against: tool.descriptor.inputSchema)
        let properties = try #require(tool.descriptor.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["prompt", "purpose", "timeout_seconds"])
        var source = Data("TOP-SECRET".utf8)
        let interaction = SecretInteraction(secret: AgentSecret(consumingUTF8: &source))
        let broker = SecretBroker()
        let invocation = AgentToolInvocation(
            runID: UUID(), call: .init(id: "secret", name: tool.descriptor.name, arguments: .object(arguments)))
        let result = try await tool.execute(
            invocation,
            context: .init(
                runID: invocation.runID, userIntent: "Access a service", secretBroker: broker,
                userInteraction: interaction, preflightMetadata: [:], authorize: { _ in .allow }))
        #expect(await interaction.requested?.purpose == "Access the requested service")
        #expect(!result.content.contains("TOP-SECRET"))
        let payload = try AgentJSONValue.decode(Data(try #require(result.untrustedPayload).utf8))
        let object = try #require(payload.objectValue)
        #expect(Set(object.keys) == ["secret_handle", "single_use"])
        #expect(object["single_use"] == .bool(true))
        let id = try #require(object["secret_handle"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let secret = try await broker.consume(.init(id: id))
        defer { secret.clear() }
        #expect(try bytes(secret) == Array("TOP-SECRET".utf8))
        let fields = RequestUserSecretTool.present(
            .init(result: payload, arguments: arguments, locale: Locale(identifier: "en"))
        ).compactMap { item -> AgentToolDetail.Field? in
            if case .field(let field) = item { return field }
            return nil
        }
        #expect(fields.map(\.label) == ["Request", "Purpose", "Status"])
        #expect(!fields.contains { $0.value.contains("TOP-SECRET") || $0.value.contains(id.uuidString) })
    }

    private func bytes(_ secret: AgentSecret) throws -> [UInt8] {
        try secret.withUnsafeBytes { Array($0) }
    }
}

private actor SecretInteraction: AgentUserInteractionHandling {
    let secret: AgentSecret
    private(set) var requested: AgentUserInputRequest?

    init(secret: AgentSecret) { self.secret = secret }

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        requested = request
        return .answered([.init(questionID: "secret", value: .secret(secret))])
    }
}
