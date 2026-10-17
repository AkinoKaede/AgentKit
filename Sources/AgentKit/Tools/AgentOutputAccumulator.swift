import Foundation

/// Ordered UTF-8 output from synchronous transport callbacks. Memory for a model
/// capture is bounded by the workspace's file quota, not command duration.
/// One coalescing writer archives snapshots without blocking the transport.
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
    private var exceededQuota = false
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
            if audience == .externalClient || full.count + data.count <= AgentScratchWorkspace.Limits.fileBytes {
                if !exceededQuota { full.append(data) }
            } else {
                exceededQuota = true
                full.removeAll()
            }
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
    /// bounded capture, so credentials split between callbacks are still hidden.
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
            (full, tailText, revision, needsCapture, exceededQuota, totalBytes, lineCount)
        }
        if audience == .externalClient {
            return Snapshot(output: Self.decoded(state.0), isTruncated: false, revision: state.2)
        }
        let text = AgentSensitiveDataRedactor.visibleText(
            state.4 ? state.1 : Self.decoded(state.0))
        var capture: AgentOutputCaptureInfo?
        if state.4 {
            capture = AgentOutputCaptureInfo(
                bytes: state.5, lines: state.6,
                error: "Output exceeds the scratch file quota; no complete saved copy is available.")
        } else if state.3
            || AgentJSONValue.string(text).encodedString.utf8.count + envelopeBytes > AgentTruncateLimits.maximumBytes
        {
            capture = await workspace.captureOutput(
                text, id: capturePath == nil ? id : UUID(), revision: state.2, path: capturePath ?? makePath)
        }
        lock.withLock {
            if state.2 >= savedRevision {
                savedRevision = state.2
            }
        }
        let selected = AgentTruncateResult.apply(text, strategy: .tail)
        let totalLines = state.4 ? state.6 : selected.totalLines
        return Snapshot(
            output: selected.content, capture: capture, isTruncated: state.4 || selected.isTruncated,
            revision: state.2, totalLines: totalLines, lineOffset: max(0, totalLines - selected.returnedLines))
    }

    /// Non-streaming tools opt in using the same collector. Only the received
    /// result is archived; this never fetches additional pages from a source.
    public func capturing(_ result: AgentToolResult) async -> AgentToolResult {
        guard audience == .model else { return result }
        let payload = result.untrustedPayload ?? result.content
        let text = AgentToolOutputProjection.archiveText(payload)
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
