import Foundation

/// A group of related tasks within a project folder (e.g., "Website Redesign" under AAGL)
/// Named ProjectGroup to avoid conflict with SwiftUI's TaskGroup
struct ProjectGroup: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    let projectPath: String  // Parent folder path
    let createdAt: Date
    var isExpanded: Bool = true  // UI state for collapsible sections

    init(id: UUID = UUID(), name: String, projectPath: String, createdAt: Date = Date(), isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.isExpanded = isExpanded
    }
}
