import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentContextPipelineTests {
    private func context(_ messages: [AgentTranscriptMessage]) -> AgentModelContext {
        AgentModelContext(systemPrompt: "system", messages: messages, tools: [])
    }

    private func assistant(calling ids: [String]) -> AgentTranscriptMessage {
        AgentTranscriptMessage(
            role: .assistant,
            toolCalls: ids.map { AgentToolCall(id: $0, name: $0, arguments: .object([:])) }
        )
    }

    private func result(_ id: String, _ text: String = "") -> AgentTranscriptMessage {
        AgentTranscriptMessage(
            role: .tool, text: text.isEmpty ? id : text, toolCallID: id, toolName: id
        )
    }

    /// The reason this transform exists: a reader following the event stream
    /// appends results as `toolFinished` arrives, which under parallel
    /// execution is completion order, while the run's own snapshot appends in
    /// source order. The reader's copy is what seeds the next run.
    @Test
    func toolResultsAreReorderedToMatchTheCallTheyAnswer() {
        let messages = [
            AgentTranscriptMessage(role: .user, text: "go"),
            assistant(calling: ["a", "b", "c"]),
            result("c"), result("a"), result("b"),
            AgentTranscriptMessage(role: .user, text: "next"),
        ]

        let ordered = AgentToolResultOrdering().transform(context(messages)).messages

        #expect(ordered.compactMap(\.toolCallID) == ["a", "b", "c"])
        // Everything else keeps its place.
        #expect(ordered.first?.text == "go")
        #expect(ordered.last?.text == "next")
    }

    @Test
    func reorderingLeavesTurnsThatCalledNothingAlone() {
        let messages = [
            assistant(calling: []),
            AgentTranscriptMessage(role: .user, text: "still here"),
            assistant(calling: ["x"]),
            result("x"),
        ]

        let ordered = AgentToolResultOrdering().transform(context(messages)).messages

        #expect(ordered.map(\.role) == [.assistant, .user, .assistant, .tool])
    }

    /// A result the turn above it never asked for sorts to the end rather than
    /// to an arbitrary slot; the orphan repair is what actually removes it.
    @Test
    func anUnmatchedResultSinksToTheEndOfItsBlock() {
        let messages = [
            assistant(calling: ["a", "b"]),
            result("stray"), result("b"), result("a"),
        ]

        let ordered = AgentToolResultOrdering().transform(context(messages)).messages

        #expect(ordered.compactMap(\.toolCallID) == ["a", "b", "stray"])
    }

    @Test
    func onlyTheNewestTurnsResultsSurviveAtFullLength() {
        let long = String(repeating: "x", count: 40_000)
        let messages = [
            assistant(calling: ["old"]),
            result("old", long),
            AgentTranscriptMessage(role: .assistant, text: long),
            assistant(calling: ["new"]),
            result("new", long),
        ]

        let trimmed = AgentToolResultTrimming(limit: 1_000)
            .transform(context(messages)).messages

        #expect(trimmed[1].text.count < 1_200)
        // The head and the tail both survive: a command output whose ending is
        // missing has lost its error message.
        #expect(trimmed[1].text.hasPrefix("xxxx"))
        #expect(trimmed[1].text.hasSuffix("xxxx"))
        // What the assistant concluded stays whole at any age, and so does the
        // output the model is currently reasoning about.
        #expect(trimmed[2].text.count == 40_000)
        #expect(trimmed[4].text.count == 40_000)
    }

    @Test
    func aResultThatFitsIsNeverAltered() {
        let messages = [assistant(calling: ["a"]), result("a", "short"), .init(role: .user)]
        let trimmed = AgentToolResultTrimming(limit: 1_000)
            .transform(context(messages)).messages
        #expect(trimmed[1].text == "short")
    }

    /// Anchored to the prompt's identity, not to a captured index: the
    /// transforms ahead of it are free to add and remove messages.
    @Test
    func sessionContextLandsDirectlyInFrontOfTheTurnItDescribes() {
        let prompt = AgentTranscriptMessage(role: .user, text: "inspect")
        let block = AgentTranscriptMessage(role: .user, text: "Session context")
        let messages = [
            AgentTranscriptMessage(role: .user, text: "earlier"),
            // An orphan, so the repair ahead of injection changes the count.
            result("gone"),
            prompt,
        ]

        let sent = AgentContextPipeline.chat(sessionContext: block, before: prompt.id)(
            context(messages)
        ).messages

        #expect(
            sent.map(\.text).filter { $0 == "earlier" || $0 == "Session context" || $0 == "inspect" } == [
                "earlier", "Session context", "inspect",
            ])
    }

    @Test
    func anAbsentSessionEstablishesAnExplicitBaseline() {
        let prompt = AgentTranscriptMessage(role: .user, text: "inspect")
        let sent = AgentContextPipeline.chat(sessionContext: nil, before: prompt.id)(
            context([prompt])
        ).messages
        #expect(sent.last?.id == prompt.id)
        let baseline = Array(sent.dropLast())
        #expect(baseline.count == 3)
        #expect(baseline.allSatisfy { $0.role == .user && !$0.text.isEmpty })
        #expect(baseline.map(\.text) == AgentTurnContextSnapshot().changes(from: nil))
    }

    @Test
    func orphanedToolResultsAreDroppedAndAnsweredOnesKept() {
        let messages = [
            assistant(calling: ["kept"]),
            result("kept"),
            result("orphan"),
            // No call id at all: Google addresses a result by name, so absence
            // is not evidence of an orphan.
            AgentTranscriptMessage(role: .tool, text: "ok", toolName: "list_hosts"),
        ]

        let repaired = AgentOrphanedToolResultRepair.apply(messages)

        #expect(repaired.count == 3)
        #expect(!repaired.contains { $0.toolCallID == "orphan" })
    }

    @Test
    func exchangeRepairMovesLateRealResultsBeforeTheInterveningPrompt() {
        let call = assistant(calling: ["a"])
        let prompt = AgentTranscriptMessage(role: .user, text: "continue")
        let real = result("a", "completed")

        let repaired = AgentToolExchangeRepair.apply([call, prompt, real])

        #expect(repaired == [call, real, prompt])
        #expect(AgentToolExchangeRepair.apply(repaired) == repaired)
    }

    @Test
    func exchangeRepairDropsDuplicateResultsAndUsesCallOrder() {
        let call = assistant(calling: ["a", "b"])
        let firstA = result("a", "first result")
        let duplicateA = result("a", "duplicate result")
        let b = result("b")
        let prompt = AgentTranscriptMessage(role: .user, text: "continue")

        let repaired = AgentToolExchangeRepair.apply([call, b, firstA, prompt, duplicateA, result("stray")])

        #expect(repaired == [call, firstA, b, prompt])
        #expect(AgentToolExchangeRepair.apply(repaired) == repaired)
    }

    @Test
    func exchangeRepairFillsOnlyMissingResultsAndIsIdempotent() throws {
        let call = assistant(calling: ["a", "b", "c"])
        let b = result("b", "real output")
        let repaired = AgentToolExchangeRepair.apply([call, b])

        #expect(repaired.compactMap(\.toolCallID) == ["a", "b", "c"])
        #expect(repaired[2] == b)
        let missing = try #require(repaired.first { $0.toolCallID == "a" })
        #expect(missing.isError)
        #expect(missing.text.contains("unknown"))
        #expect(missing.text.contains("check the current state"))
        #expect(repaired[3].isError)
        // Equality checks IDs, timestamps, projections, and bodies, not just roles.
        #expect(AgentToolExchangeRepair.apply(repaired) == repaired)
    }

    @Test
    func exchangeRepairDoesNotBorrowResultsAcrossAssistantTurns() {
        let first = assistant(calling: ["a"])
        let boundary = AgentTranscriptMessage(role: .assistant, text: "another turn")
        let late = result("a", "misplaced old output")
        let second = assistant(calling: ["b"])
        let b = result("b")

        let repaired = AgentToolExchangeRepair.apply([first, boundary, late, second, b])

        #expect(repaired.map(\.role) == [.assistant, .tool, .assistant, .assistant, .tool])
        #expect(repaired[1].isError)
        #expect(!repaired.contains { $0.id == late.id })
        #expect(repaired.last == b)
        #expect(AgentToolExchangeRepair.apply(repaired) == repaired)
    }

    @Test
    func exchangeRepairScopesReusedCallIDsToTheirOwnTurn() {
        let first = assistant(calling: ["a"])
        let second = assistant(calling: ["a"])
        let firstResult = result("a", "first turn")
        let secondResult = result("a", "second turn")
        let messages = [first, firstResult, second, secondResult]

        #expect(AgentToolExchangeRepair.apply(messages) == messages)
    }

    @Test
    func exchangeRepairCollapsesRepeatedCallIDsWithinOneBatch() {
        let call = assistant(calling: ["a", "a"])
        let real = result("a")
        let repaired = AgentToolExchangeRepair.apply([call, real])

        #expect(repaired.count == 2)
        #expect(repaired[0].toolCalls.count == 1)
        #expect(repaired[1] == real)
        #expect(AgentToolExchangeRepair.apply(repaired) == repaired)
    }

    @Test
    func exchangeRepairMatchesLegacyNameOnlyResultsWithoutInventingIDs() {
        let call = assistant(calling: ["a", "b"])
        let a = AgentTranscriptMessage(role: .tool, text: "a output", toolName: "a")
        let b = AgentTranscriptMessage(role: .tool, text: "b output", toolCallID: "", toolName: "b")
        let legacy = AgentTranscriptMessage(role: .tool, text: "legacy output", toolName: "other")
        let repaired = AgentToolExchangeRepair.apply([call, b, a, legacy])

        #expect(repaired == [call, a, b, legacy])
        #expect(AgentToolExchangeRepair.apply(repaired) == repaired)
        #expect(AgentToolExchangeRepair.apply([legacy]) == [legacy])
    }

    @Test
    func exchangeRepairMatchesRepeatedNamesByOccurrenceAfterExplicitIDs() {
        let call = AgentTranscriptMessage(
            role: .assistant,
            toolCalls: ["a", "b", "c"].map {
                AgentToolCall(id: $0, name: "lookup", arguments: .object([:]))
            }
        )
        let named = AgentTranscriptMessage(role: .tool, text: "first name-only", toolName: "lookup")
        let nextNamed = AgentTranscriptMessage(role: .tool, text: "second name-only", toolName: "lookup")
        let explicit = AgentTranscriptMessage(role: .tool, text: "explicit", toolCallID: "a", toolName: "lookup")
        let repaired = AgentToolExchangeRepair.apply([call, named, nextNamed, explicit])

        #expect(repaired == [call, explicit, named, nextNamed])
        #expect(AgentToolExchangeRepair.apply(repaired) == repaired)
    }

    @Test
    func exchangeRepairPreservesOpaqueItemsAndResultProjections() {
        var call = assistant(calling: ["a"])
        call.providerItems = [.object(["type": .string("reasoning"), "opaque": .string("keep")])]
        var real = result("a", "full output")
        real.modelText = "projected output"
        real.providerItems = [.object(["opaque": .string("result")])]
        let native = AgentTranscriptMessage(
            role: .assistant, providerItems: [.object(["type": .string("web_search_call")])]
        )
        let messages = [call, real, native]

        #expect(AgentToolExchangeRepair.apply(messages) == messages)
    }

    @Test
    func exchangeRepairRetainsUnassignedLegacyAndOpaqueMessagesConservatively() {
        let call = assistant(calling: ["a"])
        let real = result("a", "real output")
        let named = AgentTranscriptMessage(role: .tool, text: "unassigned legacy", toolName: "a")
        let opaque = AgentTranscriptMessage(
            role: .tool, text: "opaque output", toolCallID: "native",
            providerItems: [.object(["opaque": .string("keep")])]
        )
        // An unassigned name cannot prove duplication, and opaque provider
        // state must not be interpreted as ordinary function-result grammar.
        let messages = [call, real, named, opaque]
        let repaired = AgentToolExchangeRepair.apply(messages)

        #expect(repaired == messages)
        #expect(AgentToolExchangeRepair.apply(repaired) == repaired)
        #expect(AgentToolExchangeRepair.apply([opaque]) == [opaque])
    }

    @Test
    func exchangeRepairSupportsCallsWithEmptyLegacyIDs() {
        let call = AgentTranscriptMessage(
            role: .assistant,
            toolCalls: [
                AgentToolCall(id: "", name: "lookup", arguments: .object([:])),
                AgentToolCall(id: "", name: "lookup", arguments: .object([:])),
            ]
        )
        let real = AgentTranscriptMessage(role: .tool, text: "real", toolName: "lookup")
        let repaired = AgentToolExchangeRepair.apply([call, real])

        #expect(repaired.count == 3)
        #expect(repaired[0] == call)
        #expect(repaired[1] == real)
        #expect(repaired[2].isError)
        #expect(AgentToolExchangeRepair.apply(repaired) == repaired)
    }

    @Test
    func defaultPipelineUsesCoherentExchangeRepair() throws {
        let call = assistant(calling: ["a"])
        let prompt = AgentTranscriptMessage(role: .user, text: "continue")
        let real = result("a", "completed")
        let sent = AgentContextPipeline.chat(sessionContext: nil, before: nil)(
            context([call, prompt, real])
        ).messages

        #expect(sent.filter { $0.role == .tool } == [real])
        let resultIndex = try #require(sent.firstIndex(where: { $0.id == real.id }))
        let promptIndex = try #require(sent.firstIndex(where: { $0.id == prompt.id }))
        #expect(resultIndex < promptIndex)
    }

    @Test
    func unavailableHistoricalSecretCapabilitiesAreRemoved() throws {
        let realHandle = UUID().uuidString
        let messages = [
            AgentTranscriptMessage(
                role: .assistant,
                toolCalls: [
                    AgentToolCall(
                        id: "exec", name: "run_command",
                        arguments: .object([
                            "command": .string("uptime"),
                            "secret_handle": .string("[REDACTED]"),
                        ])
                    ),
                    AgentToolCall(
                        id: "secret", name: "request_user_secret",
                        arguments: .object(["purpose": .string("sudo")])
                    ),
                ]
            ),
            AgentTranscriptMessage(
                role: .tool,
                text: "<untrusted-data>\n{\"secret_handle\":\"\(realHandle)\"}\n</untrusted-data>",
                toolCallID: "secret", toolName: nil
            ),
        ]

        let sanitized = AgentSecretLifecycle.sanitizeHistoricalMessages(messages)
        let execArguments = try #require(
            sanitized[0].toolCalls[0].arguments.objectValue
        )

        #expect(execArguments["secret_handle"] == nil)
        #expect(sanitized[1].text == AgentSecretLifecycle.expiredResultContent)
        #expect(!sanitized[1].text.contains(realHandle))
    }
}
