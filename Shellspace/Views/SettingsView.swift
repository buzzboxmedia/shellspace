import SwiftUI
import SwiftData
import AppKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    // Fetch projects
    @Query(sort: \Project.name) private var allProjects: [Project]

    var mainProjects: [Project] {
        allProjects.filter { $0.category == .main }
    }

    var clientProjects: [Project] {
        allProjects.filter { $0.category == .client }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Projects")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Main Projects Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("MAIN PROJECTS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addProject(category: .main)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ForEach(mainProjects) { project in
                    ProjectRow(project: project)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Client Projects Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CLIENTS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addProject(category: .client)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)

                ForEach(clientProjects) { project in
                    ProjectRow(project: project)
                }
            }

            Spacer()

            Divider()

            // About Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ABOUT")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                HStack {
                    Text("Shellspace")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                    Text("v\(AppVersion.version)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)

                HStack {
                    Text("Build: \(AppVersion.buildHash)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Check for Updates") {
                        checkForUpdates()
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()

            // Footer
            HStack {
                Text("Click + to add a folder from your Mac")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 350, height: 480)
        .background(.ultraThinMaterial)
    }

    func checkForUpdates() {
        // Open GitHub releases page
        if let url = URL(string: "https://github.com/buzzboxmedia/shellspace/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    func addProject(category: ProjectCategory) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to add as a project"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                let name = url.lastPathComponent
                let path = url.path
                let icon = "folder.fill"

                let project = Project(name: name, path: path, icon: icon, category: category)
                modelContext.insert(project)
                ProjectSyncService.shared.exportProjects(from: modelContext)
            }
        }
    }
}

struct ProjectRow: View {
    @Environment(\.modelContext) private var modelContext
    let project: Project
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: project.icon)
                .font(.system(size: 16))
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 15, weight: .medium))

                Text(displayPath(project.path))
                    .font(.system(size: 12))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered {
                Button {
                    editProjectPath()
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(.blue.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Change folder path")

                Button {
                    modelContext.delete(project)
                    ProjectSyncService.shared.exportProjects(from: modelContext)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovered = $0 }
    }

    func editProjectPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select new folder for \(project.name)"
        panel.directoryURL = URL(fileURLWithPath: project.path)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                project.path = url.path
                ProjectSyncService.shared.exportProjects(from: modelContext)
            }
        }
    }

    func displayPath(_ path: String) -> String {
        // Show just the last 2 path components for cleaner look
        let components = path.split(separator: "/")
        if components.count >= 2 {
            let lastTwo = components.suffix(2).joined(separator: "/")
            return ".../" + lastTwo
        }
        return path
    }
}

// Preview
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppState())
    }
}
