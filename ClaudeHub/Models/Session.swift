import Foundation

struct Session: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    let projectPath: String
    let createdAt: Date
    var lastAccessedAt: Date = Date()
    var claudeSessionId: String?  // Claude's session ID for --resume

    // Link to active project from ACTIVE-PROJECTS.md
    var activeProjectName: String?
    var parkerBriefing: String?

    enum CodingKeys: String, CodingKey {
        case id, name, projectPath, createdAt, lastAccessedAt, claudeSessionId
        case activeProjectName, parkerBriefing
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
            projectPath: "/Users/baron/Dropbox/Buzzbox/Clients/AAGL",
            createdAt: Date()
        )
    }
}
