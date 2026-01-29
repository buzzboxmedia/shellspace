import SwiftUI
import SwiftData

/// A Slack-style navigation rail with project/client icons
struct NavigationRailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    @Query private var allSessions: [Session]

    @State private var showAddProject = false

    // Dropbox path (check both locations)
    private var dropboxPath: String {
        let newPath = NSString("~/Library/CloudStorage/Dropbox").expandingTildeInPath
        let legacyPath = NSString("~/Dropbox").expandingTildeInPath
        return FileManager.default.fileExists(atPath: newPath) ? newPath : legacyPath
    }

    // Default projects - always show if folder exists
    private var defaultMainProjects: [(name: String, path: String, icon: String)] {
        [
            ("Miller", "\(dropboxPath)/Miller", "person.fill"),
            ("Talkspresso", "\(dropboxPath)/Talkspresso", "cup.and.saucer.fill"),
            ("Buzzbox", "\(dropboxPath)/Buzzbox", "shippingbox.fill")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var defaultClientProjects: [(name: String, path: String, icon: String)] {
        let clientsPath = "\(dropboxPath)/Buzzbox/Clients"
        return [
            ("AAGL", "\(clientsPath)/AAGL", "cross.case.fill"),
            ("AFL", "\(clientsPath)/AFL", "building.columns.fill"),
            ("INFAB", "\(clientsPath)/INFAB", "shield.fill"),
            ("TDS", "\(clientsPath)/TDS", "eye.fill")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var developmentProjects: [(name: String, path: String, icon: String)] {
        let claudeHubPath = "\(dropboxPath)/ClaudeHub"
        if FileManager.default.fileExists(atPath: claudeHubPath) {
            return [("Claude Hub", claudeHubPath, "terminal.fill")]
        }
        return []
    }

    // Items that need attention (waiting or working)
    private var needsAttentionItems: [(name: String, path: String, icon: String)] {
        let allItems = defaultMainProjects + defaultClientProjects + developmentProjects
        return allItems.filter { item in
            let sessions = allSessions.filter { $0.projectPath == item.path }
            return sessions.contains { appState.waitingSessions.contains($0.id) || appState.workingSessions.contains($0.id) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Needs Attention section (dynamic)
            if !needsAttentionItems.isEmpty {
                VStack(spacing: 8) {
                    ForEach(needsAttentionItems, id: \.path) { item in
                        RailItem(
                            name: item.name,
                            path: item.path,
                            icon: item.icon,
                            sessions: allSessions.filter { $0.projectPath == item.path }
                        )
                    }
                }
                .padding(.vertical, 12)

                RailDivider()
            }

            ScrollView {
                VStack(spacing: 0) {
                    // Projects section
                    if !defaultMainProjects.isEmpty {
                        RailSection(
                            items: defaultMainProjects,
                            sessions: allSessions
                        )
                        RailDivider()
                    }

                    // Clients section
                    if !defaultClientProjects.isEmpty {
                        RailSection(
                            items: defaultClientProjects,
                            sessions: allSessions
                        )
                        RailDivider()
                    }

                    // Development section
                    if !developmentProjects.isEmpty {
                        RailSection(
                            items: developmentProjects,
                            sessions: allSessions
                        )
                    }
                }
            }

            Spacer()

            RailDivider()

            // Add button
            Button {
                showAddProject = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Add Project")
            .padding(.vertical, 12)
            .sheet(isPresented: $showAddProject) {
                AddProjectSheet()
            }
        }
        .frame(width: 52)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Rail Section

struct RailSection: View {
    @EnvironmentObject var appState: AppState
    let items: [(name: String, path: String, icon: String)]
    let sessions: [Session]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items, id: \.path) { item in
                RailItem(
                    name: item.name,
                    path: item.path,
                    icon: item.icon,
                    sessions: sessions.filter { $0.projectPath == item.path }
                )
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Rail Item

struct RailItem: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState

    let name: String
    let path: String
    let icon: String
    let sessions: [Session]

    @State private var isHovered = false

    private var isSelected: Bool {
        windowState.selectedProject?.path == path
    }

    private var waitingCount: Int {
        sessions.filter { appState.waitingSessions.contains($0.id) }.count
    }

    private var workingCount: Int {
        sessions.filter { appState.workingSessions.contains($0.id) }.count
    }

    private var runningCount: Int {
        sessions.filter { appState.terminalControllers[$0.id] != nil }.count
    }

    var body: some View {
        Button {
            selectProject()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.primary.opacity(0.1) : .clear))
                    )
                    .overlay(
                        // Selection indicator bar on left
                        HStack {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor)
                                    .frame(width: 3, height: 20)
                                    .offset(x: -18)
                            }
                            Spacer()
                        }
                    )

                // Badge overlay
                if waitingCount > 0 {
                    // Orange badge with count for waiting
                    Text("\(waitingCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.orange)
                        .clipShape(Circle())
                        .offset(x: 4, y: -4)
                } else if workingCount > 0 {
                    // Green dot for working
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        )
                        .offset(x: 2, y: -2)
                } else if runningCount > 0 {
                    // Blue dot for running
                    Circle()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(name)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private func selectProject() {
        let category: ProjectCategory = path.contains("/Clients/") ? .client : .main
        let project = Project(name: name, path: path, icon: icon, category: category)

        // Mark as external terminal for Claude Hub
        if name == "Claude Hub" {
            project.usesExternalTerminal = true
        }

        withAnimation(.spring(response: 0.3)) {
            windowState.selectedProject = project
        }

        // Persist last-used project
        UserDefaults.standard.set(path, forKey: "lastSelectedProjectPath")
    }
}

// MARK: - Rail Divider

struct RailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 8)
    }
}

// MARK: - Add Project Sheet

struct AddProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var projectName = ""
    @State private var projectPath = ""
    @State private var projectIcon = "folder.fill"

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Project")
                .font(.headline)

            TextField("Project Name", text: $projectName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Path", text: $projectPath)
                    .textFieldStyle(.roundedBorder)

                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        projectPath = url.path
                        if projectName.isEmpty {
                            projectName = url.lastPathComponent
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    // TODO: Add project to the appropriate section
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.isEmpty || projectPath.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
