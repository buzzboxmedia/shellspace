import Foundation
import os.log

private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "TaskFolderService")

/// Service for managing task folders with TASK.md files
/// Structure:
///   ~/Dropbox/Buzzbox/clients/{client}/tasks/
///   ├── project-name/                    ← Project folder (no number)
///   │   ├── 001-task-name/
///   │   │   └── TASK.md
///   │   └── 002-another-task/
///   │       └── TASK.md
///   └── 001-standalone-task/             ← Task without project
///       └── TASK.md
class TaskFolderService {
    static let shared = TaskFolderService()

    private let fileManager = FileManager.default
    private let clientsBasePath: String

    private init() {
        clientsBasePath = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/clients").expandingTildeInPath
    }

    // MARK: - Path Helpers

    /// Get the tasks directory for a client
    func tasksDirectory(for clientName: String) -> URL {
        URL(fileURLWithPath: clientsBasePath)
            .appendingPathComponent(clientName)
            .appendingPathComponent("tasks")
    }

    /// Get the project directory within a client's tasks
    func projectDirectory(clientName: String, projectName: String) -> URL {
        tasksDirectory(for: clientName)
            .appendingPathComponent(slugify(projectName))
    }

    /// Get the task folder path (includes number prefix)
    func taskFolderPath(clientName: String, projectName: String?, taskNumber: Int, taskName: String) -> URL {
        let folderName = String(format: "%03d-%@", taskNumber, slugify(taskName))

        if let project = projectName {
            return projectDirectory(clientName: clientName, projectName: project)
                .appendingPathComponent(folderName)
        } else {
            return tasksDirectory(for: clientName)
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

    /// Create a project folder
    func createProject(clientName: String, projectName: String) throws -> URL {
        let projectDir = projectDirectory(clientName: clientName, projectName: projectName)

        if !fileManager.fileExists(atPath: projectDir.path) {
            try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
            logger.info("Created project folder: \(projectDir.path)")
        }

        return projectDir
    }

    /// List all projects for a client
    func listProjects(for clientName: String) -> [String] {
        let tasksDir = tasksDirectory(for: clientName)

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

    /// Get the next task number for a project (or root level)
    func nextTaskNumber(clientName: String, projectName: String?) -> Int {
        let searchDir: URL
        if let project = projectName {
            searchDir = projectDirectory(clientName: clientName, projectName: project)
        } else {
            searchDir = tasksDirectory(for: clientName)
        }

        guard fileManager.fileExists(atPath: searchDir.path) else {
            return 1
        }

        do {
            let contents = try fileManager.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil)
            let taskNumbers = contents.compactMap { url -> Int? in
                let name = url.lastPathComponent
                // Extract number from "001-task-name" format
                if let match = name.range(of: "^\\d{3}", options: .regularExpression) {
                    return Int(name[match])
                }
                return nil
            }
            return (taskNumbers.max() ?? 0) + 1
        } catch {
            return 1
        }
    }

    /// Create a new task folder with TASK.md
    func createTask(
        clientName: String,
        projectName: String?,
        taskName: String,
        description: String?
    ) throws -> URL {
        // Create parent directories if needed
        let tasksDir = tasksDirectory(for: clientName)
        if !fileManager.fileExists(atPath: tasksDir.path) {
            try fileManager.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        }

        if let project = projectName {
            _ = try createProject(clientName: clientName, projectName: project)
        }

        // Get next task number
        let taskNumber = nextTaskNumber(clientName: clientName, projectName: projectName)
        let taskFolder = taskFolderPath(clientName: clientName, projectName: projectName, taskNumber: taskNumber, taskName: taskName)

        // Create task folder
        try fileManager.createDirectory(at: taskFolder, withIntermediateDirectories: true)

        // Create TASK.md
        let taskFile = taskFolder.appendingPathComponent("TASK.md")
        let content = generateTaskContent(
            taskName: taskName,
            clientName: clientName,
            projectName: projectName,
            description: description
        )

        try content.write(to: taskFile, atomically: true, encoding: .utf8)
        logger.info("Created task folder: \(taskFolder.path)")

        return taskFolder
    }

    /// Generate the TASK.md content
    func generateTaskContent(
        taskName: String,
        clientName: String,
        projectName: String?,
        description: String?
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        return """
        # \(taskName)

        **Status:** active
        **Created:** \(today)
        **Client:** \(clientName)
        \(projectName != nil ? "**Project:** \(projectName!)\n" : "")
        ## Description
        \(description ?? "No description provided.")

        ## Billing
        **Estimated:** _
        **Actual:** _
        **Billable:** Yes

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
            if line.hasPrefix("**Estimated:**") {
                task.estimatedHours = line.replacingOccurrences(of: "**Estimated:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("**Actual:**") {
                task.actualHours = line.replacingOccurrences(of: "**Actual:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("**Billable:**") {
                task.billable = line.replacingOccurrences(of: "**Billable:**", with: "").trimmingCharacters(in: .whitespaces).lowercased() == "yes"
                continue
            }

            // Track sections
            if line.hasPrefix("## Description") {
                currentSection = "description"
                continue
            }
            if line.hasPrefix("## Billing") {
                currentSection = "billing"
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

        // Extract task number from folder name
        let folderName = folderPath.lastPathComponent
        if let match = folderName.range(of: "^\\d{3}", options: .regularExpression) {
            task.taskNumber = Int(folderName[match])
        }

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
        clientName: String,
        projectName: String?,
        taskNumber: Int,
        taskSlug: String,
        content: String,
        duration: String? = nil
    ) throws {
        let taskFolder = taskFolderPath(clientName: clientName, projectName: projectName, taskNumber: taskNumber, taskName: taskSlug)
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
        status: String,
        estimatedHours: String? = nil,
        actualHours: String? = nil
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

        // Update hours if provided
        if let est = estimatedHours {
            content = content.replacingOccurrences(
                of: "\\*\\*Estimated:\\*\\* [^\\n]+",
                with: "**Estimated:** \(est)",
                options: .regularExpression
            )
        }

        if let actual = actualHours {
            content = content.replacingOccurrences(
                of: "\\*\\*Actual:\\*\\* [^\\n]+",
                with: "**Actual:** \(actual)",
                options: .regularExpression
            )
        }

        try content.write(to: taskFile, atomically: true, encoding: .utf8)
    }

    /// List all tasks for a client (across all projects)
    func listAllTasks(for clientName: String) -> [TaskContent] {
        let tasksDir = tasksDirectory(for: clientName)
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
                    // It's a project folder - scan for tasks inside
                    let projectTasks = listTasksInProject(clientName: clientName, projectName: name)
                    tasks.append(contentsOf: projectTasks)
                }
            }
        } catch {
            logger.error("Failed to list tasks: \(error.localizedDescription)")
        }

        return tasks.sorted { ($0.taskNumber ?? 0) < ($1.taskNumber ?? 0) }
    }

    /// List tasks within a specific project
    func listTasksInProject(clientName: String, projectName: String) -> [TaskContent] {
        let projectDir = projectDirectory(clientName: clientName, projectName: projectName)
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
            logger.error("Failed to list tasks in project: \(error.localizedDescription)")
        }

        return tasks.sorted { ($0.taskNumber ?? 0) < ($1.taskNumber ?? 0) }
    }

    /// Move a task to a different project
    func moveTask(from sourcePath: URL, toProject projectName: String?, clientName: String) throws {
        guard readTask(at: sourcePath) != nil else {
            return
        }

        let taskSlug = sourcePath.lastPathComponent.replacingOccurrences(of: "^\\d{3}-", with: "", options: .regularExpression)
        let newNumber = nextTaskNumber(clientName: clientName, projectName: projectName)
        let newFolder = taskFolderPath(clientName: clientName, projectName: projectName, taskNumber: newNumber, taskName: taskSlug)

        // Create parent if needed
        if let project = projectName {
            _ = try createProject(clientName: clientName, projectName: project)
        }

        try fileManager.moveItem(at: sourcePath, to: newFolder)

        // Update project in TASK.md
        let taskFile = newFolder.appendingPathComponent("TASK.md")
        var content = try String(contentsOf: taskFile, encoding: .utf8)

        if let project = projectName {
            if content.contains("**Project:**") {
                content = content.replacingOccurrences(
                    of: "\\*\\*Project:\\*\\* [^\\n]+",
                    with: "**Project:** \(project)",
                    options: .regularExpression
                )
            } else {
                content = content.replacingOccurrences(
                    of: "(\\*\\*Client:\\*\\* [^\\n]+)",
                    with: "$1\n**Project:** \(project)",
                    options: .regularExpression
                )
            }
        } else {
            // Remove project line
            content = content.replacingOccurrences(
                of: "\\*\\*Project:\\*\\* [^\\n]+\\n?",
                with: "",
                options: .regularExpression
            )
        }

        try content.write(to: taskFile, atomically: true, encoding: .utf8)
        logger.info("Moved task to \(newFolder.path)")
    }
}

// MARK: - Data Models

struct TaskContent: Identifiable {
    var id: String { folderPath }
    var folderPath: String
    var taskNumber: Int?
    var title: String?
    var status: String?
    var created: String?
    var client: String?
    var project: String?
    var description: String?
    var estimatedHours: String?
    var actualHours: String?
    var billable: Bool = true
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
