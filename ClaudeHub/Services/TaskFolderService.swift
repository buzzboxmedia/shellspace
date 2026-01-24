import Foundation
import os.log

private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "TaskFolderService")

/// Service for managing task folders with TASK.md files
/// Structure:
///   {projectPath}/tasks/
///   ├── project-name/                    ← Project folder
///   │   ├── task-name/
///   │   │   └── TASK.md
///   │   └── another-task/
///   │       └── TASK.md
///   └── standalone-task/                 ← Task without project
///       └── TASK.md
///
/// Works with any project path (Talkspresso, Buzzbox clients, etc.)
class TaskFolderService {
    static let shared = TaskFolderService()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Path Helpers

    /// Get the tasks directory for a project path
    func tasksDirectory(for projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent("tasks")
    }

    /// Get the sub-project directory within a project's tasks
    func projectDirectory(projectPath: String, projectName: String) -> URL {
        tasksDirectory(for: projectPath)
            .appendingPathComponent(slugify(projectName))
    }

    /// Get the task folder path
    func taskFolderPath(projectPath: String, subProjectName: String?, taskName: String) -> URL {
        let folderName = slugify(taskName)

        if let subProject = subProjectName {
            return projectDirectory(projectPath: projectPath, projectName: subProject)
                .appendingPathComponent(folderName)
        } else {
            return tasksDirectory(for: projectPath)
                .appendingPathComponent(folderName)
        }
    }

    /// Convert a name to a filesystem-safe slug
    func slugify(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Project Operations

    /// Create a sub-project folder within a project's tasks
    func createProject(projectPath: String, projectName: String) throws -> URL {
        let projectDir = projectDirectory(projectPath: projectPath, projectName: projectName)

        if !fileManager.fileExists(atPath: projectDir.path) {
            try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
            logger.info("Created project folder: \(projectDir.path)")
        }

        return projectDir
    }

    /// List all sub-projects for a project
    func listProjects(for projectPath: String) -> [String] {
        let tasksDir = tasksDirectory(for: projectPath)

        guard fileManager.fileExists(atPath: tasksDir.path) else {
            return []
        }

        do {
            let contents = try fileManager.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: [.isDirectoryKey])
            return contents.compactMap { url in
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    let name = url.lastPathComponent
                    // Projects don't have number prefix, tasks do
                    if !name.first!.isNumber {
                        return name
                    }
                }
                return nil
            }
        } catch {
            logger.error("Failed to list projects: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Task Operations

    /// Create a new task folder with TASK.md
    func createTask(
        projectPath: String,
        projectName: String,
        subProjectName: String?,
        taskName: String,
        description: String?
    ) throws -> URL {
        // Create parent directories if needed
        let tasksDir = tasksDirectory(for: projectPath)
        if !fileManager.fileExists(atPath: tasksDir.path) {
            try fileManager.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        }

        if let subProject = subProjectName {
            _ = try createProject(projectPath: projectPath, projectName: subProject)
        }

        let taskFolder = taskFolderPath(projectPath: projectPath, subProjectName: subProjectName, taskName: taskName)

        // Create task folder
        try fileManager.createDirectory(at: taskFolder, withIntermediateDirectories: true)

        // Create TASK.md
        let taskFile = taskFolder.appendingPathComponent("TASK.md")
        let content = generateTaskContent(
            taskName: taskName,
            projectName: projectName,
            subProjectName: subProjectName,
            description: description
        )

        try content.write(to: taskFile, atomically: true, encoding: .utf8)

        // Create task-level CLAUDE.md with context paths for Claude Code
        let claudeMdFile = taskFolder.appendingPathComponent("CLAUDE.md")
        let claudeMdContent = generateClaudeMdContent(taskName: taskName, subProjectName: subProjectName)
        try claudeMdContent.write(to: claudeMdFile, atomically: true, encoding: .utf8)

        logger.info("Created task folder: \(taskFolder.path)")

        return taskFolder
    }

    /// Generate CLAUDE.md content for task folder
    func generateClaudeMdContent(taskName: String, subProjectName: String?) -> String {
        // Calculate relative path to client root based on folder depth
        let clientRoot = subProjectName != nil ? "../../../" : "../../"

        return """
        # Task: \(taskName)

        ## Context Paths
        - **Client root:** \(clientRoot)
        - **Credentials:** \(clientRoot)credentials/

        ## Task File
        See TASK.md in this folder for task description, status, and progress log.

        ---
        *Parent CLAUDE.md files are automatically loaded for team and client context.*
        """
    }

    /// Generate the TASK.md content
    func generateTaskContent(
        taskName: String,
        projectName: String,
        subProjectName: String?,
        description: String?
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        return """
        # \(taskName)

        **Status:** active
        **Created:** \(today)
        **Project:** \(projectName)
        \(subProjectName != nil ? "**Sub-project:** \(subProjectName!)\n" : "")
        ## Description
        \(description ?? "No description provided.")

        ## Progress

        """
    }

    /// Read and parse a TASK.md file
    func readTask(at folderPath: URL) -> TaskContent? {
        let taskFile = folderPath.appendingPathComponent("TASK.md")

        guard fileManager.fileExists(atPath: taskFile.path) else {
            return nil
        }

        do {
            let content = try String(contentsOf: taskFile, encoding: .utf8)
            return parseTaskContent(content: content, folderPath: folderPath)
        } catch {
            logger.error("Failed to read task: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse TASK.md content
    func parseTaskContent(content: String, folderPath: URL) -> TaskContent {
        var task = TaskContent(folderPath: folderPath.path)

        let lines = content.components(separatedBy: "\n")
        var currentSection: String? = nil
        var descriptionLines: [String] = []
        var progressLines: [String] = []

        for line in lines {
            // Parse title
            if line.hasPrefix("# ") && task.title == nil {
                task.title = String(line.dropFirst(2))
                continue
            }

            // Parse metadata
            if line.hasPrefix("**Status:**") {
                task.status = line.replacingOccurrences(of: "**Status:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("**Created:**") {
                task.created = line.replacingOccurrences(of: "**Created:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("**Client:**") {
                task.client = line.replacingOccurrences(of: "**Client:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("**Project:**") {
                task.project = line.replacingOccurrences(of: "**Project:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }

            // Track sections
            if line.hasPrefix("## Description") {
                currentSection = "description"
                continue
            }
            if line.hasPrefix("## Progress") {
                currentSection = "progress"
                continue
            }
            if line.hasPrefix("## ") {
                currentSection = nil
                continue
            }

            // Collect section content
            if currentSection == "description" {
                descriptionLines.append(line)
            }
            if currentSection == "progress" {
                progressLines.append(line)
            }
        }

        task.description = descriptionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        task.progressLog = progressLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        task.progressEntries = parseProgressEntries(from: task.progressLog ?? "")

        return task
    }

    /// Parse progress entries from the progress section
    func parseProgressEntries(from progressLog: String) -> [ProgressEntry] {
        var entries: [ProgressEntry] = []
        var currentEntry: ProgressEntry? = nil
        var currentLines: [String] = []

        for line in progressLog.components(separatedBy: "\n") {
            // New entry starts with ### Date (duration)
            if line.hasPrefix("### ") {
                // Save previous entry
                if var entry = currentEntry {
                    entry.content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    entries.append(entry)
                }

                // Parse date and optional duration: "### 2026-01-19 (45 min)"
                let headerContent = String(line.dropFirst(4))
                var date = headerContent
                var duration: String? = nil

                if let durationMatch = headerContent.range(of: "\\(([^)]+)\\)", options: .regularExpression) {
                    duration = String(headerContent[durationMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    date = String(headerContent[..<durationMatch.lowerBound]).trimmingCharacters(in: .whitespaces)
                }

                currentEntry = ProgressEntry(date: date, duration: duration, content: "")
                currentLines = []
            } else if currentEntry != nil {
                currentLines.append(line)
            }
        }

        // Don't forget the last entry
        if var entry = currentEntry {
            entry.content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(entry)
        }

        return entries
    }

    /// Append progress to a task
    func appendProgress(
        projectPath: String,
        subProjectName: String?,
        taskSlug: String,
        content: String,
        duration: String? = nil
    ) throws {
        let taskFolder = taskFolderPath(projectPath: projectPath, subProjectName: subProjectName, taskName: taskSlug)
        let taskFile = taskFolder.appendingPathComponent("TASK.md")

        guard fileManager.fileExists(atPath: taskFile.path) else {
            logger.warning("Task file doesn't exist: \(taskFile.path)")
            return
        }

        var fileContent = try String(contentsOf: taskFile, encoding: .utf8)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timestamp = dateFormatter.string(from: Date())

        var progressEntry = "\n### \(timestamp)"
        if let duration = duration {
            progressEntry += " (\(duration))"
        }
        progressEntry += "\n\(content)\n"

        fileContent += progressEntry
        try fileContent.write(to: taskFile, atomically: true, encoding: .utf8)

        logger.info("Appended progress to task")
    }

    /// Update task status
    func updateTaskStatus(
        at folderPath: URL,
        status: String
    ) throws {
        let taskFile = folderPath.appendingPathComponent("TASK.md")

        guard fileManager.fileExists(atPath: taskFile.path) else {
            return
        }

        var content = try String(contentsOf: taskFile, encoding: .utf8)

        // Update status
        content = content.replacingOccurrences(
            of: "\\*\\*Status:\\*\\* [^\\n]+",
            with: "**Status:** \(status)",
            options: .regularExpression
        )

        try content.write(to: taskFile, atomically: true, encoding: .utf8)
    }

    /// List all tasks for a project (across all sub-projects)
    func listAllTasks(for projectPath: String) -> [TaskContent] {
        let tasksDir = tasksDirectory(for: projectPath)
        var tasks: [TaskContent] = []

        guard fileManager.fileExists(atPath: tasksDir.path) else {
            return []
        }

        do {
            let contents = try fileManager.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: [.isDirectoryKey])

            for item in contents {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                let name = item.lastPathComponent

                // Check if it's a task folder (has number prefix)
                if name.first?.isNumber == true {
                    if let task = readTask(at: item) {
                        tasks.append(task)
                    }
                } else {
                    // It's a sub-project folder - scan for tasks inside
                    let subProjectTasks = listTasksInSubProject(projectPath: projectPath, subProjectName: name)
                    tasks.append(contentsOf: subProjectTasks)
                }
            }
        } catch {
            logger.error("Failed to list tasks: \(error.localizedDescription)")
        }

        return tasks.sorted { $0.folderPath.localizedStandardCompare($1.folderPath) == .orderedAscending }
    }

    /// List tasks within a specific sub-project
    func listTasksInSubProject(projectPath: String, subProjectName: String) -> [TaskContent] {
        let projectDir = projectDirectory(projectPath: projectPath, projectName: subProjectName)
        var tasks: [TaskContent] = []

        guard fileManager.fileExists(atPath: projectDir.path) else {
            return []
        }

        do {
            let contents = try fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: [.isDirectoryKey])

            for item in contents {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                if let task = readTask(at: item) {
                    tasks.append(task)
                }
            }
        } catch {
            logger.error("Failed to list tasks in sub-project: \(error.localizedDescription)")
        }

        return tasks.sorted { $0.folderPath.localizedStandardCompare($1.folderPath) == .orderedAscending }
    }

    /// Move a task to a different sub-project
    func moveTask(from sourcePath: URL, toSubProject subProjectName: String?, projectPath: String) throws {
        guard readTask(at: sourcePath) != nil else {
            return
        }

        // Strip any existing number prefix from folder name (for legacy folders)
        let taskSlug = sourcePath.lastPathComponent.replacingOccurrences(of: "^\\d{3}-", with: "", options: .regularExpression)
        let newFolder = taskFolderPath(projectPath: projectPath, subProjectName: subProjectName, taskName: taskSlug)

        // Create parent if needed
        if let subProject = subProjectName {
            _ = try createProject(projectPath: projectPath, projectName: subProject)
        }

        try fileManager.moveItem(at: sourcePath, to: newFolder)

        // Update sub-project in TASK.md
        let taskFile = newFolder.appendingPathComponent("TASK.md")
        var content = try String(contentsOf: taskFile, encoding: .utf8)

        if let subProject = subProjectName {
            if content.contains("**Sub-project:**") {
                content = content.replacingOccurrences(
                    of: "\\*\\*Sub-project:\\*\\* [^\\n]+",
                    with: "**Sub-project:** \(subProject)",
                    options: .regularExpression
                )
            } else {
                content = content.replacingOccurrences(
                    of: "(\\*\\*Project:\\*\\* [^\\n]+)",
                    with: "$1\n**Sub-project:** \(subProject)",
                    options: .regularExpression
                )
            }
        } else {
            // Remove sub-project line
            content = content.replacingOccurrences(
                of: "\\*\\*Sub-project:\\*\\* [^\\n]+\\n?",
                with: "",
                options: .regularExpression
            )
        }

        try content.write(to: taskFile, atomically: true, encoding: .utf8)
        logger.info("Moved task to \(newFolder.path)")
    }

    // MARK: - Completed Tasks

    /// Get the completed tasks directory for a project
    func completedDirectory(for projectPath: String) -> URL {
        tasksDirectory(for: projectPath)
            .appendingPathComponent("completed")
    }

    /// Move a task folder to the completed directory
    /// Returns the new path if successful
    func moveToCompleted(taskFolderPath: String, projectPath: String) throws -> URL? {
        let sourceFolder = URL(fileURLWithPath: taskFolderPath)

        guard fileManager.fileExists(atPath: sourceFolder.path) else {
            logger.warning("Task folder doesn't exist: \(taskFolderPath)")
            return nil
        }

        // Create completed directory if needed
        let completedDir = completedDirectory(for: projectPath)
        if !fileManager.fileExists(atPath: completedDir.path) {
            try fileManager.createDirectory(at: completedDir, withIntermediateDirectories: true)
        }

        // Move to completed folder (keep the same folder name)
        let destFolder = completedDir.appendingPathComponent(sourceFolder.lastPathComponent)

        // Handle case where folder already exists in completed
        var finalDest = destFolder
        var suffix = 1
        while fileManager.fileExists(atPath: finalDest.path) {
            finalDest = completedDir.appendingPathComponent("\(sourceFolder.lastPathComponent)-\(suffix)")
            suffix += 1
        }

        try fileManager.moveItem(at: sourceFolder, to: finalDest)

        // Update status in TASK.md
        try updateTaskStatus(at: finalDest, status: "completed")

        logger.info("Moved task to completed: \(finalDest.path)")
        return finalDest
    }
}

// MARK: - Data Models

struct TaskContent: Identifiable {
    var id: String { folderPath }
    var folderPath: String
    var title: String?
    var status: String?
    var created: String?
    var client: String?
    var project: String?
    var description: String?
    var progressLog: String?
    var progressEntries: [ProgressEntry] = []

    var isActive: Bool {
        status?.lowercased() == "active"
    }

    var isDone: Bool {
        status?.lowercased() == "done" || status?.lowercased() == "completed"
    }
}

struct ProgressEntry: Identifiable {
    var id: String { date + content.prefix(20) }
    var date: String
    var duration: String?
    var content: String
}
