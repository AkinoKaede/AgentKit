import Foundation

extension GuardianEvidence {
    /// Extracts only locally attributable user authorization. User-role text
    /// without `authoredText` may have been injected or expanded and is not
    /// promoted to authorization after the fact.
    public static func collect(from messages: [AgentTranscriptMessage]) -> [Self] {
        var evidence = messages.compactMap { message -> Self? in
            guard message.role == .user,
                let authored = message.authoredText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !authored.isEmpty
            else { return nil }
            return Self(id: "user:\(message.id.uuidString)", source: .directUser, text: authored)
        }

        let calls = Dictionary(
            messages
                .filter { $0.role == .assistant }
                .flatMap(\.toolCalls)
                .filter { $0.name == RequestUserInputTool.name }
                .map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for message in messages where message.role == .tool {
            guard message.toolName == RequestUserInputTool.name,
                let callID = message.toolCallID,
                let call = calls[callID]
            else { continue }
            evidence.append(contentsOf: answers(call: call, resultText: message.text))
        }
        return deduplicated(evidence)
    }

    public static func answers(call: AgentToolCall, resultText: String) -> [Self] {
        guard call.name == RequestUserInputTool.name,
            let questions = call.arguments.objectValue?["questions"]?.arrayValue,
            let payload = payload(in: resultText)?.objectValue,
            let answers = payload["answers"]?.arrayValue
        else { return [] }

        let prompts = Dictionary(
            uniqueKeysWithValues: questions.compactMap { value -> (String, String)? in
                guard let fields = value.objectValue,
                    let id = fields["id"]?.stringValue,
                    let prompt = fields["prompt"]?.stringValue
                else { return nil }
                return (id, prompt)
            }
        )
        return answers.compactMap { value -> Self? in
            guard let fields = value.objectValue,
                let id = fields["question_id"]?.stringValue,
                let answer = fields["answer"]?.stringValue,
                !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let question = prompts[id] ?? id
            return Self(
                id: "answer:\(call.id):\(id)", source: .userInputAnswer,
                text: "Question: \(question)\nAnswer: \(answer)"
            )
        }
    }

    private static func payload(in text: String) -> AgentJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = AgentToolResult.untrustedDataOpeningMarker
            .trimmingCharacters(in: .newlines)
        let closing = AgentToolResult.untrustedDataClosingMarker
            .trimmingCharacters(in: .newlines)
        guard trimmed.hasPrefix(opening), trimmed.hasSuffix(closing) else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: opening.count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -closing.count)
        let json = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? AgentJSONValue.decode(data)
    }

    private static func deduplicated(_ values: [Self]) -> [Self] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }
}

actor GuardianEvidenceLog {
    private var evidence: [GuardianEvidence]
    private var ids: Set<String>

    init(_ evidence: [GuardianEvidence]) {
        var seen = Set<String>()
        self.evidence = evidence.filter { seen.insert($0.id).inserted }
        ids = seen
    }

    func append(_ values: [GuardianEvidence]) {
        for value in values where ids.insert(value.id).inserted { evidence.append(value) }
    }

    func snapshot() -> [GuardianEvidence] { evidence }
}
