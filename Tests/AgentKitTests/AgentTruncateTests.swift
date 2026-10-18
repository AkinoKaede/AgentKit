import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentTruncateTests {
    private func invocation() -> AgentToolInvocation {
        AgentToolInvocation(runID: UUID(), call: .init(id: "call", name: "test_output", arguments: .object([:])))
    }

    private func fields(_ result: AgentToolResult) throws -> [String: AgentJSONValue] {
        let text = try #require(result.modelContent)
        let framed = AgentToolResult(callID: "call", content: text, metadata: ["untrusted": .bool(true)])
        let payload = try #require(framed.untrustedPayload)
        return try #require(AgentJSONValue.decode(Data(payload.utf8)).objectValue)
    }

    @Test(arguments: [false, true])
    func structuralRedactionPreservesFramingAndNestedFields(framed: Bool) throws {
        let payload = AgentJSONValue.object([
            "headers": .array([
                .object(["name": .string("Authorization"), "value": .string("Bearer private-header")]),
                .object(["name": .string("Content-Type"), "value": .string("text/plain")]),
            ]),
            "output": .string("token=\"private-value\"\nfinished\n"),
            "secret_handle": .null,
            "password": .string(""),
        ]).encodedString
        let source =
            framed
            ? AgentToolResult.untrustedDataOpeningMarker + payload
                + AgentToolResult.untrustedDataClosingMarker : payload
        let redacted = AgentSensitiveDataRedactor.toolResultText(source)
        let fields = try #require(AgentToolResult.decodeStructuredPayload(redacted)?.objectValue)
        #expect(redacted.hasPrefix(AgentToolResult.untrustedDataOpeningMarker) == framed)
        #expect(redacted.hasSuffix(AgentToolResult.untrustedDataClosingMarker) == framed)
        #expect(fields["headers"]?.arrayValue?.first?.objectValue?["value"] == .string("[REDACTED]"))
        #expect(fields["headers"]?.arrayValue?.last?.objectValue?["value"] == .string("text/plain"))
        #expect(fields["output"] == .string("token=\"[REDACTED]\"\nfinished\n"))
        #expect(fields["secret_handle"] == .null)
        #expect(fields["password"] == .string(""))
        #expect(!redacted.contains("private-"))
    }

    @Test
    func structuredPayloadRequiresCompleteOptedInFramingAndNeverRepairsMalformedText() {
        let payload = #"{"output":"ready"}"#
        let framed = AgentToolResult.untrustedDataOpeningMarker + payload + AgentToolResult.untrustedDataClosingMarker
        #expect(AgentToolResult.decodeStructuredPayload(framed)?.objectValue?["output"] == .string("ready"))
        #expect(AgentToolResult.decodeStructuredPayload(framed, isUntrusted: false) == nil)
        #expect(AgentToolResult.decodeStructuredPayload(payload, isUntrusted: false)?.objectValue != nil)
        for malformed in [
            "password=private-value", AgentToolResult.untrustedDataOpeningMarker + payload,
            AgentToolResult.untrustedDataOpeningMarker + "{\"token\":\"private-value"
                + AgentToolResult.untrustedDataClosingMarker,
        ] {
            #expect(AgentToolResult.decodeStructuredPayload(malformed) == nil)
            #expect(
                AgentSensitiveDataRedactor.toolResultText(malformed)
                    == AgentSensitiveDataRedactor.visibleText(malformed))
        }
    }

    @Test
    func nestedStructuredCaptureRetainsSortedReadableLinesBelowRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let accumulator = AgentOutputAccumulator(workspace: workspace, path: { "nested.txt" })
        let lines = String(repeating: "log\n", count: 2_100)
        let raw = AgentToolResult(
            callID: "call",
            content: AgentToolOutputProjection.frame([
                "z": .number(7), "a": .array([.string(lines), .object(["ok": .bool(true)])]),
            ]), metadata: ["untrusted": .bool(true)])
        let captured = await accumulator.capturing(raw)
        let path = try #require(captured.outputCapture?.path)
        let saved = try await workspace.data(at: path)
        #expect(String(decoding: saved.data, as: UTF8.self) == "a:\n[0]\n\(lines)\n\n[1]\nok:\ntrue\n\nz:\n7")
        #expect(captured.content == raw.content)
        #expect(captured.modelContent == nil)
    }

    @Test
    func malformedSourceKeepsHistoricalReadableFallbackAfterRedaction() async throws {
        let raw = AgentToolResult(
            callID: "call", content: #"{"token":unquoted,"output":"first\nsecond\n"}"#,
            isTruncated: true)
        let projected = await AgentToolOutputProjection().project(raw, invocation: invocation())
        let output = try fields(projected)
        #expect(output["preview"] == .string("output:\nfirst\nsecond\n\n\ntoken:\n[REDACTED]"))
        #expect(output["source_truncated"] == .bool(true))
        #expect(projected.content == raw.content)
    }

    @Test
    func strategiesKeepWholeLinesIncludingCRLFAndFinalPrompt() {
        let source = "first\r\nsecond\r\nprompt>"
        #expect(AgentTruncateResult.apply(source, limits: .init(bytes: 10)).content == "first\r\n")
        #expect(AgentTruncateResult.apply(source, strategy: .tail, limits: .init(bytes: 10)).content == "prompt>")
        #expect(AgentTruncateResult.apply(source, strategy: .none, limits: .init(bytes: 0)).content == source)
        let oversized = AgentTruncateResult.apply(String(repeating: "x", count: 65_537))
        #expect(oversized.content.isEmpty)
        #expect(oversized.oversizedLine)
    }

    @Test
    func defaultLimitsAre64KiBAnd2000WholeLines() {
        let exact = String(repeating: "x", count: 65_536)
        #expect(!AgentTruncateResult.apply(exact).isTruncated)
        let text = (1...2_001).map { "\($0)\n" }.joined()
        let head = AgentTruncateResult.apply(text)
        let tail = AgentTruncateResult.apply(text, strategy: .tail)
        #expect(head.returnedLines == 2_000)
        #expect(tail.ranges == [2...2_001])
        for strategy in AgentTruncateStrategy.allCases where strategy != .none {
            let result = AgentTruncateResult.apply(text, strategy: strategy, limits: .init(bytes: 80, lines: 12))
            #expect(result.content.utf8.count <= 80)
            #expect(AgentTruncateResult.logicalLines(result.content).count <= 12)
            for range in result.ranges {
                #expect(result.content.contains("\(range.lowerBound)\n"))
                #expect(result.content.contains("\(range.upperBound)\n"))
            }
        }
    }

    @Test
    func captureIsLazyAndReusesTheGeneratedFilenameAcrossSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let names = FilenameCounter()
        let accumulator = AgentOutputAccumulator(workspace: workspace, path: { names.next() })
        accumulator.append(Data("start\n".utf8))
        let small = await accumulator.snapshot()
        #expect(small.capture == nil)
        #expect(names.count == 0)
        accumulator.append(Data(String(repeating: "log\n", count: 2_100).utf8))
        let first = await accumulator.snapshot()
        let path = try #require(first.capture?.path)
        #expect(path == "output/test-1.txt")
        accumulator.append(Data("finished\n".utf8))
        let last = await accumulator.snapshot()
        #expect(last.capture?.path == path)
        #expect(names.count == 1)
        let saved = try await workspace.data(at: path)
        let text = String(decoding: saved.data, as: UTF8.self)
        #expect(text.hasPrefix("start\n"))
        #expect(text.hasSuffix("finished\n"))
        #expect(last.output.hasSuffix("finished\n"))
        #expect(last.isTruncated)
    }

    @Test
    func externalAudienceNeitherTruncatesNorGeneratesFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = FilenameCounter()
        let accumulator = AgentOutputAccumulator(
            workspace: AgentScratchWorkspace(base: directory), audience: .externalClient, path: { names.next() })
        let text = String(repeating: "long output\n", count: 7_000)
        accumulator.append(Data(text.utf8))
        let snapshot = await accumulator.snapshot()
        #expect(snapshot.output == text)
        #expect(snapshot.capture == nil)
        #expect(!snapshot.isTruncated)
        #expect(names.count == 0)
    }

    @Test
    func callerOwnsTheEntirePathAndSnapshotCapturesContainTheFullSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let accumulator = AgentOutputAccumulator(workspace: workspace, path: { "chat/custom/raw" })
        let source = "first\n" + String(repeating: "log\n", count: 2_100) + "last>"
        accumulator.append(Data(source.utf8))
        let cumulative = await accumulator.snapshot()
        #expect(cumulative.capture?.path == "chat/custom/raw")
        let snapshot = await accumulator.snapshot(capturePath: { "chat/outputs/other-tool-test.txt" })
        #expect(snapshot.capture?.path == "chat/outputs/other-tool-test.txt")
        #expect(snapshot.output != source)
        #expect(try await workspace.data(at: "chat/outputs/other-tool-test.txt").data == Data(source.utf8))
        accumulator.append(Data("\nfinished\n".utf8))
        let updated = await accumulator.snapshot()
        #expect(updated.capture?.path == cumulative.capture?.path)
        #expect(try await workspace.data(at: "chat/outputs/other-tool-test.txt").data == Data(source.utf8))
        #expect(try await workspace.data(at: "chat/custom/raw").data == Data((source + "\nfinished\n").utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("output").path))
    }

    @Test
    func captureRedactsUnfinishedQuotedSecretsAcrossCallbacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let accumulator = AgentOutputAccumulator(workspace: workspace, path: { "redacted.txt" })
        accumulator.append(Data((String(repeating: "log\n", count: 2_100) + "password=\"top hidden").utf8))
        let partial = await accumulator.snapshot()
        #expect(!partial.output.contains("hidden"))
        let path = try #require(partial.capture?.path)
        #expect(!String(decoding: try await workspace.data(at: path).data, as: UTF8.self).contains("hidden"))
        accumulator.append(Data(" value\"\nfinished\n".utf8))
        let complete = await accumulator.snapshot()
        #expect(complete.output.hasSuffix("password=\"[REDACTED]\"\nfinished\n"))
        #expect(!String(decoding: try await workspace.data(at: path).data, as: UTF8.self).contains("hidden"))
    }

    @Test
    func filenameValidationAndCollisionsCannotOverwriteFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        try await workspace.write("output/occupied.txt", data: Data("keep".utf8))
        let collision = await workspace.captureOutput("replacement", id: UUID(), path: { "output/occupied.txt" })
        #expect(collision.path == nil)
        #expect(collision.error != nil)
        let invalid = await workspace.captureOutput("escape", id: UUID(), path: { "../escape.txt" })
        #expect(invalid.path == nil)
        #expect(invalid.error != nil)
        #expect(try await workspace.data(at: "output/occupied.txt").data == Data("keep".utf8))
    }

    @Test
    func onlySavedCapturesAddAPathToThePiStyleMarker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let projection = AgentToolOutputProjection(workspace: workspace)
        let source = String(repeating: "line\n", count: 2_100)
        let raw = AgentToolResult(callID: "call", content: source)
        let unrequested = await projection.project(raw, invocation: invocation())
        #expect(try fields(unrequested)["capture_status"] == .string("not_requested"))
        #expect(try fields(unrequested)["captured_output_path"] == nil)
        #expect(unrequested.truncateMarker == "[Showing lines 1-2000 of 2100]")
        #expect(try await workspace.usage().entries == 0)
        let accumulator = AgentOutputAccumulator(workspace: workspace, path: { "output/saved.txt" })
        let captured = await accumulator.capturing(raw)
        let saved = await projection.project(captured, invocation: invocation())
        #expect(try fields(saved)["capture_status"] == .string("saved"))
        #expect(saved.truncateMarker == "[Showing lines 1-2000 of 2100. Full output: output/saved.txt]")
        #expect(try fields(saved)["notice"]?.stringValue == saved.truncateMarker)
        var failure = raw
        failure.outputCapture = AgentOutputCaptureInfo(bytes: source.utf8.count, lines: 2_100, error: "disk full")
        let failed = await projection.project(failure, invocation: invocation())
        #expect(try fields(failed)["capture_status"] == .string("failed"))
        #expect(try fields(failed)["captured_output_path"] == nil)
        #expect(try fields(failed)["capture_error"] == .string("disk full"))
        #expect(failed.truncateMarker == unrequested.truncateMarker)
    }

    @Test
    func markerUsesActualWholeLineRangesForMiddleAndEmptySelections() {
        #expect(
            AgentTruncateMarker.render(ranges: [1...3, 98...100], totalLines: 100)
                == "[Showing lines 1-3, 98-100 of 100]")
        #expect(AgentTruncateMarker.render(ranges: [], totalLines: 1) == "[Showing 0 of 1 lines]")
        #expect(AgentTruncateMarker.render(ranges: [21...25]) == "[Showing lines 21-25]")
        let failed = AgentOutputCaptureInfo(path: "partial.txt", bytes: 10, lines: 1, error: "disk full")
        #expect(
            AgentTruncateMarker.render(ranges: [], totalLines: 1, capture: failed) == "[Showing 0 of 1 lines]")
    }

    @Test
    func capturedQuotedOutputKeepsReadableLinesAfterRedaction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let accumulator = AgentOutputAccumulator(workspace: workspace, path: { "captures/quoted-output.txt" })
        let source = (1...400).map {
            "line \($0) " + String(repeating: "x", count: 192) + " token=\"private-value\"\n"
        }.joined()
        accumulator.append(Data(source.utf8))
        let snapshot = await accumulator.snapshot()
        var raw = AgentToolResult(
            callID: "call",
            content: AgentToolOutputProjection.frame(["output": .string(snapshot.output)]),
            isTruncated: snapshot.isTruncated,
            metadata: [
                "untrusted": .bool(true),
                "output_total_lines": .number(Double(snapshot.totalLines)),
                "output_line_offset": .number(Double(snapshot.lineOffset)),
            ])
        raw.outputCapture = snapshot.capture
        let projected = await AgentToolOutputProjection(workspace: workspace).project(
            raw, invocation: invocation(), strategy: .tail)
        let value = try fields(projected)
        #expect((value["returned_lines"]?.integerValue ?? 0) > 0)
        let output = try #require(value["output"]?.stringValue)
        #expect(value["returned_lines"]?.integerValue == AgentTruncateResult.logicalLines(output).count)
        #expect(output.contains("line 400 "))
        #expect(!output.contains("private-value"))
        #expect(projected.truncateMarker?.contains("-400 of 400. Full output: captures/quoted-output.txt") == true)
        #expect(try #require(projected.modelContent).utf8.count <= AgentTruncateLimits.maximumBytes)
    }

    @Test(arguments: [AgentTruncateStrategy.head, .none])
    func smallJSONOutputRemainsValidWhenTextContainsQuotedSecrets(strategy: AgentTruncateStrategy) async throws {
        let raw = AgentToolResult(
            callID: "call",
            content: AgentToolOutputProjection.frame([
                "output": .string("export token=\"private-value\"\nfinished\n")
            ]),
            metadata: ["untrusted": .bool(true)])
        let projected = await AgentToolOutputProjection().project(raw, invocation: invocation(), strategy: strategy)
        #expect(try fields(projected)["output"]?.stringValue == "export token=\"[REDACTED]\"\nfinished\n")
        #expect(projected.truncateMarker == nil)
    }

    @Test
    func streamingProjectionKeepsOriginalLineNumbersAfterTwoTailSelections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let accumulator = AgentOutputAccumulator(workspace: workspace, path: { "chat/outputs/command.txt" })
        accumulator.append(Data((1...3_000).map { "line \($0)\n" }.joined().utf8))
        let snapshot = await accumulator.snapshot()
        var raw = AgentToolResult(
            callID: "call", content: AgentJSONValue.object(["output": .string(snapshot.output)]).encodedString,
            isTruncated: snapshot.isTruncated,
            metadata: [
                "output_total_lines": .number(Double(snapshot.totalLines)),
                "output_line_offset": .number(Double(snapshot.lineOffset)),
            ])
        raw.outputCapture = snapshot.capture
        let result = await AgentToolOutputProjection(workspace: workspace, maximumLines: 10).project(
            raw, invocation: invocation(), strategy: .tail)
        #expect(
            result.truncateMarker
                == "[Showing lines 2991-3000 of 3000. Full output: chat/outputs/command.txt]")
        #expect(try fields(result)["returned_lines"] == .number(10))
    }

    @Test
    func pageBudgetPreservesActualContinuationWithoutCreatingACapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let line = String(repeating: "\"", count: 400)
        var page = AgentToolResult(
            callID: "call",
            content: AgentJSONValue.object([
                "path": .string("input.txt"), "offset": .number(10),
                "content": .string(Array(repeating: line, count: 100).joined(separator: "\n")),
                "returned_lines": .number(100), "eof": .bool(true),
            ]).encodedString)
        page.hasBoundedModelContent = true
        let result = await AgentToolOutputProjection(workspace: workspace).project(page, invocation: invocation())
        let output = try fields(result)
        let returned = try #require(output["returned_lines"]?.integerValue)
        #expect(returned > 0 && returned < 100)
        #expect(output["next_offset"] == .number(Double(10 + returned)))
        #expect(output["eof"] == .bool(false))
        #expect(result.modelContent!.utf8.count <= 65_536)
        #expect(output["capture_status"] == .string("not_requested"))
        #expect(result.truncateMarker == "[Showing lines 10-\(9 + returned)]")
        #expect(output["continuation"] == .string("Continue with offset \(10 + returned)."))
        #expect(try await workspace.usage().entries == 0)
        let untouched = await AgentToolOutputProjection(workspace: workspace).project(
            page, invocation: invocation(), strategy: .none)
        #expect(untouched.modelContent == page.content)
        let tiny = await AgentToolOutputProjection(workspace: workspace, maximumBytes: 1).project(
            page, invocation: invocation())
        #expect(try #require(tiny.modelContent).utf8.count <= 1)
    }

    @Test
    func messagePagePreservesItsCursorAfterByteAndLineTruncation() async throws {
        var raw = AgentToolResult(
            callID: "call",
            content: AgentJSONValue.object([
                "message_offset": .number(4),
                "messages": .array([
                    .object([
                        "text": .string(String(repeating: "\"quoted\"\n", count: 100)),
                        "line_offset": .number(21),
                    ])
                ]),
                "next_cursor": .string("5"),
            ]).encodedString)
        raw.hasBoundedModelContent = true
        let result = await AgentToolOutputProjection(maximumLines: 10).project(raw, invocation: invocation())
        let output = try fields(result)
        #expect(output["next_cursor"] == .string("4:31"))
        #expect(
            output["messages"]?.arrayValue?.first?.objectValue?["text"]
                == .string(String(repeating: "\"quoted\"\n", count: 10)))
        #expect(result.outputCapture == nil)
        #expect(result.truncateMarker == "[Showing lines 1-10 of 100]")
    }

    @Test
    func escapingOverageMustNotCollapseAPageToZeroLines() async throws {
        let line = String(repeating: "\"", count: 400) + "\n"
        var raw = AgentToolResult(
            callID: "call",
            content: AgentJSONValue.object([
                "message_offset": .number(0),
                "messages": .array([.object(["text": .string(String(repeating: line, count: 200))])]),
            ]).encodedString)
        raw.hasBoundedModelContent = true
        let result = await AgentToolOutputProjection().project(raw, invocation: invocation())
        let output = try fields(result)
        let text = try #require(output["messages"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(!text.isEmpty)
        #expect(text.components(separatedBy: "\n").dropLast().allSatisfy { $0 + "\n" == line })
        #expect(output["next_cursor"]?.stringValue != "0:1")
        #expect(try #require(result.modelContent).utf8.count <= 65_536)

        raw.content =
            AgentJSONValue.object([
                "message_offset": .number(0),
                "messages": .array([.object(["text": .string(String(repeating: "x", count: 65_537))])]),
            ]).encodedString
        let oversized = await AgentToolOutputProjection().project(raw, invocation: invocation())
        #expect(oversized.truncateMarker == "[Showing 0 of 1 lines]")
        #expect(try fields(oversized)["skip_cursor"] == .string("1"))
        #expect(
            try fields(oversized)["continuation"]
                == .string(
                    "A whole line exceeds the response limit. Cursor 1 skips it."))
    }
}

private final class FilenameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> String {
        lock.withLock {
            value += 1
            return "output/test-\(value).txt"
        }
    }
}
