/// Pi-style tool-output diagnostics, never localized. Presentation reuses the
/// frozen marker; display-only folding does not create one.
public nonisolated enum AgentTruncateMarker {
    public static func render(
        ranges: [ClosedRange<Int>], totalLines: Int? = nil, capture: AgentOutputCaptureInfo? = nil
    ) -> String {
        var text: String
        if ranges.isEmpty {
            text = totalLines.map { "Showing 0 of \($0) lines" } ?? "Showing 0 lines"
        } else {
            text = "Showing lines " + ranges.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", ")
            if let totalLines { text += " of \(totalLines)" }
        }
        if let capture, capture.error == nil, let path = capture.path {
            text += ". Full output: \(path)"
        }
        return "[\(text)]"
    }
}
