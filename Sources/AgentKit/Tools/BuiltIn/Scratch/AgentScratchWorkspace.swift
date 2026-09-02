import CryptoKit
import Foundation

// MARK: - Values

public nonisolated enum ScratchEntryKind: String, Hashable, Sendable, Codable {
    case file, directory
}

public nonisolated struct ScratchEntry: Hashable, Sendable {
    public init(
        path: String,
        kind: ScratchEntryKind,
        bytes: Int,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.modifiedAt = modifiedAt
    }

    public var path: String
    public var kind: ScratchEntryKind
    public var bytes: Int
    public var modifiedAt: Date?
}

/// How much of the workspace is spent. Returned with every write so the agent can
/// stay under the ceiling deliberately rather than discover it by failing.
public nonisolated struct ScratchUsage: Hashable, Sendable {
    public init(
        bytes: Int,
        entries: Int,
        byteQuota: Int,
        entryQuota: Int
    ) {
        self.bytes = bytes
        self.entries = entries
        self.byteQuota = byteQuota
        self.entryQuota = entryQuota
    }

    public var bytes: Int
    public var entries: Int
    public var byteQuota: Int
    public var entryQuota: Int
}

public nonisolated struct ScratchFile: Hashable, Sendable {
    public init(
        path: String,
        data: Data,
        sha256: String
    ) {
        self.path = path
        self.data = data
        self.sha256 = sha256
    }

    public var path: String
    public var data: Data
    public var sha256: String

    public var bytes: Int { data.count }
}

/// A bounded window of a text file, in lines.
public nonisolated struct ScratchText: Hashable, Sendable {
    public init(
        path: String,
        content: String,
        bytes: Int,
        totalLines: Int,
        offset: Int,
        returnedLines: Int,
        isTruncated: Bool,
        lineEnding: LineEnding
    ) {
        self.path = path
        self.content = content
        self.bytes = bytes
        self.totalLines = totalLines
        self.offset = offset
        self.returnedLines = returnedLines
        self.isTruncated = isTruncated
        self.lineEnding = lineEnding
    }

    public var path: String
    public var content: String
    public var bytes: Int
    /// Lines in the whole file, not in this window.
    public var totalLines: Int
    /// 1-based, and the first line this window contains.
    public var offset: Int
    public var returnedLines: Int
    public var isTruncated: Bool
    public var lineEnding: LineEnding
}

public nonisolated struct ScratchSearchMatch: Hashable, Sendable {
    public init(
        path: String,
        line: Int,
        text: String,
        textTruncated: Bool
    ) {
        self.path = path
        self.line = line
        self.text = text
        self.textTruncated = textTruncated
    }

    public var path: String
    /// 1-based, matching `scratch_read`, diffs and editors.
    public var line: Int
    public var text: String
    public var textTruncated: Bool
}

public nonisolated struct ScratchSearchOutcome: Hashable, Sendable {
    public init(
        matches: [ScratchSearchMatch],
        matchingLines: Int,
        searchedFiles: Int,
        skippedBinaryFiles: Int,
        caseSensitive: Bool,
        isTruncated: Bool
    ) {
        self.matches = matches
        self.matchingLines = matchingLines
        self.searchedFiles = searchedFiles
        self.skippedBinaryFiles = skippedBinaryFiles
        self.caseSensitive = caseSensitive
        self.isTruncated = isTruncated
    }

    public var matches: [ScratchSearchMatch]
    /// Matching lines in the whole search, including those past `limit`.
    public var matchingLines: Int
    public var searchedFiles: Int
    public var skippedBinaryFiles: Int
    public var caseSensitive: Bool
    public var isTruncated: Bool
}

/// One replacement, matched against the file as it was before any replacement in
/// the same call was applied.
public nonisolated struct ScratchReplacement: Hashable, Sendable {
    public init(
        oldText: String,
        newText: String,
        isRegularExpression: Bool = false,
        count: Int? = nil
    ) {
        self.oldText = oldText
        self.newText = newText
        self.isRegularExpression = isRegularExpression
        self.count = count
    }

    /// Literal text, or an ICU pattern when `isRegularExpression`.
    public var oldText: String
    /// Literal text, or an `NSRegularExpression` template — `$1` for a capture
    /// group — when `isRegularExpression`.
    public var newText: String
    public var isRegularExpression = false
    /// How many occurrences this replacement claims.
    ///
    /// `nil` is the careful default and the behavior this tool had before the
    /// field existed: the match must be unique, and anything ambiguous fails the
    /// whole call. `0` means every occurrence, and `n` means the first `n` in
    /// document order — fewer than `n` is an error rather than a partial apply,
    /// because a replacement that silently did less than it said is the one
    /// outcome nobody can reason about.
    public var count: Int? = nil
}

public nonisolated struct ScratchWriteOutcome: Hashable, Sendable {
    public init(
        path: String,
        bytes: Int,
        sha256: String,
        didCreate: Bool,
        usage: ScratchUsage
    ) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
        self.didCreate = didCreate
        self.usage = usage
    }

    public var path: String
    public var bytes: Int
    public var sha256: String
    public var didCreate: Bool
    public var usage: ScratchUsage
}

public nonisolated struct ScratchReplaceOutcome: Hashable, Sendable {
    public init(
        path: String,
        entriesApplied: Int,
        replacementsApplied: Int,
        diff: UnifiedDiff,
        bytes: Int,
        sha256: String,
        lineEnding: LineEnding,
        usage: ScratchUsage
    ) {
        self.path = path
        self.entriesApplied = entriesApplied
        self.replacementsApplied = replacementsApplied
        self.diff = diff
        self.bytes = bytes
        self.sha256 = sha256
        self.lineEnding = lineEnding
        self.usage = usage
    }

    public var path: String
    /// Entries in the request. One of them may have rewritten many regions.
    public var entriesApplied: Int
    /// Regions actually rewritten, which is what `count` bounds.
    public var replacementsApplied: Int
    public var diff: UnifiedDiff
    public var bytes: Int
    public var sha256: String
    public var lineEnding: LineEnding
    public var usage: ScratchUsage
}

/// The result of moving bytes from one place in the workspace to another.
public nonisolated struct ScratchTransferOutcome: Hashable, Sendable {
    public init(
        from: String,
        to: String,
        kind: ScratchEntryKind,
        files: Int,
        bytes: Int,
        didOverwrite: Bool,
        usage: ScratchUsage
    ) {
        self.from = from
        self.to = to
        self.kind = kind
        self.files = files
        self.bytes = bytes
        self.didOverwrite = didOverwrite
        self.usage = usage
    }

    public var from: String
    public var to: String
    public var kind: ScratchEntryKind
    /// Regular files involved. One for a file, and the whole subtree for a
    /// directory.
    public var files: Int
    public var bytes: Int
    public var didOverwrite: Bool
    public var usage: ScratchUsage
}

// MARK: - Workspace

/// A per-conversation staging directory inside the app's own container.
///
/// It exists so bytes can move between a host and the model's attention without
/// passing *through* the model: a transfer tool can land a file here and take
/// can take one from here, so the ordinary "pull a config, change three lines, push
/// it back" job stops costing two full copies of the file in tokens.
///
/// An `actor`, and that is load-bearing rather than incidental. Pi serializes file
/// mutations through an explicit per-path queue (`file-mutation-queue.ts`); here the
/// actor already serializes every operation against every other, so `replace(_:in:)`
/// is atomic across its read and its write for free. That is what lets every scratch
/// tool stay `.parallel` — a batch containing one of them does not have to drag its
/// whole turn serial to be safe.
///
/// Nothing outside the scope directory is reachable. Paths are relative, `..` is
/// refused outright rather than resolved, and the built URL is proven to still be
/// inside the scope after symlink resolution.
public actor AgentScratchWorkspace {
    public nonisolated enum Limits {
        public static let fileBytes = 8 * 1_024 * 1_024
        public static let totalBytes = 64 * 1_024 * 1_024
        public static let entries = 512
        public static let pathBytes = 1_024
        public static let componentBytes = 255
        public static let depth = 8
        /// What `scratch_read` will put in front of the model at once, matching
        /// a remote read's inline ceiling. A *file* may be far larger; reading it
        /// whole is what the offset/limit window and a transfer tool are for.
        public static let inlineReadBytes = 128 * 1_024
        public static let searchQueryCharacters = 4_096
        public static let searchLineBytes = 1_024
        public static let searchResults = 100
        public static let replacements = 32
        /// The ceiling on one replacement's `count`, and on how many regions it
        /// may collect when asked for all of them. A pattern matching more than
        /// this is one nobody meant to write.
        public static let matchesPerReplacement = 10_000
    }

    private let conversationID: UUID
    private let base: URL?
    private let applicationName: String
    private var scope: URL?

    /// `base` is injectable for tests only; in the app it resolves to Application
    /// Support inside the sandbox container, under `applicationName`.
    public init(conversationID: UUID, applicationName: String = "Agent", base: URL? = nil) {
        self.conversationID = conversationID
        self.applicationName = applicationName
        self.base = base
    }

    /// The folder every scope lives under, named for the app that owns it.
    ///
    /// Application Support rather than Caches deliberately: the system may evict a
    /// Caches directory mid-run, and a staging area that can vanish between two tool
    /// calls is worse than no staging area. `applicationName` is a parameter rather
    /// than a constant because two apps sharing a container must not share a
    /// workspace, and because a sandboxed app's Application Support is already its
    /// own — the name is what makes the path legible to a person looking at it.
    public static func defaultBase(applicationName: String) throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appending(path: applicationName, directoryHint: .isDirectory)
        .appending(path: "Scratch", directoryHint: .isDirectory)
    }

    public static func copyScope(
        from sourceID: UUID, to destinationID: UUID, applicationName: String
    ) throws {
        let base = try defaultBase(applicationName: applicationName)
        let source = base.appending(path: sourceID.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            return
        }
        let destination = base.appending(
            path: destinationID.uuidString, directoryHint: .isDirectory
        )
        guard
            !FileManager.default.fileExists(
                atPath: destination.path(percentEncoded: false)
            )
        else { return }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: Reading

    public func usage() throws -> ScratchUsage { try measure(in: try root()) }

    public func list(_ path: String?, recursive: Bool) throws -> [ScratchEntry] {
        let root = try root()
        let directory = try path.map { try resolve($0, in: root) } ?? root
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            throw AgentToolError.scratchNotFound(path ?? ".")
        }
        var entries: [ScratchEntry] = []
        try walk(directory, root: root, recursive: recursive) { entries.append($0) }
        return entries.sorted { $0.path < $1.path }
    }

    /// A bounded window, in lines, of a UTF-8 file.
    ///
    /// `offset` is 1-based to match how the file will be talked about everywhere
    /// else — a diff hunk, an error message, an editor.
    public func read(
        _ path: String, offset: Int? = nil, limit: Int? = nil,
        maximumBytes: Int = Limits.inlineReadBytes
    ) throws -> ScratchText {
        let file = try data(at: path)
        guard let raw = String(data: file.data, encoding: .utf8) else {
            throw AgentToolError.scratchNotText(path)
        }
        let ending = LineEnding.detected(in: raw)
        let (lines, _) = UnifiedDiff.split(LineEnding.normalizedToLF(raw))

        let start = max(1, offset ?? 1)
        guard start <= max(lines.count, 1) else {
            throw AgentToolError.invalidArguments(
                "offset \(start) is past the end of \(path), which has \(lines.count) lines."
            )
        }
        let end = limit.map { min(lines.count, start - 1 + max(0, $0)) } ?? lines.count
        let window = start - 1 < end ? Array(lines[(start - 1)..<end]) : []

        var content = window.joined(separator: "\n")
        var isTruncated = false
        if content.utf8.count > maximumBytes {
            content = String(decoding: content.utf8.prefix(maximumBytes), as: UTF8.self)
            isTruncated = true
        }
        return ScratchText(
            path: path, content: content, bytes: file.bytes, totalLines: lines.count,
            offset: start, returnedLines: window.count,
            isTruncated: isTruncated || end < lines.count, lineEnding: ending
        )
    }

    /// The whole file, undecoded. What a transfer tool uses, and the reason
    /// a scratch file does not have to be text at all.
    public func data(at path: String) throws -> ScratchFile {
        let url = try resolve(path, in: try root())
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
        else { throw AgentToolError.scratchNotFound(path) }
        let data = try Data(contentsOf: url)
        return ScratchFile(path: path, data: data, sha256: Self.digest(data))
    }

    /// Search UTF-8 files one line at a time without putting whole files into the
    /// transcript. A directory scope is always recursive; `nil` means the workspace
    /// root. Non-text files are counted and skipped rather than making a mixed tree
    /// impossible to search.
    public func search(
        _ query: String, path: String? = nil, regex: Bool = false,
        caseSensitive requestedCaseSensitivity: Bool? = nil, limit: Int = 20
    ) throws -> ScratchSearchOutcome {
        guard !query.isEmpty else {
            throw AgentToolError.invalidArguments("query is required.")
        }
        guard query.count <= Limits.searchQueryCharacters else {
            throw AgentToolError.invalidArguments(
                "query is past the limit of \(Limits.searchQueryCharacters) characters."
            )
        }
        guard !query.contains("\n"), !query.contains("\r") else {
            throw AgentToolError.invalidArguments(
                "query must fit on one line; scratch_search does not match across lines."
            )
        }
        guard (1...Limits.searchResults).contains(limit) else {
            throw AgentToolError.invalidArguments(
                "limit must be between 1 and \(Limits.searchResults)."
            )
        }

        let caseSensitive =
            requestedCaseSensitivity
            ?? query.unicodeScalars.contains {
                CharacterSet.uppercaseLetters.contains($0)
            }
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(
                pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]
            )
        } catch {
            throw AgentToolError.invalidArguments("query is not a valid regular expression.")
        }

        let root = try root()
        let files = try searchFiles(at: path, in: root)
        var matches: [ScratchSearchMatch] = []
        var matchingLines = 0
        var searchedFiles = 0
        var skippedBinaryFiles = 0
        var previewWasTruncated = false

        for filePath in files {
            let file = try data(at: filePath)
            guard let raw = String(data: file.data, encoding: .utf8) else {
                skippedBinaryFiles += 1
                continue
            }
            searchedFiles += 1
            let normalized = LineEnding.normalizedToLF(raw)
            let (lines, _) = UnifiedDiff.split(normalized)
            for (index, line) in lines.enumerated() {
                let wholeLine = NSRange(line.startIndex..<line.endIndex, in: line)
                guard
                    let first = expression.firstMatch(
                        in: line, range: wholeLine
                    ), let range = Range(first.range, in: line)
                else { continue }
                matchingLines += 1
                guard matches.count < limit else { continue }
                let preview = Self.searchPreview(
                    of: line, around: range, maximumBytes: Limits.searchLineBytes
                )
                previewWasTruncated = previewWasTruncated || preview.truncated
                matches.append(
                    ScratchSearchMatch(
                        path: filePath, line: index + 1, text: preview.text,
                        textTruncated: preview.truncated
                    ))
            }
        }
        return ScratchSearchOutcome(
            matches: matches, matchingLines: matchingLines,
            searchedFiles: searchedFiles, skippedBinaryFiles: skippedBinaryFiles,
            caseSensitive: caseSensitive,
            isTruncated: previewWasTruncated || matchingLines > matches.count
        )
    }

    // MARK: Writing

    @discardableResult
    public func write(_ path: String, data: Data) throws -> ScratchWriteOutcome {
        let root = try root()
        let url = try resolve(path, in: root)
        let existing = Self.size(of: url)
        try checkQuota(in: root, adding: data.count, replacing: existing)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return ScratchWriteOutcome(
            path: path, bytes: data.count, sha256: Self.digest(data),
            didCreate: existing == nil, usage: try measure(in: root)
        )
    }

    /// Replacement inside one staged file, following Pi's `edit` tool and widened
    /// with a pattern mode and an occurrence count.
    ///
    /// Every `oldText` is matched against the file as it was *before* this call, not
    /// against the result of the preceding entry — so the model never has to simulate
    /// its own changes to write the second one. Regions must not overlap, and an
    /// entry that leaves `count` unset must name exactly one of them; anything
    /// ambiguous fails the whole call rather than applying part of it, because a
    /// half-applied change is the one outcome nobody can reason about.
    public func replace(
        _ replacements: [ScratchReplacement], in path: String
    ) throws -> ScratchReplaceOutcome {
        guard !replacements.isEmpty else {
            throw AgentToolError.invalidArguments("replacements must contain at least one entry.")
        }
        guard replacements.count <= Limits.replacements else {
            throw AgentToolError.invalidArguments(
                """
                replacements contains \(replacements.count) entries, past the limit of \
                \(Limits.replacements).
                """
            )
        }
        let file = try data(at: path)
        guard let raw = String(data: file.data, encoding: .utf8) else {
            throw AgentToolError.scratchNotText(path)
        }

        let ending = LineEnding.detected(in: raw)
        // Read from the bytes, not from `raw`: Foundation strips a UTF-8 BOM while
        // decoding, so by the time the file is a String the only evidence it ever
        // had one is gone — and writing the String back drops those three bytes
        // from a file nobody asked to change that way.
        let bom = file.data.starts(with: [0xEF, 0xBB, 0xBF]) ? "\u{FEFF}" : ""
        let original = LineEnding.normalizedToLF(raw)

        var located: [Located] = []
        for replacement in replacements {
            located += try Self.locate(replacement, in: original, path: path)
        }
        located.sort { $0.range.lowerBound < $1.range.lowerBound }
        for (previous, next) in zip(located, located.dropFirst())
        where next.range.lowerBound < previous.range.upperBound {
            throw AgentToolError.invalidArguments(
                """
                Two replacements of \(path) match overlapping regions. Merge changes that \
                touch the same block into one entry.
                """
            )
        }

        var updated = ""
        var cursor = original.startIndex
        for entry in located {
            updated += original[cursor..<entry.range.lowerBound]
            updated += entry.text
            cursor = entry.range.upperBound
        }
        updated += original[cursor...]

        guard updated != original else {
            throw AgentToolError.invalidArguments("The replacements of \(path) produced no change.")
        }
        let diff = try UnifiedDiff.between(original, updated, fromPath: path, toPath: path)
        let encoded = Data((bom + ending.restore(updated)).utf8)
        let written = try write(path, data: encoded)
        return ScratchReplaceOutcome(
            path: path, entriesApplied: replacements.count,
            replacementsApplied: located.count, diff: diff, bytes: written.bytes,
            sha256: written.sha256, lineEnding: ending, usage: written.usage
        )
    }

    /// Copies a scratch file, or a whole subtree, to another path in the workspace.
    ///
    /// The point is that the bytes never enter the transcript: duplicating a staged
    /// file before a risky change would otherwise mean reading it out and writing it
    /// back, which costs two full copies of the document in tokens.
    @discardableResult
    public func copy(
        _ from: String, to: String, overwrite: Bool = false
    ) throws -> ScratchTransferOutcome {
        let plan = try transferPlan(from: from, to: to, overwrite: overwrite)
        try checkQuota(in: plan.root, addingFiles: plan.files, bytes: plan.bytes)
        if plan.replaces { try FileManager.default.removeItem(at: plan.destination) }
        try FileManager.default.createDirectory(
            at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: plan.source, to: plan.destination)
        return ScratchTransferOutcome(
            from: from, to: to, kind: plan.kind, files: plan.files, bytes: plan.bytes,
            didOverwrite: plan.replaces, usage: try measure(in: plan.root)
        )
    }

    /// Moves or renames a scratch file or subtree. Byte totals are unchanged unless
    /// the move replaced a file.
    @discardableResult
    public func move(
        _ from: String, to: String, overwrite: Bool = false
    ) throws -> ScratchTransferOutcome {
        let plan = try transferPlan(from: from, to: to, overwrite: overwrite)
        if plan.replaces { try FileManager.default.removeItem(at: plan.destination) }
        try FileManager.default.createDirectory(
            at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: plan.source, to: plan.destination)
        return ScratchTransferOutcome(
            from: from, to: to, kind: plan.kind, files: plan.files, bytes: plan.bytes,
            didOverwrite: plan.replaces, usage: try measure(in: plan.root)
        )
    }

    public func delete(_ path: String, kind: ScratchEntryKind) throws {
        let url = try resolve(path, in: try root())
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            throw AgentToolError.scratchNotFound(path)
        }
        let isDirectory = values.isDirectory == true
        guard isDirectory == (kind == .directory) else {
            throw AgentToolError.invalidArguments(
                "\(path) is a \(isDirectory ? "directory" : "file"), not a \(kind.rawValue)."
            )
        }
        if isDirectory {
            let children = try FileManager.default.contentsOfDirectory(
                atPath: url.path(percentEncoded: false)
            )
            // Only empty directories, as remote file tools generally do. A recursive delete is
            // the one scratch action that can destroy work the user wanted kept, and
            // "it is contained" is too thin a reason to let it through un-gated.
            guard children.isEmpty else {
                throw AgentToolError.invalidArguments(
                    "\(path) is not empty. Delete its \(children.count) entries first."
                )
            }
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Transfers

    /// Everything `copy` and `move` need to know before either touches the disk.
    private struct TransferPlan {
        var root: URL
        var source: URL
        var destination: URL
        var kind: ScratchEntryKind
        var files: Int
        var bytes: Int
        /// True when an existing regular file at the destination will be removed
        /// first. A directory destination is never replaced.
        var replaces: Bool
    }

    /// Validates a transfer completely before either operation begins.
    ///
    /// Both directions go through `resolve(_:in:)`, so `..`, absolute paths and
    /// traversal through a symlink are already refused. What is added here is what
    /// only a transfer can get wrong: a destination inside its own source, a subtree
    /// whose depth would exceed the limit once re-rooted, and a destination that
    /// already holds something.
    private func transferPlan(
        from: String, to: String, overwrite: Bool
    ) throws -> TransferPlan {
        let root = try root()
        let sourcePath = try Self.normalize(from)
        let destinationPath = try Self.normalize(to)
        guard sourcePath != destinationPath else {
            throw AgentToolError.invalidArguments("from and to name the same path.")
        }
        guard !destinationPath.hasPrefix(sourcePath + "/") else {
            throw AgentToolError.invalidArguments("\(to) is inside \(from).")
        }
        let source = try resolve(from, in: root)
        let destination = try resolve(to, in: root)

        guard let sourceValues = try? source.resourceValues(forKeys: [.isDirectoryKey]) else {
            throw AgentToolError.scratchNotFound(from)
        }
        let kind: ScratchEntryKind = sourceValues.isDirectory == true ? .directory : .file
        let inventory = try Self.inventory(of: source, kind: kind, path: from)

        // Re-rooting a subtree can push it past the depth limit even though both
        // arguments were fine on their own.
        for relative in inventory.relativePaths {
            _ = try Self.normalize(relative.isEmpty ? to : "\(to)/\(relative)")
        }

        var replaces = false
        if let existing = try? destination.resourceValues(forKeys: [.isDirectoryKey]) {
            guard existing.isDirectory != true else {
                throw AgentToolError.invalidArguments(
                    """
                    \(to) is an existing directory. Replacing one would delete everything \
                    beneath it, which no scratch tool does; choose another destination.
                    """
                )
            }
            guard overwrite else {
                throw AgentToolError.invalidArguments(
                    "\(to) already exists. Pass overwrite to replace it."
                )
            }
            replaces = true
        }
        return TransferPlan(
            root: root, source: source, destination: destination, kind: kind,
            files: inventory.files, bytes: inventory.bytes, replaces: replaces
        )
    }

    /// What a subtree holds, refusing anything a transfer must not duplicate.
    ///
    /// `walk` skips a symlink silently, which is right for a listing and wrong here:
    /// `copyItem` would recreate the link, and an alias inside the workspace makes
    /// two paths the same file — which is exactly what breaks both the quota
    /// arithmetic and the atomicity `replace(_:in:)` claims.
    private static func inventory(
        of url: URL, kind: ScratchEntryKind, path: String
    ) throws -> (files: Int, bytes: Int, relativePaths: [String]) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard kind == .directory else {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AgentToolError.scratchNotFound(path)
            }
            return (1, values.fileSize ?? 0, [""])
        }

        var files = 0
        var bytes = 0
        var relativePaths: [String] = []
        var pending: [(url: URL, relative: String)] = [(url, "")]
        while let entry = pending.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                at: entry.url, includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            )
            for child in children {
                let relative =
                    entry.relative.isEmpty
                    ? child.lastPathComponent : "\(entry.relative)/\(child.lastPathComponent)"
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    throw AgentToolError.scratchPathEscapes
                }
                if values.isDirectory == true {
                    relativePaths.append(relative)
                    pending.append((child, relative))
                } else if values.isRegularFile == true {
                    files += 1
                    bytes += values.fileSize ?? 0
                    relativePaths.append(relative)
                } else {
                    // A socket, a device node — nothing this workspace put there,
                    // and nothing it will duplicate.
                    throw AgentToolError.scratchPathEscapes
                }
            }
        }
        return (files, bytes, relativePaths.isEmpty ? [""] : relativePaths)
    }

    /// Called when the conversation this workspace belongs to is deleted.
    public func removeScope() throws {
        guard let scope = try? root() else { return }
        self.scope = nil
        guard FileManager.default.fileExists(atPath: scope.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: scope)
    }

    // MARK: - Containment

    private func root() throws -> URL {
        if let scope { return scope }
        let base = try self.base ?? Self.defaultBase(applicationName: applicationName)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Working data, and often a copy of somebody's production config. It has no
        // business in a Time Machine snapshot.
        var backupExcluded = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? backupExcluded.setResourceValues(values)

        let scope = base.appending(path: conversationID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        self.scope = scope
        return scope
    }

    /// Normalizes a model-supplied path and proves the result is inside the scope.
    ///
    /// `..` is rejected rather than popped — the inverse of `normalizeRemotePath`,
    /// which resolves it. A relative path with `..` in it is never something the
    /// agent needed to write, so refusing is both safe and a clearer error than
    /// silently rewriting what was asked for.
    private func resolve(_ raw: String, in root: URL) throws -> URL {
        let relative = try Self.normalize(raw)
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try Self.assertNoSymlink(in: url, below: root)

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        guard resolved.hasPrefix(resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/")
        else { throw AgentToolError.scratchPathEscapes }
        return url
    }

    public static func normalize(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= Limits.pathBytes else {
            throw AgentToolError.scratchPathEscapes
        }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~"),
            !raw.contains("\0"), !raw.contains("\r"), !raw.contains("\n")
        else { throw AgentToolError.scratchPathEscapes }

        var components: [String] = []
        for component in raw.split(separator: "/") {
            if component == "." { continue }
            guard component != ".." else { throw AgentToolError.scratchPathEscapes }
            guard component.utf8.count <= Limits.componentBytes else {
                throw AgentToolError.scratchPathEscapes
            }
            components.append(String(component))
        }
        guard !components.isEmpty, components.count <= Limits.depth else {
            throw AgentToolError.scratchPathEscapes
        }
        return components.joined(separator: "/")
    }

    /// Refuses to traverse or write through a symlink, even one pointing back inside
    /// the scope.
    ///
    /// Containment alone would already stop an escape. This is the stricter rule
    /// because an alias *inside* the workspace makes two paths the same file, which
    /// quietly breaks both the quota arithmetic and the atomicity `replace(_:in:)`
    /// claims.
    private static func assertNoSymlink(in url: URL, below root: URL) throws {
        let rootDepth = root.standardizedFileURL.pathComponents.count
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootDepth else { return }
        var candidate = root
        for component in components[rootDepth...] {
            candidate = candidate.appending(path: component, directoryHint: .notDirectory)
            guard let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
                return  // Does not exist yet, so nothing below it can either.
            }
            if values.isSymbolicLink == true { throw AgentToolError.scratchPathEscapes }
        }
    }

    // MARK: - Quota

    private func checkQuota(in root: URL, adding bytes: Int, replacing existing: Int?) throws {
        guard bytes <= Limits.fileBytes else {
            throw AgentToolError.scratchQuotaExceeded(
                "\(bytes) bytes is past the \(Limits.fileBytes)-byte limit for one scratch file."
            )
        }
        let usage = try measure(in: root)
        let projected = usage.bytes - (existing ?? 0) + bytes
        guard projected <= Limits.totalBytes else {
            throw AgentToolError.scratchQuotaExceeded(
                """
                The scratch workspace would reach \(projected) of \(Limits.totalBytes) bytes. \
                Delete what is no longer needed.
                """
            )
        }
        guard existing != nil || usage.entries < Limits.entries else {
            throw AgentToolError.scratchQuotaExceeded(
                "The scratch workspace already holds its limit of \(Limits.entries) files."
            )
        }
    }

    /// The same ceilings, asked about a whole subtree before any of it is copied.
    private func checkQuota(in root: URL, addingFiles files: Int, bytes: Int) throws {
        let usage = try measure(in: root)
        let projected = usage.bytes + bytes
        guard projected <= Limits.totalBytes else {
            throw AgentToolError.scratchQuotaExceeded(
                """
                The scratch workspace would reach \(projected) of \(Limits.totalBytes) bytes. \
                Delete what is no longer needed.
                """
            )
        }
        guard usage.entries + files <= Limits.entries else {
            throw AgentToolError.scratchQuotaExceeded(
                """
                The scratch workspace would hold \(usage.entries + files) files, past its limit \
                of \(Limits.entries).
                """
            )
        }
    }

    private func measure(in root: URL) throws -> ScratchUsage {
        var bytes = 0
        var entries = 0
        try walk(root, root: root, recursive: true) { entry in
            guard entry.kind == .file else { return }
            bytes += entry.bytes
            entries += 1
        }
        return ScratchUsage(
            bytes: bytes, entries: entries,
            byteQuota: Limits.totalBytes, entryQuota: Limits.entries
        )
    }

    // MARK: - Enumeration

    private func walk(
        _ directory: URL, root: URL, recursive: Bool, into visit: (ScratchEntry) -> Void
    ) throws {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        // Hidden files are *not* skipped. A quota the agent can evade by naming a
        // file `.big` is not a quota, and a listing that omits what it wrote is a
        // listing it cannot clean up from.
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        )
        for child in children {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            // Anything that is neither a regular file nor a directory — a symlink, a
            // socket — is not something this workspace put there and not something
            // it will report.
            guard isDirectory || values?.isRegularFile == true else { continue }
            visit(
                ScratchEntry(
                    path: Self.relative(child, to: root),
                    kind: isDirectory ? .directory : .file,
                    bytes: isDirectory ? 0 : (values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate
                ))
            if isDirectory, recursive {
                try walk(child, root: root, recursive: true, into: visit)
            }
        }
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let rootDepth = root.standardizedFileURL.pathComponents.count
        return url.standardizedFileURL.pathComponents.dropFirst(rootDepth).joined(separator: "/")
    }

    private static func size(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
        else { return nil }
        return values.fileSize ?? 0
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func searchFiles(at path: String?, in root: URL) throws -> [String] {
        guard let path else {
            var entries: [ScratchEntry] = []
            try walk(root, root: root, recursive: true) { entries.append($0) }
            return entries.filter { $0.kind == .file }.map(\.path).sorted()
        }
        let url = try resolve(path, in: root)
        guard
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey]
            )
        else { throw AgentToolError.scratchNotFound(path) }
        if values.isRegularFile == true { return [Self.relative(url, to: root)] }
        guard values.isDirectory == true else { throw AgentToolError.scratchNotFound(path) }
        var entries: [ScratchEntry] = []
        try walk(url, root: root, recursive: true) { entries.append($0) }
        return entries.filter { $0.kind == .file }.map(\.path).sorted()
    }

    /// Keep the first match visible in a bounded UTF-8 window. The byte boundaries
    /// are advanced to scalar boundaries so clipping never introduces replacement
    /// characters into a valid text file.
    private static func searchPreview(
        of line: String, around match: Range<String.Index>, maximumBytes: Int
    ) -> (text: String, truncated: Bool) {
        let bytes = Array(line.utf8)
        guard bytes.count > maximumBytes else { return (line, false) }
        let matchOffset = line[..<match.lowerBound].utf8.count
        var start = max(0, min(bytes.count - maximumBytes, matchOffset - maximumBytes / 2))
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        var end = min(bytes.count, start + maximumBytes)
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        let body = String(decoding: bytes[start..<end], as: UTF8.self)
        return ((start > 0 ? "…" : "") + body + (end < bytes.count ? "…" : ""), true)
    }

    // MARK: - Matching

    /// One located region and the text that will stand in its place.
    ///
    /// The text travels with the range because a pattern replacement differs per
    /// match: `$1` means whatever *that* match captured.
    private struct Located {
        var range: Range<String.Index>
        var text: String
    }

    /// Finds every region one entry names, or explains why it named the wrong number
    /// of them.
    private static func locate(
        _ replacement: ScratchReplacement, in haystack: String, path: String
    ) throws -> [Located] {
        if let count = replacement.count {
            guard count >= 0, count <= Limits.matchesPerReplacement else {
                throw AgentToolError.invalidArguments(
                    "count must be between 0 and \(Limits.matchesPerReplacement)."
                )
            }
        }
        return replacement.isRegularExpression
            ? try matchPattern(replacement, in: haystack, path: path)
            : try matchLiteral(replacement, in: haystack, path: path)
    }

    /// Exact first. The fallback is line-aligned rather than character-aligned: a
    /// window of lines whose normalized forms equal the normalized needle's. That
    /// covers the failure this fallback exists for — a model retyping a block with
    /// tidied quotes, dashes or trailing whitespace — without the index-mapping a
    /// character-level fuzzy match would need to translate a position in normalized
    /// text back into the original.
    private static func matchLiteral(
        _ replacement: ScratchReplacement, in haystack: String, path: String
    ) throws -> [Located] {
        let needle = LineEnding.normalizedToLF(replacement.oldText)
        guard !needle.isEmpty else {
            throw AgentToolError.invalidArguments("old_text must not be empty.")
        }
        let text = LineEnding.normalizedToLF(replacement.newText)
        let wanted = replacement.count

        let exact = ranges(of: needle, in: haystack, limit: searchLimit(for: wanted))
        if !exact.isEmpty {
            return try select(
                exact, count: wanted, path: path,
                ambiguity: """
                    old_text occurs \(exact.count) times in \(path). Extend it with surrounding \
                    lines until it names exactly one region, or set count to say how many to \
                    replace.
                    """
            )
            .map { Located(range: $0, text: text) }
        }

        let (lines, _) = UnifiedDiff.split(haystack)
        let (needleLines, needleEndsWithNewline) = UnifiedDiff.split(needle)
        guard !needleLines.isEmpty, needleLines.count <= lines.count else {
            throw noMatch(path)
        }
        let normalizedLines = lines.map(normalizedForMatch)
        let normalizedNeedle = needleLines.map(normalizedForMatch)
        // Greedy and non-overlapping, matching how the exact search advances past
        // each hit. Two windows sharing a line are one region asked about twice, not
        // two regions to rewrite.
        var starts: [Int] = []
        var next = 0
        for start in 0...(lines.count - needleLines.count)
        where start >= next
            && Array(normalizedLines[start..<(start + needleLines.count)]) == normalizedNeedle
        {
            starts.append(start)
            next = start + needleLines.count
        }
        let candidates = starts.map {
            lineRange(
                $0..<($0 + needleLines.count), in: haystack, lines: lines,
                includingTrailingNewline: needleEndsWithNewline
            )
        }
        return try select(
            candidates, count: wanted, path: path,
            ambiguity: """
                old_text matches \(candidates.count) regions of \(path) once punctuation and \
                trailing whitespace are ignored. Extend it until it names exactly one, or set \
                count to say how many to replace.
                """
        )
        .map { Located(range: $0, text: text) }
    }

    /// Pattern matching over the whole normalized file, so a pattern may span lines.
    ///
    /// `^` and `$` bind to lines rather than to the file, which is how a change to a
    /// config is actually described. Matching is case-sensitive; a pattern that wants
    /// otherwise says `(?i)`. The normalized fallback above does not apply here — a
    /// pattern is exact by construction, and forgiving its punctuation would mean
    /// matching something other than what it says.
    private static func matchPattern(
        _ replacement: ScratchReplacement, in haystack: String, path: String
    ) throws -> [Located] {
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(
                pattern: replacement.oldText, options: [.anchorsMatchLines]
            )
        } catch {
            throw AgentToolError.invalidArguments("old_text is not a valid regular expression.")
        }
        let template = LineEnding.normalizedToLF(replacement.newText)
        let whole = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)

        var found: [Located] = []
        var matchedNothing = false
        expression.enumerateMatches(in: haystack, range: whole) { match, _, stop in
            guard let match else { return }
            // A pattern that can match the empty string would splice new_text between
            // characters rather than replace anything, and there is no length at
            // which to stop.
            guard match.range.length > 0 else {
                matchedNothing = true
                stop.pointee = true
                return
            }
            guard let range = Range(match.range, in: haystack) else { return }
            found.append(
                Located(
                    range: range,
                    text: expression.replacementString(
                        for: match, in: haystack, offset: 0, template: template
                    )
                ))
            if found.count > Limits.matchesPerReplacement { stop.pointee = true }
        }
        guard !matchedNothing else {
            throw AgentToolError.invalidArguments(
                "old_text matched an empty string in \(path). Narrow the pattern."
            )
        }

        let selected = try select(
            found.map(\.range), count: replacement.count, path: path,
            ambiguity: """
                old_text matches \(found.count) regions of \(path). Narrow the pattern until it \
                names exactly one, or set count to say how many to replace.
                """
        )
        // `select` keeps document order and only ever returns a prefix, so the
        // matching replacement texts are the same prefix of `found`.
        return Array(found.prefix(selected.count))
    }

    /// Turns however many regions were found into exactly the set the entry asked
    /// for, or into the error that says which way the number was wrong.
    private static func select(
        _ found: [Range<String.Index>], count: Int?, path: String, ambiguity: String
    ) throws -> [Range<String.Index>] {
        guard !found.isEmpty else { throw noMatch(path) }
        switch count {
        case nil:
            guard found.count == 1 else { throw AgentToolError.invalidArguments(ambiguity) }
            return found
        case 0:
            guard found.count <= Limits.matchesPerReplacement else {
                throw AgentToolError.invalidArguments(
                    """
                    old_text matches more than \(Limits.matchesPerReplacement) regions of \
                    \(path). Narrow it.
                    """
                )
            }
            return found
        case let wanted?:
            guard found.count >= wanted else {
                throw AgentToolError.invalidArguments(
                    """
                    count is \(wanted) but old_text matches \(found.count) \
                    \(found.count == 1 ? "region" : "regions") of \(path).
                    """
                )
            }
            return Array(found.prefix(wanted))
        }
    }

    /// How many matches are worth collecting for a given `count`.
    ///
    /// Two is all an unbounded entry needs to know — one is a match, more than one is
    /// ambiguous — and stopping there keeps a one-character `old_text` against a
    /// large file from collecting a range per occurrence. Asking for all of them
    /// collects one past the ceiling, so exceeding it is an error rather than a
    /// silent truncation.
    private static func searchLimit(for count: Int?) -> Int {
        switch count {
        case nil: 2
        case 0: Limits.matchesPerReplacement + 1
        case let wanted?: wanted
        }
    }

    private static func noMatch(_ path: String) -> AgentToolError {
        .invalidArguments(
            """
            old_text does not appear in \(path). Read the file and copy the region exactly as \
            it is now.
            """
        )
    }

    private static func ranges(
        of needle: String, in haystack: String, limit: Int
    ) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchFrom = haystack.startIndex
        while found.count < limit,
            let range = haystack.range(of: needle, range: searchFrom..<haystack.endIndex)
        {
            found.append(range)
            searchFrom =
                range.lowerBound < range.upperBound
                ? range.upperBound : haystack.index(after: range.lowerBound)
            guard searchFrom < haystack.endIndex else { break }
        }
        return found
    }

    /// Pi's `normalizeForFuzzyMatch`: the differences a model introduces by retyping
    /// a block rather than copying it.
    private static func normalizedForMatch(_ line: String) -> String {
        var output = line.precomposedStringWithCompatibilityMapping
        for (characters, replacement) in [
            ("\u{2018}\u{2019}\u{201A}\u{201B}", "'"),
            ("\u{201C}\u{201D}\u{201E}\u{201F}", "\""),
            ("\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}", "-"),
            (
                "\u{00A0}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}"
                    + "\u{200A}\u{202F}\u{205F}\u{3000}", " "
            ),
        ] {
            for character in characters {
                output = output.replacingOccurrences(of: String(character), with: replacement)
            }
        }
        while output.hasSuffix(" ") || output.hasSuffix("\t") { output.removeLast() }
        return output
    }

    /// The character range covering a window of whole lines.
    ///
    /// `includingTrailingNewline` mirrors whether the needle itself ended with one.
    /// Getting this wrong is not cosmetic: consuming a newline the needle did not
    /// have would splice the replacement onto the following line, and leaving one
    /// the needle did have would double it.
    private static func lineRange(
        _ window: Range<Int>, in haystack: String, lines all: [String],
        includingTrailingNewline: Bool
    ) -> Range<String.Index> {
        let lower = startIndex(ofLine: window.lowerBound, in: haystack, lines: all)
        var upper = startIndex(ofLine: window.upperBound, in: haystack, lines: all)
        if !includingTrailingNewline, upper > lower,
            haystack[haystack.index(before: upper)] == "\n"
        {
            upper = haystack.index(before: upper)
        }
        return lower..<upper
    }

    private static func startIndex(
        ofLine line: Int, in haystack: String, lines all: [String]
    ) -> String.Index {
        var index = haystack.startIndex
        for existing in all[..<min(line, all.count)] {
            index = haystack.index(index, offsetBy: existing.count)
            if index < haystack.endIndex { index = haystack.index(after: index) }
        }
        return index
    }
}
