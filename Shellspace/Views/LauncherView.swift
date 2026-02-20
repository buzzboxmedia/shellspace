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

    // Main projects from database (excluding Shellspace which goes in Development)
    var mainProjects: [Project] {
        allProjects.filter { $0.category == .main && $0.name != "Shellspace" }
    }

    // Client projects from database
    var clientProjects: [Project] {
        allProjects.filter { $0.category == .client }
    }

    // Shellspace project (shown in Development section)
    var shellspaceProject: Project? {
        allProjects.first { $0.name == "Shellspace" }
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
                        Text("Shellspace")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .overlay(alignment: .leading) {
                        // Show running sessions indicator
                        if !appState.terminalControllers.isEmpty {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 8, height: 8)
                                Text("\(appState.terminalControllers.count) running")
                                    .font(.system(size: 14, weight: .medium))
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
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Manage Sessions")

                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 20))
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
                        // Main Projects Section
                        if !mainProjects.isEmpty {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("PROJECTS")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(1.5)

                                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                                    ForEach(mainProjects) { project in
                                        ProjectCard(project: project)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Clients Section
                        if !clientProjects.isEmpty {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("CLIENTS")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(1.5)

                                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                                    ForEach(clientProjects) { project in
                                        ProjectCard(project: project)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Development Section - Shellspace
                        if let shellspace = shellspaceProject {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("DEVELOPMENT")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(1.5)

                                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                                    ProjectCard(project: shellspace, highlight: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
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

struct ProjectCard: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    @Query private var allSessions: [Session]
    let project: Project
    var highlight: Bool = false  // Blue accent for special projects like Shellspace
    @State private var isHovered = false

    /// Count of sessions with active terminal controllers (running in background)
    var runningCount: Int {
        project.sessions.filter { appState.terminalControllers[$0.id] != nil }.count
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
                        .font(.system(size: 40))
                        .foregroundStyle(highlight ? .blue : .primary)

                    // Show blue dot for running sessions
                    if runningCount > 0 {
                        Circle()
                            .fill(Color.blue.opacity(0.7))
                            .frame(width: 10, height: 10)
                            .offset(x: 5, y: -5)
                    }
                }

                Text(project.name)
                    .font(.system(size: 18, weight: .medium))
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
                    .stroke(highlight ? Color.blue.opacity(0.3) : .white.opacity(0.2), lineWidth: 1)
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
