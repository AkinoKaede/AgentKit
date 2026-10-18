import Foundation

/// Ordered UTF-8 output from synchronous transport callbacks.
/// One coalescing writer archives complete snapshots without blocking the transport.
public nonisolated final class AgentOutputAccumulator: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var output: String
        public var capture: AgentOutputCaptureInfo?
        public var isTruncated: Bool
        public var revision: Int = 0
        public var totalLines: Int = 0
        public var lineOffset: Int = 0
    }

    public let id = UUID()
    private let lock = NSLock()
    private let workspace: AgentScratchWorkspace
    private let audience: AgentOutputAudience
    private let makePath: @Sendable () -> String
    private var full = Data()
    private var tail = Data()
    private var tailStartsInsideLine = false
    private var totalBytes = 0
    private var totalNewlines = 0
    private var lastByte: UInt8?
    private var writerRunning = false
    private var revision = 0
    private var savedRevision = -1

    public init(
        workspace: AgentScratchWorkspace = .shared(), audience: AgentOutputAudience = .model,
        path: @escaping @Sendable () -> String
    ) {
        self.workspace = workspace
        self.audience = audience
        makePath = path
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let startWriter = lock.withLock {
            totalBytes += data.count
            totalNewlines += data.filter { $0 == 10 }.count
            lastByte = data.last
            revision += 1
            full.append(data)
            tail.append(data)
            // Keep a bounded suffix, but never expose the fragment left by its
            // byte boundary. A later newline restores a valid starting line.
            if tail.count > AgentTruncateLimits.maximumBytes {
                let removed = tail.count - AgentTruncateLimits.maximumBytes
                tailStartsInsideLine = tail[tail.startIndex + removed - 1] != 10
                tail = Data(tail.suffix(AgentTruncateLimits.maximumBytes))
            }
            guard audience == .model, needsCapture, !writerRunning else { return false }
            writerRunning = true
            return true
        }
        if startWriter {
            Task { [self] in
                while true {
                    _ = await snapshot()
                    let again = lock.withLock {
                        if savedRevision < revision { return true }
                        writerRunning = false
                        return false
                    }
                    if !again { return }
                }
            }
        }
    }

    private var needsCapture: Bool {
        totalBytes > AgentTruncateLimits.maximumBytes || lineCount > AgentTruncateLimits.maximumLines
    }

    private var lineCount: Int { totalNewlines + (lastByte != nil && lastByte != 10 ? 1 : 0) }

    /// Progress is intentionally cheap; durable snapshots redact the complete
    /// capture, so credentials split between callbacks are still hidden.
    public var preview: String {
        lock.withLock {
            AgentTruncateResult.apply(
                AgentSensitiveDataRedactor.visibleText(tailText), strategy: .tail
            ).content
        }
    }

    private var tailText: String {
        let bytes: Data
        if tailStartsInsideLine {
            bytes = tail.firstIndex(of: 10).map { Data(tail.suffix(from: $0 + 1)) } ?? Data()
        } else {
            bytes = tail
        }
        // A decoder must not turn a UTF-8 sequence split across callbacks into
        // replacement characters in a live preview.
        for suffix in 0...min(3, bytes.count) {
            if let text = String(data: bytes.dropLast(suffix), encoding: .utf8) { return text }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A caller may archive this snapshot under its own tool-specific path,
    /// without copying a previously truncated preview or changing the stream's archive.
    public func snapshot(
        envelopeBytes: Int = 0, capturePath: (@Sendable () -> String)? = nil
    ) async -> Snapshot {
        let state = lock.withLock {
            (full: full, revision: revision, needsCapture: needsCapture)
        }
        if audience == .externalClient {
            return Snapshot(output: Self.decoded(state.full), isTruncated: false, revision: state.revision)
        }
        let text = AgentSensitiveDataRedactor.visibleText(Self.decoded(state.full))
        var capture: AgentOutputCaptureInfo?
        if state.needsCapture
            || AgentJSONValue.string(text).encodedString.utf8.count + envelopeBytes > AgentTruncateLimits.maximumBytes
        {
            capture = await workspace.captureOutput(
                text, id: capturePath == nil ? id : UUID(), revision: state.revision, path: capturePath ?? makePath)
        }
        lock.withLock {
            if state.revision >= savedRevision {
                savedRevision = state.revision
            }
        }
        let selected = AgentTruncateResult.apply(text, strategy: .tail)
        return Snapshot(
            output: selected.content, capture: capture, isTruncated: selected.isTruncated,
            revision: state.revision, totalLines: selected.totalLines,
            lineOffset: max(0, selected.totalLines - selected.returnedLines))
    }

    /// Non-streaming tools opt in using the same collector. Only the received
    /// result is archived; this never fetches additional pages from a source.
    public func capturing(_ result: AgentToolResult) async -> AgentToolResult {
        guard audience == .model else { return result }
        let text =
            AgentToolResult.decodeStructuredPayload(
                result.content, isUntrusted: result.metadata["untrusted"]?.boolValue == true
            ).map(AgentToolResult.archiveText) ?? result.untrustedPayload ?? result.content
        append(Data(text.utf8))
        let snapshot = await snapshot(envelopeBytes: max(0, result.content.utf8.count - text.utf8.count))
        var result = result
        result.outputCapture = snapshot.capture
        return result
    }

    private static func decoded(_ data: Data) -> String {
        for suffix in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(suffix), encoding: .utf8) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
