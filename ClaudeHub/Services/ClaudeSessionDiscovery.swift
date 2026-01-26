import Foundation
import os.log

private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "ClaudeSessionDiscovery")

/// Represents a Claude Code session discovered from ~/.claude/projects/
struct DiscoveredSession: Identifiable {
    let id: String  // Claude's sessionId
    let summary: String
    let firstPrompt: String
    let messageCount: Int
    let created: Date
    let modified: Date
    let projectPath: String
    let fullPath: String

    var name: String {
        summary.isEmpty ? "New Session" : summary
    }
}

/// Service to discover Claude Code sessions from the file system
/// This allows sessions to sync via Dropbox without needing SwiftData
class ClaudeSessionDiscovery {
    static let shared = ClaudeSessionDiscovery()

    private let fileManager = FileManager.default

    /// Path to Claude's projects directory
    private var claudeProjectsPath: String {
        NSString("~/.claude/projects").expandingTildeInPath
    }

    /// Convert a project path to Claude's folder name format
    /// e.g., /Users/baron/Dropbox/Talkspresso -> -Users-baron-Dropbox-Talkspresso
    func claudeFolderName(for projectPath: String) -> String {
        return projectPath.replacingOccurrences(of: "/", with: "-")
    }

    /// Get the full path to Claude's session folder for a project
    func claudeSessionFolder(for projectPath: String) -> String {
        let folderName = claudeFolderName(for: projectPath)
        return "\(claudeProjectsPath)/\(folderName)"
    }

    /// Discover all sessions for a given project path
    func discoverSessions(for projectPath: String) -> [DiscoveredSession] {
        let sessionFolder = claudeSessionFolder(for: projectPath)
        let indexPath = "\(sessionFolder)/sessions-index.json"

        guard fileManager.fileExists(atPath: indexPath) else {
            logger.debug("No sessions-index.json found at \(indexPath)")
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: indexPath))
            let index = try JSONDecoder().decode(ClaudeSessionsIndex.self, from: data)

            return index.entries.map { entry in
                DiscoveredSession(
                    id: entry.sessionId,
                    summary: entry.summary ?? "",
                    firstPrompt: entry.firstPrompt ?? "",
                    messageCount: entry.messageCount ?? 0,
                    created: entry.createdDate ?? Date(),
                    modified: entry.modifiedDate ?? Date(),
                    projectPath: entry.projectPath ?? projectPath,
                    fullPath: entry.fullPath ?? ""
                )
            }.sorted { $0.modified > $1.modified }  // Most recent first

        } catch {
            logger.error("Failed to read sessions-index.json: \(error.localizedDescription)")
            return []
        }
    }

    /// Get the most recent session for a project
    func mostRecentSession(for projectPath: String) -> DiscoveredSession? {
        return discoverSessions(for: projectPath).first
    }
}

// MARK: - JSON Structures

private struct ClaudeSessionsIndex: Codable {
    let version: Int
    let entries: [ClaudeSessionEntry]
}

private struct ClaudeSessionEntry: Codable {
    let sessionId: String
    let fullPath: String?
    let fileMtime: Int64?
    let firstPrompt: String?
    let summary: String?
    let messageCount: Int?
    let created: String?
    let modified: String?
    let gitBranch: String?
    let projectPath: String?
    let isSidechain: Bool?

    var createdDate: Date? {
        guard let created = created else { return nil }
        return ISO8601DateFormatter().date(from: created)
    }

    var modifiedDate: Date? {
        guard let modified = modified else { return nil }
        return ISO8601DateFormatter().date(from: modified)
    }
}
