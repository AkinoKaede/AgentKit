import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentProviderResponseParserTests {
    @Test(arguments: [ModelAPIFormat.chatCompletions, .responses, .messages])
    func streamedAndBufferedSSEShareToolState(_ format: ModelAPIFormat) throws {
        let chunks: [String]
        switch format {
        case .chatCompletions:
            chunks = [
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"wire_lookup","arguments":"{"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]}}]}"#,
            ]
        case .responses:
            chunks = [
                #"{"type":"response.output_item.added","item":{"type":"function_call","id":"item-1","call_id":"call-1","namespace":"tools","name":"lookup"}}"#,
                #"{"type":"response.function_call_arguments.delta","item_id":"item-1","delta":"{}"}"#,
            ]
        case .messages:
            chunks = [
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call-1","name":"wire_lookup"}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
            ]
        case .generateContent:
            Issue.record("Gemini has no fragmented tool call state")
            return
        }
        var streamed = parser(format)
        let streamedEvents = try (chunks + ["[DONE]"]).flatMap { try streamed.consume(SSEEvent(data: $0)) }
        var buffered = parser(format)
        let bufferedEvents = try buffered.parseResponse(
            Data((chunks + ["[DONE]"]).map { "data: \($0)\n\n" }.joined().utf8))
        for events in [streamedEvents, bufferedEvents] {
            var ids: [String] = []
            var names: [String] = []
            var arguments = ""
            for event in events {
                if case .toolCallDelta(let id, let name, let fragment) = event {
                    ids.append(id)
                    if let name { names.append(name) }
                    arguments += fragment
                }
            }
            #expect(ids == ["call-1", "call-1"])
            #expect(!names.isEmpty)
            #expect(names.allSatisfy { $0 == "tools.lookup" })
            #expect(try AgentJSONValue.decode(Data(arguments.utf8)) == .object([:]))
        }
        #expect(streamed.shouldStop)
        #expect(buffered.shouldStop)
    }

    @Test
    func oneResponsesStateCannotLeakIntoAnotherRequest() throws {
        var first = parser(.responses)
        _ = try first.consume(
            SSEEvent(
                data:
                    #"{"type":"response.output_item.added","item":{"type":"function_call","id":"item-1","call_id":"call-1","name":"lookup"}}"#
            ))
        let continuation = SSEEvent(
            data:
                #"{"type":"response.function_call_arguments.delta","item_id":"item-1","delta":"{}"}"#
        )
        var second = parser(.responses)
        let firstEvents = try first.consume(continuation)
        let secondEvents = try second.consume(continuation)
        guard case .toolCallDelta(let firstID, let firstName, _) = try #require(firstEvents.first),
            case .toolCallDelta(let secondID, let secondName, _) = try #require(secondEvents.first)
        else {
            Issue.record("Expected tool argument deltas")
            return
        }
        #expect(firstID == "call-1")
        #expect(firstName == "lookup")
        #expect(secondID == "item-1")
        #expect(secondName == nil)
    }

    @Test(arguments: ["rate_limit_error", "invalid_request_error"])
    func providerFailuresKeepTheirRetryClassification(_ code: String) throws {
        var parser = parser(.messages)
        let event = SSEEvent(data: #"{"type":"error","error":{"type":"\#(code)","message":"fixture"}}"#)
        do {
            _ = try parser.consume(event)
            Issue.record("Expected the provider failure to propagate")
        } catch let error as AgentProviderStreamFailure {
            #expect(error.code == code)
            #expect(error.isRetryable == (code == "rate_limit_error"))
        }
    }

    private func parser(_ format: ModelAPIFormat) -> AgentProviderResponseParser {
        AgentProviderResponseParser(format: format, wireNames: ["wire_lookup": "tools.lookup"], buffered: true)
    }
}
