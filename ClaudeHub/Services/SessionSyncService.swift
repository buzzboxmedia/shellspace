import Foundation
import SwiftData
import os.log

private let syncLogger = Logger(subsystem: "com.buzzbox.claudehub", category: "SessionSync")

/// Codable representation of Project for Dropbox sync
struct ProjectMetadata: Codable {
    let id: UUID
    var name: String
    var path: String
    var icon: String
    var category: String  // "main" or "client"
    var usesExternalTerminal: Bool
    var lastActiveSessionId: UUID?
}

extension Project {
    func toMetadata() -> ProjectMetadata {
        return ProjectMetadata(
            id: id,
            name: name,
            path: path,
            icon: icon,
            category: category == .main ? "main" : "client",
            usesExternalTerminal: usesExternalTerminal,
            lastActiveSessionId: lastActiveSessionId
        )
    }

    func updateFromMetadata(_ metadata: ProjectMetadata) {
        self.name = metadata.name
        self.path = metadata.path
        self.icon = metadata.icon
        self.category = metadata.category == "main" ? .main : .client
        self.usesExternalTerminal = metadata.usesExternalTerminal
        self.lastActiveSessionId = metadata.lastActiveSessionId
    }
}

/// Service for syncing sessions and projects to/from Dropbox
class SessionSyncService {
    static let shared = SessionSyncService()

    /// Feature flag - sync is disabled by default for safety
    var isEnabled: Bool = false

    /// Centralized sessions directory in Dropbox (syncs across machines)
    static var centralSessionsDir: URL {
        let path = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/ClaudeHub/sessions").expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    /// Centralized projects directory in Dropbox
    static var centralProjectsDir: URL {
        let path = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/ClaudeHub/projects").expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    private init() {}

    // MARK: - Export Projects

    /// Export a single project to Dropbox
    func exportProject(_ project: Project) {
        guard isEnabled else { return }

        let projectsDir = Self.centralProjectsDir

        do {
            try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        } catch {
            syncLogger.error("Failed to create projects directory: \(error.localizedDescription)")
            return
        }

        let projectPath = projectsDir.appendingPathComponent("\(project.id.uuidString).json")

        do {
            let metadata = project.toMetadata()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: projectPath, options: .atomic)
            syncLogger.info("Exported project '\(project.name)' to Dropbox")
        } catch {
            syncLogger.error("Failed to export project '\(project.name)': \(error.localizedDescription)")
        }
    }

    /// Export all projects to Dropbox
    func exportAllProjects(modelContext: ModelContext) {
        guard isEnabled else { return }

        let descriptor = FetchDescriptor<Project>()
        guard let projects = try? modelContext.fetch(descriptor) else {
            syncLogger.error("Failed to fetch projects for export")
            return
        }

        syncLogger.info("Exporting \(projects.count) projects to Dropbox")
        for project in projects {
            exportProject(project)
        }
    }

    // MARK: - Export Sessions

    /// Export a single session to Dropbox
    func exportSession(_ session: Session) {
        guard isEnabled else { return }

        let sessionsDir = Self.centralSessionsDir

        do {
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        } catch {
            syncLogger.error("Failed to create sessions directory: \(error.localizedDescription)")
            return
        }

        let sessionPath = sessionsDir.appendingPathComponent("\(session.id.uuidString).json")

        do {
            let metadata = session.toMetadata()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: sessionPath, options: .atomic)
            syncLogger.info("Exported session '\(session.name)' to Dropbox")
        } catch {
            syncLogger.error("Failed to export session '\(session.name)': \(error.localizedDescription)")
        }
    }

    /// Export all sessions to Dropbox
    func exportAllSessions(modelContext: ModelContext) {
        guard isEnabled else { return }

        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? modelContext.fetch(descriptor) else {
            syncLogger.error("Failed to fetch sessions for export")
            return
        }

        syncLogger.info("Exporting \(sessions.count) sessions to Dropbox")
        for session in sessions {
            exportSession(session)
        }
    }

    // MARK: - Import All (Projects first, then Sessions)

    /// Import all projects and sessions from Dropbox (merge with local)
    func importAllSessions(modelContext: ModelContext) {
        guard isEnabled else {
            syncLogger.debug("Sync disabled, skipping import")
            return
        }

        // Import projects FIRST so sessions can link to them
        importAllProjects(modelContext: modelContext)

        // Then import sessions
        importSessions(modelContext: modelContext)
    }

    /// Import all projects from Dropbox
    private func importAllProjects(modelContext: ModelContext) {
        let projectsDir = Self.centralProjectsDir

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            syncLogger.info("Projects directory doesn't exist yet: \(projectsDir.path)")
            return
        }

        guard let files = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            syncLogger.error("Failed to read projects directory")
            return
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        syncLogger.info("Found \(jsonFiles.count) project files to import")

        var imported = 0
        var updated = 0

        for file in jsonFiles {
            do {
                let data = try Data(contentsOf: file)
                let decoder = JSONDecoder()
                let metadata = try decoder.decode(ProjectMetadata.self, from: data)

                // Check if project exists locally
                let descriptor = FetchDescriptor<Project>(
                    predicate: #Predicate { $0.id == metadata.id }
                )
                let existingProjects = try modelContext.fetch(descriptor)

                if let existing = existingProjects.first {
                    // Update existing project
                    existing.updateFromMetadata(metadata)
                    updated += 1
                    syncLogger.debug("Updated project '\(metadata.name)' from Dropbox")
                } else {
                    // Create new project
                    let project = Project(
                        name: metadata.name,
                        path: metadata.path,
                        icon: metadata.icon,
                        category: metadata.category == "main" ? .main : .client,
                        usesExternalTerminal: metadata.usesExternalTerminal
                    )
                    project.id = metadata.id
                    project.lastActiveSessionId = metadata.lastActiveSessionId
                    modelContext.insert(project)
                    imported += 1
                    syncLogger.info("Imported new project '\(metadata.name)' from Dropbox")
                }
            } catch {
                syncLogger.error("Failed to import project from \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        syncLogger.info("Project import complete: \(imported) imported, \(updated) updated")
    }

    /// Import sessions from Dropbox
    private func importSessions(modelContext: ModelContext) {
        let sessionsDir = Self.centralSessionsDir

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            syncLogger.info("Sessions directory doesn't exist yet: \(sessionsDir.path)")
            return
        }

        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            syncLogger.error("Failed to read sessions directory")
            return
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        syncLogger.info("Found \(jsonFiles.count) session files to import")

        var imported = 0
        var updated = 0
        var skipped = 0

        for file in jsonFiles {
            let result = importSession(from: file, modelContext: modelContext)
            switch result {
            case .imported:
                imported += 1
            case .updated:
                updated += 1
            case .skipped:
                skipped += 1
            case .failed:
                break
            }
        }

        syncLogger.info("Session import complete: \(imported) imported, \(updated) updated, \(skipped) skipped")
    }

    /// Result of importing a session
    private enum ImportResult {
        case imported
        case updated
        case skipped
        case failed
    }

    /// Import a single session from JSON file
    @discardableResult
    private func importSession(from file: URL, modelContext: ModelContext) -> ImportResult {
        do {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(SessionMetadata.self, from: data)

            // Check if session already exists locally
            let descriptor = FetchDescriptor<Session>(
                predicate: #Predicate { $0.id == metadata.id }
            )
            let existingSessions = try modelContext.fetch(descriptor)
            let existingSession = existingSessions.first

            if let existing = existingSession {
                return mergeSession(local: existing, remote: metadata, modelContext: modelContext)
            } else {
                let newSession = createSessionFromMetadata(metadata, modelContext: modelContext)
                modelContext.insert(newSession)
                syncLogger.info("Imported new session '\(newSession.name)' from Dropbox")
                return .imported
            }
        } catch {
            syncLogger.error("Failed to import session from \(file.lastPathComponent): \(error.localizedDescription)")
            return .failed
        }
    }

    /// Merge remote session with local (last-write-wins)
    private func mergeSession(local: Session, remote: SessionMetadata, modelContext: ModelContext) -> ImportResult {
        if remote.lastAccessedAt > local.lastAccessedAt {
            local.updateFromMetadata(remote)
            resolveRelationships(for: local, projectId: remote.projectId, taskGroupId: remote.taskGroupId, modelContext: modelContext)
            syncLogger.info("Updated session '\(local.name)' from remote")
            return .updated
        } else {
            syncLogger.debug("Skipped session '\(local.name)' (local newer)")
            return .skipped
        }
    }

    /// Create a new Session from metadata
    private func createSessionFromMetadata(_ metadata: SessionMetadata, modelContext: ModelContext) -> Session {
        let session = Session(
            name: metadata.name,
            projectPath: metadata.projectPath,
            createdAt: metadata.createdAt,
            userNamed: metadata.userNamed,
            activeProjectName: metadata.activeProjectName,
            parkerBriefing: metadata.parkerBriefing
        )

        session.id = metadata.id
        session.sessionDescription = metadata.sessionDescription
        session.lastAccessedAt = metadata.lastAccessedAt
        session.claudeSessionId = metadata.claudeSessionId
        session.lastSessionSummary = metadata.lastSessionSummary
        session.logFilePath = metadata.logFilePath
        session.lastLogSavedAt = metadata.lastLogSavedAt
        session.lastProgressSavedAt = metadata.lastProgressSavedAt
        session.taskFolderPath = metadata.taskFolderPath
        session.isCompleted = metadata.isCompleted
        session.completedAt = metadata.completedAt
        session.isWaitingForInput = metadata.isWaitingForInput
        session.hasBeenLaunched = metadata.hasBeenLaunched

        // Resolve relationships (projects should exist now since we imported them first)
        resolveRelationships(for: session, projectId: metadata.projectId, taskGroupId: metadata.taskGroupId, modelContext: modelContext)

        return session
    }

    /// Resolve Project and ProjectGroup relationships by UUID
    private func resolveRelationships(for session: Session, projectId: UUID?, taskGroupId: UUID?, modelContext: ModelContext) {
        if let projectId = projectId {
            let projectDescriptor = FetchDescriptor<Project>(
                predicate: #Predicate { $0.id == projectId }
            )
            if let projects = try? modelContext.fetch(projectDescriptor),
               let project = projects.first {
                session.project = project
                syncLogger.debug("Resolved project relationship for session '\(session.name)' -> '\(project.name)'")
            } else {
                syncLogger.warning("Could not resolve project with ID \(projectId) for session '\(session.name)'")
            }
        }

        if let taskGroupId = taskGroupId {
            let groupDescriptor = FetchDescriptor<ProjectGroup>(
                predicate: #Predicate { $0.id == taskGroupId }
            )
            if let groups = try? modelContext.fetch(groupDescriptor),
               let group = groups.first {
                session.taskGroup = group
            }
        }
    }
}
