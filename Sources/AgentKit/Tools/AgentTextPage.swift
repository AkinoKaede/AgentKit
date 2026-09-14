import Foundation

public nonisolated struct AgentTextPage: Sendable, Equatable {
    public var content: String
    public var offset: Int
    public var returnedLines: Int
    public var nextOffset: Int?
    public var isTruncated: Bool { nextOffset != nil }
}

/// A bounded UTF-8 line scanner shared by local and streaming file readers.
/// Feed chunks until isComplete, or call finish at EOF. Skipped lines are not retained.
public nonisolated struct AgentTextPageReader: Sendable {
    public static let defaultMaximumBytes = 50 * 1_024
    public static let defaultLineLimit = 2_000
    private let offset: Int
    private let limit: Int
    private let maximumBytes: Int
    private var line = Data()
    private var hasPendingBytes = false
    private var scannedLines = 0
    private var lines: [String] = []
    private var bytes = 0
    private var hasMore = false
    public private(set) var isComplete = false

    public init(offset: Int = 1, limit: Int = defaultLineLimit, maximumBytes: Int = defaultMaximumBytes) throws {
        guard offset > 0, limit > 0, maximumBytes > 0 else {
            throw AgentToolError.invalidArguments(
                String(localized: "offset, limit, and maximumBytes must be positive.", bundle: .module))
        }
        self.offset = offset
        self.limit = limit
        self.maximumBytes = maximumBytes
    }

    public mutating func append(_ data: Data) throws {
        for byte in data {
            guard !isComplete else { return }
            if lines.count == limit {
                hasMore = true
                isComplete = true
                return
            }
            hasPendingBytes = true
            if byte == 10 {
                try finishLine()
            } else if scannedLines + 1 >= offset {
                line.append(byte)
                // One extra byte permits CRLF at the exact byte limit.
                if line.count > maximumBytes + 1 {
                    if lines.isEmpty {
                        throw AgentToolError.invalidArguments(
                            String(
                                localized:
                                    "Line \(scannedLines + 1) exceeds the \(maximumBytes)-byte page limit. Use a targeted byte slice or search.",
                                bundle: .module)
                        )
                    }
                    hasMore = true
                    isComplete = true
                }
            }
        }
    }

    public mutating func finish() throws -> AgentTextPage {
        if !isComplete, hasPendingBytes { try finishLine() }
        if !isComplete, offset > max(1, scannedLines) {
            throw AgentToolError.invalidArguments(
                String(
                    localized: "offset \(offset) is past the end of the file (\(scannedLines) lines).", bundle: .module)
            )
        }
        isComplete = true
        return AgentTextPage(
            content: lines.joined(separator: "\n"), offset: offset,
            returnedLines: lines.count, nextOffset: hasMore ? offset + lines.count : nil
        )
    }

    private mutating func finishLine() throws {
        scannedLines += 1
        hasPendingBytes = false
        defer { line.removeAll(keepingCapacity: true) }
        guard scannedLines >= offset else { return }
        if line.last == 13 { line.removeLast() }
        guard line.count <= maximumBytes else {
            throw AgentToolError.invalidArguments(
                String(
                    localized:
                        "Line \(scannedLines) exceeds the \(maximumBytes)-byte page limit. Use a targeted byte slice or search.",
                    bundle: .module)
            )
        }
        guard let text = String(data: line, encoding: .utf8) else {
            throw AgentToolError.invalidArguments(
                String(localized: "The selected file window is not UTF-8 text.", bundle: .module))
        }
        let added = line.count + (lines.isEmpty ? 0 : 1)
        guard bytes + added <= maximumBytes else {
            hasMore = true
            isComplete = true
            return
        }
        lines.append(text)
        bytes += added
    }
}
