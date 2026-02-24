import Foundation

struct RemoteSession: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let projectPath: String
    let createdAt: String
    let lastAccessedAt: String
    let isCompleted: Bool
    let isHidden: Bool
    let isWaitingForInput: Bool
    let hasBeenLaunched: Bool
    let isRunning: Bool
    let summary: String?
    let taskFolderPath: String?
    let parkerBriefing: String?

    /// Project name derived from path or set by the browse context
    var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    /// Relative time since last accessed
    var relativeTime: String {
        guard let date = ISO8601DateFormatter().date(from: lastAccessedAt) else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct SessionsResponse: Codable {
    let sessions: [RemoteSession]
}

struct TerminalResponse: Codable {
    let sessionId: String
    let content: String
    let isRunning: Bool
}

struct ServerStatus: Codable {
    let status: String
    let version: String
    let app: String
    let activeSessions: Int
    let totalControllers: Int
}

struct InputResponse: Codable {
    let status: String
    let sessionId: String
}
