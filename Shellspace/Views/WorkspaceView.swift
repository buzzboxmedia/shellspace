import SwiftUI
import SwiftData

struct WorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project

    // Query sessions by projectPath - works even for non-persisted projects
    @Query private var allSessions: [Session]

    // Track when this workspace was opened (for unsaved progress check)
    @State private var workspaceOpenedAt: Date = Date()
    @State private var showUnsavedAlert = false
    @State private var pendingCloseSession: Session?
    @State private var isSummarizingBeforeClose = false
    @State private var previousSessionId: UUID?
    @State private var launchedExternalSessions: Set<UUID> = []

    // Filter sessions by project path (canonical comparison handles symlink differences)
    var sessions: [Session] {
        let canonicalProjectPath = project.path.canonicalPath
        return allSessions.filter { $0.projectPath == canonicalProjectPath || $0.projectPath == project.path }
    }

    /// Check if the active session has unsaved progress (no note saved since opening)
    func hasUnsavedProgress(for session: Session?) -> Bool {
        guard let session = session else { return false }

        // If no task folder, nothing to save to
        guard session.taskFolderPath != nil else { return false }

        // Check if progress was saved after the workspace was opened
        if let lastSaved = session.lastProgressSavedAt {
            return lastSaved < workspaceOpenedAt
        }

        // No progress saved ever - only prompt if session was created before this workspace opened
        return session.createdAt < workspaceOpenedAt
    }

    func goBack() {
        // Just go back - let Claude sessions keep running in background
        performGoBack()
    }

    private func performGoBack() {
        withAnimation(.spring(response: 0.3)) {
            windowState.selectedProject = nil
            windowState.activeSession = nil
        }
    }

    private func summarizeAndClose(session: Session) {
        guard session.taskFolderPath != nil else {
            performGoBack()
            return
        }

        isSummarizingBeforeClose = true

        // Get terminal controller and ask Claude to summarize
        let controller = appState.getOrCreateController(for: session)

        // Send prompt to Claude asking it to update TASK.md
        let prompt = "Please add a brief 1-2 sentence summary of what we accomplished to the Progress section of TASK.md (append with today's date as ### heading). Just update the file, no need to show me the contents.\n"
        controller.sendToTerminal(prompt)

        // Wait for Claude to process, then close
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.isSummarizingBeforeClose = false
            self.performGoBack()
        }
    }

    var body: some View {
        HSplitView {
            SessionSidebar(project: project)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)

            // Terminal pane - shows embedded SwiftTerm when a session is active
            let _ = DebugLog.log("[WorkspaceView] body: project=\(project.name), activeSession=\(windowState.activeSession?.name ?? "NIL"), hasBeenLaunched=\(windowState.activeSession?.hasBeenLaunched == true)")
            if let activeSession = windowState.activeSession, activeSession.hasBeenLaunched {
                TerminalView(session: activeSession)
                    .id(activeSession.id)  // Force new view identity per session — prevents @State leaking across session switches
                    .frame(minWidth: 400)
            } else {
                // Empty state when no session is launched
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a task to start a session")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.11, alpha: 1.0)))
            }
        }
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
        .onAppear {
            DebugLog.log("[WorkspaceView] onAppear: project=\(project.name), sessions=\(sessions.count), activeSession=\(windowState.activeSession?.name ?? "NIL")")

            workspaceOpenedAt = Date()
            launchedExternalSessions = Set(sessions.filter { $0.hasBeenLaunched }.map { $0.id })

            // Restore last active session
            restoreLastSession()

            // Import task folders in background
            Task.detached(priority: .background) {
                _ = await MainActor.run {
                    TaskImportService.shared.importTasks(for: project, modelContext: modelContext)
                }
            }
        }
        // Backup: .task(id:) fires reliably even when onAppear doesn't (SwiftUI .id() changes)
        .task(id: project.path) {
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms — let onAppear run first
            await MainActor.run {
                DebugLog.log("[WorkspaceView] .task(id:) backup: project=\(project.name), activeSession=\(windowState.activeSession?.name ?? "NIL")")
                if windowState.activeSession == nil {
                    DebugLog.log("[WorkspaceView]   backup restoring — activeSession is nil")
                    restoreLastSession()
                } else {
                    let belongs = sessions.contains { $0.id == windowState.activeSession?.id }
                    if !belongs {
                        DebugLog.log("[WorkspaceView]   backup restoring — activeSession wrong project")
                        restoreLastSession()
                    }
                }
            }
        }
        .onChange(of: sessions.count) { oldCount, newCount in
            if oldCount == 0 && newCount > 0 && windowState.activeSession == nil {
                DebugLog.log("[WorkspaceView] sessions populated (\(newCount)) — restoring")
                restoreLastSession()
            }
        }
        .onChange(of: windowState.activeSession) { oldSession, newSession in
            DebugLog.log("[WorkspaceView] activeSession changed: '\(oldSession?.name ?? "NIL")' -> '\(newSession?.name ?? "NIL")' (project: \(project.name))")
            if let newSession = newSession {
                // Only save if this session belongs to THIS project — prevents cross-contamination when switching projects
                guard sessions.contains(where: { $0.id == newSession.id }) else {
                    DebugLog.log("[WorkspaceView]   SKIP save — session '\(newSession.name)' doesn't belong to project '\(project.name)'")
                    return
                }
                UserDefaults.standard.set(newSession.id.uuidString, forKey: "lastSession:\(project.path)")
                if !newSession.hasBeenLaunched {
                    DebugLog.log("[WorkspaceView]   launching session: \(newSession.name)")
                    launchSessionInTerminal(newSession)
                }
                windowState.userTappedSession = false
            }
        }
        .onChange(of: project.path) { oldPath, newPath in
            if oldPath != newPath {
                DebugLog.log("[WorkspaceView] project.path changed: \(oldPath) -> \(newPath)")
                restoreLastSession()
            }
        }
        // Safety net: when selectedProject changes, ensure we restore if activeSession is nil
        .onChange(of: windowState.selectedProject?.path) { _, newPath in
            DebugLog.log("[WorkspaceView] selectedProject.path changed to '\(newPath ?? "NIL")' (this view: \(project.name), activeSession: \(windowState.activeSession?.name ?? "NIL"))")
            if newPath == project.path && windowState.activeSession == nil {
                DebugLog.log("[WorkspaceView]   Safety net: restoring for \(project.name)")
                restoreLastSession()
            }
        }
        .onDisappear {
            // Remember last active session for next time — but only if it belongs to THIS project
            if let activeSession = windowState.activeSession,
               sessions.contains(where: { $0.id == activeSession.id }) {
                project.lastActiveSessionId = activeSession.id
                UserDefaults.standard.set(activeSession.id.uuidString, forKey: "lastSession:\(project.path)")
            }
        }
        .alert("Summarize before leaving?", isPresented: $showUnsavedAlert) {
            Button("Don't Save") {
                performGoBack()
            }
            Button("Summarize & Close") {
                if let session = pendingCloseSession {
                    summarizeAndClose(session: session)
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let session = pendingCloseSession {
                Text("Save an AI summary for \"\(session.name)\" before closing?")
            }
        }
        .overlay {
            if isSummarizingBeforeClose {
                ZStack {
                    Color.black.opacity(0.5)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Summarizing...")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Session Restoration

    /// Restore the last active session from UserDefaults
    private func restoreLastSession() {
        DebugLog.log("[restore] project=\(project.name), sessions=\(sessions.count), activeSession=\(windowState.activeSession?.name ?? "NIL")")

        // Check if current activeSession belongs to this project
        let currentSessionBelongsToProject = windowState.activeSession.map { session in
            sessions.contains { $0.id == session.id }
        } ?? false

        guard !currentSessionBelongsToProject else {
            DebugLog.log("[restore]   activeSession already belongs — skipping")
            return
        }

        // Only consider visible (non-hidden, non-completed) sessions for restore
        let visibleSessions = sessions.filter { !$0.isHidden && !$0.isCompleted }
        DebugLog.log("[restore]   visibleSessions=\(visibleSessions.count)")

        if visibleSessions.isEmpty {
            DebugLog.log("[restore]   No visible sessions — creating root session")
            let rootSession = Session(
                name: project.name,
                projectPath: project.path,
                userNamed: false
            )
            rootSession.project = project
            modelContext.insert(rootSession)

            launchSessionInTerminal(rootSession)
            windowState.activeSession = rootSession
            DebugLog.log("[restore]   Created & activated root: \(rootSession.name)")
        } else {
            let savedKey = "lastSession:\(project.path)"
            let savedString = UserDefaults.standard.string(forKey: savedKey)
            let lastId = savedString.flatMap { UUID(uuidString: $0) }
            DebugLog.log("[restore]   savedKey=\(savedKey)")
            DebugLog.log("[restore]   savedUUID=\(savedString ?? "NIL")")
            DebugLog.log("[restore]   visibleIDs=\(visibleSessions.map { "\($0.name):\($0.id.uuidString)" }.joined(separator: ", "))")

            let restoredSession: Session?
            if let lastId = lastId,
               let lastSession = visibleSessions.first(where: { $0.id == lastId }) {
                restoredSession = lastSession
                DebugLog.log("[restore]   Found saved session: \(lastSession.name)")
            } else {
                restoredSession = visibleSessions.first
                DebugLog.log("[restore]   Fallback to first visible: \(visibleSessions.first?.name ?? "NIL")")
            }

            if let session = restoredSession {
                DebugLog.log("[restore]   Launching: \(session.name) (hasBeenLaunched=\(session.hasBeenLaunched))")
                launchSessionInTerminal(session)
                windowState.activeSession = session
                DebugLog.log("[restore]   DONE — activeSession=\(session.name)")
            }
        }
    }

    // MARK: - Terminal Launch

    /// Launch a session in external Terminal.app with proper flags
    private func launchSessionInTerminal(_ session: Session) {
        DebugLog.log("[launch] \(session.name) — hasBeenLaunched was \(session.hasBeenLaunched), setting to true")
        session.hasBeenLaunched = true
        session.lastAccessedAt = Date()
        launchedExternalSessions.insert(session.id)
    }

    // MARK: - Terminal Activation

    private func activateTerminal() {
        // Terminal is embedded via SwiftTerm - just ensure the window is focused
        if let window = NSApplication.shared.keyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Data Operations

    func createSession(name: String?, inGroup group: ProjectGroup?) -> Session {
        let taskName: String
        let isUserNamed: Bool

        if let name = name, !name.isEmpty {
            taskName = name
            isUserNamed = true
        } else {
            let existingCount = sessions.filter { !$0.isProjectLinked }.count
            taskName = "Task \(existingCount + 1)"
            isUserNamed = false
        }

        let session = Session(
            name: taskName,
            projectPath: project.path,
            userNamed: isUserNamed
        )
        session.project = project
        session.taskGroup = group
        modelContext.insert(session)

        // Export to Dropbox (if sync enabled)
        SessionSyncService.shared.exportSession(session)

        return session
    }
}

struct SessionSidebar: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project
    @Query private var allSessions: [Session]
    @Query private var allProjects: [Project]
    @Query private var allProjectGroups: [ProjectGroup]
    @State private var isCreatingTask = false
    @State private var isCreatingGroup = false
    @State private var newTaskName = ""
    @State private var newGroupName = ""
    @State private var selectedGroupForNewTask: ProjectGroup?
    @State private var draggedGroupId: UUID?
    @State private var isCompletedExpanded: Bool = false
    @State private var showTaskList: Bool = false
    @State private var showingAddTaskSheet = false
    @FocusState private var isTaskFieldFocused: Bool
    @FocusState private var isGroupFieldFocused: Bool

    /// Find the persisted project with matching path (for relationships)
    var persistedProject: Project? {
        allProjects.first { $0.path == project.path }
    }

    /// The project to use - don't auto-persist, just use the passed-in one
    var effectiveProject: Project {
        // Return persisted if exists, otherwise just use the passed-in project
        // Don't auto-insert to avoid creating duplicates
        persistedProject ?? project
    }

    var sessions: [Session] {
        let canonicalProjectPath = project.path.canonicalPath
        return allSessions.filter { $0.projectPath == canonicalProjectPath || $0.projectPath == project.path }
    }

    var activeSessions: [Session] {
        sessions.filter { !$0.isCompleted && !$0.isHidden }
    }

    var completedSessions: [Session] {
        sessions.filter { $0.isCompleted && !$0.isHidden }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var hiddenSessions: [Session] {
        sessions.filter { $0.isHidden }
    }

    var taskGroups: [ProjectGroup] {
        // Use persisted project's groups, or filter all groups by project path
        if let persisted = persistedProject {
            return persisted.taskGroups.sorted { $0.sortOrder < $1.sortOrder }
        }
        // Fallback: filter all groups by matching project path
        return allProjectGroups
            .filter { $0.project?.path == project.path }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var standaloneTasks: [Session] {
        activeSessions.filter { $0.taskGroup == nil }
    }

    func createTask() {
        let name = newTaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isCreatingTask = false
            newTaskName = ""
            selectedGroupForNewTask = nil
            return
        }

        // Check if a session with this name already exists (case-insensitive)
        if let existingSession = sessions.first(where: {
            $0.name.lowercased() == name.lowercased()
        }) {
            // Unhide if hidden
            if existingSession.isHidden {
                existingSession.isHidden = false
            }
            existingSession.lastAccessedAt = Date()
            showTaskList = true
            windowState.userTappedSession = true
            windowState.activeSession = existingSession
            SessionSyncService.shared.exportSession(existingSession)

            isCreatingTask = false
            newTaskName = ""
            selectedGroupForNewTask = nil
            return
        }

        // Create task folder path
        let subProjectName = selectedGroupForNewTask?.name
        let expectedPath = TaskFolderService.shared.taskFolderPath(
            projectPath: project.path,
            subProjectName: subProjectName,
            taskName: name
        )

        // Use the persisted project for relationships
        let targetProject = effectiveProject

        let session = Session(
            name: name,
            projectPath: project.path,
            userNamed: true
        )
        session.project = targetProject
        session.taskGroup = selectedGroupForNewTask
        session.taskFolderPath = expectedPath.path  // Set BEFORE insert to prevent duplicate imports

        // Create the directory immediately so startClaude() uses it as workingDir
        // instead of falling back to the project directory (which has old conversations).
        // The full TASK.md setup happens asynchronously below.
        try? FileManager.default.createDirectory(at: expectedPath, withIntermediateDirectories: true)

        modelContext.insert(session)
        try? modelContext.save()  // Ensure it's persisted before file watcher can trigger

        // Export to Dropbox (if sync enabled)
        SessionSyncService.shared.exportSession(session)

        selectedGroupForNewTask = nil
        showTaskList = true
        windowState.userTappedSession = true
        windowState.activeSession = session
        isCreatingTask = false
        newTaskName = ""
        isTaskFieldFocused = false  // Unfocus text field so terminal can take focus

        Task {
            do {
                let taskFolder = try TaskFolderService.shared.createTask(
                    projectPath: project.path,
                    projectName: project.name,
                    subProjectName: subProjectName,
                    taskName: name,
                    description: nil
                )
                // Verify path matches (it should)
                if taskFolder.path != expectedPath.path {
                    await MainActor.run {
                        session.taskFolderPath = taskFolder.path
                    }
                }
            } catch {
                print("Failed to create task folder: \(error)")
                // Clear the path since folder creation failed
                await MainActor.run {
                    session.taskFolderPath = nil
                }
            }
        }
    }

    private func launchQuickSession() {
        // Check if a root session already exists (no task folder, same name as project)
        let existingRoot = sessions.first { $0.taskFolderPath == nil && !$0.isCompleted && !$0.isHidden }

        let session: Session
        if let existing = existingRoot {
            // Reuse existing root session
            existing.lastAccessedAt = Date()
            existing.isHidden = false
            session = existing
        } else {
            // Create a new session with no task folder
            let newSession = Session(
                name: project.name,
                projectPath: project.path,
                userNamed: true
            )
            newSession.project = effectiveProject
            // No taskFolderPath - this opens in project root
            modelContext.insert(newSession)
            session = newSession
        }

        // Mark as launched - TerminalView will auto-start Claude via SwiftTerm
        session.hasBeenLaunched = true
        showTaskList = true
        windowState.activeSession = session
    }

    func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isCreatingGroup = false
            newGroupName = ""
            return
        }

        // Use the persisted project for relationships
        let targetProject = effectiveProject

        let maxOrder = taskGroups.map { $0.sortOrder }.max() ?? -1
        let group = ProjectGroup(name: name, projectPath: project.path, sortOrder: maxOrder + 1)
        group.project = targetProject
        modelContext.insert(group)

        // Create a session for the project itself (so it can be opened like a task)
        let session = Session(
            name: name,
            projectPath: project.path,
            userNamed: true
        )
        session.project = targetProject
        session.taskGroup = group
        session.sessionDescription = "Project folder for organizing related tasks."
        modelContext.insert(session)

        // Persist immediately to prevent race conditions with validateFilesystem
        try? modelContext.save()

        // Export to Dropbox (if sync enabled)
        SessionSyncService.shared.exportSession(session)

        isCreatingGroup = false
        newGroupName = ""

        // Create sub-project folder with TASK.md and CLAUDE.md
        Task {
            do {
                let projectFolder = try TaskFolderService.shared.createProject(
                    projectPath: project.path,
                    projectName: name,
                    clientName: project.name,
                    description: nil
                )
                // Link session to project folder and make it active
                await MainActor.run {
                    session.taskFolderPath = projectFolder.path
                    windowState.activeSession = session
                }
            } catch {
                print("Failed to create project folder: \(error)")
            }
        }
    }

    func handleTasksDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { reading, _ in
                    if let idString = reading as? String {
                        // Ignore group drags - only handle task drags
                        if idString.hasPrefix("group:") { return }

                        if let sessionId = UUID(uuidString: idString),
                           let session = sessions.first(where: { $0.id == sessionId }) {
                            DispatchQueue.main.async {
                                // Move folder on disk if task has a folder
                                if let currentPath = session.taskFolderPath {
                                    Task {
                                        do {
                                            try TaskFolderService.shared.moveTask(
                                                from: URL(fileURLWithPath: currentPath),
                                                toSubProject: nil,
                                                projectPath: project.path
                                            )
                                            // Update session with new path
                                            let taskSlug = URL(fileURLWithPath: currentPath).lastPathComponent
                                                .replacingOccurrences(of: "^\\d{3}-", with: "", options: .regularExpression)
                                            let newPath = TaskFolderService.shared.taskFolderPath(
                                                projectPath: project.path,
                                                subProjectName: nil,
                                                taskName: taskSlug
                                            )
                                            await MainActor.run {
                                                session.taskFolderPath = newPath.path
                                            }
                                        } catch {
                                            print("Failed to move task folder: \(error)")
                                        }
                                    }
                                }
                                session.taskGroup = nil
                            }
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                // Header row - fixed height
                HStack(spacing: 12) {
                    Image(systemName: project.icon)
                        .font(.system(size: 26))
                        .foregroundStyle(.primary)

                    Text(project.name)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Spacer()

                    // Quick launch - opens claude in project root (no task folder)
                    Button {
                        launchQuickSession()
                    } label: {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Open Claude in project root")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)

                Divider()

                // Task list - fills remaining space
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Task input with autocomplete
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                TextField("What are you working on?", text: $newTaskName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 16))
                                    .focused($isTaskFieldFocused)
                                    .onSubmit { createTask() }

                                Button {
                                    createTask()
                                } label: {
                                    Text("GO")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(newTaskName.isEmpty ? Color.gray : Color.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .disabled(newTaskName.isEmpty)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )

                            // Autocomplete suggestions
                            if !newTaskName.isEmpty {
                                let suggestions = sessions.filter {
                                    $0.name.lowercased().contains(newTaskName.lowercased())
                                }.prefix(5)

                                if !suggestions.isEmpty {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(Array(suggestions)) { session in
                                            Button {
                                                newTaskName = session.name
                                                createTask()
                                            } label: {
                                                HStack {
                                                    Text(session.name)
                                                        .font(.system(size: 14))
                                                        .foregroundStyle(.primary)
                                                    Spacer()
                                                    if session.isHidden {
                                                        Text("hidden")
                                                            .font(.system(size: 12))
                                                            .foregroundStyle(.tertiary)
                                                    }
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color.white.opacity(0.04))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        // Tasks list - show if user searched/clicked GO, or if any sessions are launched
                        if showTaskList || activeSessions.contains(where: { $0.hasBeenLaunched }) {
                            if activeSessions.isEmpty {
                                Text("No tasks yet")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .padding(.horizontal, 16)
                            } else {
                                LazyVStack(spacing: 4) {
                                    ForEach(activeSessions) { session in
                                        TaskRow(session: session, project: project)
                                    }
                                }
                            }
                        }

                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
        )
        .onChange(of: project.path) { _, _ in
            showTaskList = false
        }
    }
}

// MARK: - Project Group Section (collapsible)

struct ProjectGroupSection: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let group: ProjectGroup
    let project: Project
    let index: Int
    let totalGroups: Int
    @Query private var allSessions: [Session]
    @Binding var draggedGroupId: UUID?
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var isCreatingTask = false
    @State private var newTaskName = ""
    @State private var isDropTarget = false
    @FocusState private var isTaskFieldFocused: Bool

    /// All sessions for this project (by path)
    var projectSessions: [Session] {
        allSessions.filter { $0.projectPath == project.path }
    }

    /// Get tasks by folder path (more reliable than relationship)
    var tasks: [Session] {
        let groupFolderPath = TaskFolderService.shared.projectDirectory(
            projectPath: project.path,
            projectName: group.name
        ).path

        return projectSessions.filter { session in
            guard !session.isCompleted, !session.isHidden,
                  let path = session.taskFolderPath else { return false }
            // Task is in this group if its parent folder matches the group folder
            // AND it's not the project session itself
            let isInGroup = path.hasPrefix(groupFolderPath + "/")
            return isInGroup
        }
    }

    /// The session representing the project itself (not a sub-task)
    var projectSession: Session? {
        let expectedProjectPath = TaskFolderService.shared.projectDirectory(
            projectPath: project.path,
            projectName: group.name
        ).path
        return projectSessions.first { $0.taskFolderPath == expectedProjectPath }
    }

    /// Check if a session is the project session (its folder is the project folder, not a sub-task)
    private func isProjectSession(_ session: Session) -> Bool {
        guard let path = session.taskFolderPath else { return false }
        let expectedProjectPath = TaskFolderService.shared.projectDirectory(
            projectPath: project.path,
            projectName: group.name
        ).path
        return path == expectedProjectPath
    }

    var isDragging: Bool {
        draggedGroupId == group.id
    }

    var isProjectActive: Bool {
        guard let projectSession = projectSession else { return false }
        return windowState.activeSession?.id == projectSession.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Group header
            HStack(spacing: 8) {
                // Expand/collapse chevron
                Button {
                    group.isExpanded.toggle()
                } label: {
                    Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                // Folder icon + name - clickable to open project
                if isEditing {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.purple)

                        TextField("Project name", text: $editedName, onCommit: {
                            group.name = editedName
                            isEditing = false
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .medium))
                        .onExitCommand {
                            isEditing = false
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(isProjectActive ? .blue : .purple)
                            .fixedSize()

                        Text(group.name)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isProjectActive ? .blue : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .layoutPriority(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let session = projectSession {
                            windowState.activeSession = session
                        }
                    }
                }

                Spacer(minLength: 4)

                // Task count badge
                Text("\(tasks.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
                    .fixedSize()

                // Actions - only show when hovered to save space
                if isHovered {
                    HStack(spacing: 4) {
                    // Open project session in Terminal.app
                    if let projSession = projectSession {
                        Button {
                            let controller = appState.getOrCreateController(for: projSession)
                            let workingDir = projSession.taskFolderPath ?? projSession.projectPath
                            controller.popOutToTerminal(workingDir: workingDir)
                        } label: {
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open in Terminal.app")
                    }

                    // Add task to group
                    Button {
                        isCreatingTask = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14))
                            .foregroundStyle(.blue)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Edit name
                    Button {
                        editedName = group.name
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Delete group
                    Button {
                        deleteGroup()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDropTarget ? Color.purple.opacity(0.2) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isDropTarget ? Color.purple.opacity(0.5) : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .opacity(isDragging ? 0.5 : 1.0)
            .onTapGesture(count: 2) {
                editedName = group.name
                isEditing = true
            }
            .onTapGesture(count: 1) {
                group.isExpanded.toggle()
            }
            .onHover { isHovered = $0 }
            .onDrag {
                draggedGroupId = group.id
                return NSItemProvider(object: "group:\(group.id.uuidString)" as NSString)
            }
            .onDrop(of: [.text], isTargeted: $isDropTarget) { providers in
                handleGroupDrop(providers: providers)
            }
            .padding(.horizontal, 8)

            // New task input (inline)
            if isCreatingTask {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                        .foregroundStyle(.blue)

                    TextField("Task name...", text: $newTaskName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isTaskFieldFocused)
                        .onSubmit {
                            createTask()
                        }
                        .onExitCommand {
                            isCreatingTask = false
                            newTaskName = ""
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 32)
                .padding(.horizontal, 8)
                .onAppear { isTaskFieldFocused = true }
            }

            // Tasks in this group (indented)
            if group.isExpanded {
                LazyVStack(spacing: 2) {
                    ForEach(tasks) { session in
                        TaskRow(session: session, project: project, indented: true)
                    }
                }
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers: providers, toGroup: group)
        }
    }

    private func deleteGroup() {
        // Move all tasks in this group to standalone
        for session in group.sessions {
            session.taskGroup = nil
        }
        modelContext.delete(group)
    }

    private func handleDrop(providers: [NSItemProvider], toGroup: ProjectGroup?) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { reading, _ in
                    if let idString = reading as? String {
                        // Ignore group drags - only handle task drags
                        if idString.hasPrefix("group:") { return }

                        if let sessionId = UUID(uuidString: idString),
                           let session = projectSessions.first(where: { $0.id == sessionId }) {
                            DispatchQueue.main.async {
                                // Move folder on disk if task has a folder
                                if let currentPath = session.taskFolderPath {
                                    Task {
                                        do {
                                            try TaskFolderService.shared.moveTask(
                                                from: URL(fileURLWithPath: currentPath),
                                                toSubProject: toGroup?.name,
                                                projectPath: project.path
                                            )
                                            // Update session with new path
                                            let taskSlug = URL(fileURLWithPath: currentPath).lastPathComponent
                                                .replacingOccurrences(of: "^\\d{3}-", with: "", options: .regularExpression)
                                            let newPath = TaskFolderService.shared.taskFolderPath(
                                                projectPath: project.path,
                                                subProjectName: toGroup?.name,
                                                taskName: taskSlug
                                            )
                                            await MainActor.run {
                                                session.taskFolderPath = newPath.path
                                            }
                                        } catch {
                                            print("Failed to move task folder: \(error)")
                                        }
                                    }
                                }
                                session.taskGroup = toGroup
                            }
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func handleGroupDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { reading, _ in
                    guard let idString = reading as? String else { return }

                    if idString.hasPrefix("group:") {
                        // Handle group reordering
                        let groupIdString = String(idString.dropFirst("group:".count))
                        if let draggedId = UUID(uuidString: groupIdString),
                           draggedId != group.id {
                            DispatchQueue.main.async {
                                if let draggedGroup = project.taskGroups.first(where: { $0.id == draggedId }) {
                                    reorderGroup(draggedGroup, toIndex: index)
                                }
                                draggedGroupId = nil
                            }
                        }
                    } else {
                        // Handle task drop into this group
                        if let sessionId = UUID(uuidString: idString),
                           let session = projectSessions.first(where: { $0.id == sessionId }) {
                            DispatchQueue.main.async {
                                // Move folder on disk if task has a folder
                                if let currentPath = session.taskFolderPath {
                                    Task {
                                        do {
                                            try TaskFolderService.shared.moveTask(
                                                from: URL(fileURLWithPath: currentPath),
                                                toSubProject: group.name,
                                                projectPath: project.path
                                            )
                                            // Update session with new path
                                            let taskSlug = URL(fileURLWithPath: currentPath).lastPathComponent
                                                .replacingOccurrences(of: "^\\d{3}-", with: "", options: .regularExpression)
                                            let newPath = TaskFolderService.shared.taskFolderPath(
                                                projectPath: project.path,
                                                subProjectName: group.name,
                                                taskName: taskSlug
                                            )
                                            await MainActor.run {
                                                session.taskFolderPath = newPath.path
                                            }
                                        } catch {
                                            print("Failed to move task folder: \(error)")
                                        }
                                    }
                                }
                                session.taskGroup = group
                            }
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func reorderGroup(_ draggedGroup: ProjectGroup, toIndex newIndex: Int) {
        var projectGroups = project.taskGroups.sorted { $0.sortOrder < $1.sortOrder }
        guard let currentIndex = projectGroups.firstIndex(where: { $0.id == draggedGroup.id }) else { return }
        guard newIndex >= 0 && newIndex < projectGroups.count else { return }
        guard currentIndex != newIndex else { return }

        // Remove from current position and insert at new position
        let movedGroup = projectGroups.remove(at: currentIndex)
        projectGroups.insert(movedGroup, at: newIndex)

        // Update sortOrder for all groups
        for (idx, g) in projectGroups.enumerated() {
            g.sortOrder = idx
        }
    }

    private func createTask() {
        let name = newTaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isCreatingTask = false
            newTaskName = ""
            return
        }

        let session = Session(
            name: name,
            projectPath: project.path,
            userNamed: true
        )
        session.project = project
        session.taskGroup = group

        // Create task folder with TASK.md (inside the project group folder)
        let subProjectName = group.name

        // Set expected task folder path BEFORE creating it (prevents duplicate import)
        let expectedPath = TaskFolderService.shared.taskFolderPath(
            projectPath: project.path,
            subProjectName: subProjectName,
            taskName: name
        )
        session.taskFolderPath = expectedPath.path

        // Create the directory immediately so startClaude() uses it as workingDir
        try? FileManager.default.createDirectory(at: expectedPath, withIntermediateDirectories: true)

        modelContext.insert(session)
        try? modelContext.save()  // Ensure it's persisted before file watcher can trigger

        // Export to Dropbox (if sync enabled)
        SessionSyncService.shared.exportSession(session)

        windowState.activeSession = session
        isCreatingTask = false
        newTaskName = ""
        isTaskFieldFocused = false  // Unfocus text field so terminal can take focus

        Task {
            do {
                let taskFolder = try TaskFolderService.shared.createTask(
                    projectPath: project.path,
                    projectName: project.name,
                    subProjectName: subProjectName,
                    taskName: name,
                    description: nil
                )
                // Verify path matches (it should)
                if taskFolder.path != expectedPath.path {
                    await MainActor.run {
                        session.taskFolderPath = taskFolder.path
                    }
                }
            } catch {
                print("Failed to create task folder: \(error)")
                // Clear the path since folder creation failed
                await MainActor.run {
                    session.taskFolderPath = nil
                }
            }
        }
    }
}

struct TaskRow: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let session: Session
    let project: Project
    var indented: Bool = false  // For tasks inside groups
    var isCompletedSection: Bool = false  // For completed tasks section
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var isCompleting = false
    @State private var showBillingSheet = false
    @State private var calculatedBilling: BillingHours?

    var isActive: Bool {
        windowState.activeSession?.id == session.id
    }

    var isLogged: Bool {
        session.lastSessionSummary != nil && !session.lastSessionSummary!.isEmpty
    }

    var isCompleted: Bool {
        session.isCompleted
    }

    /// Status color: green (completed), blue (active), gray (inactive)
    var statusColor: Color {
        if isCompleted { return .green }
        if isActive { return .blue }
        return Color.gray.opacity(0.4)
    }

    /// Shared formatter to avoid creating a new one on every render
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Relative time string for hover display
    var relativeTime: String {
        Self.relativeDateFormatter.localizedString(for: session.createdAt, relativeTo: Date())
    }

    // MARK: - Extracted sub-views (breaks up body for Swift type-checker)

    private var statusIndicator: some View {
        ZStack {
            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
            } else if isActive && session.hasBeenLaunched {
                // Active and running in Terminal
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            } else if isActive {
                Circle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
            } else if session.hasBeenLaunched {
                // Launched but not currently selected
                Image(systemName: "terminal")
                    .font(.system(size: 13))
                    .foregroundStyle(.green.opacity(0.6))
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 16, height: 16)
    }

    private var taskContent: some View {
        Group {
            if isEditing {
                TextField("Task name", text: $editedName, onCommit: {
                    session.name = editedName
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onExitCommand {
                    isEditing = false
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(session.name)
                            .font(.system(size: 17))
                            .foregroundStyle(isActive ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isLogged {
                            Text("Logged")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
                                .fixedSize()
                        }
                    }

                    if let summary = session.lastSessionSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button {
                let controller = appState.getOrCreateController(for: session)
                let workingDir = session.taskFolderPath ?? session.projectPath
                controller.popOutToTerminal(workingDir: workingDir)
            } label: {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Terminal.app")

            Button {
                archiveTask()
            } label: {
                Image(systemName: "eye.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide this task")
        }
        .opacity(isHovered && !isEditing ? 1 : 0)
    }

    private var taskContextMenu: some View {
        Group {
            Button {
                editedName = session.name
                isEditing = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            if let folderPath = session.taskFolderPath {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: folderPath))
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
            }

            if session.taskGroup == nil && !isCompleted {
                Button {
                    promoteToProject()
                } label: {
                    Label("Promote to Project", systemImage: "folder.badge.plus")
                }
            }

            if isCompleted {
                Button {
                    session.isCompleted = false
                    session.completedAt = nil
                } label: {
                    Label("Reopen Task", systemImage: "arrow.uturn.backward")
                }
            }

            Divider()

            Button(role: .destructive) {
                if windowState.activeSession?.id == session.id {
                    windowState.activeSession = nil
                }
                appState.removeController(for: session)
                modelContext.delete(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var rowBackgroundColor: Color {
        if isActive { return Color.blue.opacity(0.15) }
        if isHovered { return Color.white.opacity(0.08) }
        return Color.clear
    }

    private var leadingPadding: CGFloat { indented ? 32 : 8 }
    private var verticalPadding: CGFloat { indented ? 8 : 10 }

    var body: some View {
        rowContent
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                editedName = session.name
                isEditing = true
            }
            .onTapGesture(count: 1) { handleTap() }
            .onHover { hovering in isHovered = hovering }
            .onDrag { NSItemProvider(object: session.id.uuidString as NSString) }
            .contextMenu { taskContextMenu }
            .sheet(isPresented: $showBillingSheet) { billingSheet }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            statusIndicator
            taskContent
            Spacer()

            if isHovered && !isEditing {
                Text(relativeTime)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 4)
            }

            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .padding(.leading, leadingPadding)
        .padding(.trailing, 8)
    }

    private func handleTap() {
        if isEditing {
            session.name = editedName
            isEditing = false
            return
        }
        if session.isCompleted {
            session.isCompleted = false
            session.completedAt = nil
        }
        if windowState.activeSession?.id == session.id {
            // Already selected - bring Terminal to front if launched
            if session.hasBeenLaunched {
                activateTerminal()
            } else {
                windowState.activeSession = nil
            }
        } else {
            windowState.userTappedSession = true
            windowState.activeSession = session
        }
    }

    private func activateTerminal() {
        // Terminal is embedded via SwiftTerm - just ensure the window is focused
        if let window = NSApplication.shared.keyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private var billingSheet: some View {
        BillingSheetView(
            taskName: session.name,
            billing: calculatedBilling ?? BillingHours(actualHours: 0.25, suggestedHours: 0.25),
            onConfirm: { billedHours in
                showBillingSheet = false
                finalizeCompletion(billedHours: billedHours)
            },
            onCancel: {
                showBillingSheet = false
            }
        )
    }

    /// Complete a task - calculate billing hours and show confirmation
    private func completeTask() {
        // Calculate billing hours from conversation timestamps
        if let taskFolderPath = session.taskFolderPath {
            calculatedBilling = TaskFolderService.shared.calculateBillingHours(taskFolderPath: taskFolderPath)
        } else {
            calculatedBilling = BillingHours(actualHours: 0.25, suggestedHours: 0.25)
        }

        // Show billing confirmation sheet
        showBillingSheet = true
    }

    /// Hide task from list without deleting - can be reopened later by typing same name
    private func archiveTask() {
        // Clear active session if this was it
        if windowState.activeSession?.id == session.id {
            windowState.activeSession = nil
        }
        appState.removeController(for: session)

        // Hide immediately for instant UI response
        session.isHidden = true

        // Persist and sync in background
        let sessionRef = session
        Task.detached(priority: .utility) {
            await MainActor.run {
                try? self.modelContext.save()
                SessionSyncService.shared.exportSession(sessionRef)
            }
        }

        // Invoice logging is fire-and-forget
        Task.detached(priority: .background) {
            await MainActor.run {
                self.logToInvoice()
            }
        }
    }

    /// Append task info to invoice log file
    private func logToInvoice() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        // Extract project name from path
        let projectName = URL(fileURLWithPath: project.path).lastPathComponent

        // Create log entry
        let entry = "\(today) | \(projectName) | \(session.name) | archived\n"

        // Invoice log location
        let invoiceLogPath = NSString("~/Library/CloudStorage/Dropbox/Shellspace/invoice-log.txt").expandingTildeInPath
        let invoiceLogURL = URL(fileURLWithPath: invoiceLogPath)

        do {
            // Create directory if needed
            let dir = invoiceLogURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            // Append to file (or create if doesn't exist)
            if FileManager.default.fileExists(atPath: invoiceLogPath) {
                let handle = try FileHandle(forWritingTo: invoiceLogURL)
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                try entry.write(to: invoiceLogURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Failed to log to invoice: \(error)")
        }
    }

    /// Actually complete the task after billing confirmation
    private func finalizeCompletion(billedHours: Double) {
        isCompleting = true

        // Save the log first
        if let controller = appState.terminalControllers[session.id] {
            controller.saveLog(for: session)
        }

        // Ask Claude to update TASK.md with completion summary (if task folder exists)
        if session.taskFolderPath != nil {
            let controller = appState.getOrCreateController(for: session)
            let prompt = "Please add a brief completion summary to the Progress section of TASK.md (append with today's date as ### heading, and note that the task is now complete). Just update the file, no need to show me the contents.\n"
            controller.sendToTerminal(prompt)
        }

        // Wait for Claude to process, then mark complete
        let delay = session.taskFolderPath != nil ? 3.0 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Mark as completed
            session.isCompleted = true
            session.completedAt = Date()

            // Save the log one final time
            if let controller = appState.terminalControllers[session.id] {
                controller.saveLog(for: session)
            }

            // Update TASK.md status and billing
            if let taskFolderPath = session.taskFolderPath {
                let folderURL = URL(fileURLWithPath: taskFolderPath)
                do {
                    try TaskFolderService.shared.updateTaskStatus(
                        at: folderURL,
                        status: "completed"
                    )
                    // Add billing info to TASK.md
                    let actualHours = calculatedBilling?.actualHours ?? 0.25
                    try TaskFolderService.shared.updateTaskBilling(
                        at: folderURL,
                        actualHours: actualHours,
                        billedHours: billedHours
                    )
                } catch {
                    print("Failed to update task: \(error)")
                }
            }

            // Export to Dropbox (if sync enabled)
            SessionSyncService.shared.exportSession(session)

            // Clear active session if this was it
            if windowState.activeSession?.id == session.id {
                windowState.activeSession = nil
            }

            isCompleting = false
        }
    }

    /// Save session summary to task TASK.md file
    private func saveToTaskFile(summary: String, isCompleted: Bool = false) {
        // If session has a linked task folder, use that
        if let taskFolderPath = session.taskFolderPath {
            let folderURL = URL(fileURLWithPath: taskFolderPath)
            do {
                // Append progress to TASK.md
                let taskFile = folderURL.appendingPathComponent("TASK.md")
                if FileManager.default.fileExists(atPath: taskFile.path) {
                    var content = try String(contentsOf: taskFile, encoding: .utf8)

                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
                    let timestamp = dateFormatter.string(from: Date())

                    content += "\n### \(timestamp)\n\(summary)\n"
                    try content.write(to: taskFile, atomically: true, encoding: .utf8)
                }

                // Update status if completed and move to completed folder
                if isCompleted {
                    try TaskFolderService.shared.updateTaskStatus(
                        at: folderURL,
                        status: "done"
                    )

                    // Move task folder to completed directory
                    if let newPath = try TaskFolderService.shared.moveToCompleted(
                        taskFolderPath: taskFolderPath,
                        projectPath: project.path
                    ) {
                        session.taskFolderPath = newPath.path
                    }
                }
            } catch {
                print("Failed to save to task file: \(error)")
            }
        }
    }

    /// Promote this task to a project (sub-project within the current project)
    private func promoteToProject() {
        // Create a new ProjectGroup with the task's name
        let group = ProjectGroup(
            name: session.name,
            projectPath: project.path,
            sortOrder: (project.taskGroups.map(\.sortOrder).max() ?? -1) + 1
        )
        group.project = project
        modelContext.insert(group)

        // Move the session into the new group
        session.taskGroup = group

        // Create project folder on disk if task has a folder
        if let taskFolderPath = session.taskFolderPath {
            Task {
                do {
                    // Create the project folder structure
                    let projectFolder = try TaskFolderService.shared.createProject(
                        projectPath: project.path,
                        projectName: session.name,
                        clientName: project.name,
                        description: nil
                    )

                    // Move task folder into the new project folder
                    let taskFolderURL = URL(fileURLWithPath: taskFolderPath)
                    let taskFolderName = taskFolderURL.lastPathComponent
                    let newTaskLocation = projectFolder.appendingPathComponent(taskFolderName)

                    try FileManager.default.moveItem(at: taskFolderURL, to: newTaskLocation)

                    await MainActor.run {
                        session.taskFolderPath = newTaskLocation.path
                    }
                } catch {
                    print("Failed to create project folder structure: \(error)")
                }
            }
        }
    }
}

// MARK: - Billing Sheet View

struct BillingSheetView: View {
    let taskName: String
    let billing: BillingHours
    let onConfirm: (Double) -> Void
    let onCancel: () -> Void

    @State private var selectedHours: Double = 0.25

    // Available billing increments (0.25 to 8 hours)
    private let hourOptions: [Double] = stride(from: 0.25, through: 8.0, by: 0.25).map { $0 }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)

                Text("Complete Task")
                    .font(.system(size: 22, weight: .semibold))

                Text(taskName)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 8)

            Divider()

            // Time breakdown
            VStack(alignment: .leading, spacing: 16) {
                // Actual time
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Actual Time")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Based on conversation timestamps")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(billing.actualDisplay)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Suggested time
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Suggested Billing")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Industry standard (1.5x actual)")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(billing.suggestedDisplay)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Billed hours picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bill for:")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)

                    Picker("Hours", selection: $selectedHours) {
                        ForEach(hourOptions, id: \.self) { hours in
                            Text(formatHoursForPicker(hours))
                                .tag(hours)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 8)

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    onConfirm(selectedHours)
                } label: {
                    Text("Complete")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 8)
        }
        .padding(24)
        .frame(width: 360)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .onAppear {
            // Default to suggested hours
            selectedHours = billing.suggestedHours
        }
    }

    private func formatHoursForPicker(_ hours: Double) -> String {
        if hours < 1 {
            return String(format: "%.0f minutes", hours * 60)
        } else if hours == 1 {
            return "1 hour"
        } else {
            let wholeHours = Int(hours)
            let minutes = Int((hours - Double(wholeHours)) * 60)
            if minutes == 0 {
                return "\(wholeHours) hours"
            } else {
                return "\(wholeHours)h \(minutes)m"
            }
        }
    }
}

// Preview available in Xcode only
