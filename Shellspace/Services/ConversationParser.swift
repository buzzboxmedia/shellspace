import Foundation

// MARK: - Models

struct ConversationEntry: Identifiable {
    let id: String
    let timestamp: Date
    let role: ConversationRole
    let content: String
    let toolCalls: [ToolCallInfo]
}

enum ConversationRole {
    case user
    case assistant
}

struct ToolCallInfo: Identifiable {
    let id: String
    let toolName: String
    let summary: String
}

// MARK: - ConversationParser

struct ConversationParser {

    /// Parse a .jsonl file and return the last N conversation entries.
    static func parse(filePath: String, lastN: Int = 15) -> [ConversationEntry] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: "\n")
        var rawMessages: [RawMessage] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard let parsed = parseRawMessage(json) else { continue }
            rawMessages.append(parsed)
        }

        // Collapse consecutive same-role messages into single entries
        let entries = collapseMessages(rawMessages)

        // Return last N
        return Array(entries.suffix(lastN))
    }

    // MARK: - Internal Types

    private struct RawMessage {
        let uuid: String
        let timestamp: Date
        let role: ConversationRole
        let textParts: [String]
        let toolCalls: [ToolCallInfo]
    }

    // MARK: - Parsing

    private static func parseRawMessage(_ json: [String: Any]) -> RawMessage? {
        guard let type = json["type"] as? String else { return nil }

        // Skip non-message types
        guard type == "user" || type == "assistant" else { return nil }

        guard let message = json["message"] as? [String: Any] else { return nil }
        let uuid = json["uuid"] as? String ?? UUID().uuidString
        let timestamp = parseTimestamp(json["timestamp"])

        let role: ConversationRole = type == "user" ? .user : .assistant

        guard let rawContent = message["content"] else { return nil }

        var textParts: [String] = []
        var toolCalls: [ToolCallInfo] = []

        if let text = rawContent as? String {
            // Simple string content (user messages)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                textParts.append(trimmed)
            }
        } else if let blocks = rawContent as? [[String: Any]] {
            // Array of content blocks
            var hasToolResult = false

            for block in blocks {
                guard let blockType = block["type"] as? String else { continue }

                switch blockType {
                case "text":
                    if let text = block["text"] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            textParts.append(trimmed)
                        }
                    }

                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let toolId = block["id"] as? String ?? UUID().uuidString
                    let summary = generateToolSummary(name: name, input: block["input"] as? [String: Any])
                    toolCalls.append(ToolCallInfo(id: toolId, toolName: name, summary: summary))

                case "tool_result":
                    hasToolResult = true

                case "thinking":
                    // Skip thinking blocks
                    break

                default:
                    break
                }
            }

            // If this is a user message that only contains tool_result blocks, skip it
            if role == .user && hasToolResult && textParts.isEmpty {
                return nil
            }
        }

        // Skip completely empty messages
        if textParts.isEmpty && toolCalls.isEmpty {
            return nil
        }

        return RawMessage(
            uuid: uuid,
            timestamp: timestamp,
            role: role,
            textParts: textParts,
            toolCalls: toolCalls
        )
    }

    // MARK: - Collapsing

    /// Collapse consecutive messages with the same role into single entries.
    /// Claude often sends multiple message objects for one turn (thinking, then tools, then text).
    private static func collapseMessages(_ messages: [RawMessage]) -> [ConversationEntry] {
        guard !messages.isEmpty else { return [] }

        var entries: [ConversationEntry] = []
        var currentRole = messages[0].role
        var currentTexts: [String] = []
        var currentTools: [ToolCallInfo] = []
        var currentTimestamp = messages[0].timestamp
        var currentUuid = messages[0].uuid

        func flushCurrent() {
            let content = currentTexts.joined(separator: "\n\n")
            entries.append(ConversationEntry(
                id: currentUuid,
                timestamp: currentTimestamp,
                role: currentRole,
                content: content,
                toolCalls: currentTools
            ))
        }

        for msg in messages {
            if msg.role == currentRole {
                // Same role - accumulate
                currentTexts.append(contentsOf: msg.textParts)
                currentTools.append(contentsOf: msg.toolCalls)
            } else {
                // Role changed - flush previous and start new
                flushCurrent()
                currentRole = msg.role
                currentTexts = Array(msg.textParts)
                currentTools = Array(msg.toolCalls)
                currentTimestamp = msg.timestamp
                currentUuid = msg.uuid
            }
        }

        // Flush the last group
        flushCurrent()

        return entries
    }

    // MARK: - Tool Summaries

    private static func generateToolSummary(name: String, input: [String: Any]?) -> String {
        guard let input = input else { return name }

        switch name {
        case "Read":
            if let path = input["file_path"] as? String {
                return shortenPath(path)
            }
        case "Write":
            if let path = input["file_path"] as? String {
                return shortenPath(path)
            }
        case "Edit":
            if let path = input["file_path"] as? String {
                return shortenPath(path)
            }
        case "Bash":
            if let cmd = input["command"] as? String {
                // Truncate long commands
                let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                let firstLine = trimmed.components(separatedBy: "\n").first ?? trimmed
                if firstLine.count > 60 {
                    return String(firstLine.prefix(57)) + "..."
                }
                return firstLine
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                let truncated = pattern.count > 30 ? String(pattern.prefix(27)) + "..." : pattern
                return "\"\(truncated)\""
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                let truncated = query.count > 40 ? String(query.prefix(37)) + "..." : query
                return "\"\(truncated)\""
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                // Extract domain from URL
                if let urlObj = URL(string: url) {
                    return urlObj.host ?? url
                }
                return String(url.prefix(40))
            }
        case "LSP":
            if let op = input["operation"] as? String {
                return op
            }
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return ""
        default:
            break
        }

        return ""
    }

    /// Shorten a file path to just the last 2 components for readability.
    private static func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
        if components.count <= 2 {
            return path
        }
        return components.suffix(2).joined(separator: "/")
    }

    // MARK: - Timestamp Parsing

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601FallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ value: Any?) -> Date {
        guard let str = value as? String else { return Date() }
        if let date = iso8601Formatter.date(from: str) { return date }
        if let date = iso8601FallbackFormatter.date(from: str) { return date }
        return Date()
    }
}
