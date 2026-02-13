import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var path: String
    var icon: String
    var category: ProjectCategory

    /// When true, sessions open in external Terminal.app instead of embedded terminal
    var usesExternalTerminal: Bool = true

    // Remember last active session when returning to project
    var lastActiveSessionId: UUID?

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \Session.project)
    var sessions: [Session] = []

    @Relationship(deleteRule: .cascade, inverse: \ProjectGroup.project)
    var taskGroups: [ProjectGroup] = []

    // Computed (not synced)
    var url: URL {
        URL(fileURLWithPath: path)
    }

    init(name: String, path: String, icon: String, category: ProjectCategory = .main, usesExternalTerminal: Bool = true) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.icon = icon
        self.category = category
        self.usesExternalTerminal = usesExternalTerminal
    }
}

// MARK: - Legacy types for migration

/// Codable wrapper for Project persistence (used during migration)
struct SavedProject: Codable {
    let name: String
    let path: String
    let icon: String

    init(from project: Project) {
        self.name = project.name
        self.path = project.path
        self.icon = project.icon
    }

    func toProject(category: ProjectCategory) -> Project {
        Project(name: name, path: path, icon: icon, category: category)
    }
}

/// Container for saving both project lists (used during migration)
struct SavedProjectsFile: Codable {
    let main: [SavedProject]
    let clients: [SavedProject]
}
