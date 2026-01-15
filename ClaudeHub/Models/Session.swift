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

    enum CodingKeys: String, CodingKey {
        case id, name, description, projectPath, createdAt, lastAccessedAt, claudeSessionId
        case activeProjectName, parkerBriefing, lastSessionSummary
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
