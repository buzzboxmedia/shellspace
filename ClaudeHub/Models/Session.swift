import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Path Normalization

extension String {
    /// Resolve symlinks to get the canonical path.
    /// Claude CLI resolves symlinks internally, so ClaudeHub must do the same
    /// to correctly match session files across machines and symlink configurations.
    var canonicalPath: String {
        URL(fileURLWithPath: self).resolvingSymlinksInPath().path
    }
}

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

    // Hidden from active list (but not deleted - can be reopened)
    var isHidden: Bool = false

    // Waiting for input (local state, synced for mobile notifications)
    var isWaitingForInput: Bool

    // Track if Claude has been launched in this session (for --continue logic)
    var hasBeenLaunched: Bool = false

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
        self.projectPath = projectPath.canonicalPath
        self.createdAt = createdAt
        self.lastAccessedAt = Date()
        self.userNamed = userNamed
        self.activeProjectName = activeProjectName
        self.parkerBriefing = parkerBriefing
        self.isCompleted = false
        self.isWaitingForInput = false
        self.hasBeenLaunched = false
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

// MARK: - Session Sync Support

/// Codable representation of Session for Dropbox sync
struct SessionMetadata: Codable {
    let id: UUID
    var name: String
    var sessionDescription: String?
    var projectPath: String
    var createdAt: Date
    var lastAccessedAt: Date
    var claudeSessionId: String?
    var activeProjectName: String?
    var parkerBriefing: String?
    var lastSessionSummary: String?
    var userNamed: Bool
    var logFilePath: String?
    var lastLogSavedAt: Date?
    var lastProgressSavedAt: Date?
    var taskFolderPath: String?
    var isCompleted: Bool
    var completedAt: Date?
    var isHidden: Bool
    var isWaitingForInput: Bool
    var hasBeenLaunched: Bool

    // Relationship references (stored as UUIDs, not objects)
    var projectId: UUID?
    var taskGroupId: UUID?
}

extension Session {
    /// Convert Session to syncable metadata
    func toMetadata() -> SessionMetadata {
        return SessionMetadata(
            id: id,
            name: name,
            sessionDescription: sessionDescription,
            projectPath: projectPath,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt,
            claudeSessionId: claudeSessionId,
            activeProjectName: activeProjectName,
            parkerBriefing: parkerBriefing,
            lastSessionSummary: lastSessionSummary,
            userNamed: userNamed,
            logFilePath: logFilePath,
            lastLogSavedAt: lastLogSavedAt,
            lastProgressSavedAt: lastProgressSavedAt,
            taskFolderPath: taskFolderPath,
            isCompleted: isCompleted,
            completedAt: completedAt,
            isHidden: isHidden,
            isWaitingForInput: isWaitingForInput,
            hasBeenLaunched: hasBeenLaunched,
            projectId: project?.id,
            taskGroupId: taskGroup?.id
        )
    }

    /// Update Session from metadata (for merging remote changes)
    func updateFromMetadata(_ metadata: SessionMetadata) {
        self.name = metadata.name
        self.sessionDescription = metadata.sessionDescription
        self.projectPath = metadata.projectPath.canonicalPath
        self.createdAt = metadata.createdAt
        self.lastAccessedAt = metadata.lastAccessedAt
        self.claudeSessionId = metadata.claudeSessionId
        self.activeProjectName = metadata.activeProjectName
        self.parkerBriefing = metadata.parkerBriefing
        self.lastSessionSummary = metadata.lastSessionSummary
        self.userNamed = metadata.userNamed
        self.logFilePath = metadata.logFilePath
        self.lastLogSavedAt = metadata.lastLogSavedAt
        self.lastProgressSavedAt = metadata.lastProgressSavedAt
        self.taskFolderPath = metadata.taskFolderPath?.canonicalPath
        self.isCompleted = metadata.isCompleted
        self.completedAt = metadata.completedAt
        self.isHidden = metadata.isHidden
        self.isWaitingForInput = metadata.isWaitingForInput
        self.hasBeenLaunched = metadata.hasBeenLaunched

        // Note: Project and TaskGroup relationships are resolved separately
        // by SessionSyncService during import
    }
}

// MARK: - Drag and Drop Support

extension UTType {
    static let session = UTType(exportedAs: "com.buzzbox.claudehub.session")
}

// Note: Transferable conformance needs adjustment for SwiftData @Model classes
// For now, drag and drop uses session.id instead
