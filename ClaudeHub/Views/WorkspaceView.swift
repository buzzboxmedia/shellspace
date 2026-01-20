import SwiftUI
import SwiftData

struct WorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project

    // Track when this workspace was opened (for unsaved progress check)
    @State private var workspaceOpenedAt: Date = Date()
    @State private var showUnsavedAlert = false
    @State private var showSaveNoteBeforeClose = false
    @State private var pendingCloseSession: Session?

    // Use the project's sessions relationship instead of a separate query
    var sessions: [Session] {
        project.sessions
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
        // Check for unsaved progress before going back
        if let session = windowState.activeSession, hasUnsavedProgress(for: session) {
            pendingCloseSession = session
            showUnsavedAlert = true
        } else {
            performGoBack()
        }
    }

    private func performGoBack() {
        withAnimation(.spring(response: 0.3)) {
            windowState.selectedProject = nil
            windowState.activeSession = nil
        }
    }

    var body: some View {
        HSplitView {
            // Sidebar
            SessionSidebar(project: project, goBack: goBack)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 500)

            // Terminal area
            TerminalArea(project: project)
                .frame(minWidth: 400)
        }
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
        .onAppear {
            workspaceOpenedAt = Date()

            if project.sessions.isEmpty {
                // No sessions, create a generic one
                let newSession = createSession(name: nil, inGroup: nil)
                windowState.activeSession = newSession
            } else if windowState.activeSession == nil {
                // Select the first session if none active
                windowState.activeSession = project.sessions.first
            }
        }
        .alert("Save progress before closing?", isPresented: $showUnsavedAlert) {
            Button("Don't Save") {
                performGoBack()
            }
            Button("Add Note") {
                showSaveNoteBeforeClose = true
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let session = pendingCloseSession {
                Text("You haven't saved a progress note for \"\(session.name)\" this session.")
            }
        }
        .sheet(isPresented: $showSaveNoteBeforeClose) {
            if let session = pendingCloseSession {
                SaveNoteSheetWrapper(
                    session: session,
                    project: project,
                    onSave: {
                        showSaveNoteBeforeClose = false
                        performGoBack()
                    },
                    onCancel: {
                        showSaveNoteBeforeClose = false
                    }
                )
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
            let existingCount = project.sessions.filter { !$0.isProjectLinked }.count
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

        return session
    }
}

struct SessionSidebar: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project
    let goBack: () -> Void
    @State private var isBackHovered = false
    @State private var isCreatingTask = false
    @State private var isCreatingGroup = false
    @State private var newTaskName = ""
    @State private var newTaskDescription = ""
    @State private var newGroupName = ""
    @State private var selectedGroupForNewTask: ProjectGroup?
    @State private var draggedGroupId: UUID?
    @State private var isCompletedExpanded: Bool = false
    @State private var showingAddTaskSheet = false
    @FocusState private var isTaskFieldFocused: Bool
    @FocusState private var isGroupFieldFocused: Bool

    var sessions: [Session] {
        project.sessions
    }

    var activeSessions: [Session] {
        sessions.filter { !$0.isCompleted }
    }

    var completedSessions: [Session] {
        sessions.filter { $0.isCompleted }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var taskGroups: [ProjectGroup] {
        project.taskGroups.sorted { $0.sortOrder < $1.sortOrder }
    }

    var standaloneTasks: [Session] {
        activeSessions.filter { $0.taskGroup == nil }
    }

    func createTask() {
        let name = newTaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = newTaskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isCreatingTask = false
            newTaskName = ""
            newTaskDescription = ""
            selectedGroupForNewTask = nil
            return
        }

        let session = Session(
            name: name,
            projectPath: project.path,
            userNamed: true
        )
        session.sessionDescription = description.isEmpty ? nil : description
        session.project = project
        session.taskGroup = selectedGroupForNewTask
        modelContext.insert(session)

        windowState.activeSession = session
        isCreatingTask = false
        newTaskName = ""
        newTaskDescription = ""

        // Create task folder with TASK.md
        let subProjectName = selectedGroupForNewTask?.name
        selectedGroupForNewTask = nil

        Task {
            do {
                let taskFolder = try TaskFolderService.shared.createTask(
                    projectPath: project.path,
                    projectName: project.name,
                    subProjectName: subProjectName,
                    taskName: name,
                    description: description.isEmpty ? nil : description
                )
                // Link session to task folder
                await MainActor.run {
                    session.taskFolderPath = taskFolder.path
                }
            } catch {
                print("Failed to create task folder: \(error)")
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

        let maxOrder = taskGroups.map { $0.sortOrder }.max() ?? -1
        let group = ProjectGroup(name: name, projectPath: project.path, sortOrder: maxOrder + 1)
        group.project = project
        modelContext.insert(group)

        isCreatingGroup = false
        newGroupName = ""

        // Create sub-project folder
        Task {
            do {
                _ = try TaskFolderService.shared.createProject(
                    projectPath: project.path,
                    projectName: name
                )
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
                VStack(alignment: .leading, spacing: 12) {
                    // Back button
                    Button(action: goBack) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .medium))
                            Text("Back")
                                .font(.system(size: 14))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isBackHovered ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isBackHovered = $0 }

                    // Project name with icon - prominent
                    HStack(spacing: 12) {
                        Image(systemName: project.icon)
                            .font(.system(size: 24))
                            .foregroundStyle(.primary)

                        Text(project.name)
                            .font(.system(size: 22, weight: .semibold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)

                Divider()

                // Task list - fills remaining space
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Action buttons row
                        HStack(spacing: 8) {
                            // New Task button
                            if isCreatingTask {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.blue)

                                        TextField("Task name...", text: $newTaskName)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 13))
                                            .focused($isTaskFieldFocused)
                                            .onSubmit { createTask() }
                                            .onExitCommand {
                                                isCreatingTask = false
                                                newTaskName = ""
                                                newTaskDescription = ""
                                                selectedGroupForNewTask = nil
                                            }
                                    }

                                    TextField("Description (optional)...", text: $newTaskDescription)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .onSubmit { createTask() }

                                    HStack {
                                        Button("Cancel") {
                                            isCreatingTask = false
                                            newTaskName = ""
                                            newTaskDescription = ""
                                        }
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .buttonStyle(.plain)

                                        Spacer()

                                        Button("Create") {
                                            createTask()
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.blue)
                                        .buttonStyle(.plain)
                                        .disabled(newTaskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.blue.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                                )
                                .onAppear { isTaskFieldFocused = true }
                            } else {
                                Button {
                                    isCreatingTask = true
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 11, weight: .medium))
                                        Text("Task")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            // New Project button
                            if isCreatingGroup {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.badge.plus")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.purple)

                                    TextField("Project name...", text: $newGroupName)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13))
                                        .focused($isGroupFieldFocused)
                                        .onSubmit { createGroup() }
                                        .onExitCommand {
                                            isCreatingGroup = false
                                            newGroupName = ""
                                        }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.purple.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                                )
                                .onAppear { isGroupFieldFocused = true }
                            } else {
                                Button {
                                    isCreatingGroup = true
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "folder.badge.plus")
                                            .font(.system(size: 11, weight: .medium))
                                        Text("Project")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            // Import Tasks button
                            let importCount = TaskImportService.shared.countImportableTasks(for: project)
                            if importCount > 0 {
                                Button {
                                    let imported = TaskImportService.shared.importTasks(for: project, modelContext: modelContext)
                                    if imported > 0 {
                                        print("Imported \(imported) tasks")
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.system(size: 11, weight: .medium))
                                        Text("Import (\(importCount))")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)

                        // Project Groups with their tasks
                        ForEach(Array(taskGroups.enumerated()), id: \.element.id) { index, group in
                            ProjectGroupSection(
                                group: group,
                                project: project,
                                index: index,
                                totalGroups: taskGroups.count,
                                draggedGroupId: $draggedGroupId
                            )
                        }

                        // Standalone Tasks Section (drop here to remove from group)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TASKS")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.2)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)

                            if standaloneTasks.isEmpty {
                                // Drop zone when empty
                                Text("Drop tasks here")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(Color.white.opacity(0.03))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .padding(.horizontal, 8)
                            } else {
                                LazyVStack(spacing: 4) {
                                    ForEach(standaloneTasks) { session in
                                        TaskRow(session: session, project: project)
                                    }
                                }
                            }
                        }
                        .onDrop(of: [.text], isTargeted: nil) { providers in
                            handleTasksDrop(providers: providers)
                        }

                        // Completed Tasks Section (collapsible)
                        if !completedSessions.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isCompletedExpanded.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: isCompletedExpanded ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 12)

                                        Text("COMPLETED")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                            .tracking(1.2)

                                        Text("\(completedSessions.count)")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.white.opacity(0.1))
                                            .clipShape(Capsule())

                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if isCompletedExpanded {
                                    LazyVStack(spacing: 4) {
                                        ForEach(completedSessions) { session in
                                            TaskRow(session: session, project: project, isCompletedSection: true)
                                                .opacity(0.7)
                                        }
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .padding(.top, 8)
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
    @Binding var draggedGroupId: UUID?
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var isCreatingTask = false
    @State private var newTaskName = ""
    @State private var isDropTarget = false
    @FocusState private var isTaskFieldFocused: Bool

    var tasks: [Session] {
        group.sessions.filter { !$0.isCompleted }
    }

    var isDragging: Bool {
        draggedGroupId == group.id
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

                // Folder icon
                Image(systemName: "folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.purple)

                // Group name
                if isEditing {
                    TextField("Project name", text: $editedName, onCommit: {
                        group.name = editedName
                        isEditing = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                } else {
                    Text(group.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                }

                Spacer()

                // Task count badge
                Text("\(tasks.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())

                // Actions - always in layout, opacity controlled by hover
                HStack(spacing: 4) {
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
                .opacity(isHovered ? 1 : 0)
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
                           let session = project.sessions.first(where: { $0.id == sessionId }) {
                            DispatchQueue.main.async {
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
                           let session = project.sessions.first(where: { $0.id == sessionId }) {
                            DispatchQueue.main.async {
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
        modelContext.insert(session)

        windowState.activeSession = session
        isCreatingTask = false
        newTaskName = ""
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
    @State private var isResuming = false
    @State private var isCompleting = false
    @State private var showingTaskDetail = false
    @State private var showingBillingSheet = false

    var isActive: Bool {
        windowState.activeSession?.id == session.id
    }

    var isWaiting: Bool {
        appState.waitingSessions.contains(session.id)
    }

    var isWorking: Bool {
        appState.workingSessions.contains(session.id)
    }

    var isLogged: Bool {
        session.lastSessionSummary != nil && !session.lastSessionSummary!.isEmpty
    }

    var hasLog: Bool {
        session.hasLog
    }

    var isCompleted: Bool {
        session.isCompleted
    }

    /// Status color: blue (working), green (active/logged), orange (waiting), gray (inactive)
    var statusColor: Color {
        if isWorking { return .blue }
        if isActive { return .green }
        if isWaiting { return .orange }
        if isLogged { return .green.opacity(0.6) }
        return Color.gray.opacity(0.4)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator with logged checkmark
            ZStack {
                if isWorking {
                    // Pulsing blue circle when Claude is working
                    Circle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 16, height: 16)
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                        .modifier(PulseAnimation())
                } else if isActive {
                    Circle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 16, height: 16)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                } else if isWaiting {
                    Circle()
                        .fill(Color.orange.opacity(0.3))
                        .frame(width: 16, height: 16)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                } else if isLogged && !isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
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

                        // Show "working" badge when Claude is actively outputting
                        if isWorking {
                            Text("working")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        // Show "waiting" badge when Claude needs input
                        if isWaiting && !isWorking {
                            Text("waiting")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        // Show "Logged" badge for tasks with summaries
                        if isLogged && !isWaiting && !isWorking {
                            Text("Logged")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
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

                    // Show "Project" badge for linked sessions
                    if session.isProjectLinked {
                        Text("Project")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            // Action buttons - simplified: just primary action + delete
            HStack(spacing: 4) {
                if isCompleted {
                    // Billing button for completed tasks
                    Button {
                        showingBillingSheet = true
                    } label: {
                        Image(systemName: "dollarsign.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Send to billing")
                } else {
                    // Complete button for active tasks
                    Button {
                        completeTask()
                    } label: {
                        if isCompleting {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 24, height: 24)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(.green)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Complete this task")
                }

                // Delete button
                Button {
                    if windowState.activeSession?.id == session.id {
                        windowState.activeSession = nil
                    }
                    appState.removeController(for: session)
                    modelContext.delete(session)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this task")
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
            windowState.activeSession = session
            // Clear waiting state when user views this session
            appState.clearSessionWaiting(session)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrag {
            NSItemProvider(object: session.id.uuidString as NSString)
        }
        .contextMenu {
            Button {
                showingTaskDetail = true
            } label: {
                Label("View Details", systemImage: "info.circle")
            }

            if hasLog {
                Button {
                    NSWorkspace.shared.open(session.actualLogPath)
                } label: {
                    Label("View Log", systemImage: "doc.text")
                }

                if !isCompleted {
                    Button {
                        resumeTask()
                    } label: {
                        Label("Resume Task", systemImage: "arrow.clockwise")
                    }
                }
            }

            Divider()

            Button {
                editedName = session.name
                isEditing = true
            } label: {
                Label("Rename", systemImage: "pencil")
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
        .sheet(isPresented: $showingTaskDetail) {
            TaskDetailView(session: session, project: project, isPresented: $showingTaskDetail)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingBillingSheet) {
            SendToBillingSheet(session: session, project: project)
        }
    }

    /// Resume a task by loading context and sending update prompt to Claude
    private func resumeTask() {
        isResuming = true

        // First, select this session
        windowState.activeSession = session
        appState.clearSessionWaiting(session)

        // Wait for terminal to be ready, then send the resume prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Generate the resume prompt
            let prompt = appState.generateResumePrompt(for: session)

            // Get the terminal controller and send the prompt
            if let controller = appState.terminalControllers[session.id] {
                controller.sendToTerminal(prompt + "\n")
            }

            isResuming = false
        }
    }

    /// Complete a task - save log and mark as done
    private func completeTask() {
        isCompleting = true

        // Save the log first
        if let controller = appState.terminalControllers[session.id] {
            controller.saveLog(for: session)
        }

        // Generate a summary using Claude API (async)
        let content = appState.terminalControllers[session.id]?.getTerminalContent() ?? ""

        if !content.isEmpty {
            // Generate summary in background
            ClaudeAPI.shared.generateTaskSummary(from: content, taskName: session.name) { summary in
                DispatchQueue.main.async {
                    // Mark as completed with summary
                    session.isCompleted = true
                    session.completedAt = Date()
                    if let summary = summary {
                        session.lastSessionSummary = summary

                        // Also save to task file
                        self.saveToTaskFile(summary: summary, isCompleted: true)
                    }

                    // Save the log one final time
                    if let controller = appState.terminalControllers[session.id] {
                        controller.saveLog(for: session)
                    }

                    // Clear active session if this was it
                    if windowState.activeSession?.id == session.id {
                        windowState.activeSession = nil
                    }

                    isCompleting = false
                }
            }
        } else {
            // No content, just complete without summary
            session.isCompleted = true
            session.completedAt = Date()

            // Move task folder to completed directory
            if let taskFolderPath = session.taskFolderPath {
                do {
                    try TaskFolderService.shared.updateTaskStatus(
                        at: URL(fileURLWithPath: taskFolderPath),
                        status: "done"
                    )
                    if let newPath = try TaskFolderService.shared.moveToCompleted(
                        taskFolderPath: taskFolderPath,
                        projectPath: project.path
                    ) {
                        session.taskFolderPath = newPath.path
                    }
                } catch {
                    print("Failed to move task to completed: \(error)")
                }
            }

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
        } else {
            // Fallback: try old TaskFileService for legacy tasks
            let components = project.path.components(separatedBy: "/")
            guard let clientsIndex = components.firstIndex(where: { $0.lowercased() == "clients" }),
                  clientsIndex + 1 < components.count else {
                return
            }
            let clientName = components[clientsIndex + 1]

            do {
                try TaskFileService.shared.appendSessionSummary(
                    clientName: clientName,
                    taskName: session.name,
                    summary: summary
                )

                if isCompleted {
                    try TaskFileService.shared.updateTaskStatus(
                        clientName: clientName,
                        taskName: session.name,
                        status: "done",
                        completedDate: Date()
                    )
                }
            } catch {
                print("Failed to save to legacy task file: \(error)")
            }
        }
    }
}

struct TerminalHeader: View {
    @EnvironmentObject var appState: AppState
    let session: Session
    let project: Project
    @Binding var showLogSheet: Bool
    @Binding var showSaveNotePopover: Bool
    @State private var isLogHovered = false
    @State private var isSaveNoteHovered = false

    var body: some View {
        HStack(spacing: 14) {
            // Status indicator (static to avoid layout thrashing)
            ZStack {
                // Outer glow ring
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 18, height: 18)

                // Core dot
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.green.opacity(0.8), radius: 4)
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let description = session.sessionDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            // Save Note button (📌)
            Button {
                showSaveNotePopover = true
            } label: {
                Image(systemName: "pin.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSaveNoteHovered ? .blue : .secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(isSaveNoteHovered ? Color.blue.opacity(0.15) : Color.white.opacity(0.08))
                    )
                    .overlay(
                        Circle()
                            .stroke(isSaveNoteHovered ? Color.blue.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .scaleEffect(isSaveNoteHovered ? 1.05 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { isSaveNoteHovered = $0 }
            .help("Save a progress note")

            // Log Task button
            Button {
                showLogSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                    Text("Log Task")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    LinearGradient(
                        colors: [Color.blue, Color.blue.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(Capsule())
                .shadow(color: Color.blue.opacity(isLogHovered ? 0.5 : 0.3), radius: isLogHovered ? 8 : 4)
                .scaleEffect(isLogHovered ? 1.03 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { isLogHovered = $0 }

            // Running status badge
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
                // Frosted glass base
                VisualEffectView(material: .headerView, blendingMode: .withinWindow)

                // Subtle top highlight
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
    @StateObject private var progressManager = ProgressNoteManager.shared
    let project: Project
    @State private var showLogSheet = false
    @State private var showSaveNotePopover = false
    @State private var showProgressReminder = false
    @State private var reminderTimer: Timer?

    var body: some View {
        Group {
            if let session = windowState.activeSession {
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        TerminalHeader(session: session, project: project, showLogSheet: $showLogSheet, showSaveNotePopover: $showSaveNotePopover)

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
                    )
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
                    .shadow(color: Color.blue.opacity(0.1), radius: 20, x: 0, y: 0)
                    .padding(14)
                    .sheet(isPresented: $showLogSheet) {
                        LogTaskSheet(session: session, project: project, isPresented: $showLogSheet)
                    }
                    .popover(isPresented: $showSaveNotePopover, arrowEdge: .top) {
                        SaveNotePopover(
                            session: session,
                            project: project,
                            onSave: {
                                showSaveNotePopover = false
                                showProgressReminder = false
                                progressManager.noteSaved(for: session)
                            },
                            onCancel: {
                                showSaveNotePopover = false
                            }
                        )
                    }

                    // Progress reminder toast
                    if showProgressReminder {
                        ProgressReminderToast(
                            onAddNote: {
                                showProgressReminder = false
                                showSaveNotePopover = true
                            },
                            onDismiss: {
                                showProgressReminder = false
                                progressManager.dismissReminder(for: session)
                            }
                        )
                        .padding(.bottom, 24)
                        .padding(.horizontal, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onAppear {
                    startReminderTimer(for: session)
                }
                .onDisappear {
                    stopReminderTimer()
                }
                .onChange(of: windowState.activeSession?.id) { _, _ in
                    // Reset when switching sessions
                    showProgressReminder = false
                    if let newSession = windowState.activeSession {
                        startReminderTimer(for: newSession)
                    }
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

    // MARK: - Reminder Timer

    private func startReminderTimer(for session: Session) {
        stopReminderTimer()

        // Check immediately
        checkReminder(for: session)

        // Then check every minute
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            checkReminder(for: session)
        }
    }

    private func stopReminderTimer() {
        reminderTimer?.invalidate()
        reminderTimer = nil
    }

    private func checkReminder(for session: Session) {
        if progressManager.shouldShowReminder(for: session) {
            withAnimation(.spring(response: 0.4)) {
                showProgressReminder = true
            }

            // Auto-dismiss after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if showProgressReminder {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showProgressReminder = false
                    }
                    progressManager.dismissReminder(for: session)
                }
            }
        }
    }
}

// MARK: - Log Task Sheet

struct LogTaskSheet: View {
    @EnvironmentObject var appState: AppState
    let session: Session
    let project: Project
    @Binding var isPresented: Bool

    // Form fields
    @State private var billableDescription: String = ""
    @State private var estimatedHours: String = ""
    @State private var actualHours: String = ""
    @State private var notes: String = ""

    // State
    @State private var isGenerating = true
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var savedSuccessfully = false

    var canSave: Bool {
        !billableDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !actualHours.isEmpty &&
        Double(actualHours) != nil &&
        !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log Task")
                        .font(.system(size: 16, weight: .semibold))
                    Text(session.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Billable Description
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Billable Description")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        if isGenerating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Generating summary...")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: 32)
                        } else {
                            TextField("e.g., Designed social media graphics", text: $billableDescription)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(10)
                                .background(Color.black.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }

                    // Hours row
                    HStack(spacing: 16) {
                        // Estimated Hours
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Est. Hours")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)

                            TextField("0.5", text: $estimatedHours)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(10)
                                .frame(width: 80)
                                .background(Color.black.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }

                        // Actual Hours
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Actual Hours *")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)

                            TextField("0.5", text: $actualHours)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(10)
                                .frame(width: 80)
                                .background(Color.black.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(actualHours.isEmpty ? Color.orange.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }

                        Spacer()
                    }

                    // Notes (optional)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes (optional)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $notes)
                            .font(.system(size: 13))
                            .frame(minHeight: 60)
                            .padding(8)
                            .background(Color.black.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }

                    if let error = saveError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    if savedSuccessfully {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Task logged successfully!")
                                .foregroundStyle(.green)
                        }
                        .font(.system(size: 12))
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    saveLog()
                } label: {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 60)
                    } else {
                        Text("Save Log")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 500, height: 420)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .onAppear {
            generateSummary()
        }
    }

    func generateSummary() {
        // Get terminal content from the session's controller
        guard let controller = appState.terminalControllers[session.id] else {
            isGenerating = false
            billableDescription = session.name
            estimatedHours = "0.5"
            return
        }

        let content = controller.getTerminalContent()

        if content.isEmpty {
            isGenerating = false
            billableDescription = session.name
            estimatedHours = "0.5"
            return
        }

        ClaudeAPI.shared.generateBillableSummary(from: content, taskName: session.name) { summary in
            isGenerating = false
            if let summary = summary {
                billableDescription = summary.description
                estimatedHours = String(format: "%.2f", summary.estimatedHours)
            } else {
                // Fallback to task name
                billableDescription = session.name
                estimatedHours = "0.5"
            }
        }
    }

    /// Extract client name from project path
    var clientName: String? {
        let components = project.path.components(separatedBy: "/")
        if let clientsIndex = components.firstIndex(where: { $0.lowercased() == "clients" }),
           clientsIndex + 1 < components.count {
            return components[clientsIndex + 1]
        }
        return nil
    }

    func saveLog() {
        guard canSave else { return }

        isSaving = true
        saveError = nil

        let estHrs = Double(estimatedHours) ?? 0.5
        let actHrs = Double(actualHours) ?? 0.5

        Task {
            // Save locally first - this is the critical part
            session.lastSessionSummary = billableDescription

            // Also save to task markdown file
            if let clientName = clientName {
                do {
                    try TaskFileService.shared.appendSessionSummary(
                        clientName: clientName,
                        taskName: session.name,
                        summary: billableDescription
                    )
                } catch {
                    print("Failed to save to task file: \(error)")
                }
            }

            // Sync to Google Sheets billing (optional, may fail)
            do {
                let result = try await GoogleSheetsService.shared.logBilling(
                    client: project.name,
                    project: nil,
                    task: session.name,
                    description: billableDescription,
                    estHours: estHrs,
                    actualHours: actHrs,
                    status: "billed"
                )

                await MainActor.run {
                    isSaving = false
                    savedSuccessfully = true

                    if result.success {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            isPresented = false
                        }
                    } else {
                        saveError = "Saved locally. Billing sync: \(result.error ?? "unknown error")"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isPresented = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    savedSuccessfully = true
                    saveError = "Saved locally. Billing sync failed."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isPresented = false
                    }
                }
            }
        }
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

// Preview available in Xcode only
