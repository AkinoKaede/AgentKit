import Foundation

public nonisolated enum AgentOutputAudience: Sendable {
    case model, externalClient
}

/// A capture is complete only through its recorded byte count, not through future appends.
public nonisolated struct AgentOutputCaptureInfo: Sendable, Equatable {
    public var path: String?
    public var localPath: String?
    public var bytes: Int
    public var lines: Int
    public var error: String?

    public init(path: String? = nil, localPath: String? = nil, bytes: Int, lines: Int, error: String? = nil) {
        self.path = path
        self.localPath = localPath
        self.bytes = bytes
        self.lines = lines
        self.error = error
    }

    public var json: AgentJSONValue {
        .object([
            "path": path.map(AgentJSONValue.string) ?? .null,
            "local_path": localPath.map(AgentJSONValue.string) ?? .null,
            "bytes": .number(Double(bytes)), "lines": .number(Double(lines)),
            "error": error.map(AgentJSONValue.string) ?? .null,
        ])
    }

    public init?(json: AgentJSONValue) {
        guard let object = json.objectValue,
            let bytes = object["bytes"]?.integerValue, let lines = object["lines"]?.integerValue
        else { return nil }
        self.init(
            path: object["path"]?.stringValue, localPath: object["local_path"]?.stringValue,
            bytes: bytes, lines: lines, error: object["error"]?.stringValue)
    }
}

extension AgentToolResult {
    /// Produced only by tool-output projection, not by a display preview.
    public var truncateMarker: String? {
        get { metadata["truncate_marker"]?.stringValue }
        set { metadata["truncate_marker"] = newValue.map(AgentJSONValue.string) }
    }

    public var outputCapture: AgentOutputCaptureInfo? {
        get { metadata["output_capture"].flatMap(AgentOutputCaptureInfo.init(json:)) }
        set { metadata["output_capture"] = newValue?.json }
    }
}
