import Foundation
import SwiftData

/// A group of related tasks within a project folder (e.g., "Website Redesign" under AAGL)
/// Named ProjectGroup to avoid conflict with SwiftUI's TaskGroup
@Model
final class ProjectGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var projectPath: String  // Parent folder path
    var createdAt: Date
    var isExpanded: Bool  // UI state for collapsible sections
    var sortOrder: Int  // For drag-and-drop reordering

    // Relationships
    var project: Project?

    @Relationship(deleteRule: .nullify, inverse: \Session.taskGroup)
    var sessions: [Session] = []

    init(name: String, projectPath: String, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.projectPath = projectPath
        self.createdAt = Date()
        self.isExpanded = true
        self.sortOrder = sortOrder
    }
}
