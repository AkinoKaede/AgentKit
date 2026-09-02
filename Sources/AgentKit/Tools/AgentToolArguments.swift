import Foundation

public nonisolated struct Arguments: Sendable {
    public let object: [String: AgentJSONValue]

    public init(_ invocation: AgentToolInvocation) throws {
        guard let object = invocation.call.arguments.objectValue else {
            throw AgentToolError.invalidArguments("Arguments must be an object.")
        }
        self.object = object
    }

    public func string(_ key: String) throws -> String {
        guard let value = object[key]?.stringValue, !value.isEmpty else {
            throw AgentToolError.invalidArguments("\(key) is required.")
        }
        return value
    }

    public func uuid(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(key)) else { throw AgentToolError.invalidHost }
        return value
    }

    public func optionalString(_ key: String) -> String? { object[key]?.stringValue }
    public func optionalInt(_ key: String) -> Int? { object[key]?.integerValue }
    public func optionalBool(_ key: String) -> Bool? { object[key]?.boolValue }
    /// The `questions` array of `request_user_input`.
    ///
    /// Everything malformed is rejected rather than dropped. A form silently
    /// missing the question — or the option — the user needed is a worse
    /// failure than an error the model can see and retry.
    public func userQuestions() throws -> [AgentUserQuestion] {
        guard let rows = object["questions"]?.arrayValue else {
            throw AgentToolError.invalidArguments("questions must be an array.")
        }
        guard !rows.isEmpty else {
            throw AgentToolError.invalidArguments("questions must contain at least one question.")
        }
        guard rows.count <= AgentUserInputLimits.maxQuestions else {
            throw AgentToolError.invalidArguments(
                "At most \(AgentUserInputLimits.maxQuestions) questions may be asked at once."
            )
        }

        var seen: Set<String> = []
        return try rows.map { row in
            guard let fields = row.objectValue,
                let id = fields["id"]?.stringValue, !id.isEmpty,
                let prompt = fields["prompt"]?.stringValue, !prompt.isEmpty
            else {
                throw AgentToolError.invalidArguments("Each question requires id and prompt.")
            }
            guard seen.insert(id).inserted else {
                throw AgentToolError.invalidArguments("Question ids must be unique: \(id).")
            }

            let options = try Self.options(in: fields)
            return AgentUserQuestion(
                id: id,
                header: fields["header"]?.stringValue ?? "",
                prompt: prompt,
                kind: options.isEmpty
                    ? .text
                    : .choice(
                        AgentUserInputChoice(
                            options: options,
                            allowsCustomAnswer: fields["allow_custom"]?.boolValue ?? true,
                            allowsMultipleAnswers: fields["multi_select"]?.boolValue ?? false,
                            customPlaceholder: fields["custom_placeholder"]?.stringValue ?? ""
                        )
                    )
            )
        }
    }

    private static func options(in question: [String: AgentJSONValue]) throws
        -> [AgentUserInputOption]
    {
        guard let value = question["options"], value != .null else { return [] }
        guard let rows = value.arrayValue else {
            throw AgentToolError.invalidArguments("options must be an array.")
        }
        var seen: Set<String> = []
        return try rows.map { row in
            guard let fields = row.objectValue,
                let id = fields["id"]?.stringValue, !id.isEmpty,
                let label = fields["label"]?.stringValue, !label.isEmpty
            else {
                throw AgentToolError.invalidArguments("Each option requires id and label.")
            }
            guard seen.insert(id).inserted else {
                throw AgentToolError.invalidArguments("Option ids must be unique: \(id).")
            }
            return AgentUserInputOption(
                id: id, label: label,
                detail: fields["description"]?.stringValue ?? "",
                isRecommended: fields["recommended"]?.boolValue ?? false
            )
        }
    }

    /// The `replacements` array of `scratch_replace`.
    ///
    /// `new_text` may legitimately be empty — that is how a block is deleted — so it
    /// is read for presence rather than through `string(_:)`, which rejects empty.
    /// Every failure names the entry it came from, because a batch of thirty-two
    /// that fails anonymously is one the model has to bisect by hand.
    public func scratchReplacements() throws -> [ScratchReplacement] {
        guard let rows = object["replacements"]?.arrayValue, !rows.isEmpty else {
            throw AgentToolError.invalidArguments("replacements must be a non-empty array.")
        }
        return try rows.enumerated().map { index, row in
            let position = index + 1
            guard let fields = row.objectValue,
                let oldText = fields["old_text"]?.stringValue,
                let newText = fields["new_text"]?.stringValue
            else {
                throw AgentToolError.invalidArguments(
                    "Replacement \(position) requires old_text and new_text."
                )
            }
            let isRegularExpression = fields["regex"]?.boolValue ?? false
            if isRegularExpression,
                (try? NSRegularExpression(pattern: oldText)) == nil
            {
                throw AgentToolError.invalidArguments(
                    "Replacement \(position) has an old_text that is not a valid regular expression."
                )
            }
            let count = fields["count"]?.integerValue
            if let count, count < 0 || count > AgentScratchWorkspace.Limits.matchesPerReplacement {
                throw AgentToolError.invalidArguments(
                    """
                    Replacement \(position) has a count of \(count); it must be between 0 and \
                    \(AgentScratchWorkspace.Limits.matchesPerReplacement).
                    """
                )
            }
            return ScratchReplacement(
                oldText: oldText, newText: newText,
                isRegularExpression: isRegularExpression, count: count
            )
        }
    }
}

public nonisolated enum AgentToolError: LocalizedError, Sendable {
    case invalidHost, invalidPath, notFound, cancelled
    case invalidArguments(String)
    case userInputTimedOut(Int)
    case scratchPathEscapes
    case scratchNotFound(String)
    case scratchNotText(String)
    case scratchQuotaExceeded(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost: "The host ID is invalid or unavailable."
        case .invalidPath: "The remote path must be an absolute normalized path."
        case .notFound: "The remote path does not exist."
        case .cancelled: "The user cancelled the request."
        case .userInputTimedOut(let seconds):
            "User input timed out after \(seconds) seconds."
        case .invalidArguments(let message): message
        case .scratchPathEscapes:
            """
            A scratch path must be relative, must not contain "..", and must stay inside \
            the workspace.
            """
        case .scratchNotFound(let path): "\(path) is not in the scratch workspace."
        case .scratchNotText(let path):
            """
            \(path) is not UTF-8 text. It can still be moved as bytes, \
            which does not decode it.
            """
        case .scratchQuotaExceeded(let message): message
        }
    }
}
