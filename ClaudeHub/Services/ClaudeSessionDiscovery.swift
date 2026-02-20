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
    /// Always resolves symlinks first since Claude CLI does the same internally.
    /// e.g., /Users/baron/Dropbox/Talkspresso -> -Users-baron-Library-CloudStorage-Dropbox-Talkspresso
    func claudeFolderName(for projectPath: String) -> String {
        return projectPath.canonicalPath.replacingOccurrences(of: "/", with: "-")
    }

    /// Get the full path to Claude's session folder for a project
    func claudeSessionFolder(for projectPath: String) -> String {
        let folderName = claudeFolderName(for: projectPath)
        return "\(claudeProjectsPath)/\(folderName)"
    }

    /// Discover all sessions for a given project path
    func discoverSessions(for projectPath: String) -> [DiscoveredSession] {
        // Use canonical path (symlinks resolved) since Claude CLI does the same
        if let sessions = discoverSessionsAtPath(projectPath.canonicalPath), !sessions.isEmpty {
            return sessions
        }

        // Fall back to original path in case older sessions used un-resolved paths
        let originalPath = projectPath
        if originalPath != projectPath.canonicalPath {
            if let sessions = discoverSessionsAtPath(originalPath), !sessions.isEmpty {
                return sessions
            }
        }

        logger.debug("No sessions found for \(projectPath)")
        return []
    }

    /// Internal: discover sessions at a specific path
    private func discoverSessionsAtPath(_ projectPath: String) -> [DiscoveredSession]? {
        let sessionFolder = claudeSessionFolder(for: projectPath)
        let indexPath = "\(sessionFolder)/sessions-index.json"

        guard fileManager.fileExists(atPath: indexPath) else {
            logger.debug("No sessions-index.json found at \(indexPath)")
            return nil
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

    /// Shared formatter -- ISO8601DateFormatter is expensive to construct
    private static let isoFormatter = ISO8601DateFormatter()

    var createdDate: Date? {
        guard let created = created else { return nil }
        return Self.isoFormatter.date(from: created)
    }

    var modifiedDate: Date? {
        guard let modified = modified else { return nil }
        return Self.isoFormatter.date(from: modified)
    }
}
