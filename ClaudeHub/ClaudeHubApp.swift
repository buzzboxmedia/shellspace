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
                    // Give AppDelegate access to appState for cleanup on quit
                    appDelegate.appState = appState
                }
        }
        .windowResizability(.contentMinSize)
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

            // Zoom commands for scaling the whole UI
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    appState.increaseUIScale()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    appState.decreaseUIScale()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    appState.resetUIScale()
                }
                .keyboardShortcut("0", modifiers: .command)
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
    weak var appState: AppState?

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

    func applicationWillTerminate(_ notification: Notification) {
        // Save all active session logs before quitting
        appState?.saveAllActiveLogs()
    }
}

class AppState: ObservableObject {
    // Shared data across all windows
    @Published var sessions: [Session] = []
    @Published var taskGroups: [ProjectGroup] = []  // Task groups (projects within folders)
    @Published var mainProjects: [Project] = []
    @Published var clientProjects: [Project] = []
    @Published var devProjects: [Project] = []  // Meta: ClaudeHub itself

    // Global UI scale (Cmd+/- to adjust)
    @Published var uiScale: CGFloat = 1.0
    private static let minScale: CGFloat = 0.7
    private static let maxScale: CGFloat = 1.5

    func increaseUIScale() {
        uiScale = min(uiScale + 0.1, Self.maxScale)
        appLogger.info("UI scale increased to \(self.uiScale)")
    }

    func decreaseUIScale() {
        uiScale = max(uiScale - 0.1, Self.minScale)
        appLogger.info("UI scale decreased to \(self.uiScale)")
    }

    func resetUIScale() {
        uiScale = 1.0
        appLogger.info("UI scale reset to 1.0")
    }

    // Track which sessions are waiting for user input
    @Published var waitingSessions: Set<UUID> = []

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

    // Global config path (for project list only)
    private var configPath: URL {
        let path = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/ClaudeHub").expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    private var projectsFilePath: URL {
        configPath.appendingPathComponent("projects.json")
    }

    init() {
        // Ensure config directory exists
        try? FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true)
        loadProjects()
        loadAllSessions()
        loadAllProjectGroups()
    }

    /// Get the sessions file path for a project
    private func sessionsFilePath(for projectPath: String) -> URL {
        // Special case: ClaudeHub dev folder -> save to Dropbox version
        if projectPath.contains("/Code/claudehub") || projectPath.contains("/code/claudehub") {
            return configPath.appendingPathComponent("sessions.json")
        }
        // All other projects: save in project folder
        return URL(fileURLWithPath: projectPath).appendingPathComponent(".claudehub-sessions.json")
    }

    /// Get the task groups file path for a project
    private func taskGroupsFilePath(for projectPath: String) -> URL {
        if projectPath.contains("/Code/claudehub") || projectPath.contains("/code/claudehub") {
            return configPath.appendingPathComponent("taskgroups.json")
        }
        return URL(fileURLWithPath: projectPath).appendingPathComponent(".claudehub-taskgroups.json")
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

    // MARK: - Task Group Management

    func taskGroupsFor(project: Project) -> [ProjectGroup] {
        taskGroups.filter { $0.projectPath == project.path }
    }

    func sessionsFor(taskGroup: ProjectGroup) -> [Session] {
        sessions.filter { $0.taskGroupId == taskGroup.id }
    }

    /// Sessions that are not in any task group (standalone tasks)
    func standaloneSessions(for project: Project) -> [Session] {
        sessions.filter { $0.projectPath == project.path && $0.taskGroupId == nil && !$0.isProjectLinked }
    }

    func createProjectGroup(for project: Project, name: String) -> ProjectGroup {
        let group = ProjectGroup(name: name, projectPath: project.path)
        taskGroups.append(group)
        saveProjectGroups()
        appLogger.info("Created task group: \(name)")
        return group
    }

    func deleteProjectGroup(_ group: ProjectGroup) {
        // Move all tasks in this group to standalone
        for i in sessions.indices where sessions[i].taskGroupId == group.id {
            sessions[i].taskGroupId = nil
        }
        taskGroups.removeAll { $0.id == group.id }
        saveProjectGroups()
        saveSessions()
        appLogger.info("Deleted task group: \(group.name)")
    }

    func renameProjectGroup(_ group: ProjectGroup, name: String) {
        if let index = taskGroups.firstIndex(where: { $0.id == group.id }) {
            taskGroups[index].name = name
            saveProjectGroups()
        }
    }

    func toggleProjectGroupExpanded(_ group: ProjectGroup) {
        if let index = taskGroups.firstIndex(where: { $0.id == group.id }) {
            taskGroups[index].isExpanded.toggle()
            saveProjectGroups()
        }
    }

    func moveSession(_ session: Session, toGroup group: ProjectGroup?) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].taskGroupId = group?.id
            saveSessions()
            appLogger.info("Moved session '\(session.name)' to group: \(group?.name ?? "standalone")")
        }
    }

    func createSession(for project: Project, name: String? = nil, inGroup group: ProjectGroup? = nil) -> Session {
        // Use provided name or generate default "Task 1", "Task 2", etc
        let taskName: String
        let isUserNamed: Bool

        if let name = name, !name.isEmpty {
            taskName = name
            isUserNamed = true  // User provided the name, don't auto-rename
        } else {
            let existingCount = sessionsFor(project: project).filter { !$0.isProjectLinked }.count
            taskName = "Task \(existingCount + 1)"
            isUserNamed = false  // Auto-generated, can be renamed by AI
        }

        var session = Session(
            id: UUID(),
            name: taskName,
            projectPath: project.path,
            createdAt: Date(),
            userNamed: isUserNamed
        )
        session.taskGroupId = group?.id
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

    func updateSessionSummary(_ session: Session, summary: String) {
        appLogger.info("Saving session summary for '\(session.name)'")
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].lastSessionSummary = summary
            saveSessions()
            appLogger.info("Session summary saved")
        }
    }

    func updateSessionLogPath(_ session: Session, logPath: String) {
        appLogger.info("Updating log path for '\(session.name)'")
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].logFilePath = logPath
            sessions[index].lastLogSavedAt = Date()
            saveSessions()
            appLogger.info("Session log path updated")
        }
    }

    /// Read the saved log content for a session
    func readSessionLog(_ session: Session) -> String? {
        let logPath = session.logPath
        guard FileManager.default.fileExists(atPath: logPath.path) else {
            appLogger.info("No log file found for session: \(session.name)")
            return nil
        }

        do {
            let content = try String(contentsOf: logPath, encoding: .utf8)
            appLogger.info("Read log for session '\(session.name)': \(content.count) characters")
            return content
        } catch {
            appLogger.error("Failed to read log: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generate a resume prompt for continuing a task
    func generateResumePrompt(for session: Session) -> String {
        var prompt = "I'm resuming work on: \"\(session.name)\"\n\n"

        // Add summary if available
        if let summary = session.lastSessionSummary, !summary.isEmpty {
            prompt += "Last session summary:\n\(summary)\n\n"
        }

        // Add recent log context if available (last ~2000 chars)
        if let logContent = readSessionLog(session) {
            // Strip the header and get the conversation content
            let lines = logContent.components(separatedBy: "\n")
            let contentLines = lines.dropFirst(5) // Skip header lines
            let content = contentLines.joined(separator: "\n")

            // Take the last portion for context
            let recentContent = String(content.suffix(3000))
            if !recentContent.isEmpty {
                prompt += "Recent conversation context:\n---\n\(recentContent)\n---\n\n"
            }
        }

        prompt += "What's the current status and what are the recommended next steps?"

        return prompt
    }

    /// Save logs for all active sessions (called on app quit or session switch)
    func saveAllActiveLogs() {
        for (sessionId, controller) in terminalControllers {
            if let session = sessions.first(where: { $0.id == sessionId }) {
                controller.saveLog(for: session)
            }
        }
        appLogger.info("Saved logs for all active sessions")
    }

    // MARK: - Waiting State Management

    /// Mark a session as waiting for user input
    func markSessionWaiting(_ session: Session) {
        guard !waitingSessions.contains(session.id) else { return }

        waitingSessions.insert(session.id)
        appLogger.info("Session marked as waiting: \(session.name)")

        // Find project name for notification
        let allProjects = mainProjects + clientProjects + devProjects
        let projectName = allProjects.first { $0.path == session.projectPath }?.name ?? "Unknown"

        // Send notification
        NotificationManager.shared.notifyClaudeWaiting(
            sessionId: session.id,
            sessionName: session.name,
            projectName: projectName
        )

        // Update dock badge
        NotificationManager.shared.updateDockBadge(count: waitingSessions.count)
    }

    /// Clear waiting state when user interacts with session
    func clearSessionWaiting(_ session: Session) {
        guard waitingSessions.contains(session.id) else { return }

        waitingSessions.remove(session.id)
        appLogger.info("Session no longer waiting: \(session.name)")

        // Clear notification for this session
        NotificationManager.shared.clearNotification(for: session.id)

        // Update dock badge
        NotificationManager.shared.updateDockBadge(count: waitingSessions.count)
    }

    /// Get count of waiting sessions for a project
    func waitingCountFor(project: Project) -> Int {
        sessionsFor(project: project)
            .filter { waitingSessions.contains($0.id) }
            .count
    }

    // MARK: - Session Persistence (per-project)

    /// Load sessions from all known project folders
    private func loadAllSessions() {
        var allSessions: [Session] = []
        let allProjects = mainProjects + clientProjects + devProjects

        for project in allProjects {
            let filePath = sessionsFilePath(for: project.path)
            if let data = try? Data(contentsOf: filePath),
               let projectSessions = try? JSONDecoder().decode([Session].self, from: data) {
                allSessions.append(contentsOf: projectSessions)
                appLogger.info("Loaded \(projectSessions.count) sessions from \(project.name)")
            }
        }

        // Also migrate any old sessions from UserDefaults
        if allSessions.isEmpty, let data = defaults.data(forKey: sessionsKey),
           let oldSessions = try? JSONDecoder().decode([Session].self, from: data) {
            allSessions = oldSessions
            // Save to new per-project format
            sessions = allSessions
            saveAllSessions(allSessions)
            appLogger.info("Migrated \(oldSessions.count) sessions to per-project storage")
        }

        sessions = allSessions
    }

    /// Save sessions to their respective project folders
    private func saveSessions() {
        // Run save on background thread to avoid UI lag
        let sessionsToSave = sessions
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveAllSessions(sessionsToSave)
        }
    }

    private func saveAllSessions(_ sessionsToSave: [Session]) {
        // Group sessions by project path
        let grouped = Dictionary(grouping: sessionsToSave) { $0.projectPath }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        for (projectPath, projectSessions) in grouped {
            let filePath = sessionsFilePath(for: projectPath)
            if let data = try? encoder.encode(projectSessions) {
                try? data.write(to: filePath)
            }
        }
        appLogger.info("Saved sessions to project folders")
    }

    // MARK: - Task Group Persistence (per-project)

    private func loadAllProjectGroups() {
        var allGroups: [ProjectGroup] = []
        let allProjects = mainProjects + clientProjects + devProjects

        for project in allProjects {
            let filePath = taskGroupsFilePath(for: project.path)
            if let data = try? Data(contentsOf: filePath),
               let projectGroups = try? JSONDecoder().decode([ProjectGroup].self, from: data) {
                allGroups.append(contentsOf: projectGroups)
                appLogger.info("Loaded \(projectGroups.count) task groups from \(project.name)")
            }
        }

        taskGroups = allGroups
    }

    private func saveProjectGroups() {
        let groupsToSave = taskGroups
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveAllProjectGroups(groupsToSave)
        }
    }

    private func saveAllProjectGroups(_ groupsToSave: [ProjectGroup]) {
        let grouped = Dictionary(grouping: groupsToSave) { $0.projectPath }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        for (projectPath, projectGroups) in grouped {
            let filePath = taskGroupsFilePath(for: projectPath)
            if let data = try? encoder.encode(projectGroups) {
                try? data.write(to: filePath)
            }
        }
        appLogger.info("Saved task groups to project folders")
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

    // MARK: - Project Persistence (Dropbox synced)

    private func loadProjects() {
        // Try Dropbox file first
        if let data = try? Data(contentsOf: projectsFilePath),
           let saved = try? JSONDecoder().decode(SavedProjectsFile.self, from: data) {
            mainProjects = saved.main.map { $0.toProject() }
            clientProjects = saved.clients.map { $0.toProject() }
            appLogger.info("Loaded projects from Dropbox")
        } else if let mainData = defaults.data(forKey: mainProjectsKey),
           let mainSaved = try? JSONDecoder().decode([SavedProject].self, from: mainData) {
            // Migrate from UserDefaults
            mainProjects = mainSaved.map { $0.toProject() }
            if let clientData = defaults.data(forKey: clientProjectsKey),
               let clientSaved = try? JSONDecoder().decode([SavedProject].self, from: clientData) {
                clientProjects = clientSaved.map { $0.toProject() }
            }
            saveProjects()
            appLogger.info("Migrated projects to Dropbox")
        } else {
            // Default projects
            let dropboxPath = NSString("~/Library/CloudStorage/Dropbox").expandingTildeInPath
            mainProjects = [
                Project(name: "Miller", path: "\(dropboxPath)/Miller", icon: "person.fill"),
                Project(name: "Talkspresso", path: "\(dropboxPath)/Talkspresso", icon: "cup.and.saucer.fill"),
                Project(name: "Buzzbox", path: "\(dropboxPath)/Buzzbox", icon: "shippingbox.fill")
            ]
            // Default clients
            let clientsPath = NSString("~/Library/CloudStorage/Dropbox/Buzzbox/Clients").expandingTildeInPath
            clientProjects = [
                Project(name: "AAGL", path: "\(clientsPath)/AAGL", icon: "cross.case.fill"),
                Project(name: "AFL", path: "\(clientsPath)/AFL", icon: "building.columns.fill"),
                Project(name: "Citadel", path: "\(clientsPath)/Citadel", icon: "car.fill"),
                Project(name: "INFAB", path: "\(clientsPath)/INFAB", icon: "shield.fill"),
                Project(name: "MAGicALL", path: "\(clientsPath)/MAGicALL", icon: "airplane"),
                Project(name: "TDS", path: "\(clientsPath)/TDS", icon: "eye.fill")
            ]
        }

        // Dev projects (always this, not persisted - path is machine-specific)
        devProjects = [
            Project(name: "ClaudeHub", path: "\(NSHomeDirectory())/Code/claudehub", icon: "hammer.fill")
        ]
    }

    private func saveProjects() {
        let saved = SavedProjectsFile(
            main: mainProjects.map { SavedProject(from: $0) },
            clients: clientProjects.map { SavedProject(from: $0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(saved) {
            try? data.write(to: projectsFilePath)
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

// Container for saving both project lists
struct SavedProjectsFile: Codable {
    let main: [SavedProject]
    let clients: [SavedProject]
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
        .background(WindowResizer(scale: appState.uiScale))
    }
}

/// Helper to resize the window when scale changes
struct WindowResizer: NSViewRepresentable {
    let scale: CGFloat

    private static let baseWidth: CGFloat = 1100
    private static let baseHeight: CGFloat = 700

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.resizeWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.resizeWindow(nsView.window)
        }
    }

    private func resizeWindow(_ window: NSWindow?) {
        guard let window = window else { return }

        let newWidth = Self.baseWidth * scale
        let newHeight = Self.baseHeight * scale

        // Get current frame and screen
        var frame = window.frame
        guard let screen = window.screen else { return }

        // Calculate new frame, keeping top-left corner in place
        let oldMaxY = frame.maxY
        frame.size.width = newWidth
        frame.size.height = newHeight
        frame.origin.y = oldMaxY - newHeight  // Keep top edge fixed

        // Ensure window stays on screen
        let visibleFrame = screen.visibleFrame
        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
        }
        if frame.origin.x < visibleFrame.origin.x {
            frame.origin.x = visibleFrame.origin.x
        }
        if frame.origin.y < visibleFrame.origin.y {
            frame.origin.y = visibleFrame.origin.y
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - frame.height
        }

        // Animate the resize
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().setFrame(frame, display: true)
        }
    }
}
