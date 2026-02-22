import Foundation
import SwiftData
import os.log

private let syncLogger = Logger(subsystem: "com.buzzbox.shellspace", category: "ProjectSync")

/// JSON structure for syncing projects and preferences via Dropbox
struct ProjectsSyncFile: Codable {
    var version: Int = 1
    var exportedAt: Date
    var dashboardOrder: [String]
    var railOrder: [String]
    var projects: [SyncedProject]
}

/// Codable project for sync (subset of Project model)
struct SyncedProject: Codable {
    var id: UUID
    var name: String
    var path: String
    var icon: String
    var category: String
}

/// Service for syncing projects.json to/from Dropbox
class ProjectSyncService {
    static let shared = ProjectSyncService()

    private init() {}

    /// Path to projects.json in Dropbox
    private var syncFileURL: URL? {
        let newPath = NSString("~/Library/CloudStorage/Dropbox/Shellspace/projects.json").expandingTildeInPath
        let legacyPath = NSString("~/Dropbox/Shellspace/projects.json").expandingTildeInPath

        // Check if the parent directory exists
        let newDir = NSString("~/Library/CloudStorage/Dropbox/Shellspace").expandingTildeInPath
        let legacyDir = NSString("~/Dropbox/Shellspace").expandingTildeInPath

        if FileManager.default.fileExists(atPath: newDir) {
            return URL(fileURLWithPath: newPath)
        } else if FileManager.default.fileExists(atPath: legacyDir) {
            return URL(fileURLWithPath: legacyPath)
        }
        return nil
    }

    // MARK: - Export

    /// Export all projects and preferences to projects.json
    func exportProjects(from modelContext: ModelContext) {
        guard let fileURL = syncFileURL else {
            syncLogger.info("No Dropbox found, skipping project export")
            return
        }

        let descriptor = FetchDescriptor<Project>()
        guard let projects = try? modelContext.fetch(descriptor) else {
            syncLogger.error("Failed to fetch projects for export")
            return
        }

        let syncedProjects = projects.map { project in
            SyncedProject(
                id: project.id,
                name: project.name,
                path: project.path,
                icon: project.icon,
                category: project.category.rawValue
            )
        }

        // Read current order preferences from UserDefaults
        let dashboardOrder: [String] = {
            guard let data = UserDefaults.standard.data(forKey: "dashboardOrder"),
                  let order = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return order
        }()

        let railOrder: [String] = {
            guard let data = UserDefaults.standard.data(forKey: "railOrder"),
                  let order = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return order
        }()

        let syncFile = ProjectsSyncFile(
            exportedAt: Date(),
            dashboardOrder: dashboardOrder,
            railOrder: railOrder,
            projects: syncedProjects
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(syncFile)
            try data.write(to: fileURL, options: .atomic)
            syncLogger.info("Exported \(projects.count) projects to projects.json")
        } catch {
            syncLogger.error("Failed to export projects: \(error.localizedDescription)")
        }
    }

    // MARK: - Import

    /// Import projects and preferences from projects.json (full bidirectional sync)
    func importProjects(into modelContext: ModelContext) {
        guard let fileURL = syncFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            syncLogger.info("No projects.json found, skipping import")
            return
        }

        let syncFile: ProjectsSyncFile
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            syncFile = try decoder.decode(ProjectsSyncFile.self, from: data)
        } catch {
            syncLogger.error("Failed to read projects.json: \(error.localizedDescription)")
            return
        }

        // Fetch existing projects
        let descriptor = FetchDescriptor<Project>()
        let existingProjects = (try? modelContext.fetch(descriptor)) ?? []
        let existingByPath = Dictionary(uniqueKeysWithValues: existingProjects.map { ($0.path, $0) })

        // Track which paths are in the sync file
        let syncedPaths = Set(syncFile.projects.map { $0.path })

        var added = 0
        var updated = 0
        var removed = 0

        // Add or update projects from sync file
        for synced in syncFile.projects {
            // Skip projects whose folder doesn't exist on this machine
            guard FileManager.default.fileExists(atPath: synced.path) else {
                syncLogger.info("Skipping \(synced.name) - path not found on this machine")
                continue
            }

            if let existing = existingByPath[synced.path] {
                // Update display fields from sync file
                existing.name = synced.name
                existing.icon = synced.icon
                existing.category = ProjectCategory(rawValue: synced.category) ?? .main
                updated += 1
            } else {
                // Add new project
                let project = Project(
                    name: synced.name,
                    path: synced.path,
                    icon: synced.icon,
                    category: ProjectCategory(rawValue: synced.category) ?? .main
                )
                // Preserve the original UUID so it stays consistent across machines
                project.id = synced.id
                modelContext.insert(project)
                added += 1
            }
        }

        // Remove projects that are in the DB but were removed from the sync file
        // (only if the path exists on disk - meaning it was intentionally removed, not a different machine)
        for existing in existingProjects {
            if !syncedPaths.contains(existing.path) &&
               FileManager.default.fileExists(atPath: existing.path) {
                syncLogger.info("Removing \(existing.name) - deleted on another machine")
                modelContext.delete(existing)
                removed += 1
            }
        }

        // Restore order preferences
        if !syncFile.dashboardOrder.isEmpty {
            if let data = try? JSONEncoder().encode(syncFile.dashboardOrder) {
                UserDefaults.standard.set(data, forKey: "dashboardOrder")
            }
        }
        if !syncFile.railOrder.isEmpty {
            if let data = try? JSONEncoder().encode(syncFile.railOrder) {
                UserDefaults.standard.set(data, forKey: "railOrder")
            }
        }

        if added > 0 || updated > 0 || removed > 0 {
            try? modelContext.save()
        }

        syncLogger.info("Project import: \(added) added, \(updated) updated, \(removed) removed from projects.json")
    }
}
