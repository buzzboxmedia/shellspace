import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "TaskImportService")

/// Service for importing existing task folders as sessions
/// Scans {projectPath}/tasks/ for TASK.md files and creates sessions if they don't exist
class TaskImportService {
    static let shared = TaskImportService()

    private let fileManager = FileManager.default
    private let taskFolderService = TaskFolderService.shared

    private init() {}

    /// Validate existing sessions and groups against the filesystem
    /// - Marks sessions as completed if their folder is in completed/
    /// - Removes sessions whose folders no longer exist
    /// - Removes groups that are actually task folders (have TASK.md)
    @MainActor
    func validateFilesystem(for project: Project, modelContext: ModelContext) {
        let tasksDir = taskFolderService.tasksDirectory(for: project.path)
        let completedDir = taskFolderService.completedDirectory(for: project.path)

        var sessionsToDelete: [Session] = []
        var groupsToDelete: [ProjectGroup] = []

        // Grace period: don't delete recently created items (folder creation is async)
        let gracePeriod: TimeInterval = 30

        // Build set of active task folder names for reference
        let activeTaskFolders = findTaskFolders(in: tasksDir)
        let activeTaskNames = Set(activeTaskFolders.map { taskFolderService.slugify($0.lastPathComponent) })

        // Get completed folder names
        var completedTaskNames: [String: URL] = [:]
        if let completedContents = try? fileManager.contentsOfDirectory(at: completedDir, includingPropertiesForKeys: nil) {
            for item in completedContents {
                let name = item.lastPathComponent
                // Store both the full name and stripped name (without number prefix)
                let strippedName = name.replacingOccurrences(of: "^\\d{3}-", with: "", options: .regularExpression)
                completedTaskNames[name] = item
                completedTaskNames[strippedName] = item
            }
        }

        // Validate all sessions
        for session in project.sessions ?? [] {
            // Skip already completed sessions
            if session.isCompleted { continue }

            // Check sessions WITHOUT taskFolderPath first
            if session.taskFolderPath == nil {
                let sessionSlug = taskFolderService.slugify(session.name)

                // Check if this session name matches a completed task
                if let completedPath = completedTaskNames[sessionSlug] {
                    logger.info("Session matches completed task (no folder path): \(session.name)")
                    session.taskFolderPath = completedPath.path
                    session.isCompleted = true
                    session.completedAt = Date()
                    continue
                }

                // Check if there's NO matching active task folder
                if !activeTaskNames.contains(sessionSlug) {
                    // Grace period: don't delete recently created sessions (folder creation is async)
                    let sessionAge = Date().timeIntervalSince(session.createdAt)
                    if sessionAge < gracePeriod {
                        logger.info("Skipping recently created session (folder may still be creating): \(session.name)")
                        continue
                    }
                    // Session has no folder path and no matching task folder - orphaned
                    logger.info("Orphaned session (no matching task folder): \(session.name)")
                    sessionsToDelete.append(session)
                }
                continue
            }

            // Sessions WITH taskFolderPath
            guard let taskPath = session.taskFolderPath else { continue }

            let taskURL = URL(fileURLWithPath: taskPath)

            // Check if folder exists at original path
            if fileManager.fileExists(atPath: taskPath) {
                // Folder exists - check if it's in completed/
                if taskPath.contains("/completed/") && !session.isCompleted {
                    logger.info("Marking session as completed (folder in completed/): \(session.name)")
                    session.isCompleted = true
                    session.completedAt = Date()
                }
                continue
            }

            // Folder doesn't exist at original path - check if it moved to completed/
            let folderName = taskURL.lastPathComponent
            let possibleCompletedPath = completedDir.appendingPathComponent(folderName)

            if fileManager.fileExists(atPath: possibleCompletedPath.path) {
                // Found in completed folder - update path and mark completed
                logger.info("Session folder moved to completed: \(session.name)")
                session.taskFolderPath = possibleCompletedPath.path
                session.isCompleted = true
                session.completedAt = session.completedAt ?? Date()
            } else {
                // Check for numbered prefix versions (e.g., 001-branding, 002-branding)
                var found = false
                if let contents = try? fileManager.contentsOfDirectory(at: completedDir, includingPropertiesForKeys: nil) {
                    for item in contents {
                        let itemName = item.lastPathComponent
                        // Check if the folder name matches after stripping number prefix
                        let strippedName = itemName.replacingOccurrences(of: "^\\d{3}-", with: "", options: .regularExpression)
                        if strippedName == folderName || itemName == folderName {
                            logger.info("Session folder found in completed with different name: \(session.name) -> \(itemName)")
                            session.taskFolderPath = item.path
                            session.isCompleted = true
                            session.completedAt = session.completedAt ?? Date()
                            found = true
                            break
                        }
                    }
                }

                if !found {
                    // Grace period: don't delete recently created sessions (folder creation is async)
                    let sessionAge = Date().timeIntervalSince(session.createdAt)
                    if sessionAge < gracePeriod {
                        logger.info("Skipping recently created session (folder may still be creating): \(session.name)")
                        continue
                    }
                    // Folder truly doesn't exist - mark for deletion
                    logger.info("Session folder no longer exists, removing: \(session.name)")
                    sessionsToDelete.append(session)
                }
            }
        }

        // Validate project groups - they should be directories without TASK.md
        for group in project.taskGroups ?? [] {
            let groupSlug = taskFolderService.slugify(group.name)
            let groupPath = tasksDir.appendingPathComponent(groupSlug)

            // Check if directory exists
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: groupPath.path, isDirectory: &isDir) || !isDir.boolValue {
                // Grace period: don't delete recently created groups (folder creation may be async)
                let groupAge = Date().timeIntervalSince(group.createdAt)
                if groupAge < gracePeriod {
                    logger.info("Skipping recently created group (folder may still be creating): \(group.name)")
                    continue
                }
                logger.info("Group folder no longer exists, removing: \(group.name)")
                groupsToDelete.append(group)
                continue
            }

            // Check if it has TASK.md - but projects now have TASK.md too
            // Only remove if it's a task (not a project) based on **Type:** field
            let taskFile = groupPath.appendingPathComponent("TASK.md")
            if fileManager.fileExists(atPath: taskFile.path) {
                // Read the file and check if it's a project or task
                if let content = try? String(contentsOf: taskFile, encoding: .utf8) {
                    let isProject = content.contains("**Type:** project")
                    if !isProject {
                        // It's a task folder, not a project - remove the group
                        logger.info("Group is actually a task folder (has TASK.md without Type: project), removing group: \(group.name)")
                        for session in group.sessions {
                            session.taskGroup = nil
                        }
                        groupsToDelete.append(group)
                    }
                }
            }
        }

        // Delete stale records
        for session in sessionsToDelete {
            modelContext.delete(session)
        }
        for group in groupsToDelete {
            modelContext.delete(group)
        }

        if !sessionsToDelete.isEmpty || !groupsToDelete.isEmpty {
            do {
                try modelContext.save()
                logger.info("Cleaned up \(sessionsToDelete.count) sessions, \(groupsToDelete.count) groups")
            } catch {
                logger.error("Failed to save cleanup: \(error.localizedDescription)")
            }
        }
    }

    /// Re-link sessions to their correct task groups based on folder structure
    /// This fixes sessions that lost their taskGroup assignment
    @MainActor
    func relinkSessionsToGroups(for project: Project, modelContext: ModelContext) {
        let projectPath = project.path
        let tasksDir = taskFolderService.tasksDirectory(for: project.path)

        // Fetch all sessions for this project
        let sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { session in
                session.projectPath == projectPath && session.taskFolderPath != nil
            }
        )
        guard let sessions = try? modelContext.fetch(sessionDescriptor) else { return }

        // Fetch all groups for this project
        let groupDescriptor = FetchDescriptor<ProjectGroup>(
            predicate: #Predicate<ProjectGroup> { group in
                group.projectPath == projectPath
            }
        )
        guard let groups = try? modelContext.fetch(groupDescriptor), !groups.isEmpty else { return }

        var relinkedCount = 0

        for session in sessions {
            guard let taskPath = session.taskFolderPath else { continue }

            // Skip if already has a group
            if session.taskGroup != nil { continue }

            // Check if the task is inside a sub-project folder
            let taskURL = URL(fileURLWithPath: taskPath)
            let parentFolder = taskURL.deletingLastPathComponent()
            let parentName = parentFolder.lastPathComponent

            // Skip if parent is "tasks" (not in a sub-project)
            if parentName == "tasks" { continue }

            // Skip if parent is directly the tasks folder
            if parentFolder.path == tasksDir.path { continue }

            // Find matching group
            if let group = groups.first(where: { taskFolderService.slugify($0.name) == parentName }) {
                session.taskGroup = group
                relinkedCount += 1
                logger.info("Re-linked session to group: \(session.name) -> \(group.name)")
            }
        }

        if relinkedCount > 0 {
            do {
                try modelContext.save()
                logger.info("Re-linked \(relinkedCount) sessions to their groups")
            } catch {
                logger.error("Failed to save re-linked sessions: \(error.localizedDescription)")
            }
        }
    }

    /// Remove duplicate sessions with the same taskFolderPath
    /// Keeps the session with hasBeenLaunched=true, or the first one if neither has it
    @MainActor
    func cleanupDuplicateSessions(for project: Project, modelContext: ModelContext) {
        let projectPath = project.path
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { session in
                session.projectPath == projectPath && session.taskFolderPath != nil
            }
        )
        guard let sessions = try? modelContext.fetch(descriptor) else { return }

        // Group sessions by taskFolderPath (lowercased for case-insensitive)
        var sessionsByPath: [String: [Session]] = [:]
        for session in sessions {
            guard let path = session.taskFolderPath?.lowercased() else { continue }
            sessionsByPath[path, default: []].append(session)
        }

        // Find and remove duplicates
        var duplicatesToDelete: [Session] = []
        for (_, sessionsWithPath) in sessionsByPath {
            guard sessionsWithPath.count > 1 else { continue }

            // Keep the one with taskGroup set, then hasBeenLaunched=true, or the first one
            let sorted = sessionsWithPath.sorted { s1, s2 in
                // Prefer sessions with taskGroup set (linked to a sub-project)
                let s1HasGroup = s1.taskGroup != nil
                let s2HasGroup = s2.taskGroup != nil
                if s1HasGroup != s2HasGroup {
                    return s1HasGroup
                }
                // Then prefer hasBeenLaunched=true
                if s1.hasBeenLaunched != s2.hasBeenLaunched {
                    return s1.hasBeenLaunched
                }
                // Then prefer older (first created)
                return s1.createdAt < s2.createdAt
            }

            // Keep first, delete rest
            let toDelete = sorted.dropFirst()
            duplicatesToDelete.append(contentsOf: toDelete)
            logger.info("Found \(toDelete.count) duplicate(s) for: \(sorted.first?.name ?? "unknown")")
        }

        // Delete duplicates
        for session in duplicatesToDelete {
            modelContext.delete(session)
        }

        if !duplicatesToDelete.isEmpty {
            do {
                try modelContext.save()
                logger.info("Removed \(duplicatesToDelete.count) duplicate sessions")
            } catch {
                logger.error("Failed to remove duplicates: \(error.localizedDescription)")
            }
        }
    }

    /// Discover and create ProjectGroups from folder structure
    /// This allows projects created on one machine to appear on another via Dropbox sync
    @MainActor
    func discoverProjectGroups(for project: Project, modelContext: ModelContext) {
        let tasksDir = taskFolderService.tasksDirectory(for: project.path)

        guard fileManager.fileExists(atPath: tasksDir.path) else {
            return
        }

        // Get existing group names (slugified for comparison)
        let existingGroupSlugs = Set(project.taskGroups.map { taskFolderService.slugify($0.name) })

        // Scan for project folders (directories without number prefix that contain task folders or have Type: project)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: tasksDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }

        var maxSortOrder = project.taskGroups.map(\.sortOrder).max() ?? -1

        for item in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            let name = item.lastPathComponent

            // Skip archive folders and numbered task folders
            if name == "completed" || name == "archive" || (name.first?.isNumber ?? false) {
                continue
            }

            // Check if this is a project folder (has sub-tasks or has TASK.md with Type: project)
            let taskFile = item.appendingPathComponent("TASK.md")
            var isProjectFolder = false

            if fileManager.fileExists(atPath: taskFile.path) {
                // Check if it's marked as a project
                if let content = try? String(contentsOf: taskFile, encoding: .utf8) {
                    isProjectFolder = content.contains("**Type:** project")
                }
            } else {
                // No TASK.md - check if it contains task folders (making it a project)
                if let subContents = try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    isProjectFolder = subContents.contains { sub in
                        let subTaskFile = sub.appendingPathComponent("TASK.md")
                        return fileManager.fileExists(atPath: subTaskFile.path)
                    }
                }
            }

            guard isProjectFolder else { continue }

            // Skip if we already have a group for this folder
            let slug = taskFolderService.slugify(name)
            guard !existingGroupSlugs.contains(slug) else { continue }

            // Create a new ProjectGroup
            maxSortOrder += 1
            let group = ProjectGroup(name: name, projectPath: project.path, sortOrder: maxSortOrder)
            group.project = project
            modelContext.insert(group)
            logger.info("Discovered project group from folder: \(name)")
        }

        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save discovered project groups: \(error.localizedDescription)")
        }
    }

    /// Ensure each ProjectGroup has a session so it can be opened in terminal
    @MainActor
    func ensureProjectSessions(for project: Project, modelContext: ModelContext) {

        for group in project.taskGroups {
            let projectFolderPath = taskFolderService.projectDirectory(
                projectPath: project.path,
                projectName: group.name
            ).path

            // Check if this group already has a project session
            let hasProjectSession = group.sessions.contains { session in
                session.taskFolderPath == projectFolderPath
            }

            if !hasProjectSession {
                // Check if the project folder exists and has TASK.md - create if not
                let taskFile = URL(fileURLWithPath: projectFolderPath).appendingPathComponent("TASK.md")
                if !fileManager.fileExists(atPath: taskFile.path) {
                    // Create TASK.md and CLAUDE.md for the project
                    do {
                        _ = try taskFolderService.createProject(
                            projectPath: project.path,
                            projectName: group.name,
                            clientName: project.name,
                            description: nil
                        )
                    } catch {
                        logger.error("Failed to create project files: \(error.localizedDescription)")
                        continue
                    }
                }

                // Create a session for this project
                let session = Session(
                    name: group.name,
                    projectPath: project.path,
                    userNamed: true
                )
                session.project = project
                session.taskGroup = group
                session.taskFolderPath = projectFolderPath
                session.sessionDescription = "Project folder for organizing related tasks."
                modelContext.insert(session)

                logger.info("Created project session for: \(group.name)")
            }
        }

        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save project sessions: \(error.localizedDescription)")
        }
    }

    /// Import all tasks from a project's tasks directory
    /// Returns the number of tasks imported
    @MainActor
    func importTasks(for project: Project, modelContext: ModelContext) -> Int {
        // First validate existing records against filesystem
        validateFilesystem(for: project, modelContext: modelContext)

        // Clean up any duplicate sessions (same taskFolderPath)
        cleanupDuplicateSessions(for: project, modelContext: modelContext)

        // Auto-discover project groups from folder structure (BEFORE re-linking!)
        discoverProjectGroups(for: project, modelContext: modelContext)

        // Re-link sessions that lost their group assignment (AFTER groups are discovered)
        relinkSessionsToGroups(for: project, modelContext: modelContext)

        // Ensure all project groups have sessions
        ensureProjectSessions(for: project, modelContext: modelContext)

        let tasksDir = taskFolderService.tasksDirectory(for: project.path)

        guard fileManager.fileExists(atPath: tasksDir.path) else {
            logger.info("No tasks directory found for \(project.name)")
            return 0
        }

        // Query sessions directly from database by projectPath (don't rely on project.sessions relationship)
        let projectPath = project.path
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { session in
                session.projectPath == projectPath
            }
        )
        let existingSessions = (try? modelContext.fetch(descriptor)) ?? []

        // Get existing task folder paths (lowercased for case-insensitive comparison)
        let existingTaskPaths = Set(
            existingSessions.compactMap { $0.taskFolderPath?.lowercased() }
        )

        var importedCount = 0

        // Scan for task folders
        let taskFolders = findTaskFolders(in: tasksDir)

        for taskFolder in taskFolders {
            // Skip if session already exists for this task folder (case-insensitive)
            guard !existingTaskPaths.contains(taskFolder.path.lowercased()) else {
                continue
            }

            // Double-check by querying database directly for this specific path
            // This catches race conditions where multiple imports run simultaneously
            let folderPath = taskFolder.path
            let pathCheckDescriptor = FetchDescriptor<Session>(
                predicate: #Predicate<Session> { session in
                    session.taskFolderPath == folderPath
                }
            )
            if let existingCount = try? modelContext.fetchCount(pathCheckDescriptor), existingCount > 0 {
                logger.info("Skipping duplicate import for: \(taskFolder.lastPathComponent)")
                continue
            }

            // Read and parse the TASK.md
            guard let taskContent = taskFolderService.readTask(at: taskFolder) else {
                continue
            }

            // Create a new session linked to this task
            let session = Session(
                name: taskContent.title ?? taskFolder.lastPathComponent,
                projectPath: project.path,
                userNamed: true
            )
            session.sessionDescription = taskContent.description
            session.taskFolderPath = taskFolder.path
            session.project = project

            // Check if there's an existing Claude conversation for this task folder
            // If so, mark as launched so --continue will work
            if hasExistingClaudeSession(for: taskFolder.path) {
                session.hasBeenLaunched = true
                logger.info("Found existing Claude session for imported task: \(taskContent.title ?? "Unknown")")
            }

            // Mark as completed if task status is done
            if taskContent.isDone {
                session.isCompleted = true
                session.completedAt = Date()
            }

            // Try to link to a task group based on parent folder
            let parentName = taskFolder.deletingLastPathComponent().lastPathComponent
            if parentName != "tasks" {
                // Task is in a sub-project folder - query database directly for the group
                let groupDescriptor = FetchDescriptor<ProjectGroup>(
                    predicate: #Predicate<ProjectGroup> { group in
                        group.projectPath == projectPath
                    }
                )
                if let groups = try? modelContext.fetch(groupDescriptor),
                   let group = groups.first(where: { taskFolderService.slugify($0.name) == parentName }) {
                    session.taskGroup = group
                    logger.info("Linked imported task to group: \(group.name)")
                }
            }

            modelContext.insert(session)
            importedCount += 1
            logger.info("Imported task: \(taskContent.title ?? "Unknown")")
        }

        if importedCount > 0 {
            do {
                try modelContext.save()
                logger.info("Imported \(importedCount) tasks for \(project.name)")
            } catch {
                logger.error("Failed to save imported tasks: \(error.localizedDescription)")
            }
        }

        return importedCount
    }

    /// Find all task folders (those with TASK.md) in a directory, recursively
    /// Skips the "completed" and "archive" folders to prevent reimporting archived tasks
    private func findTaskFolders(in directory: URL) -> [URL] {
        var taskFolders: [URL] = []

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        for item in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            let name = item.lastPathComponent

            // Skip archive folders - don't reimport completed/archived tasks
            if name == "completed" || name == "archive" {
                continue
            }

            let taskFile = item.appendingPathComponent("TASK.md")
            let hasTaskMd = fileManager.fileExists(atPath: taskFile.path)

            if hasTaskMd {
                // This folder has a TASK.md - add it as a task
                taskFolders.append(item)
            }

            // Always recurse into non-numbered folders to find nested tasks
            // (sub-project folders can have both their own TASK.md AND contain tasks)
            if !(name.first?.isNumber ?? false) {
                taskFolders.append(contentsOf: findTaskFolders(in: item))
            }
        }

        return taskFolders
    }

    /// Check how many tasks would be imported (without actually importing)
    func countImportableTasks(for project: Project) -> Int {
        let tasksDir = taskFolderService.tasksDirectory(for: project.path)

        guard fileManager.fileExists(atPath: tasksDir.path) else {
            return 0
        }

        let existingTaskPaths = Set(
            (project.sessions ?? []).compactMap { $0.taskFolderPath }
        )

        let taskFolders = findTaskFolders(in: tasksDir)

        return taskFolders.filter { !existingTaskPaths.contains($0.path) }.count
    }

    /// Check if there's an existing Claude session (conversation) for a task folder path
    private func hasExistingClaudeSession(for taskFolderPath: String) -> Bool {
        // Convert path to Claude's folder format (slashes become hyphens)
        let claudeProjectPath = taskFolderPath.replacingOccurrences(of: "/", with: "-")
        let claudeProjectsDir = "\(NSHomeDirectory())/.claude/projects/\(claudeProjectPath)"

        // Check if the directory exists and has any .jsonl files
        guard fileManager.fileExists(atPath: claudeProjectsDir),
              let files = try? fileManager.contentsOfDirectory(atPath: claudeProjectsDir) else {
            return false
        }

        return files.contains { $0.hasSuffix(".jsonl") }
    }
}
