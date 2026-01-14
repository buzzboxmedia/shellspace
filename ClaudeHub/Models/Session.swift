import Foundation

struct Session: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    let projectPath: String
    let createdAt: Date
    var lastAccessedAt: Date = Date()
    var claudeSessionId: String?  // Claude's session ID for --resume

    enum CodingKeys: String, CodingKey {
        case id, name, projectPath, createdAt, lastAccessedAt, claudeSessionId
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
