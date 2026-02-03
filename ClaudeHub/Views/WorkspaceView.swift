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
    @State private var isSidebarCollapsed = false

    // Filter sessions by project path (works for both persisted and non-persisted projects)
    var sessions: [Session] {
        allSessions.filter { $0.projectPath == project.path }
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
            // Sidebar (collapsible)
            if !isSidebarCollapsed {
                SessionSidebar(project: project)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 450)
            }

            // Terminal area with toggle button
            TerminalArea(project: project, isSidebarCollapsed: $isSidebarCollapsed)
                .frame(minWidth: 400)
        }
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
        .onAppear {
            workspaceOpenedAt = Date()

            // Auto-import any existing task folders
            let imported = TaskImportService.shared.importTasks(for: project, modelContext: modelContext)
            if imported > 0 {
                print("Auto-imported \(imported) tasks")
            }

            // Try to restore last active session (may need to wait for @Query to populate)
            restoreLastSession()
        }
        .onChange(of: sessions.count) { oldCount, newCount in
            // When sessions become available (query populated), restore last session if we don't have one
            if oldCount == 0 && newCount > 0 && windowState.activeSession == nil {
                restoreLastSession()
            }
        }
        .onDisappear {
            // Remember last active session for next time (both on Project and in UserDefaults)
            project.lastActiveSessionId = windowState.activeSession?.id
            if let sessionId = windowState.activeSession?.id {
                UserDefaults.standard.set(sessionId.uuidString, forKey: "lastSession:\(project.path)")
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
                            .font(.system(size: 14, weight: .medium))
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
        // Check if current activeSession belongs to this project
        let currentSessionBelongsToProject = windowState.activeSession.map { session in
            sessions.contains { $0.id == session.id }
        } ?? false

        // Only restore if we don't have a valid session for this project
        if !currentSessionBelongsToProject && !sessions.isEmpty {
            // Restore from UserDefaults (more reliable than project.lastActiveSessionId for non-persisted projects)
            let lastId = UserDefaults.standard.string(forKey: "lastSession:\(project.path)")
                .flatMap { UUID(uuidString: $0) }

            if let lastId = lastId,
               let lastSession = sessions.first(where: { $0.id == lastId }) {
                windowState.activeSession = lastSession
            } else {
                // Fall back to most recent session
                windowState.activeSession = sessions.first
            }
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
        allSessions.filter { $0.projectPath == project.path }
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

        // Check if a hidden session with this name already exists - if so, unhide it
        if let existingSession = sessions.first(where: {
            $0.name.lowercased() == name.lowercased() && $0.isHidden
        }) {
            existingSession.isHidden = false
            existingSession.lastAccessedAt = Date()
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
        modelContext.insert(session)
        try? modelContext.save()  // Ensure it's persisted before file watcher can trigger

        // Export to Dropbox (if sync enabled)
        SessionSyncService.shared.exportSession(session)

        selectedGroupForNewTask = nil
        windowState.activeSession = session
        isCreatingTask = false
        newTaskName = ""

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
                        .font(.system(size: 24))
                        .foregroundStyle(.primary)

                    Text(project.name)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
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
                                    .font(.system(size: 14))
                                    .focused($isTaskFieldFocused)
                                    .onSubmit { createTask() }
                                    .onChange(of: newTaskName) { _, _ in
                                        // Trigger autocomplete update
                                    }

                                Button {
                                    createTask()
                                } label: {
                                    Text("GO")
                                        .font(.system(size: 12, weight: .semibold))
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
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(.primary)
                                                    Spacer()
                                                    if session.isHidden {
                                                        Text("hidden")
                                                            .font(.system(size: 10))
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

                        // Tasks list (flat, no groups)
                        if activeSessions.isEmpty {
                            Text("No tasks yet")
                                .font(.system(size: 12))
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
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
        )
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
            guard !session.isCompleted,
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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                // Folder icon + name - clickable to open project
                if isEditing {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.purple)

                        TextField("Project name", text: $editedName, onCommit: {
                            group.name = editedName
                            isEditing = false
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(isProjectActive ? .blue : .purple)
                            .fixedSize()

                        Text(group.name)
                            .font(.system(size: 15, weight: .medium))
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
                    .font(.system(size: 10, weight: .medium))
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
                                .font(.system(size: 10))
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
                            .font(.system(size: 12))
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
                            .font(.system(size: 12))
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
                            .font(.system(size: 14))
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
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)

                    TextField("Task name...", text: $newTaskName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
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

        modelContext.insert(session)
        try? modelContext.save()  // Ensure it's persisted before file watcher can trigger

        // Export to Dropbox (if sync enabled)
        SessionSyncService.shared.exportSession(session)

        windowState.activeSession = session
        isCreatingTask = false
        newTaskName = ""

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

    /// Relative time string for hover display
    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: session.createdAt, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            ZStack {
                if isCompleted {
                    // Green checkmark for completed tasks
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                } else if isActive {
                    Circle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 16, height: 16)
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 16, height: 16)

            if isEditing {
                TextField("Task name", text: $editedName, onCommit: {
                    session.name = editedName
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(session.name)
                            .font(.system(size: 15))
                            .foregroundStyle(isActive ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Show "Logged" badge for tasks with summaries
                        if isLogged {
                            Text("Logged")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
                                .fixedSize()
                        }
                    }

                    // Show summary preview if logged
                    if let summary = session.lastSessionSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }

                }
            }

            Spacer()

            // Timestamp on hover
            if isHovered && !isEditing {
                Text(relativeTime)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 4)
            }

            // Action buttons - simplified: just primary action + delete
            HStack(spacing: 4) {
                // Open in Terminal.app
                Button {
                    let controller = appState.getOrCreateController(for: session)
                    let workingDir = session.taskFolderPath ?? session.projectPath
                    controller.popOutToTerminal(workingDir: workingDir)
                } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in Terminal.app")

                // Hide button - hides task from list (can reopen by typing name)
                Button {
                    archiveTask()
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide this task")
            }
            .opacity(isHovered && !isEditing ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, indented ? 8 : 10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.blue.opacity(0.15) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
        }
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            }
        }
        .padding(.leading, indented ? 32 : 8)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editedName = session.name
            isEditing = true
        }
        .onTapGesture(count: 1) {
            // Reopen completed tasks when clicked
            if session.isCompleted {
                session.isCompleted = false
                session.completedAt = nil
            }
            windowState.activeSession = session
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrag {
            NSItemProvider(object: session.id.uuidString as NSString)
        }
        .contextMenu {
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

            // Only show "Promote to Project" for tasks not already in a group
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
        .sheet(isPresented: $showBillingSheet) {
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

        // Log to invoice file
        logToInvoice()

        // Just hide it - folder stays in place so it can be reopened
        session.isHidden = true

        // Export updated state to Dropbox
        SessionSyncService.shared.exportSession(session)
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
        let invoiceLogPath = NSString("~/Library/CloudStorage/Dropbox/ClaudeHub/invoice-log.txt").expandingTildeInPath
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

struct TerminalHeader: View {
    @EnvironmentObject var appState: AppState
    let session: Session
    let project: Project
    @Binding var isSidebarCollapsed: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Sidebar toggle button
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: isSidebarCollapsed ? "sidebar.leading" : "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar")

            // Status indicator
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 18, height: 18)

                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.green.opacity(0.8), radius: 4)
            }
            .frame(width: 20, height: 20)

            // Session name
            Text(session.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Running badge
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Running")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.12))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            ZStack {
                VisualEffectView(material: .headerView, blendingMode: .withinWindow)
                LinearGradient(
                    colors: [Color.white.opacity(0.08), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
    }


}

struct TerminalArea: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project
    @Binding var isSidebarCollapsed: Bool
    @State private var launchedExternalSessions: Set<UUID> = []

    var body: some View {
        Group {
            if let session = windowState.activeSession {
                // Check if this project uses external terminal
                if project.usesExternalTerminal {
                    ExternalTerminalView(
                        session: session,
                        project: project,
                        launchedSessions: $launchedExternalSessions
                    )
                } else {
                    VStack(spacing: 0) {
                        TerminalHeader(session: session, project: project, isSidebarCollapsed: $isSidebarCollapsed)

                        // Subtle separator line with gradient
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.2), Color.blue.opacity(0.3)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 1)

                        TerminalView(session: session)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.2),
                                        Color.white.opacity(0.05),
                                        Color.white.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                            .allowsHitTesting(false)  // Don't intercept mouse events
                    )
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
                    .shadow(color: Color.blue.opacity(0.1), radius: 20, x: 0, y: 0)
                    .padding(14)
                }
            } else {
                // Enhanced empty state
                VStack(spacing: 20) {
                    ZStack {
                        // Background glow
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 120, height: 120)
                            .blur(radius: 30)

                        Image(systemName: "terminal.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.4), Color.white.opacity(0.2)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    VStack(spacing: 8) {
                        Text("No Active Session")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text("Select a task from the sidebar or create a new one")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    ZStack {
                        Color.black.opacity(0.4)

                        // Subtle radial gradient for depth
                        RadialGradient(
                            colors: [Color.blue.opacity(0.05), Color.clear],
                            center: .center,
                            startRadius: 50,
                            endRadius: 300
                        )
                    }
                )
            }
        }
    }
}

// MARK: - External Terminal View (for projects that open in Terminal.app)

struct ExternalTerminalView: View {
    let session: Session
    let project: Project
    @Binding var launchedSessions: Set<UUID>

    var isLaunched: Bool {
        launchedSessions.contains(session.id)
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isLaunched ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                        .frame(width: 18, height: 18)

                    Circle()
                        .fill(isLaunched ? Color.green : Color.blue)
                        .frame(width: 8, height: 8)
                }

                Text(session.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if isLaunched {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Running in Terminal")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                VisualEffectView(material: .headerView, blendingMode: .withinWindow)
            )

            Spacer()

            // Main content area
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 100, height: 100)
                        .blur(radius: 25)

                    Image(systemName: "terminal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.8), Color.blue.opacity(0.5)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                if isLaunched {
                    VStack(spacing: 8) {
                        Text("Session Running Externally")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("Check Terminal.app for this session")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        // Bring Terminal to front
                        let script = """
                        tell application "Terminal"
                            activate
                        end tell
                        """
                        if let appleScript = NSAppleScript(source: script) {
                            var error: NSDictionary?
                            appleScript.executeAndReturnError(&error)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.forward.app")
                            Text("Switch to Terminal")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 8) {
                        Text("Ready to Launch")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("This will open in a new Terminal window")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        launchInExternalTerminal()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("Open in Terminal")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color.black.opacity(0.4)
                RadialGradient(
                    colors: [Color.blue.opacity(0.08), Color.clear],
                    center: .center,
                    startRadius: 50,
                    endRadius: 300
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
        .padding(14)
    }

    private func launchInExternalTerminal() {
        // Use task folder if available, otherwise project path
        let workingDir = session.taskFolderPath ?? project.path

        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(workingDir)' && claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }

        // Mark as launched
        launchedSessions.insert(session.id)
    }
}

// MARK: - Pulse Animation for Working Indicator

struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .animation(
                Animation.easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
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
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                Text("Complete Task")
                    .font(.system(size: 20, weight: .semibold))

                Text(taskName)
                    .font(.system(size: 14))
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Based on conversation timestamps")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(billing.actualDisplay)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Industry standard (1.5x actual)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(billing.suggestedDisplay)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Billed hours picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bill for:")
                        .font(.system(size: 13, weight: .medium))
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
                        .font(.system(size: 14, weight: .medium))
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
                        .font(.system(size: 14, weight: .semibold))
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
