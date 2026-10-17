import Foundation

extension AgentToolOutputProjection {
    /// Message cursors address a message and a complete logical line, so shrinking
    /// an encoded page never advances past text the model did not receive.
    func projectMessagePage(_ result: AgentToolResult, object: [String: AgentJSONValue]) -> AgentToolResult {
        let source = object["messages"]!.arrayValue!
        let offset = object["message_offset"]!.integerValue!
        let totalLines = source.reduce(0) {
            $0 + AgentTruncateResult.logicalLines($1.objectValue?["text"]?.stringValue ?? "").count
        }
        var budget = maximumBytes
        var fields = object
        var encoded = ""
        var wasShortened = false
        repeat {
            fields = object
            var messages: [AgentJSONValue] = []
            var bytes = budget
            var lines = maximumLines
            var returned = 0
            wasShortened = false
            for (index, value) in source.enumerated() {
                guard var message = value.objectValue, let text = message["text"]?.stringValue else { continue }
                let selected = AgentTruncateResult.apply(text, limits: .init(bytes: bytes, lines: lines))
                let firstLine = message["line_offset"]?.integerValue ?? 1
                message["text"] = .string(selected.content)
                messages.append(.object(message))
                bytes -= selected.content.utf8.count
                lines -= selected.returnedLines
                returned += selected.returnedLines
                if selected.isTruncated {
                    wasShortened = true
                    fields["next_cursor"] = .string("\(offset + index):\(firstLine + selected.returnedLines)")
                    if selected.returnedLines == 0, returned == 0 {
                        fields["oversized_line"] = .bool(true)
                        fields["skip_cursor"] = .string(
                            selected.totalLines == 1 ? "\(offset + index + 1)" : "\(offset + index):\(firstLine + 1)")
                    }
                    break
                }
            }
            fields["messages"] = .array(messages)
            fields["message_count"] = .number(Double(messages.count))
            if wasShortened {
                fields["truncated"] = .bool(true)
                fields["capture_status"] = .string("not_requested")
                fields["notice"] = .string(
                    AgentTruncateMarker.render(ranges: returned == 0 ? [] : [1...returned], totalLines: totalLines))
            }
            if let skip = fields["skip_cursor"]?.stringValue {
                fields["continuation"] = .string("A whole line exceeds the response limit. Cursor \(skip) skips it.")
            } else if let cursor = fields["next_cursor"]?.stringValue {
                fields["continuation"] = .string("Continue with cursor \(cursor).")
            }
            encoded = Self.frame(fields)
            guard encoded.utf8.count > maximumBytes, budget > 0 else { break }
            budget = smallerBudget(budget, encodedBytes: encoded.utf8.count)
        } while true
        var projected = result
        if encoded.utf8.count > maximumBytes {
            let marker = AgentTruncateMarker.render(ranges: [], totalLines: totalLines)
            encoded = marker.utf8.count <= maximumBytes ? marker : ""
            fields["notice"] = .string(marker)
            wasShortened = true
        }
        projected.modelContent = encoded
        projected.truncateMarker = fields["notice"]?.stringValue
        if wasShortened { projected.metadata["output_truncated"] = .bool(true) }
        return projected
    }
}
