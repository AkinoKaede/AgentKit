import CryptoKit
import Foundation

/// Downloads public GitHub packages without credentials, archives, redirects, or executing their contents.
public nonisolated struct GitHubSkillPackageResolver: AgentSkillPackageResolving {
    private let transport: any SkillPackageHTTPTransport
    public init() { transport = PublicGitHubSkillTransport() }
    init(transport: any SkillPackageHTTPTransport) { self.transport = transport }

    public func resolve(sourceURL: String) async throws -> AgentResolvedSkillPackage {
        let source = try Source(sourceURL)
        let base = "https://api.github.com/repos/\(source.owner)/\(source.repo)"
        let tail = source.tail
        var resolved: (Commit, [String])?
        if tail.isEmpty {
            let repository: Repository = try await json(base, as: Repository.self)
            resolved = (try await commit(base: base, ref: repository.defaultBranch), [])
        } else {
            // A Git ref may itself contain slashes. Resolve the longest existing ref first.
            for count in stride(from: min(tail.count, 32), through: 1, by: -1) {
                do {
                    let value = try await commit(base: base, ref: tail.prefix(count).joined(separator: "/"))
                    resolved = (value, Array(tail.dropFirst(count)))
                    break
                } catch let error as SkillPackageHTTPError where error.status == 404 || error.status == 422 {
                    continue
                }
            }
        }
        guard let (commit, path) = resolved, Self.isSHA(commit.sha), Self.isSHA(commit.commit.tree.sha) else {
            throw AgentToolError.invalidArguments("No public GitHub revision matches this skill URL.")
        }
        var directory = path
        if source.isFile {
            guard directory.last == "SKILL.md" else { throw AgentSkillImportError.noSkillFile }
            directory.removeLast()
        }
        var treeID = commit.commit.tree.sha
        for part in directory {
            let tree = try await tree(base: base, sha: treeID)
            guard let entry = tree.tree.first(where: { $0.path == part }), entry.type == "tree", entry.mode == "040000",
                Self.isSHA(entry.sha)
            else {
                throw AgentToolError.invalidArguments("The skill directory is missing or is not a regular directory.")
            }
            treeID = entry.sha
        }
        var pending: [(String, String, Int)] = [(treeID, "", 0)]
        var files: [(String, Entry)] = []
        var directoryCount = 0
        var total = 0
        while let (sha, prefix, depth) = pending.popLast() {
            try Task.checkCancellation()
            directoryCount += 1
            guard directoryCount <= 256, depth <= 32 else { throw AgentSkillImportError.tooLarge }
            let tree = try await tree(base: base, sha: sha)
            for entry in tree.tree {
                try AgentSkillPackage.validatePath(entry.path)
                guard !entry.path.contains("/"), Self.isSHA(entry.sha) else { throw AgentSkillImportError.notReadable }
                let relative = prefix + entry.path
                try AgentSkillPackage.validatePath(relative)
                if entry.type == "tree", entry.mode == "040000" {
                    pending.append((entry.sha, relative + "/", depth + 1))
                } else {
                    guard entry.type == "blob", ["100644", "100755"].contains(entry.mode), let size = entry.size,
                        size >= 0
                    else {
                        throw AgentToolError.invalidArguments(
                            "Skill packages cannot contain symbolic links or submodules.")
                    }
                    let limit =
                        relative == "SKILL.md" ? AgentSkill.maximumBodyBytes : AgentSkillPackage.maximumFileBytes
                    guard size <= limit else { throw AgentSkillImportError.tooLarge }
                    total += size
                    files.append((relative, entry))
                    guard files.count <= AgentSkillPackage.maximumFiles + 1,
                        total <= AgentSkillPackage.maximumBytes + AgentSkill.maximumBodyBytes
                    else { throw AgentSkillImportError.tooLarge }
                }
            }
        }
        guard files.contains(where: { $0.0 == "SKILL.md" }) else { throw AgentSkillImportError.noSkillFile }
        var bytes: [String: Data] = [:]
        for (path, entry) in files.sorted(by: { $0.0 < $1.0 }) {
            let fullPath = (directory + path.components(separatedBy: "/")).map(Self.segment).joined(separator: "/")
            let url = try Self.url(
                "https://raw.githubusercontent.com/\(source.owner)/\(source.repo)/\(commit.sha)/\(fullPath)")
            let data = try await transport.get(url, maximumBytes: entry.size ?? 0)
            let hash = Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data)
                .map { String(format: "%02x", $0) }.joined()
            guard data.count == entry.size, hash == entry.sha,
                !data.starts(with: Data("version https://git-lfs.github.com/spec/v1\n".utf8))
            else { throw AgentToolError.invalidArguments("The downloaded package is incomplete or changed.") }
            bytes[path] = data
        }
        guard let root = bytes.removeValue(forKey: "SKILL.md"), let text = String(data: root, encoding: .utf8) else {
            throw AgentSkillImportError.notReadable
        }
        var document = try AgentSkillDocument.parse(text, fallbackName: directory.last ?? source.repo)
        document.package.files = bytes
        try document.package.validate()
        let origin =
            "https://github.com/\(source.owner)/\(source.repo)/tree/\(commit.sha)"
            + (directory.isEmpty ? "" : "/" + directory.map(Self.segment).joined(separator: "/"))
        return AgentResolvedSkillPackage(document: document, sourceURL: origin, revision: commit.sha)
    }

    private func commit(base: String, ref: String) async throws -> Commit {
        try await json(base + "/commits/" + Self.segment(ref), as: Commit.self)
    }
    private func tree(base: String, sha: String) async throws -> Tree {
        let value: Tree = try await json(base + "/git/trees/" + sha, as: Tree.self)
        guard !value.truncated else { throw AgentSkillImportError.tooLarge }
        return value
    }
    private func json<T: Decodable>(_ address: String, as type: T.Type) async throws -> T {
        let data = try await transport.get(Self.url(address), maximumBytes: 1_048_576)
        return try JSONDecoder().decode(type, from: data)
    }
    private static func url(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw AgentSkillImportError.notReadable }
        return url
    }
    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
            ?? ""
    }
    private static func isSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
    private struct Repository: Decodable {
        var defaultBranch: String
        enum CodingKeys: String, CodingKey { case defaultBranch = "default_branch" }
    }
    private struct Commit: Decodable {
        var sha: String
        var commit: Details
        struct Details: Decodable { var tree: ObjectID }
        struct ObjectID: Decodable { var sha: String }
    }
    private struct Entry: Decodable {
        var path: String
        var mode: String
        var type: String
        var sha: String
        var size: Int?
    }
    private struct Tree: Decodable {
        var tree: [Entry]
        var truncated: Bool
    }
    private struct Source {
        var owner: String
        var repo: String
        var tail: [String]
        var isFile: Bool
        init(_ raw: String) throws {
            guard raw.utf8.count <= 2_048, let url = URL(string: raw), url.scheme == "https",
                ["github.com", "raw.githubusercontent.com"].contains(url.host?.lowercased() ?? ""),
                url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil
            else { throw AgentToolError.invalidArguments("Use a public HTTPS GitHub skill directory or SKILL.md URL.") }
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, parts.count <= 66 else { throw AgentSkillImportError.notReadable }
            for part in parts { try AgentSkillPackage.validatePath(part) }
            owner = Self.validIdentifier(parts[0]) ? parts[0] : ""
            repo = Self.validIdentifier(parts[1]) ? parts[1] : ""
            guard !owner.isEmpty, !repo.isEmpty else { throw AgentSkillImportError.notReadable }
            if url.host?.lowercased() == "github.com" {
                if parts.count == 2 {
                    tail = []
                    isFile = false
                    return
                }
                guard parts.count >= 4, ["tree", "blob"].contains(parts[2]) else {
                    throw AgentSkillImportError.notReadable
                }
                tail = Array(parts.dropFirst(3))
                isFile = parts[2] == "blob"
            } else {
                tail = Array(parts.dropFirst(2))
                isFile = true
            }
            if tail.starts(with: ["refs", "heads"]) || tail.starts(with: ["refs", "tags"]) { tail.removeFirst(2) }
            if isFile, tail.last != "SKILL.md" { throw AgentSkillImportError.noSkillFile }
        }
        private static func validIdentifier(_ value: String) -> Bool {
            !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }
        }
    }
}

nonisolated protocol SkillPackageHTTPTransport: Sendable {
    func get(_ url: URL, maximumBytes: Int) async throws -> Data
}
nonisolated struct SkillPackageHTTPError: LocalizedError {
    var status: Int
    var errorDescription: String? {
        String(
            localized: "GitHub returned HTTP \(status). Check that the skill is public and try again later.",
            bundle: .module)
    }
}

private nonisolated struct PublicGitHubSkillTransport: SkillPackageHTTPTransport {
    func get(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard url.scheme == "https", ["api.github.com", "raw.githubusercontent.com"].contains(url.host),
            url.port == nil, url.user == nil, url.password == nil
        else { throw AgentSkillImportError.notReadable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoSkillRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("AgentKit-Skill-Installer", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentSkillImportError.notReadable }
        guard http.statusCode == 200 else { throw SkillPackageHTTPError(status: http.statusCode) }
        guard response.expectedContentLength <= maximumBytes else { throw AgentSkillImportError.tooLarge }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw AgentSkillImportError.tooLarge }
            data.append(byte)
        }
        return data
    }
}
private final class NoSkillRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
