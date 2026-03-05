import Foundation

/// Per-user project assignments for multi-user relay access.
/// Maps relay user IDs to sets of project IDs they can access.
/// When a team member connects via tunnel, they only see assigned projects.
enum TeamAssignments {
    private static let assignmentsKey = "teamProjectAssignments"
    private static let membersKey = "teamMembers"

    // MARK: - Team Member

    struct TeamMember: Codable, Identifiable, Equatable {
        let userId: String
        let email: String
        var name: String?

        var id: String { userId }
        var displayName: String { name ?? email }
    }

    // MARK: - Members

    static var members: [TeamMember] {
        get {
            guard let data = UserDefaults.standard.data(forKey: membersKey),
                  let members = try? JSONDecoder().decode([TeamMember].self, from: data) else {
                return []
            }
            return members
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: membersKey)
        }
    }

    /// Add or update a team member (called on tunnel_connected)
    static func addMember(userId: String, email: String) {
        var current = members
        if let idx = current.firstIndex(where: { $0.userId == userId }) {
            // Update email if changed
            if current[idx].email != email {
                current[idx] = TeamMember(userId: userId, email: email, name: current[idx].name)
                members = current
            }
        } else {
            current.append(TeamMember(userId: userId, email: email))
            members = current
        }
    }

    static func removeMember(userId: String) {
        members = members.filter { $0.userId != userId }
        // Also remove their assignments
        var assignments = allAssignments
        assignments.removeValue(forKey: userId)
        allAssignments = assignments
    }

    static func updateMemberName(userId: String, name: String) {
        var current = members
        if let idx = current.firstIndex(where: { $0.userId == userId }) {
            current[idx] = TeamMember(userId: userId, email: current[idx].email, name: name)
            members = current
        }
    }

    static func member(for userId: String) -> TeamMember? {
        members.first { $0.userId == userId }
    }

    // MARK: - Assignments

    static var allAssignments: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: assignmentsKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: assignmentsKey) }
    }

    /// Get the set of project IDs assigned to a user
    static func assignedProjectIds(for userId: String) -> Set<String> {
        Set(allAssignments[userId] ?? [])
    }

    /// Set the assigned projects for a user
    static func setAssignedProjects(for userId: String, projectIds: Set<String>) {
        var assignments = allAssignments
        assignments[userId] = Array(projectIds)
        allAssignments = assignments
    }

    /// Check if a specific project is assigned to a user
    static func isProjectAssigned(_ projectId: String, to userId: String) -> Bool {
        assignedProjectIds(for: userId).contains(projectId)
    }

    /// Toggle a project assignment for a user
    static func toggleProject(_ projectId: String, for userId: String) {
        var ids = assignedProjectIds(for: userId)
        if ids.contains(projectId) {
            ids.remove(projectId)
        } else {
            ids.insert(projectId)
        }
        setAssignedProjects(for: userId, projectIds: ids)
    }

    /// Whether the user has any project assignments configured
    static func hasAssignments(for userId: String) -> Bool {
        !(allAssignments[userId] ?? []).isEmpty
    }

    /// If no assignments exist for a user, they see all projects (owner/admin behavior)
    /// If assignments exist, they only see those projects
    static func effectiveProjectIds(for userId: String, allProjectIds: Set<String>) -> Set<String> {
        let assigned = assignedProjectIds(for: userId)
        if assigned.isEmpty {
            return allProjectIds // No restrictions = see everything
        }
        return assigned
    }
}
