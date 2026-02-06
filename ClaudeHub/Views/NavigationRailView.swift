import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A Slack-style navigation rail with project/client icons
struct NavigationRailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    @Query private var allSessions: [Session]
    @Query(sort: \Project.name) private var allProjects: [Project]

    @State private var showAddProject = false
    @State private var draggedPath: String?

    // Cached client list (refreshed on appear, not every render)
    @State private var cachedClients: [(name: String, path: String, icon: String)] = []
    @State private var cachedMainProjects: [(name: String, path: String, icon: String)] = []

    // Persisted order for each section
    @AppStorage("railOrderProjects") private var projectsOrderData: Data = Data()
    @AppStorage("railOrderClients") private var clientsOrderData: Data = Data()

    // Dropbox path (check both locations) - computed once
    private var dropboxPath: String {
        let newPath = NSString("~/Library/CloudStorage/Dropbox").expandingTildeInPath
        let legacyPath = NSString("~/Dropbox").expandingTildeInPath
        return FileManager.default.fileExists(atPath: newPath) ? newPath : legacyPath
    }

    // Icons for known clients
    private let clientIcons: [String: String] = [
        "AAGL": "cross.case.fill",
        "AFL": "building.columns.fill",
        "INFAB": "shield.fill",
        "TDS": "eye.fill",
        "Bassi": "b.circle.fill",
        "CDW": "c.circle.fill",
        "Citadel": "building.2.fill",
        "MAGicALL": "wand.and.stars",
        "RICO": "r.circle.fill",
        "Talkspresso": "cup.and.saucer.fill"
    ]

    // Scan filesystem for projects (called once on appear)
    private func refreshProjectLists() {
        // Main projects
        let mainItems = [
            ("Miller", "\(dropboxPath)/Miller", "person.fill"),
            ("Talkspresso", "\(dropboxPath)/Talkspresso", "cup.and.saucer.fill"),
            ("Buzzbox", "\(dropboxPath)/Buzzbox", "shippingbox.fill")
        ].filter { FileManager.default.fileExists(atPath: $0.1) }
        cachedMainProjects = sortItems(mainItems, using: projectsOrder)

        // Clients
        let clientsPath = "\(dropboxPath)/Buzzbox/Clients"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: clientsPath) else {
            cachedClients = []
            return
        }

        let items = contents.compactMap { name -> (String, String, String)? in
            let path = "\(clientsPath)/\(name)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            guard !name.hasPrefix(".") else { return nil }
            let icon = clientIcons[name] ?? "hammer.fill"
            return (name, path, icon)
        }.sorted { $0.0 < $1.0 }

        cachedClients = sortItems(items, using: clientsOrder)
    }

    private var developmentProjects: [(name: String, path: String, icon: String)] {
        let claudeHubPath = "\(dropboxPath)/ClaudeHub"
        if FileManager.default.fileExists(atPath: claudeHubPath) {
            return [("Claude Hub", claudeHubPath, "terminal.fill")]
        }
        return []
    }

    // Database projects not already shown (main projects only - clients come from folder scan)
    private var additionalMainProjects: [(name: String, path: String, icon: String)] {
        let defaultPaths = Set(cachedMainProjects.map { $0.path } + developmentProjects.map { $0.path })
        return allProjects
            .filter { $0.category == .main && !defaultPaths.contains($0.path) }
            .map { ($0.name, $0.path, $0.icon) }
    }

    // Decode persisted order
    private var projectsOrder: [String] {
        (try? JSONDecoder().decode([String].self, from: projectsOrderData)) ?? []
    }

    private var clientsOrder: [String] {
        (try? JSONDecoder().decode([String].self, from: clientsOrderData)) ?? []
    }

    // Sort items by persisted order
    private func sortItems(_ items: [(name: String, path: String, icon: String)], using order: [String]) -> [(name: String, path: String, icon: String)] {
        guard !order.isEmpty else { return items }

        return items.sorted { a, b in
            let indexA = order.firstIndex(of: a.path) ?? Int.max
            let indexB = order.firstIndex(of: b.path) ?? Int.max
            return indexA < indexB
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // Projects section (defaults + database)
                    if !cachedMainProjects.isEmpty || !additionalMainProjects.isEmpty {
                        ReorderableRailSection(
                            items: cachedMainProjects + additionalMainProjects,
                            sessions: allSessions,
                            draggedPath: $draggedPath,
                            onReorder: { newOrder in
                                if let data = try? JSONEncoder().encode(newOrder) {
                                    projectsOrderData = data
                                }
                                refreshProjectLists()
                            }
                        )
                        RailDivider()
                    }

                    // Clients section (cached)
                    if !cachedClients.isEmpty {
                        ReorderableRailSection(
                            items: cachedClients,
                            sessions: allSessions,
                            draggedPath: $draggedPath,
                            onReorder: { newOrder in
                                if let data = try? JSONEncoder().encode(newOrder) {
                                    clientsOrderData = data
                                }
                                refreshProjectLists()
                            }
                        )
                        RailDivider()
                    }

                    // Development section (not reorderable)
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
                    .font(.system(size: 20, weight: .medium))
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
        .onAppear {
            refreshProjectLists()
        }
    }
}

// MARK: - Reorderable Rail Section

struct ReorderableRailSection: View {
    @EnvironmentObject var appState: AppState
    let items: [(name: String, path: String, icon: String)]
    let sessions: [Session]
    @Binding var draggedPath: String?
    let onReorder: ([String]) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items, id: \.path) { item in
                RailItem(
                    name: item.name,
                    path: item.path,
                    icon: item.icon,
                    sessions: sessions.filter { $0.projectPath == item.path }
                )
                .onDrag {
                    draggedPath = item.path
                    return NSItemProvider(object: item.path as NSString)
                }
                .onDrop(of: [.text], delegate: RailDropDelegate(
                    item: item,
                    items: items,
                    draggedPath: $draggedPath,
                    onReorder: onReorder
                ))
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Rail Drop Delegate

struct RailDropDelegate: DropDelegate {
    let item: (name: String, path: String, icon: String)
    let items: [(name: String, path: String, icon: String)]
    @Binding var draggedPath: String?
    let onReorder: ([String]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedPath = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedPath = draggedPath,
              draggedPath != item.path,
              let fromIndex = items.firstIndex(where: { $0.path == draggedPath }),
              let toIndex = items.firstIndex(where: { $0.path == item.path }) else {
            return
        }

        var newItems = items
        let movedItem = newItems.remove(at: fromIndex)
        newItems.insert(movedItem, at: toIndex)

        withAnimation(.easeInOut(duration: 0.2)) {
            onReorder(newItems.map { $0.path })
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Rail Section (non-reorderable)

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
    @State private var isPulsing = false

    private var isSelected: Bool {
        windowState.selectedProject?.path == path
    }

    /// Count of sessions with active terminal controllers (running) - excludes hidden
    private var runningCount: Int {
        sessions.filter { !$0.isHidden && appState.terminalControllers[$0.id] != nil }.count
    }

    /// Check if any session in this project needs attention - excludes hidden
    private var needsAttention: Bool {
        sessions.contains { !$0.isHidden && appState.sessionsNeedingAttention.contains($0.id) }
    }

    /// Has any active sessions (tasks open)
    private var hasActiveSessions: Bool {
        !sessions.filter { !$0.isCompleted && !$0.isHidden }.isEmpty
    }

    var body: some View {
        Button {
            selectProject()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(hasActiveSessions ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.primary.opacity(0.1) : .clear))
                    )
                    // Glow effect when there are active sessions
                    .shadow(
                        color: hasActiveSessions ? Color.blue.opacity(0.5) : .clear,
                        radius: hasActiveSessions ? 6 : 0
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

                // Badge overlay - pulsing blue dot for attention, static dot for running
                if needsAttention {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                        .shadow(color: Color.blue.opacity(0.8), radius: isPulsing ? 6 : 2)
                        .scaleEffect(isPulsing ? 1.2 : 1.0)
                        .offset(x: 2, y: -2)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                isPulsing = true
                            }
                        }
                } else if runningCount > 0 {
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
        // Save current session for current project before switching
        if let currentProject = windowState.selectedProject,
           let currentSession = windowState.activeSession {
            UserDefaults.standard.set(currentSession.id.uuidString, forKey: "lastSession:\(currentProject.path)")
        }

        let isNewProject = windowState.selectedProject?.path != path
        let category: ProjectCategory = path.contains("/Clients/") ? .client : .main
        let project = Project(name: name, path: path, icon: icon, category: category)

        // Mark as external terminal for Claude Hub
        if name == "Claude Hub" {
            project.usesExternalTerminal = true
        }

        // Set project and clear session in the same transaction
        // so restoreLastSession sees the new project (not the old one)
        withAnimation(.spring(response: 0.3)) {
            windowState.selectedProject = project
            if isNewProject {
                windowState.activeSession = nil
            }
        }

        // Persist last-used project
        UserDefaults.standard.set(path, forKey: "lastSelectedProjectPath")

        // Clear attention for all sessions in this project when viewing it
        for session in sessions {
            appState.clearSessionAttention(session.id)
        }
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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var projectName = ""
    @State private var projectPath = ""
    @State private var projectIcon = "folder.fill"
    @State private var selectedCategory: ProjectCategory = .main

    // Common SF Symbols for projects
    private let availableIcons = [
        "folder.fill",
        "house.fill",
        "building.fill",
        "building.2.fill",
        "hammer.fill",
        "wrench.and.screwdriver.fill",
        "paintbrush.fill",
        "ruler.fill",
        "person.fill",
        "person.2.fill",
        "briefcase.fill",
        "doc.fill",
        "cart.fill",
        "cup.and.saucer.fill",
        "shippingbox.fill",
        "gearshape.fill",
        "star.fill",
        "heart.fill",
        "bolt.fill",
        "leaf.fill",
        "globe",
        "cloud.fill",
        "server.rack",
        "desktopcomputer",
        "laptopcomputer",
        "iphone",
        "gamecontroller.fill",
        "camera.fill",
        "music.note",
        "film.fill",
        "book.fill",
        "graduationcap.fill",
        "cross.case.fill",
        "building.columns.fill",
        "shield.fill",
        "eye.fill"
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Project")
                .font(.headline)

            // Icon picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 8), spacing: 8) {
                    ForEach(availableIcons, id: \.self) { icon in
                        Button {
                            projectIcon = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 18))
                                .foregroundStyle(projectIcon == icon ? .white : .primary)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(projectIcon == icon ? Color.accentColor : Color.primary.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

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

            // Category picker
            Picker("Category", selection: $selectedCategory) {
                Text("Project").tag(ProjectCategory.main)
                Text("Client").tag(ProjectCategory.client)
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    addProject()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.isEmpty || projectPath.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func addProject() {
        let project = Project(
            name: projectName,
            path: projectPath,
            icon: projectIcon,
            category: selectedCategory
        )
        modelContext.insert(project)
        dismiss()
    }
}
