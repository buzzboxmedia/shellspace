import Foundation
import SwiftData
import os.log

private let migrationLogger = Logger(subsystem: "com.buzzbox.claudehub", category: "Migration")

/// One-time migration from JSON files to SwiftData
struct DataMigration {

    /// Run this once on first launch after SwiftData upgrade
    @MainActor
    static func migrateIfNeeded(modelContext: ModelContext) {
        let defaults = UserDefaults.standard
        let migrationKey = "swiftdata_migration_completed_v1"

        guard !defaults.bool(forKey: migrationKey) else {
            migrationLogger.info("Migration already completed, skipping")
            return
        }

        migrationLogger.info("Starting migration from JSON to SwiftData...")

        do {
            // 1. Migrate projects
            let projects = try migrateProjects(modelContext: modelContext)

            // 2. Migrate task groups
            let taskGroups = try migrateTaskGroups(modelContext: modelContext, projects: projects)

            // 3. Migrate sessions
            try migrateSessions(modelContext: modelContext, projects: projects, taskGroups: taskGroups)

            // 4. Save everything
            try modelContext.save()

            // 5. Mark migration complete
            defaults.set(true, forKey: migrationKey)

            // Also set the default projects flag to prevent LauncherView from creating duplicates
            defaults.set(true, forKey: "hasCreatedDefaultProjects")

            migrationLogger.info("Migration completed successfully!")

        } catch {
            migrationLogger.error("Migration failed: \(error.localizedDescription)")
            // Don't mark as complete so it can retry
        }
    }

    // MARK: - Project Migration

    @MainActor
    private static func migrateProjects(modelContext: ModelContext) throws -> [String: Project] {
        var projectsByPath: [String: Project] = [:]

        let configPath = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/ClaudeHub").expandingTildeInPath
        let projectsFile = URL(fileURLWithPath: configPath).appendingPathComponent("projects.json")

        if let data = try? Data(contentsOf: projectsFile),
           let saved = try? JSONDecoder().decode(SavedProjectsFile.self, from: data) {

            // Main projects
            for legacyProject in saved.main {
                let project = Project(
                    name: legacyProject.name,
                    path: legacyProject.path,
                    icon: legacyProject.icon,
                    category: .main
                )
                modelContext.insert(project)
                projectsByPath[legacyProject.path] = project
                migrationLogger.info("Migrated main project: \(legacyProject.name)")
            }

            // Client projects
            for legacyProject in saved.clients {
                let project = Project(
                    name: legacyProject.name,
                    path: legacyProject.path,
                    icon: legacyProject.icon,
                    category: .client
                )
                modelContext.insert(project)
                projectsByPath[legacyProject.path] = project
                migrationLogger.info("Migrated client project: \(legacyProject.name)")
            }
        }

        // Always add ClaudeHub dev project (machine-specific path)
        let claudeHubPath = "\(NSHomeDirectory())/Code/claudehub"
        if projectsByPath[claudeHubPath] == nil {
            let devProject = Project(
                name: "ClaudeHub",
                path: claudeHubPath,
                icon: "hammer.fill",
                category: .dev
            )
            modelContext.insert(devProject)
            projectsByPath[claudeHubPath] = devProject
        }

        migrationLogger.info("Migrated \(projectsByPath.count) projects")
        return projectsByPath
    }

    // MARK: - Task Group Migration

    @MainActor
    private static func migrateTaskGroups(
        modelContext: ModelContext,
        projects: [String: Project]
    ) throws -> [UUID: ProjectGroup] {
        var taskGroupsById: [UUID: ProjectGroup] = [:]

        for (projectPath, project) in projects {
            let groupsFile = taskGroupsFilePath(for: projectPath)

            guard let data = try? Data(contentsOf: groupsFile),
                  let legacyGroups = try? JSONDecoder().decode([LegacyProjectGroup].self, from: data) else {
                continue
            }

            for legacyGroup in legacyGroups {
                let group = ProjectGroup(
                    name: legacyGroup.name,
                    projectPath: legacyGroup.projectPath,
                    sortOrder: legacyGroup.sortOrder
                )
                // Preserve original ID for session linking
                group.id = legacyGroup.id
                group.createdAt = legacyGroup.createdAt
                group.isExpanded = legacyGroup.isExpanded
                group.project = project

                modelContext.insert(group)
                taskGroupsById[legacyGroup.id] = group
                migrationLogger.info("Migrated task group: \(legacyGroup.name)")
            }
        }

        migrationLogger.info("Migrated \(taskGroupsById.count) task groups")
        return taskGroupsById
    }

    // MARK: - Session Migration

    @MainActor
    private static func migrateSessions(
        modelContext: ModelContext,
        projects: [String: Project],
        taskGroups: [UUID: ProjectGroup]
    ) throws {
        var sessionCount = 0

        for (projectPath, project) in projects {
            let sessionsFile = sessionsFilePath(for: projectPath)

            guard let data = try? Data(contentsOf: sessionsFile),
                  let legacySessions = try? JSONDecoder().decode([LegacySession].self, from: data) else {
                continue
            }

            for legacy in legacySessions {
                let session = Session(
                    name: legacy.name,
                    projectPath: legacy.projectPath,
                    createdAt: legacy.createdAt,
                    userNamed: legacy.userNamed,
                    activeProjectName: legacy.activeProjectName,
                    parkerBriefing: legacy.parkerBriefing
                )

                // Preserve original ID
                session.id = legacy.id

                // Copy all properties
                session.sessionDescription = legacy.description
                session.lastAccessedAt = legacy.lastAccessedAt
                session.claudeSessionId = legacy.claudeSessionId
                session.lastSessionSummary = legacy.lastSessionSummary
                session.logFilePath = legacy.logFilePath
                session.lastLogSavedAt = legacy.lastLogSavedAt
                session.isCompleted = legacy.isCompleted
                session.completedAt = legacy.completedAt

                // Link relationships
                session.project = project
                if let taskGroupId = legacy.taskGroupId {
                    session.taskGroup = taskGroups[taskGroupId]
                }

                modelContext.insert(session)
                sessionCount += 1
            }

            migrationLogger.info("Migrated \(legacySessions.count) sessions from \(project.name)")
        }

        migrationLogger.info("Migrated \(sessionCount) total sessions")
    }

    // MARK: - File Paths (matching existing logic)

    private static func sessionsFilePath(for projectPath: String) -> URL {
        if projectPath.contains("/Code/claudehub") || projectPath.contains("/code/claudehub") {
            let configPath = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/ClaudeHub").expandingTildeInPath
            return URL(fileURLWithPath: configPath).appendingPathComponent("sessions.json")
        }
        return URL(fileURLWithPath: projectPath).appendingPathComponent(".claudehub-sessions.json")
    }

    private static func taskGroupsFilePath(for projectPath: String) -> URL {
        if projectPath.contains("/Code/claudehub") || projectPath.contains("/code/claudehub") {
            let configPath = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/ClaudeHub").expandingTildeInPath
            return URL(fileURLWithPath: configPath).appendingPathComponent("taskgroups.json")
        }
        return URL(fileURLWithPath: projectPath).appendingPathComponent(".claudehub-taskgroups.json")
    }

    // MARK: - Deduplication

    /// Remove duplicate projects (keeps the first one by creation order)
    @MainActor
    static func deduplicateProjectsIfNeeded(modelContext: ModelContext) {
        let defaults = UserDefaults.standard
        let dedupeKey = "projects_deduplicated_v1"

        guard !defaults.bool(forKey: dedupeKey) else {
            return
        }

        migrationLogger.info("Checking for duplicate projects...")

        do {
            let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
            let allProjects = try modelContext.fetch(descriptor)

            // Group by path (path should be unique)
            var projectsByPath: [String: [Project]] = [:]
            for project in allProjects {
                projectsByPath[project.path, default: []].append(project)
            }

            // Delete duplicates (keep first, delete rest)
            var deletedCount = 0
            for (path, projects) in projectsByPath where projects.count > 1 {
                migrationLogger.info("Found \(projects.count) duplicates for path: \(path)")
                for duplicate in projects.dropFirst() {
                    modelContext.delete(duplicate)
                    deletedCount += 1
                }
            }

            if deletedCount > 0 {
                try modelContext.save()
                migrationLogger.info("Deleted \(deletedCount) duplicate projects")
            } else {
                migrationLogger.info("No duplicate projects found")
            }

            defaults.set(true, forKey: dedupeKey)

        } catch {
            migrationLogger.error("Deduplication failed: \(error.localizedDescription)")
        }
    }
}
