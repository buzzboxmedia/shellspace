import Foundation

struct RemoteProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let icon: String
    let category: String
    let activeSessions: Int
    let waitingSessions: Int
}

struct ProjectsResponse: Codable {
    let projects: [RemoteProject]
}
