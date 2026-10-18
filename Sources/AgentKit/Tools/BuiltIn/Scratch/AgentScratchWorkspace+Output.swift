import Foundation

extension AgentScratchWorkspace {
    /// Replaces a cumulative capture atomically. A late snapshot cannot overwrite
    /// a newer revision.
    public func captureOutput(
        _ text: String, id: UUID, revision: Int = 0, path makePath: @Sendable () -> String
    ) -> AgentOutputCaptureInfo {
        if let previous = outputCaptures[id], previous.revision >= revision,
            previous.info.path == nil
                || (try? fileURL(previous.path)).map({
                    FileManager.default.fileExists(atPath: $0.path)
                }) == true
        {
            return previous.info
        }
        let clean = AgentSensitiveDataRedactor.visibleText(text)
        var info = AgentOutputCaptureInfo(
            bytes: clean.utf8.count, lines: AgentTruncateResult.logicalLines(clean).count)
        var path = outputCaptures[id]?.path
        do {
            if path == nil {
                for _ in 0..<8 {
                    let candidate = try Self.normalize(makePath())
                    guard !candidate.contains("\n"), !candidate.contains("\r") else {
                        throw AgentToolError.invalidArguments("Output path must not contain line breaks.")
                    }
                    let url = try fileURL(candidate)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        path = candidate
                        break
                    }
                }
            }
            guard let path else {
                throw AgentToolError.invalidArguments("Could not generate an unused output path.")
            }
            let url = try fileURL(path)
            _ = try write(path, data: Data(clean.utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            info.path = path
            info.localPath = url.path
        } catch {
            info.error = error.localizedDescription
        }
        if let path { outputCaptures[id] = (path, revision, info) }
        return info
    }
}
