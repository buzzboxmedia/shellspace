import SwiftUI
import SwiftData
import os.log

private let appLogger = Logger(subsystem: "com.buzzbox.shellspace", category: "AppState")

// MARK: - Notification Names
extension Notification.Name {
    static let toggleDictation = Notification.Name("toggleDictation")
    static let sendDictationToTerminal = Notification.Name("sendDictationToTerminal")
}

/// Per-window state - each window gets its own instance
class WindowState: ObservableObject {
    @Published var selectedProject: Project?
    @Published var activeSession: Session?
    @Published var isEditingTextField: Bool = false  // Prevents terminal from stealing focus
    var userTappedSession: Bool = false  // Only launch terminal on explicit tap
}

@main
struct ShellspaceApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let remoteServer = RemoteServer()
    private let relayClient = RelayClient()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Project.self,
            Session.self,
            ProjectGroup.self
        ])

        // Local storage only (CloudKit requires paid Apple Developer account)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            WindowContainer()
                .environmentObject(appState)
                .onAppear {
                    DebugLog.clear()
                    DebugLog.log("[App] Shellspace launched")

                    // Make sure app is active when window appears
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    // Give AppDelegate access to appState for cleanup on quit
                    appDelegate.appState = appState

                    // One-time migration: flip all existing projects to embedded terminal
                    if !UserDefaults.standard.bool(forKey: "migratedToEmbeddedTerminal") {
                        let descriptor = FetchDescriptor<Project>()
                        if let projects = try? sharedModelContainer.mainContext.fetch(descriptor) {
                            for project in projects {
                                project.usesExternalTerminal = false
                            }
                            try? sharedModelContainer.mainContext.save()
                        }
                        UserDefaults.standard.set(true, forKey: "migratedToEmbeddedTerminal")
                    }

                    // One-time migration: Solidify auto-detected projects as real database entries
                    // This is for App Store readiness - no more auto-detection, only persisted projects
                    if !UserDefaults.standard.bool(forKey: "migratedToPersistedProjects") {
                        ProjectMigration.solidifyProjects(in: sharedModelContainer.mainContext)
                        UserDefaults.standard.set(true, forKey: "migratedToPersistedProjects")
                    }

                    // One-time migration: Deduplicate projects that share the same path
                    if !UserDefaults.standard.bool(forKey: "deduplicatedProjectsByPath") {
                        ProjectMigration.deduplicateByPath(in: sharedModelContainer.mainContext)
                        UserDefaults.standard.set(true, forKey: "deduplicatedProjectsByPath")
                    }

                    // Import projects from Dropbox (before session sync)
                    ProjectSyncService.shared.importProjects(into: sharedModelContainer.mainContext)

                    // Enable session sync
                    SessionSyncService.shared.isEnabled = true

                    // Start remote access for iOS companion app
                    if RelayAuth.shared.isRelayMode && RelayAuth.shared.isAuthenticated {
                        relayClient.connect(appState: appState, modelContainer: sharedModelContainer)
                        DebugLog.log("[App] Started relay client (outbound WebSocket)")
                    } else {
                        remoteServer.start(appState: appState, modelContainer: sharedModelContainer)
                        DebugLog.log("[App] Started local server (Hummingbird on port 8847)")
                    }

                    // Heavy sync operations - run on background context to avoid @Query avalanche
                    let container = sharedModelContainer
                    Task.detached {
                        let backgroundContext = ModelContext(container)
                        SessionSyncService.shared.importAllSessions(modelContext: backgroundContext)
                        try? backgroundContext.save()

                        // Clear stale waiting-for-input flags AFTER import completes
                        // (import background context may have written stale true values back)
                        await MainActor.run {
                            DebugLog.log("[App] Session import done")
                            let waitingDescriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.isWaitingForInput == true })
                            if let staleSessions = try? container.mainContext.fetch(waitingDescriptor) {
                                for session in staleSessions {
                                    session.isWaitingForInput = false
                                }
                                if !staleSessions.isEmpty {
                                    try? container.mainContext.save()
                                    DebugLog.log("[App] Cleared \(staleSessions.count) stale waiting-for-input flags (post-import)")
                                }
                            }
                            ProjectSyncService.shared.exportProjects(from: container.mainContext)
                            DebugLog.log("[App] Startup complete")
                        }
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .windowResizability(.contentMinSize)
        .commands {
            // Note: Cmd+N now opens a new independent window (default WindowGroup behavior)
            // Navigation
            CommandGroup(after: .sidebar) {
                // Escape to go back is handled per-window in WorkspaceView
            }
            // Let SwiftTerm handle copy/paste natively via standard responder chain
            // (Don't override pasteboard commands - they break terminal copy/paste)

        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var localHotkeyMonitor: Any?
    private var globalHotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure app can become active
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Local hotkeys (when Shellspace is focused)
        // R-S-X flow: Record → Send → eXit
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.option) else { return event }
            // Option+R: start/stop recording
            if event.keyCode == 15 {
                Self.handleDictationToggle()
                return nil
            }
            // Option+S: send transcript to terminal
            if event.keyCode == 1 {
                SpeechService.shared.pasteTranscript()
                return nil
            }
            // Option+X: clear/cancel transcript
            if event.keyCode == 7 {
                SpeechService.shared.clearTranscript()
                return nil
            }
            return event
        }

        // Global hotkeys (when Shellspace is NOT focused — requires Accessibility permission)
        // R-S-X flow: Record → Send → eXit
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.option) else { return }
            // Option+R: toggle recording from anywhere
            if event.keyCode == 15 {
                Self.handleDictationToggle()
            }
            // Option+S: send transcript from anywhere
            if event.keyCode == 1 {
                DispatchQueue.main.async {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                SpeechService.shared.pasteTranscript()
            }
            // Option+X: clear transcript from anywhere
            if event.keyCode == 7 {
                SpeechService.shared.clearTranscript()
            }
        }
    }

    /// Toggle dictation and bring Shellspace to front if starting
    private static func handleDictationToggle() {
        let wasListening = SpeechService.shared.isListening
        SpeechService.shared.toggleListening()

        // If we just started listening from the background, bring Shellspace forward
        if !wasListening {
            DispatchQueue.main.async {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
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

        // Export all sessions to Dropbox (if sync is enabled)
        // Note: We don't have direct access to modelContainer here, so we'll need to pass it
        // For now, this will be handled by the sync hooks on session operations
        appLogger.info("App terminating - session sync handled by operation hooks")
    }
}

/// Simplified AppState - SwiftData handles persistence, this handles local-only state
class AppState: ObservableObject {
    // MARK: - Local-only state (not synced to CloudKit)

    /// Session IDs that have been launched in Terminal.app (not synced)
    @Published var launchedSessions: Set<UUID> = []

    /// Terminal controllers by session ID (for embedded SwiftTerm)
    @Published var terminalControllers: [UUID: TerminalController] = [:]

    /// Sessions that need attention (Claude finished outputting while not viewing)
    @Published var sessionsNeedingAttention: Set<UUID> = []

    /// Relay connection status (for UI indicator)
    @Published var relayConnectionState: RelayClient.ConnectionState = .disconnected

    /// Per-window states keyed by window ID
    private var windowStates: [UUID: WindowState] = [:]

    // MARK: - Window Management

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

    // MARK: - Terminal Controllers (for embedded SwiftTerm)

    func getOrCreateController(for session: Session) -> TerminalController {
        if let existing = terminalControllers[session.id] {
            return existing
        }
        let controller = TerminalController()
        terminalControllers[session.id] = controller
        return controller
    }

    func removeController(for session: Session) {
        if let controller = terminalControllers.removeValue(forKey: session.id) {
            controller.stopIdleDetection()
        }
    }

    // MARK: - Session Launch Tracking

    func markSessionLaunched(_ session: Session) {
        launchedSessions.insert(session.id)
    }

    func isSessionLaunched(_ session: Session) -> Bool {
        launchedSessions.contains(session.id)
    }

    // MARK: - Attention Tracking

    func markSessionNeedsAttention(_ sessionId: UUID) {
        DispatchQueue.main.async {
            self.sessionsNeedingAttention.insert(sessionId)
        }
    }

    func clearSessionAttention(_ sessionId: UUID) {
        DispatchQueue.main.async {
            self.sessionsNeedingAttention.remove(sessionId)
        }
    }

    func sessionNeedsAttention(_ sessionId: UUID) -> Bool {
        sessionsNeedingAttention.contains(sessionId)
    }

    // MARK: - Log Management

    func saveAllActiveLogs() {
        // With Terminal.app approach, logs are managed by Claude CLI directly
        // Session content is read from ~/.claude/projects/
        appLogger.info("Session logs are managed by Claude CLI")
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
}

/// Each window gets its own WindowContainer with independent WindowState
struct WindowContainer: View {
    @EnvironmentObject var appState: AppState
    @State private var windowId = UUID()
    @StateObject private var windowState = WindowState()

    var body: some View {
        WindowContent()
            .environmentObject(windowState)
            .frame(minWidth: 520, minHeight: 500)
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
    @Query private var allProjects: [Project]

    var body: some View {
        HStack(spacing: 0) {
            NavigationRailView()

            if let project = windowState.selectedProject {
                WorkspaceView(project: project)
                    .id(project.path)
            } else {
                LauncherView()
            }
        }
        .background {
            // Clear activeSession when switching between projects (nav rail)
            // This ensures the new WorkspaceView starts fresh
            WindowContent.projectSwitchHandler(windowState: windowState)
        }
        .onAppear {
            // Restore last-used project on launch
            if windowState.selectedProject == nil,
               let lastPath = UserDefaults.standard.string(forKey: "lastSelectedProjectPath") {
                restoreProject(from: lastPath)
            }
        }
    }

    private func restoreProject(from path: String) {
        // Only restore if folder exists
        guard FileManager.default.fileExists(atPath: path) else { return }

        // Look up the persisted project from the database
        if let project = allProjects.first(where: { $0.path == path }) {
            windowState.selectedProject = project
        }
    }
}

extension WindowContent {
    /// When switching between projects (not to/from dashboard), clear activeSession
    /// so the new WorkspaceView starts fresh and restores the correct session.
    @ViewBuilder
    static func projectSwitchHandler(windowState: WindowState) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: windowState.selectedProject?.path) { oldPath, newPath in
                guard let oldPath, let newPath, oldPath != newPath else { return }
                DebugLog.log("[WindowContent] Project switch: \(oldPath) -> \(newPath) — clearing activeSession")
                windowState.activeSession = nil
            }
    }
}

// MARK: - Empty Project View

struct EmptyProjectView: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "arrow.left.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)

                Text("Select a project")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Text("Choose a project from the sidebar to get started")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Project Migration (App Store Readiness)

/// One-time migration to solidify auto-detected projects as real database entries.
/// After this runs, the app only shows persisted projects (no auto-detection).
enum ProjectMigration {
    static func solidifyProjects(in context: ModelContext) {
        // Determine Dropbox path
        let newPath = NSString("~/Library/CloudStorage/Dropbox").expandingTildeInPath
        let legacyPath = NSString("~/Dropbox").expandingTildeInPath
        let dropboxPath = FileManager.default.fileExists(atPath: newPath) ? newPath : legacyPath

        // Fetch existing projects to avoid duplicates
        let descriptor = FetchDescriptor<Project>()
        let existingProjects = (try? context.fetch(descriptor)) ?? []
        let existingPaths = Set(existingProjects.map { $0.path })

        // Main projects to solidify
        let mainProjects: [(name: String, path: String, icon: String)] = [
            ("Miller", "\(dropboxPath)/Miller", "person.fill"),
            ("Talkspresso", "\(dropboxPath)/Talkspresso", "cup.and.saucer.fill"),
            ("Buzzbox", "\(dropboxPath)/Buzzbox", "shippingbox.fill"),
            ("Shellspace", "\(dropboxPath)/Shellspace", "fossil.shell.fill")
        ]

        // Client icon mapping
        let clientIcons: [String: String] = [
            "AAGL": "cross.case.fill",
            "AFL": "building.columns.fill",
            "INFAB": "shield.fill",
            "TDS": "eye.fill",
            "Bassi": "b.circle.fill",
            "CDW": "c.circle.fill",
            "Citadel": "building.2.fill",
            "MAGicALL": "wand.and.stars",
            "RICO": "r.circle.fill"
        ]

        // Add main projects that exist on disk and aren't already in database
        for item in mainProjects {
            guard FileManager.default.fileExists(atPath: item.path),
                  !existingPaths.contains(item.path) else { continue }

            let project = Project(
                name: item.name,
                path: item.path,
                icon: item.icon,
                category: .main
            )
            context.insert(project)
            appLogger.info("Solidified project: \(item.name)")
        }

        // Scan Clients folder and add each client
        let clientsPath = "\(dropboxPath)/Buzzbox/Clients"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: clientsPath) {
            for name in contents {
                let path = "\(clientsPath)/\(name)"
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                      isDir.boolValue,
                      !name.hasPrefix("."),
                      !existingPaths.contains(path) else { continue }

                let icon = clientIcons[name] ?? "folder.fill"
                let project = Project(
                    name: name,
                    path: path,
                    icon: icon,
                    category: .client
                )
                context.insert(project)
                appLogger.info("Solidified client: \(name)")
            }
        }

        try? context.save()
        appLogger.info("Project migration complete - all projects now persisted")
    }

    /// Remove duplicate projects that share the same path, keeping the one with the most sessions
    static func deduplicateByPath(in context: ModelContext) {
        let descriptor = FetchDescriptor<Project>()
        guard let allProjects = try? context.fetch(descriptor) else { return }

        // Group by path
        var byPath: [String: [Project]] = [:]
        for project in allProjects {
            byPath[project.path, default: []].append(project)
        }

        var removed = 0
        for (path, projects) in byPath where projects.count > 1 {
            // Keep the project with the most sessions
            let sorted = projects.sorted { $0.sessions.count > $1.sessions.count }
            let keeper = sorted[0]
            let duplicates = sorted.dropFirst()

            for dup in duplicates {
                // Reassign sessions to keeper
                for session in dup.sessions {
                    session.project = keeper
                }
                // Reassign task groups to keeper
                for group in dup.taskGroups {
                    group.project = keeper
                }
                context.delete(dup)
                removed += 1
                appLogger.info("Removed duplicate project '\(dup.name)' at \(path)")
            }
        }

        if removed > 0 {
            try? context.save()
        }
        appLogger.info("Dedup complete: removed \(removed) duplicate projects")
    }
}
