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

    /// Import all tasks from a project's tasks directory
    /// Returns the number of tasks imported
    @MainActor
    func importTasks(for project: Project, modelContext: ModelContext) -> Int {
        // First validate existing records against filesystem
        validateFilesystem(for: project, modelContext: modelContext)

        let tasksDir = taskFolderService.tasksDirectory(for: project.path)

        guard fileManager.fileExists(atPath: tasksDir.path) else {
            logger.info("No tasks directory found for \(project.name)")
            return 0
        }

        // Get existing sessions linked to task folders
        let existingTaskPaths = Set(
            (project.sessions ?? []).compactMap { $0.taskFolderPath }
        )

        var importedCount = 0

        // Scan for task folders
        let taskFolders = findTaskFolders(in: tasksDir)

        for taskFolder in taskFolders {
            // Skip if session already exists for this task folder
            guard !existingTaskPaths.contains(taskFolder.path) else {
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

            // Mark as completed if task status is done
            if taskContent.isDone {
                session.isCompleted = true
                session.completedAt = Date()
            }

            // Try to link to a task group based on parent folder
            let parentName = taskFolder.deletingLastPathComponent().lastPathComponent
            if parentName != "tasks" {
                // Task is in a sub-project folder
                if let group = (project.taskGroups ?? []).first(where: {
                    taskFolderService.slugify($0.name) == parentName
                }) {
                    session.taskGroup = group
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
            if fileManager.fileExists(atPath: taskFile.path) {
                // This is a task folder
                taskFolders.append(item)
            } else {
                // Check if it's a sub-project folder (no number prefix)
                if !(name.first?.isNumber ?? false) {
                    // Recurse into sub-project folders
                    taskFolders.append(contentsOf: findTaskFolders(in: item))
                }
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
}
