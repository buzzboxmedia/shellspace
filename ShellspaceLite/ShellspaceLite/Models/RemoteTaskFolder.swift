import Foundation

struct RemoteTaskFolder: Codable, Identifiable, Hashable {
    let path: String
    let title: String?
    let status: String?
    let created: String?
    let description: String?

    var id: String { path }

    var displayName: String {
        title ?? URL(fileURLWithPath: path).lastPathComponent
    }

    var isActive: Bool {
        status?.lowercased() == "active"
    }

    var isCompleted: Bool {
        let s = status?.lowercased() ?? ""
        return s == "done" || s == "completed"
    }
}

struct TasksResponse: Codable {
    let tasks: [RemoteTaskFolder]
}
