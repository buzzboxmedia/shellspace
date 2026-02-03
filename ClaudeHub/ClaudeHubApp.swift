import SwiftUI
import SwiftData
import os.log

private let appLogger = Logger(subsystem: "com.buzzbox.claudehub", category: "AppState")

// MARK: - Notification Names
extension Notification.Name {
    static let toggleDictation = Notification.Name("toggleDictation")
}

/// Per-window state - each window gets its own instance
class WindowState: ObservableObject {
    @Published var selectedProject: Project?
    @Published var activeSession: Session?
    @Published var isEditingTextField: Bool = false  // Prevents terminal from stealing focus
}

@main
struct ClaudeHubApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
                    // Make sure app is active when window appears
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    // Give AppDelegate access to appState for cleanup on quit
                    appDelegate.appState = appState

                    // Enable session sync
                    SessionSyncService.shared.isEnabled = true

                    // Import sessions from Dropbox (if sync is enabled)
                    SessionSyncService.shared.importAllSessions(modelContext: sharedModelContainer.mainContext)
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
    private var hotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure app can become active
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Global hotkey for voice dictation: Ctrl+Shift+Space
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ctrl+Shift+Space
            if event.modifierFlags.contains([.control, .shift]) && event.keyCode == 49 {
                NotificationCenter.default.post(name: .toggleDictation, object: nil)
                return nil
            }
            return event
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
@Observable
class AppState: ObservableObject {
    // MARK: - Local-only state (not synced to CloudKit)

    /// Session IDs that have been launched in Terminal.app (not synced)
    var launchedSessions: Set<UUID> = []

    /// Terminal controllers by session ID (for embedded SwiftTerm)
    var terminalControllers: [UUID: TerminalController] = [:]

    /// Sessions that need attention (Claude finished outputting while not viewing)
    var sessionsNeedingAttention: Set<UUID> = []

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
        appLogger.info("getOrCreateController for session: \(session.name) id: \(session.id)")
        appLogger.info("DEBUG: terminalControllers count: \(self.terminalControllers.count), keys: \(self.terminalControllers.keys.map { $0.uuidString })")
        if let existing = terminalControllers[session.id] {
            appLogger.info("DEBUG: Found existing controller for session \(session.id)")
            return existing
        }
        appLogger.info("DEBUG: Creating NEW controller for session \(session.id)")
        let controller = TerminalController()
        terminalControllers[session.id] = controller
        return controller
    }

    func removeController(for session: Session) {
        terminalControllers.removeValue(forKey: session.id)
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
        HStack(spacing: 0) {
            NavigationRailView()

            if let project = windowState.selectedProject {
                WorkspaceView(project: project)
            } else {
                EmptyProjectView()
            }
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
        // Determine project details from path
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let category: ProjectCategory = path.contains("/Clients/") ? .client : .main

        // Determine icon based on known projects
        let icon: String
        switch name {
        case "Miller": icon = "person.fill"
        case "Talkspresso": icon = "cup.and.saucer.fill"
        case "Buzzbox": icon = "shippingbox.fill"
        case "AAGL": icon = "cross.case.fill"
        case "AFL": icon = "building.columns.fill"
        case "INFAB": icon = "shield.fill"
        case "TDS": icon = "eye.fill"
        case "ClaudeHub", "Claude Hub": icon = "terminal.fill"
        default: icon = "folder.fill"
        }

        // Only restore if folder exists
        guard FileManager.default.fileExists(atPath: path) else { return }

        let project = Project(name: name, path: path, icon: icon, category: category)
        if name == "Claude Hub" || name == "ClaudeHub" {
            project.usesExternalTerminal = true
        }

        windowState.selectedProject = project
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
