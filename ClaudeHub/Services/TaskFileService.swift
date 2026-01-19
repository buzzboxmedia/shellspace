import Foundation
import os.log

private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "TaskFileService")

/// Service for managing task markdown files in client folders
/// Files are stored at: ~/Dropbox/Buzzbox/clients/{client}/tasks/{task-slug}.md
class TaskFileService {
    static let shared = TaskFileService()

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

    /// Get the task file path for a specific task
    func taskFilePath(clientName: String, taskName: String) -> URL {
        let slug = slugify(taskName)
        return tasksDirectory(for: clientName)
            .appendingPathComponent("\(slug).md")
    }

    /// Convert a task name to a filesystem-safe slug
    func slugify(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Task File Operations

    /// Create a new task file
    func createTaskFile(
        clientName: String,
        taskName: String,
        description: String?,
        priority: String = "medium"
    ) throws -> URL {
        let tasksDir = tasksDirectory(for: clientName)

        // Create tasks directory if needed
        if !fileManager.fileExists(atPath: tasksDir.path) {
            try fileManager.createDirectory(at: tasksDir, withIntermediateDirectories: true)
            logger.info("Created tasks directory for \(clientName)")
        }

        let filePath = taskFilePath(clientName: clientName, taskName: taskName)

        // Don't overwrite existing file
        guard !fileManager.fileExists(atPath: filePath.path) else {
            logger.info("Task file already exists: \(filePath.path)")
            return filePath
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let content = """
        # \(taskName)

        **Status:** active
        **Priority:** \(priority)
        **Created:** \(today)

        ## Description
        \(description ?? "No description provided.")

        ## Session Log

        """

        try content.write(to: filePath, atomically: true, encoding: .utf8)
        logger.info("Created task file: \(filePath.path)")

        return filePath
    }

    /// Read a task file and parse its contents
    func readTaskFile(clientName: String, taskName: String) -> TaskFileContent? {
        let filePath = taskFilePath(clientName: clientName, taskName: taskName)

        guard fileManager.fileExists(atPath: filePath.path) else {
            return nil
        }

        do {
            let content = try String(contentsOf: filePath, encoding: .utf8)
            return parseTaskFile(content: content)
        } catch {
            logger.error("Failed to read task file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse task file content into structured data
    func parseTaskFile(content: String) -> TaskFileContent {
        var result = TaskFileContent()

        let lines = content.components(separatedBy: "\n")
        var currentSection: String? = nil
        var sessionLogLines: [String] = []
        var descriptionLines: [String] = []

        for line in lines {
            // Parse title
            if line.hasPrefix("# ") && result.title == nil {
                result.title = String(line.dropFirst(2))
                continue
            }

            // Parse metadata
            if line.hasPrefix("**Status:**") {
                result.status = line.replacingOccurrences(of: "**Status:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("**Priority:**") {
                result.priority = line.replacingOccurrences(of: "**Priority:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("**Created:**") {
                result.created = line.replacingOccurrences(of: "**Created:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("**Completed:**") {
                result.completed = line.replacingOccurrences(of: "**Completed:**", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }

            // Track sections
            if line.hasPrefix("## Description") {
                currentSection = "description"
                continue
            }
            if line.hasPrefix("## Session Log") {
                currentSection = "sessionLog"
                continue
            }

            // Collect section content
            if currentSection == "description" && !line.hasPrefix("## ") {
                descriptionLines.append(line)
            }
            if currentSection == "sessionLog" {
                sessionLogLines.append(line)
            }
        }

        result.description = descriptionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        result.sessionLog = sessionLogLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse session entries from log
        result.sessions = parseSessionEntries(from: result.sessionLog ?? "")

        return result
    }

    /// Parse session entries from the session log section
    func parseSessionEntries(from sessionLog: String) -> [SessionEntry] {
        var entries: [SessionEntry] = []
        var currentEntry: SessionEntry? = nil
        var currentContent: [String] = []

        for line in sessionLog.components(separatedBy: "\n") {
            // New session entry starts with ### Date
            if line.hasPrefix("### ") {
                // Save previous entry
                if var entry = currentEntry {
                    entry.content = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    entries.append(entry)
                }

                // Start new entry
                let dateString = String(line.dropFirst(4))
                currentEntry = SessionEntry(date: dateString, content: "")
                currentContent = []
            } else if currentEntry != nil {
                currentContent.append(line)
            }
        }

        // Don't forget the last entry
        if var entry = currentEntry {
            entry.content = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(entry)
        }

        return entries
    }

    /// Append a session summary to a task file
    func appendSessionSummary(
        clientName: String,
        taskName: String,
        summary: String,
        nextSteps: [String]? = nil
    ) throws {
        let filePath = taskFilePath(clientName: clientName, taskName: taskName)

        // Create file if it doesn't exist
        if !fileManager.fileExists(atPath: filePath.path) {
            logger.warning("Task file doesn't exist, creating it first")
            _ = try createTaskFile(clientName: clientName, taskName: taskName, description: nil)
        }

        var content = try String(contentsOf: filePath, encoding: .utf8)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d, yyyy"
        let today = dateFormatter.string(from: Date())

        var sessionEntry = "\n### \(today)\n\(summary)\n"

        if let nextSteps = nextSteps, !nextSteps.isEmpty {
            sessionEntry += "\n**Next steps:**\n"
            for step in nextSteps {
                sessionEntry += "- \(step)\n"
            }
        }

        content += sessionEntry
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        logger.info("Appended session summary to \(filePath.path)")
    }

    /// Update task status in the file
    func updateTaskStatus(
        clientName: String,
        taskName: String,
        status: String,
        completedDate: Date? = nil
    ) throws {
        let filePath = taskFilePath(clientName: clientName, taskName: taskName)

        guard fileManager.fileExists(atPath: filePath.path) else {
            logger.warning("Task file doesn't exist: \(filePath.path)")
            return
        }

        var content = try String(contentsOf: filePath, encoding: .utf8)

        // Update status line
        content = content.replacingOccurrences(
            of: "\\*\\*Status:\\*\\* \\w+",
            with: "**Status:** \(status)",
            options: .regularExpression
        )

        // Add completed date if completing
        if status == "done", let date = completedDate {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let dateString = dateFormatter.string(from: date)

            // Add completed line after created line if not already present
            if !content.contains("**Completed:**") {
                content = content.replacingOccurrences(
                    of: "(\\*\\*Created:\\*\\* [^\\n]+)",
                    with: "$1\n**Completed:** \(dateString)",
                    options: .regularExpression
                )
            }
        }

        try content.write(to: filePath, atomically: true, encoding: .utf8)
        logger.info("Updated task status to \(status)")
    }

    /// List all task files for a client
    func listTasks(for clientName: String) -> [TaskFileContent] {
        let tasksDir = tasksDirectory(for: clientName)

        guard fileManager.fileExists(atPath: tasksDir.path) else {
            return []
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)
            let markdownFiles = files.filter { $0.pathExtension == "md" }

            return markdownFiles.compactMap { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                    return nil
                }
                var task = parseTaskFile(content: content)
                task.filePath = url.path
                return task
            }
        } catch {
            logger.error("Failed to list tasks: \(error.localizedDescription)")
            return []
        }
    }

    /// Get the latest session summary from a task file
    func getLatestSessionSummary(clientName: String, taskName: String) -> SessionEntry? {
        guard let taskContent = readTaskFile(clientName: clientName, taskName: taskName) else {
            return nil
        }
        return taskContent.sessions.last
    }
}

// MARK: - Data Models

struct TaskFileContent {
    var title: String?
    var status: String?
    var priority: String?
    var created: String?
    var completed: String?
    var description: String?
    var sessionLog: String?
    var sessions: [SessionEntry] = []
    var filePath: String?
}

struct SessionEntry {
    var date: String
    var content: String
}
