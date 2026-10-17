import Foundation

/// Local policy, never an argument advertised to a model or accepted from MCP metadata.
public nonisolated enum AgentTruncateStrategy: String, Codable, Sendable, CaseIterable {
    case head, tail, middle, none
}

public nonisolated struct AgentTruncateLimits: Hashable, Codable, Sendable {
    public static let maximumBytes = 64 * 1_024
    public static let maximumLines = 2_000
    public var bytes: Int
    public var lines: Int

    public init(bytes: Int = Self.maximumBytes, lines: Int = Self.maximumLines) {
        self.bytes = max(0, bytes)
        self.lines = max(0, lines)
    }
}

/// Coordinates refer to logical source lines, not wrapped display rows.
public nonisolated struct AgentTruncateResult: Equatable, Sendable {
    public var content: String
    public var totalBytes: Int
    public var totalLines: Int
    public var returnedLines: Int
    public var ranges: [ClosedRange<Int>]
    public var isTruncated: Bool
    public var oversizedLine: Bool

    /// Selects whole lines, including their original line endings. An unterminated
    /// final line is a whole line in this snapshot, so interactive prompts survive.
    public static func apply(
        _ text: String, strategy: AgentTruncateStrategy = .head,
        limits: AgentTruncateLimits = AgentTruncateLimits()
    ) -> Self {
        let source = logicalLines(text)
        let totalBytes = text.utf8.count
        guard strategy != .none, totalBytes > limits.bytes || source.count > limits.lines else {
            return Self(
                content: text, totalBytes: totalBytes, totalLines: source.count,
                returnedLines: source.count, ranges: source.isEmpty ? [] : [1...source.count],
                isTruncated: false, oversizedLine: false)
        }
        let marker = "\n...\n"
        let middle = strategy == .middle
        var bytes = max(0, limits.bytes - (middle ? marker.utf8.count : 0))
        var lines = max(0, limits.lines - (middle ? 2 : 0))
        var head = 0
        var tail = source.count
        func prefix(_ byteBudget: Int, _ lineBudget: Int) -> (Int, Int) {
            var usedBytes = 0
            var usedLines = 0
            while head < tail, usedLines < lineBudget {
                let size = source[head].utf8.count
                guard usedBytes + size <= byteBudget else { break }
                head += 1
                usedLines += 1
                usedBytes += size
            }
            return (usedBytes, usedLines)
        }
        func suffix(_ byteBudget: Int, _ lineBudget: Int) -> (Int, Int) {
            var usedBytes = 0
            var usedLines = 0
            while tail > head, usedLines < lineBudget {
                let size = source[tail - 1].utf8.count
                guard usedBytes + size <= byteBudget else { break }
                tail -= 1
                usedLines += 1
                usedBytes += size
            }
            return (usedBytes, usedLines)
        }
        switch strategy {
        case .head: _ = prefix(bytes, lines)
        case .tail: _ = suffix(bytes, lines)
        case .middle:
            let first = prefix(bytes / 2, lines / 2)
            bytes -= first.0
            lines -= first.1
            let last = suffix(bytes, lines)
            _ = prefix(bytes - last.0, lines - last.1)
        case .none: break
        }
        let leading = source.prefix(head).joined()
        let trailing = source.suffix(source.count - tail).joined()
        let separator = middle && !leading.isEmpty && !trailing.isEmpty ? marker : ""
        var ranges: [ClosedRange<Int>] = []
        if head > 0 { ranges.append(1...head) }
        if tail < source.count { ranges.append((tail + 1)...source.count) }
        return Self(
            content: leading + separator + trailing, totalBytes: totalBytes, totalLines: source.count,
            returnedLines: head + source.count - tail, ranges: ranges, isTruncated: true,
            oversizedLine: source[head..<tail].contains { $0.utf8.count > limits.bytes })
    }

    /// Scanning UTF-8 keeps CRLF together, including when Swift treats it as one Character.
    public static func logicalLines(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        var result: [String] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 10 {
            result.append(String(decoding: bytes[start...index], as: UTF8.self))
            start = index + 1
        }
        if start < bytes.count { result.append(String(decoding: bytes[start...], as: UTF8.self)) }
        return result
    }
}
