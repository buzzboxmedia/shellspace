import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var name: String
    var sessionDescription: String?  // 'description' is reserved
    var projectPath: String
    var createdAt: Date
    var lastAccessedAt: Date
    var claudeSessionId: String?  // Claude's session ID for --resume

    // Link to active project from ACTIVE-PROJECTS.md
    var activeProjectName: String?
    var parkerBriefing: String?

    // Summary from last session for context when reopening
    var lastSessionSummary: String?

    // If true, user manually named this task - don't auto-rename
    var userNamed: Bool

    // Log file path for conversation history
    var logFilePath: String?

    // Last time the log was saved
    var lastLogSavedAt: Date?

    // Last time user saved a progress note (for 15-min reminder)
    var lastProgressSavedAt: Date?

    // Link to task folder (e.g., ~/Dropbox/.../tasks/001-task-name/)
    var taskFolderPath: String?

    // Completion tracking
    var isCompleted: Bool
    var completedAt: Date?

    // Waiting for input (local state, synced for mobile notifications)
    var isWaitingForInput: Bool

    // Relationships
    var project: Project?
    var taskGroup: ProjectGroup?

    /// Centralized logs directory in Dropbox (syncs across machines)
    static var centralLogsDir: URL {
        let path = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/ClaudeHub/logs").expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    /// Get the path to the log file for this session (centralized in Dropbox)
    var logPath: URL {
        return Session.centralLogsDir.appendingPathComponent("\(id.uuidString).log")
    }

    /// Legacy log path (for migration)
    var legacyLogPath: URL {
        let logsDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".claudehub-logs")
        return logsDir.appendingPathComponent("\(id.uuidString).log")
    }

    /// Check if this session has a saved log (check both locations)
    var hasLog: Bool {
        FileManager.default.fileExists(atPath: logPath.path) ||
        FileManager.default.fileExists(atPath: legacyLogPath.path)
    }

    /// Get the actual log path (prefers centralized, falls back to legacy)
    var actualLogPath: URL {
        if FileManager.default.fileExists(atPath: logPath.path) {
            return logPath
        }
        return legacyLogPath
    }

    var isProjectLinked: Bool {
        activeProjectName != nil
    }

    init(
        name: String,
        projectPath: String,
        createdAt: Date = Date(),
        userNamed: Bool = false,
        activeProjectName: String? = nil,
        parkerBriefing: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.lastAccessedAt = Date()
        self.userNamed = userNamed
        self.activeProjectName = activeProjectName
        self.parkerBriefing = parkerBriefing
        self.isCompleted = false
        self.isWaitingForInput = false
    }
}

extension Session {
    static func preview() -> Session {
        Session(
            name: "Fix authentication bug",
            projectPath: "/Users/baron/Dropbox/Buzzbox/Clients/AAGL",
            createdAt: Date()
        )
    }
}

// MARK: - Drag and Drop Support

extension UTType {
    static let session = UTType(exportedAs: "com.buzzbox.claudehub.session")
}

// Note: Transferable conformance needs adjustment for SwiftData @Model classes
// For now, drag and drop uses session.id instead

// MARK: - Legacy types for migration

struct LegacySession: Codable {
    let id: UUID
    var name: String
    var description: String?
    let projectPath: String
    let createdAt: Date
    var lastAccessedAt: Date
    var claudeSessionId: String?
    var activeProjectName: String?
    var parkerBriefing: String?
    var lastSessionSummary: String?
    var userNamed: Bool
    var logFilePath: String?
    var lastLogSavedAt: Date?
    var taskGroupId: UUID?
    var isCompleted: Bool
    var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, description, projectPath, createdAt, lastAccessedAt, claudeSessionId
        case activeProjectName, parkerBriefing, lastSessionSummary, userNamed
        case logFilePath, lastLogSavedAt, taskGroupId
        case isCompleted, completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastAccessedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessedAt) ?? Date()
        claudeSessionId = try container.decodeIfPresent(String.self, forKey: .claudeSessionId)
        activeProjectName = try container.decodeIfPresent(String.self, forKey: .activeProjectName)
        parkerBriefing = try container.decodeIfPresent(String.self, forKey: .parkerBriefing)
        lastSessionSummary = try container.decodeIfPresent(String.self, forKey: .lastSessionSummary)
        userNamed = try container.decodeIfPresent(Bool.self, forKey: .userNamed) ?? false
        logFilePath = try container.decodeIfPresent(String.self, forKey: .logFilePath)
        lastLogSavedAt = try container.decodeIfPresent(Date.self, forKey: .lastLogSavedAt)
        taskGroupId = try container.decodeIfPresent(UUID.self, forKey: .taskGroupId)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}
