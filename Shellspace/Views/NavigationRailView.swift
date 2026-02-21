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

    // Persisted order for rail
    @AppStorage("railOrder") private var orderData: Data = Data()

    // All projects sorted by persisted order
    private var displayProjects: [(name: String, path: String, icon: String)] {
        let items = allProjects.map { ($0.name, $0.path, $0.icon) }
        return sortItems(items, using: savedOrder)
    }

    // Decode persisted order
    private var savedOrder: [String] {
        (try? JSONDecoder().decode([String].self, from: orderData)) ?? []
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
            // Shellspace icon at top - goes to dashboard/launcher
            Button {
                withAnimation(.spring(response: 0.3)) {
                    windowState.selectedProject = nil
                    windowState.activeSession = nil
                }
            } label: {
                Image(systemName: "fossil.shell.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(windowState.selectedProject == nil ? .white : .secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(windowState.selectedProject == nil ? Color.accentColor : .clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Home")
            .padding(.vertical, 12)

            RailDivider()

            ScrollView {
                VStack(spacing: 0) {
                    if !displayProjects.isEmpty {
                        ReorderableRailSection(
                            items: displayProjects,
                            sessions: allSessions,
                            draggedPath: $draggedPath,
                            onReorder: { newOrder in
                                if let data = try? JSONEncoder().encode(newOrder) {
                                    orderData = data
                                }
                            }
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
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    @Query private var allProjects: [Project]

    let name: String
    let path: String
    let icon: String
    let sessions: [Session]

    @State private var isHovered = false
    @State private var isPulsing = false
    @State private var showIconPicker = false

    private var persistedProject: Project? {
        allProjects.first { $0.path == path }
    }

    private let editableIcons = [
        "folder.fill", "house.fill", "building.fill", "building.2.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "paintbrush.fill", "ruler.fill",
        "person.fill", "person.2.fill", "briefcase.fill", "doc.fill",
        "cart.fill", "cup.and.saucer.fill", "shippingbox.fill", "gearshape.fill",
        "star.fill", "heart.fill", "bolt.fill", "leaf.fill",
        "globe", "cloud.fill", "server.rack", "desktopcomputer",
        "laptopcomputer", "iphone", "gamecontroller.fill", "camera.fill",
        "music.note", "film.fill", "book.fill", "graduationcap.fill",
        "cross.case.fill", "building.columns.fill", "shield.fill", "eye.fill"
    ]

    /// Use the persisted icon from the database (single source of truth)
    private var displayIcon: String {
        persistedProject?.icon ?? icon
    }

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
        ZStack(alignment: .topTrailing) {
            Image(systemName: displayIcon)
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
        .contentShape(Rectangle())
        .onTapGesture {
            selectProject()
        }
        .help(name)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("Change Icon...") {
                showIconPicker = true
            }
        }
        .popover(isPresented: $showIconPicker, arrowEdge: .trailing) {
            VStack(spacing: 12) {
                Text("Choose Icon")
                    .font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 6), spacing: 8) {
                    ForEach(editableIcons, id: \.self) { iconName in
                        Button {
                            if let project = persistedProject {
                                project.icon = iconName
                            } else {
                                // Create a persisted project so the icon is saved
                                let category: ProjectCategory = path.contains("/Clients/") ? .client : .main
                                let newProject = Project(name: name, path: path, icon: iconName, category: category)
                                modelContext.insert(newProject)
                            }
                            // Update the selected project if it's the current one
                            if windowState.selectedProject?.path == path {
                                windowState.selectedProject?.icon = iconName
                            }
                            showIconPicker = false
                            // Post notification to refresh nav rail
                            NotificationCenter.default.post(name: .init("RefreshNavRail"), object: nil)
                        } label: {
                            Image(systemName: iconName)
                                .font(.system(size: 18))
                                .foregroundStyle(displayIcon == iconName ? .white : .primary)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(displayIcon == iconName ? Color.accentColor : Color.primary.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .frame(width: 280)
        }
    }

    private func selectProject() {
        // Save current session for current project before switching
        if let currentProject = windowState.selectedProject,
           let currentSession = windowState.activeSession {
            UserDefaults.standard.set(currentSession.id.uuidString, forKey: "lastSession:\(currentProject.path)")
        }

        let isNewProject = windowState.selectedProject?.path != path
        // Use persisted project from database instead of creating a new one
        guard let project = persistedProject else { return }

        // Shellspace uses embedded terminal like everything else

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
            icon: projectIcon
        )
        modelContext.insert(project)
        dismiss()
    }
}
