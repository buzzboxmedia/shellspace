import SwiftUI
import SwiftData

struct LauncherView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState

    // Fetch all projects, sorted by name
    @Query(sort: \Project.name) private var allProjects: [Project]

    @State private var showSettings = false

    // Filter projects by category
    var mainProjects: [Project] {
        allProjects.filter { $0.category == .main }
    }

    var clientProjects: [Project] {
        allProjects.filter { $0.category == .client }
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
                    // Header with settings button
                    HStack {
                        Spacer()
                        Text("Claude Hub")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 12) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.trailing, 8)
                    }

                    VStack(spacing: 36) {
                        // Main Projects Section
                        if !mainProjects.isEmpty {
                            ProjectSection(
                                title: "PROJECTS",
                                projects: mainProjects,
                                columns: gridColumns
                            )
                        }

                        // Clients Section
                        if !clientProjects.isEmpty {
                            ProjectSection(
                                title: "CLIENTS",
                                projects: clientProjects,
                                columns: gridColumns
                            )
                        }

                        // Development shortcut (opens in Terminal, not ClaudeHub)
                        VStack(alignment: .leading, spacing: 20) {
                            Text("DEVELOPMENT")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.orange)
                                .tracking(1.5)

                            HStack {
                                Button {
                                    openTerminalAtPath("\(NSHomeDirectory())/Dropbox/claudehub")
                                } label: {
                                    VStack(spacing: 14) {
                                        Image(systemName: "hammer.fill")
                                            .font(.system(size: 36))
                                            .foregroundStyle(.primary)
                                        Text("ClaudeHub")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(.primary)
                                    }
                                    .frame(width: 120, height: 120)
                                    .background {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(.ultraThinMaterial)
                                            .shadow(color: .black.opacity(0.1), radius: 10)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(.white.opacity(0.2), lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(48)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
        }
        .onAppear {
            // Create default projects only on first launch (use UserDefaults flag, not query)
            let hasCreatedDefaults = UserDefaults.standard.bool(forKey: "hasCreatedDefaultProjects")
            if !hasCreatedDefaults {
                createDefaultProjects()
                UserDefaults.standard.set(true, forKey: "hasCreatedDefaultProjects")
            }
        }
    }

    /// Open Terminal at a specific path
    private func openTerminalAtPath(_ path: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(path)' && claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    /// Create default projects on first launch
    private func createDefaultProjects() {
        let dropboxPath = NSString("~/Library/CloudStorage/Dropbox").expandingTildeInPath
        let clientsPath = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/Clients").expandingTildeInPath
        let codePath = NSString("~/Code").expandingTildeInPath

        // Main projects
        let mainDefaults = [
            ("ClaudeHub", "\(codePath)/claudehub", "hammer.fill"),
            ("Miller", "\(dropboxPath)/Miller", "person.fill"),
            ("Talkspresso", "\(dropboxPath)/Talkspresso", "cup.and.saucer.fill"),
            ("Buzzbox", "\(dropboxPath)/Buzzbox", "shippingbox.fill")
        ]

        for (name, path, icon) in mainDefaults {
            let project = Project(name: name, path: path, icon: icon, category: .main)
            modelContext.insert(project)
        }

        // Client projects
        let clientDefaults = [
            ("AAGL", "\(clientsPath)/AAGL", "cross.case.fill"),
            ("AFL", "\(clientsPath)/AFL", "building.columns.fill"),
            ("INFAB", "\(clientsPath)/INFAB", "shield.fill"),
            ("TDS", "\(clientsPath)/TDS", "eye.fill")
        ]

        for (name, path, icon) in clientDefaults {
            let project = Project(name: name, path: path, icon: icon, category: .client)
            modelContext.insert(project)
        }
    }
}

// Reusable section component with grid layout
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

struct ProjectCard: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project
    @State private var isHovered = false

    /// Count of sessions waiting for user input
    var waitingCount: Int {
        project.sessions.filter { appState.waitingSessions.contains($0.id) }.count
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

                    // Show badge only when sessions need attention
                    if waitingCount > 0 {
                        Text("\(waitingCount)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.orange)
                            .clipShape(Circle())
                            .offset(x: 10, y: -10)
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
