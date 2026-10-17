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
    func brokerMovesOwnershipAndScopesSingleUseToTheBinding() async throws {
        let broker = SecretBroker()
        var source = Data("one-use".utf8)
        let submitted = AgentSecret(consumingUTF8: &source)
        let binding = SecretBinding(
            runID: UUID(), toolName: "ssh_exec", hostID: UUID(), purpose: "sudo"
        )

        let handle = try await broker.issue(submitted, binding: binding)
        #expect(submitted.isConsumed)
        await #expect(throws: SecretBrokerError.bindingMismatch) {
            try await broker.consume(
                handle,
                matching: SecretBinding(
                    runID: binding.runID, toolName: "ssh_exec", hostID: binding.hostID,
                    purpose: "different"
                )
            )
        }

        let consumed = try await broker.consume(handle, matching: binding)
        #expect(try bytes(consumed) == Array("one-use".utf8))
        await #expect(throws: SecretBrokerError.notFound) {
            try await broker.consume(handle, matching: binding)
        }
    }

    @Test
    func consumerIdentityChecksAllFieldsWithoutRepeatingPurpose() async throws {
        let broker = SecretBroker()
        let runID = UUID()
        let hostID = UUID()
        var source = Data("one-use".utf8)
        let handle = try await broker.issue(
            AgentSecret(consumingUTF8: &source),
            binding: SecretBinding(runID: runID, toolName: "consumer", hostID: hostID, purpose: "User explanation")
        )
        for identity in [(UUID(), "consumer", hostID), (runID, "other", hostID), (runID, "consumer", UUID())] {
            await #expect(throws: SecretBrokerError.bindingMismatch) {
                try await broker.consume(handle, runID: identity.0, toolName: identity.1, hostID: identity.2)
            }
        }
        let secret = try await broker.consume(handle, runID: runID, toolName: "consumer", hostID: hostID)
        defer { secret.clear() }
        #expect(try bytes(secret) == Array("one-use".utf8))
        await #expect(throws: SecretBrokerError.notFound) {
            try await broker.consume(handle, runID: runID, toolName: "consumer", hostID: hostID)
        }
    }

    @Test
    func discardingASecretRemovesItsHandle() async throws {
        let broker = SecretBroker()
        let runID = UUID()
        var source = Data("discard-me".utf8)
        let handle = try await broker.issue(
            AgentSecret(consumingUTF8: &source),
            binding: SecretBinding(
                runID: runID, toolName: "ssh_exec", hostID: UUID(), purpose: "sudo"
            )
        )

        await broker.discardSecrets(for: runID)
        #expect(await broker.count == 0)
        await #expect(throws: SecretBrokerError.notFound) {
            try await broker.consume(
                handle,
                matching: SecretBinding(
                    runID: runID, toolName: "ssh_exec", hostID: nil, purpose: "sudo"
                )
            )
        }
    }

    private func bytes(_ secret: AgentSecret) throws -> [UInt8] {
        try secret.withUnsafeBytes { Array($0) }
    }
}
