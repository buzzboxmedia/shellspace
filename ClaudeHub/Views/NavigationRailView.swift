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

    // Persisted order for each section
    @AppStorage("railOrderProjects") private var projectsOrderData: Data = Data()
    @AppStorage("railOrderClients") private var clientsOrderData: Data = Data()

    // Dropbox path (check both locations)
    private var dropboxPath: String {
        let newPath = NSString("~/Library/CloudStorage/Dropbox").expandingTildeInPath
        let legacyPath = NSString("~/Dropbox").expandingTildeInPath
        return FileManager.default.fileExists(atPath: newPath) ? newPath : legacyPath
    }

    // Default projects - always show if folder exists
    private var defaultMainProjects: [(name: String, path: String, icon: String)] {
        let items = [
            ("Miller", "\(dropboxPath)/Miller", "person.fill"),
            ("Talkspresso", "\(dropboxPath)/Talkspresso", "cup.and.saucer.fill"),
            ("Buzzbox", "\(dropboxPath)/Buzzbox", "shippingbox.fill")
        ].filter { FileManager.default.fileExists(atPath: $0.1) }

        return sortItems(items, using: projectsOrder)
    }

    private var defaultClientProjects: [(name: String, path: String, icon: String)] {
        let clientsPath = "\(dropboxPath)/Buzzbox/Clients"
        let items = [
            ("AAGL", "\(clientsPath)/AAGL", "cross.case.fill"),
            ("AFL", "\(clientsPath)/AFL", "building.columns.fill"),
            ("INFAB", "\(clientsPath)/INFAB", "shield.fill"),
            ("TDS", "\(clientsPath)/TDS", "eye.fill")
        ].filter { FileManager.default.fileExists(atPath: $0.1) }

        return sortItems(items, using: clientsOrder)
    }

    private var developmentProjects: [(name: String, path: String, icon: String)] {
        let claudeHubPath = "\(dropboxPath)/ClaudeHub"
        if FileManager.default.fileExists(atPath: claudeHubPath) {
            return [("Claude Hub", claudeHubPath, "terminal.fill")]
        }
        return []
    }

    // Database projects not already in defaults
    private var additionalMainProjects: [(name: String, path: String, icon: String)] {
        let defaultPaths = Set(defaultMainProjects.map { $0.path } + developmentProjects.map { $0.path })
        return allProjects
            .filter { $0.category == .main && !defaultPaths.contains($0.path) }
            .map { ($0.name, $0.path, $0.icon) }
    }

    private var additionalClientProjects: [(name: String, path: String, icon: String)] {
        let defaultPaths = Set(defaultClientProjects.map { $0.path })
        return allProjects
            .filter { $0.category == .client && !defaultPaths.contains($0.path) }
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
                    if !defaultMainProjects.isEmpty || !additionalMainProjects.isEmpty {
                        ReorderableRailSection(
                            items: defaultMainProjects + additionalMainProjects,
                            sessions: allSessions,
                            draggedPath: $draggedPath,
                            onReorder: { newOrder in
                                if let data = try? JSONEncoder().encode(newOrder) {
                                    projectsOrderData = data
                                }
                            }
                        )
                        RailDivider()
                    }

                    // Clients section (defaults + database)
                    if !defaultClientProjects.isEmpty || !additionalClientProjects.isEmpty {
                        ReorderableRailSection(
                            items: defaultClientProjects + additionalClientProjects,
                            sessions: allSessions,
                            draggedPath: $draggedPath,
                            onReorder: { newOrder in
                                if let data = try? JSONEncoder().encode(newOrder) {
                                    clientsOrderData = data
                                }
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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var projectName = ""
    @State private var projectPath = ""
    @State private var projectIcon = "folder.fill"
    @State private var selectedCategory: ProjectCategory = .main

    // Common SF Symbols for projects
    private let availableIcons = [
        "folder.fill",
        "doc.fill",
        "building.2.fill",
        "person.fill",
        "person.2.fill",
        "briefcase.fill",
        "cart.fill",
        "cup.and.saucer.fill",
        "shippingbox.fill",
        "hammer.fill",
        "wrench.and.screwdriver.fill",
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
        "paintbrush.fill",
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
                                .font(.system(size: 16))
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
