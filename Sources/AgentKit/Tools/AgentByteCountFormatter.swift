import Foundation

/// Formats user-facing byte counts with Finder's decimal file-size units.
public nonisolated enum AgentByteCountFormatter {
    public static func string(fromByteCount count: Int64) -> String {
        guard count >= 0 else { return "—" }
        guard count != 0 else { return "0" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
