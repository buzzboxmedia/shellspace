import Foundation

struct Session: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var description: String?
    let projectPath: String
    let createdAt: Date
    var lastAccessedAt: Date = Date()
    var claudeSessionId: String?  // Claude's session ID for --resume

    // Link to active project from ACTIVE-PROJECTS.md
    var activeProjectName: String?
    var parkerBriefing: String?

    // Summary from last session for context when reopening
    var lastSessionSummary: String?

    // If true, user manually named this task - don't auto-rename
    var userNamed: Bool = false

    // Log file path for conversation history
    var logFilePath: String?

    // Last time the log was saved
    var lastLogSavedAt: Date?

    // Optional task group (project) this task belongs to
    var taskGroupId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, name, description, projectPath, createdAt, lastAccessedAt, claudeSessionId
        case activeProjectName, parkerBriefing, lastSessionSummary, userNamed
        case logFilePath, lastLogSavedAt, taskGroupId
    }

    /// Get the path to the log file for this session
    var logPath: URL {
        let logsDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".claudehub-logs")
        return logsDir.appendingPathComponent("\(id.uuidString).log")
    }

    /// Check if this session has a saved log
    var hasLog: Bool {
        FileManager.default.fileExists(atPath: logPath.path)
    }

    var isProjectLinked: Bool {
        activeProjectName != nil
    }
}

extension Session {
    static func preview() -> Session {
        Session(
            id: UUID(),
            name: "Fix authentication bug",
            description: "Debugging login flow and token refresh issues",
            projectPath: "/Users/baron/Dropbox/Buzzbox/Clients/AAGL",
            createdAt: Date()
        )
    }
}
