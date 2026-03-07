import Foundation

// MARK: - Remote data models for Companion Mode
// These mirror the relay server's JSON protocol. Used when this Mac
// connects as a tunnel client to another Mac's Shellspace instance.

struct RemoteProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let icon: String
    let category: String
    let activeSessions: Int
    let waitingSessions: Int
}

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

    var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    var lastAccessedDate: Date? {
        ISO8601DateFormatter().date(from: lastAccessedAt)
    }

    var relativeTime: String {
        guard let date = lastAccessedDate else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
