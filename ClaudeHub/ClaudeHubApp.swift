import SwiftUI
import os.log

private let appLogger = Logger(subsystem: "com.buzzbox.claudehub", category: "AppState")

/// Per-window state - each window gets its own instance
class WindowState: ObservableObject {
    @Published var selectedProject: Project?
    @Published var activeSession: Session?
}

@main
struct ClaudeHubApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            WindowContainer()
                .environmentObject(appState)
                .onAppear {
                    // Make sure app is active when window appears
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            // Note: Cmd+N now opens a new independent window (default WindowGroup behavior)
            // Navigation
            CommandGroup(after: .sidebar) {
                // Escape to go back is handled per-window in WorkspaceView
            }
            // Ensure standard Edit menu commands work
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)

                Button("Select All") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
            }
        }

        MenuBarExtra("Claude Hub", systemImage: "terminal.fill") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure app can become active
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // When app becomes active, make sure the main window is key
        if let window = NSApplication.shared.mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

class AppState: ObservableObject {
    // Shared data across all windows
    @Published var sessions: [Session] = []
    @Published var mainProjects: [Project] = []
    @Published var clientProjects: [Project] = []

    // Store terminal controllers by session ID so they persist when switching
    var terminalControllers: [UUID: TerminalController] = [:]

    // Per-window states keyed by window ID - ensures true isolation
    private var windowStates: [UUID: WindowState] = [:]

    func getOrCreateWindowState(for windowId: UUID) -> WindowState {
        if let existing = windowStates[windowId] {
            return existing
        }
        let state = WindowState()
        windowStates[windowId] = state
        appLogger.info("Created new WindowState for window \(windowId)")
        return state
    }

    func removeWindowState(for windowId: UUID) {
        windowStates.removeValue(forKey: windowId)
    }

    // Services for active project detection
    private let activeProjectsParser = ActiveProjectsParser()
    private let briefingGenerator = ParkerBriefingGenerator()

    private let defaults = UserDefaults.standard
    private let mainProjectsKey = "mainProjects"
    private let clientProjectsKey = "clientProjects"
    private let sessionsKey = "sessions"

    init() {
        loadProjects()
        loadSessions()
    }

    func getOrCreateController(for session: Session) -> TerminalController {
        if let existing = terminalControllers[session.id] {
            return existing
        }
        let controller = TerminalController()
        terminalControllers[session.id] = controller
        return controller
    }

    func removeController(for session: Session) {
        terminalControllers.removeValue(forKey: session.id)
    }

    func sessionsFor(project: Project) -> [Session] {
        sessions.filter { $0.projectPath == project.path }
    }

    func createSession(for project: Project) -> Session {
        // Generate name like "Chat 1", "Chat 2", etc
        let existingCount = sessionsFor(project: project).filter { !$0.isProjectLinked }.count
        let chatName = "Chat \(existingCount + 1)"

        let session = Session(
            id: UUID(),
            name: chatName,
            projectPath: project.path,
            createdAt: Date()
        )
        sessions.append(session)
        saveSessions()
        return session
    }

    /// Create sessions for all active projects in ACTIVE-PROJECTS.md
    func createSessionsForActiveProjects(project: Project) -> [Session] {
        let activeProjects = activeProjectsParser.parseActiveProjects(at: project.path)
        var createdSessions: [Session] = []

        for activeProject in activeProjects {
            // Check if session already exists for this active project
            let existingSession = sessions.first { session in
                session.projectPath == project.path &&
                session.activeProjectName == activeProject.name
            }

            if existingSession != nil {
                // Already exists, skip creation
                continue
            }

            // Generate Parker briefing
            let briefing = briefingGenerator.generateBriefing(
                for: activeProject,
                clientName: project.name
            )

            // Create new session linked to this active project
            let session = Session(
                id: UUID(),
                name: activeProject.name,
                projectPath: project.path,
                createdAt: Date(),
                activeProjectName: activeProject.name,
                parkerBriefing: briefing
            )

            sessions.append(session)
            createdSessions.append(session)
            appLogger.info("Created session for active project: \(activeProject.name)")
        }

        if !createdSessions.isEmpty {
            saveSessions()
        }
        return createdSessions
    }

    func deleteSession(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        removeController(for: session)
        // Note: Each window's WindowState must handle clearing its own activeSession if needed
        saveSessions()
    }

    func updateSessionName(_ session: Session, name: String) {
        appLogger.info("Updating session name from '\(session.name)' to '\(name)'")
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].name = name
            saveSessions()
            appLogger.info("Session name updated and saved")
        } else {
            appLogger.warning("Session not found for name update: \(session.id)")
        }
    }

    func updateClaudeSessionId(_ session: Session, claudeSessionId: String) {
        appLogger.info("Updating Claude session ID for '\(session.name)' to '\(claudeSessionId)'")
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].claudeSessionId = claudeSessionId
            saveSessions()
            appLogger.info("Claude session ID updated and saved")
        } else {
            appLogger.warning("Session not found for Claude session ID update: \(session.id)")
        }
    }

    // MARK: - Session Persistence

    private func loadSessions() {
        if let data = defaults.data(forKey: sessionsKey),
           let saved = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = saved
        }
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: sessionsKey)
        }
    }

    // MARK: - Project Management

    func addMainProject(_ project: Project) {
        mainProjects.append(project)
        saveProjects()
    }

    func addClientProject(_ project: Project) {
        clientProjects.append(project)
        saveProjects()
    }

    func removeMainProject(_ project: Project) {
        mainProjects.removeAll { $0.id == project.id }
        saveProjects()
    }

    func removeClientProject(_ project: Project) {
        clientProjects.removeAll { $0.id == project.id }
        saveProjects()
    }

    // MARK: - Persistence

    private func loadProjects() {
        if let data = defaults.data(forKey: mainProjectsKey),
           let saved = try? JSONDecoder().decode([SavedProject].self, from: data) {
            mainProjects = saved.map { $0.toProject() }
        } else {
            // Default projects
            let dropboxPath = NSString("~/Library/CloudStorage/Dropbox").expandingTildeInPath
            mainProjects = [
                Project(name: "Miller", path: "\(dropboxPath)/Miller", icon: "person.fill"),
                Project(name: "Talkspresso", path: "\(dropboxPath)/Talkspresso", icon: "cup.and.saucer.fill"),
                Project(name: "Buzzbox", path: "\(dropboxPath)/Buzzbox", icon: "shippingbox.fill")
            ]
        }

        if let data = defaults.data(forKey: clientProjectsKey),
           let saved = try? JSONDecoder().decode([SavedProject].self, from: data) {
            clientProjects = saved.map { $0.toProject() }
        } else {
            // Default clients
            let clientsPath = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/Clients").expandingTildeInPath
            clientProjects = [
                Project(name: "AAGL", path: "\(clientsPath)/AAGL", icon: "cross.case.fill"),
                Project(name: "AFL", path: "\(clientsPath)/AFL", icon: "building.columns.fill"),
                Project(name: "Citadel", path: "\(clientsPath)/Citadel", icon: "car.fill"),
                Project(name: "INFAB", path: "\(clientsPath)/INFAB", icon: "shield.fill"),
                Project(name: "TDS", path: "\(clientsPath)/TDS", icon: "eye.fill")
            ]
        }
    }

    private func saveProjects() {
        let mainSaved = mainProjects.map { SavedProject(from: $0) }
        let clientSaved = clientProjects.map { SavedProject(from: $0) }

        if let data = try? JSONEncoder().encode(mainSaved) {
            defaults.set(data, forKey: mainProjectsKey)
        }
        if let data = try? JSONEncoder().encode(clientSaved) {
            defaults.set(data, forKey: clientProjectsKey)
        }
    }
}

// Codable wrapper for Project persistence
struct SavedProject: Codable {
    let name: String
    let path: String
    let icon: String

    init(from project: Project) {
        self.name = project.name
        self.path = project.path
        self.icon = project.icon
    }

    func toProject() -> Project {
        Project(name: name, path: path, icon: icon)
    }
}

/// Each window gets its own WindowContainer with independent WindowState
struct WindowContainer: View {
    @EnvironmentObject var appState: AppState
    @State private var windowId = UUID()
    @State private var windowState: WindowState?

    var body: some View {
        Group {
            if let state = windowState {
                WindowContent()
                    .environmentObject(state)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            // Get or create window state for this window's unique ID
            if windowState == nil {
                windowState = appState.getOrCreateWindowState(for: windowId)
            }
        }
        .onDisappear {
            // Clean up window state when window closes
            appState.removeWindowState(for: windowId)
        }
    }
}

/// The actual window content, with its own WindowState from environment
struct WindowContent: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState

    var body: some View {
        Group {
            if let project = windowState.selectedProject {
                WorkspaceView(project: project)
            } else {
                LauncherView()
            }
        }
    }
}
