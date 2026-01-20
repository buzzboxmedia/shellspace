import SwiftUI
import SwiftData
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
                    // Start Tailscale server for iOS companion app
                    TailscaleServer.shared.start(appState: appState)
                }
                .task {
                    // Run migration on first launch
                    let context = sharedModelContainer.mainContext
                    DataMigration.migrateIfNeeded(modelContext: context)
                    // Clean up any duplicate projects
                    DataMigration.deduplicateProjectsIfNeeded(modelContext: context)
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

/// Simplified AppState - SwiftData handles persistence, this handles local-only state
@Observable
class AppState: ObservableObject {
    // MARK: - Local-only state (not synced to CloudKit)

    /// Track which sessions are waiting for user input
    var waitingSessions: Set<UUID> = []

    /// Track which sessions have Claude actively working (outputting text)
    var workingSessions: Set<UUID> = []

    /// Terminal controllers by session ID (not synced - recreated per device)
    var terminalControllers: [UUID: TerminalController] = [:]

    /// Per-window states keyed by window ID
    private var windowStates: [UUID: WindowState] = [:]

    // Services for active project detection
    private let activeProjectsParser = ActiveProjectsParser()
    private let briefingGenerator = ParkerBriefingGenerator()

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

    // MARK: - Terminal Controllers

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

    // MARK: - Waiting State Management

    func markSessionWaiting(_ session: Session, projectName: String) {
        guard !waitingSessions.contains(session.id) else { return }
        waitingSessions.insert(session.id)
        appLogger.info("Session marked as waiting: \(session.name)")

        // Update session's waiting state (syncs to CloudKit for mobile notifications)
        session.isWaitingForInput = true

        NotificationManager.shared.notifyClaudeWaiting(
            sessionId: session.id,
            sessionName: session.name,
            projectName: projectName
        )
        NotificationManager.shared.updateDockBadge(count: waitingSessions.count)
    }

    func clearSessionWaiting(_ session: Session) {
        guard waitingSessions.contains(session.id) else { return }
        waitingSessions.remove(session.id)
        appLogger.info("Session no longer waiting: \(session.name)")

        // Update session's waiting state
        session.isWaitingForInput = false

        NotificationManager.shared.clearNotification(for: session.id)
        NotificationManager.shared.updateDockBadge(count: waitingSessions.count)
    }

    // MARK: - Working State Management

    func markSessionWorking(_ session: Session) {
        guard !workingSessions.contains(session.id) else { return }
        workingSessions.insert(session.id)
        // Clear waiting state when Claude starts working
        clearSessionWaiting(session)
    }

    func clearSessionWorking(_ session: Session) {
        workingSessions.remove(session.id)
    }

    // MARK: - Log Management

    func saveAllActiveLogs() {
        for (_, controller) in terminalControllers {
            // TerminalController stores its current session
            if let session = controller.currentSession {
                controller.saveLog(for: session)
            }
        }
        appLogger.info("Saved logs for all active sessions")
    }

    // MARK: - Active Projects (ACTIVE-PROJECTS.md parsing)

    func parseActiveProjects(at projectPath: String) -> [ActiveProject] {
        activeProjectsParser.parseActiveProjects(at: projectPath)
    }

    func generateBriefing(for activeProject: ActiveProject, clientName: String) -> String {
        briefingGenerator.generateBriefing(for: activeProject, clientName: clientName)
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
        Group {
            if let project = windowState.selectedProject {
                WorkspaceView(project: project)
            } else {
                LauncherView()
            }
        }
    }
}
