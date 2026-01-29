import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LauncherView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState

    // Fetch all projects, sorted by name
    @Query(sort: \Project.name) private var allProjects: [Project]

    @State private var showSettings = false
    @State private var showCleanup = false

    // Dropbox path (check both locations)
    private var dropboxPath: String {
        let newPath = NSString("~/Library/CloudStorage/Dropbox").expandingTildeInPath
        let legacyPath = NSString("~/Dropbox").expandingTildeInPath
        return FileManager.default.fileExists(atPath: newPath) ? newPath : legacyPath
    }

    // Default projects - always show if folder exists (no database needed)
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

    // Database projects excluding those already shown as defaults
    var additionalMainProjects: [Project] {
        let defaultPaths = Set(defaultMainProjects.map { $0.path })
        return allProjects.filter {
            $0.category == .main &&
            $0.name != "Claude Hub" &&
            !defaultPaths.contains($0.path)
        }
    }

    var additionalClientProjects: [Project] {
        let defaultPaths = Set(defaultClientProjects.map { $0.path })
        return allProjects.filter {
            $0.category == .client &&
            !defaultPaths.contains($0.path)
        }
    }

    // Adaptive grid that responds to window width
    private let gridColumns = [
        GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 16)
    ]

    var body: some View {
        ZStack {
            // Glass background
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 40) {
                    // Header with settings button and running sessions indicator
                    HStack {
                        Spacer()
                        Text("Claude Hub")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .overlay(alignment: .leading) {
                        // Show running sessions indicator
                        if !appState.terminalControllers.isEmpty {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(appState.workingSessions.isEmpty ? Color.blue : Color.green)
                                    .frame(width: 8, height: 8)
                                Text("\(appState.terminalControllers.count) running")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.leading, 8)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 12) {
                            Button {
                                showCleanup = true
                            } label: {
                                Image(systemName: "tray.full.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Manage Sessions")

                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                                SettingsView()
                                    .environmentObject(appState)
                            }
                        }
                        .padding(.trailing, 8)
                    }

                    VStack(spacing: 36) {
                        // Main Projects Section - show defaults if folders exist
                        if !defaultMainProjects.isEmpty || !additionalMainProjects.isEmpty {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("PROJECTS")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(1.5)

                                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                                    // Default projects (hardcoded)
                                    ForEach(defaultMainProjects, id: \.name) { item in
                                        DefaultProjectCard(name: item.name, path: item.path, icon: item.icon)
                                    }
                                    // Additional projects from database
                                    ForEach(additionalMainProjects) { project in
                                        ProjectCard(project: project)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Clients Section - show defaults if folders exist
                        if !defaultClientProjects.isEmpty || !additionalClientProjects.isEmpty {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("CLIENTS")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(1.5)

                                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                                    // Default projects (hardcoded)
                                    ForEach(defaultClientProjects, id: \.name) { item in
                                        DefaultProjectCard(name: item.name, path: item.path, icon: item.icon)
                                    }
                                    // Additional projects from database
                                    ForEach(additionalClientProjects) { project in
                                        ProjectCard(project: project)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Development Section - Claude Hub itself (at the bottom)
                        VStack(alignment: .leading, spacing: 20) {
                            Text("DEVELOPMENT")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.5)

                            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                                ClaudeHubCard()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(48)
            }
        }
        .sheet(isPresented: $showCleanup) {
            SessionCleanupView()
        }
    }
}

// Section for default projects (based on folder existence, no database needed)
struct DefaultProjectSection: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var windowState: WindowState

    let title: String
    let defaults: [(name: String, path: String, icon: String)]
    let columns: [GridItem]
    var accentColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .tracking(1.5)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(defaults, id: \.name) { item in
                    DefaultProjectCard(name: item.name, path: item.path, icon: item.icon)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Card for default projects - creates Project on demand when clicked
struct DefaultProjectCard: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    @Query private var allSessions: [Session]

    let name: String
    let path: String
    let icon: String

    @State private var isHovered = false

    /// Sessions for this project path
    private var projectSessions: [Session] {
        allSessions.filter { $0.projectPath == path }
    }

    /// Count of sessions with active terminal controllers (running in background)
    private var runningCount: Int {
        projectSessions.filter { appState.terminalControllers[$0.id] != nil }.count
    }

    /// Count of sessions waiting for user input
    private var waitingCount: Int {
        projectSessions.filter { appState.waitingSessions.contains($0.id) }.count
    }

    /// Count of sessions with Claude actively working
    private var workingCount: Int {
        projectSessions.filter { appState.workingSessions.contains($0.id) }.count
    }

    var body: some View {
        Button {
            openProject()
        } label: {
            VStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 36))
                        .foregroundStyle(.primary)

                    // Show badge for waiting sessions (orange) or working sessions (green)
                    if waitingCount > 0 {
                        Text("\(waitingCount)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.orange)
                            .clipShape(Circle())
                            .offset(x: 10, y: -10)
                    } else if workingCount > 0 {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 12, height: 12)
                            .overlay {
                                Circle()
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            }
                            .offset(x: 6, y: -6)
                    } else if runningCount > 0 {
                        Circle()
                            .fill(Color.blue.opacity(0.7))
                            .frame(width: 10, height: 10)
                            .offset(x: 5, y: -5)
                    }
                }

                Text(name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 120, height: 120)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 16 : 10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleTaskDrop(providers: providers)
            return true
        }
    }

    /// Handle a task being dropped onto this project card
    private func handleTaskDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let dropped = String(data: data, encoding: .utf8) else { return }

                // Skip if it's a group drop (prefixed with "group:")
                if dropped.hasPrefix("group:") { return }

                // Parse the session UUID
                guard let sessionId = UUID(uuidString: dropped) else { return }

                // Find the session in our data
                guard let session = allSessions.first(where: { $0.id == sessionId }) else { return }

                // Don't move if already in this project
                if session.projectPath == path { return }

                Task { @MainActor in
                    // Move the task folder on disk
                    if let sourcePath = session.taskFolderPath {
                        let sourceURL = URL(fileURLWithPath: sourcePath)
                        do {
                            if let newPath = try TaskFolderService.shared.moveTaskToProject(
                                from: sourceURL,
                                toProjectPath: path,
                                toProjectName: name
                            ) {
                                // Update the session
                                session.projectPath = path
                                session.taskFolderPath = newPath.path
                                session.taskGroup = nil  // Remove from any group
                            }
                        } catch {
                            print("Failed to move task: \(error)")
                        }
                    } else {
                        // No task folder - just update the session
                        session.projectPath = path
                        session.taskGroup = nil
                    }
                }
            }
        }
    }

    private func openProject() {
        // Create project on demand (not persisted, just for navigation)
        let category: ProjectCategory = path.contains("/Clients/") ? .client : .main
        let project = Project(name: name, path: path, icon: icon, category: category)

        withAnimation(.spring(response: 0.3)) {
            windowState.selectedProject = project
        }
    }
}

// Reusable section component with grid layout (for database-stored projects)
struct ProjectSection: View {
    let title: String
    let projects: [Project]
    let columns: [GridItem]
    var accentColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .tracking(1.5)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(projects) { project in
                    ProjectCard(project: project)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Special card for Claude Hub - opens project view with external terminal mode
struct ClaudeHubCard: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var windowState: WindowState
    @Query(filter: #Predicate<Project> { $0.name == "Claude Hub" }) private var claudeHubProjects: [Project]
    @Query private var allSessions: [Session]
    @State private var isHovered = false

    private let claudeHubPath = "\(NSHomeDirectory())/Library/CloudStorage/Dropbox/ClaudeHub"

    var body: some View {
        Button {
            openClaudeHubProject()
        } label: {
            VStack(spacing: 14) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)

                Text("Claude Hub")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 120, height: 120)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 16 : 10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleTaskDrop(providers: providers)
            return true
        }
    }

    private func handleTaskDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let dropped = String(data: data, encoding: .utf8) else { return }

                if dropped.hasPrefix("group:") { return }
                guard let sessionId = UUID(uuidString: dropped) else { return }
                guard let session = allSessions.first(where: { $0.id == sessionId }) else { return }
                if session.projectPath == claudeHubPath { return }

                Task { @MainActor in
                    if let sourcePath = session.taskFolderPath {
                        let sourceURL = URL(fileURLWithPath: sourcePath)
                        do {
                            if let newPath = try TaskFolderService.shared.moveTaskToProject(
                                from: sourceURL,
                                toProjectPath: claudeHubPath,
                                toProjectName: "Claude Hub"
                            ) {
                                session.projectPath = claudeHubPath
                                session.taskFolderPath = newPath.path
                                session.taskGroup = nil
                            }
                        } catch {
                            print("Failed to move task: \(error)")
                        }
                    } else {
                        session.projectPath = claudeHubPath
                        session.taskGroup = nil
                    }
                }
            }
        }
    }

    private func openClaudeHubProject() {
        // Find or create the Claude Hub project
        let project: Project
        if let existing = claudeHubProjects.first {
            project = existing
            // Ensure it uses external terminal
            project.usesExternalTerminal = true
        } else {
            // Create Claude Hub project with external terminal flag
            project = Project(
                name: "Claude Hub",
                path: claudeHubPath,
                icon: "terminal.fill",
                category: .main,
                usesExternalTerminal: true
            )
            modelContext.insert(project)
        }

        withAnimation(.spring(response: 0.3)) {
            windowState.selectedProject = project
        }
    }
}

struct ProjectCard: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    @Query private var allSessions: [Session]
    let project: Project
    @State private var isHovered = false

    /// Count of sessions waiting for user input
    var waitingCount: Int {
        project.sessions.filter { appState.waitingSessions.contains($0.id) }.count
    }

    /// Count of sessions with active terminal controllers (running in background)
    var runningCount: Int {
        project.sessions.filter { appState.terminalControllers[$0.id] != nil }.count
    }

    /// Count of sessions with Claude actively working
    var workingCount: Int {
        project.sessions.filter { appState.workingSessions.contains($0.id) }.count
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                windowState.selectedProject = project
            }
        } label: {
            VStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: project.icon)
                        .font(.system(size: 36))
                        .foregroundStyle(.primary)

                    // Show badge for waiting sessions (orange), working sessions (green), or running (blue)
                    if waitingCount > 0 {
                        Text("\(waitingCount)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.orange)
                            .clipShape(Circle())
                            .offset(x: 10, y: -10)
                    } else if workingCount > 0 {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 12, height: 12)
                            .overlay {
                                Circle()
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            }
                            .offset(x: 6, y: -6)
                    } else if runningCount > 0 {
                        Circle()
                            .fill(Color.blue.opacity(0.7))
                            .frame(width: 10, height: 10)
                            .offset(x: 5, y: -5)
                    }
                }

                Text(project.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 120, height: 120)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 16 : 10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleTaskDrop(providers: providers)
            return true
        }
    }

    private func handleTaskDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let dropped = String(data: data, encoding: .utf8) else { return }

                if dropped.hasPrefix("group:") { return }
                guard let sessionId = UUID(uuidString: dropped) else { return }
                guard let session = allSessions.first(where: { $0.id == sessionId }) else { return }
                if session.projectPath == project.path { return }

                Task { @MainActor in
                    if let sourcePath = session.taskFolderPath {
                        let sourceURL = URL(fileURLWithPath: sourcePath)
                        do {
                            if let newPath = try TaskFolderService.shared.moveTaskToProject(
                                from: sourceURL,
                                toProjectPath: project.path,
                                toProjectName: project.name
                            ) {
                                session.projectPath = project.path
                                session.taskFolderPath = newPath.path
                                session.taskGroup = nil
                            }
                        } catch {
                            print("Failed to move task: \(error)")
                        }
                    } else {
                        session.projectPath = project.path
                        session.taskGroup = nil
                    }
                }
            }
        }
    }
}

// NSVisualEffectView wrapper for glass effect
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// Preview available in Xcode only
