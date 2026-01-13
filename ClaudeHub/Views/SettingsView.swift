import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Projects")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addProject(isClient: false)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ForEach(appState.mainProjects) { project in
                    ProjectRow(project: project, isClient: false)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Client Projects Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CLIENTS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addProject(isClient: true)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)

                ForEach(appState.clientProjects) { project in
                    ProjectRow(project: project, isClient: true)
                }
            }

            Spacer()

            Divider()

            // Footer
            HStack {
                Text("Click + to add a folder from your Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 350, height: 450)
        .background(.ultraThinMaterial)
    }

    func addProject(isClient: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to add as a project"

        if panel.runModal() == .OK, let url = panel.url {
            let name = url.lastPathComponent
            let path = url.path
            let icon = isClient ? "folder.fill" : "folder.fill"

            let project = Project(name: name, path: path, icon: icon)

            if isClient {
                appState.addClientProject(project)
            } else {
                appState.addMainProject(project)
            }
        }
    }
}

struct ProjectRow: View {
    @EnvironmentObject var appState: AppState
    let project: Project
    let isClient: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            Image(systemName: project.icon)
                .font(.system(size: 12))
                .frame(width: 20)
                .foregroundStyle(.secondary)

            Text(project.name)
                .font(.system(size: 13))

            Spacer()

            Text(shortenPath(project.path))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if isHovered {
                Button {
                    if isClient {
                        appState.removeClientProject(project)
                    } else {
                        appState.removeMainProject(project)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(4)
        .onHover { isHovered = $0 }
    }

    func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
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
