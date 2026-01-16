import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project

    var sessions: [Session] {
        appState.sessionsFor(project: project)
    }

    func goBack() {
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
            // First, create sessions for any active projects from ACTIVE-PROJECTS.md
            let _ = appState.createSessionsForActiveProjects(project: project)

            // Get all sessions for this project
            let projectSessions = appState.sessionsFor(project: project)

            if projectSessions.isEmpty {
                // No active projects found, create a generic chat session
                let newSession = appState.createSession(for: project)
                windowState.activeSession = newSession
            } else if windowState.activeSession == nil {
                // Select the first session if none active
                windowState.activeSession = projectSessions.first
            }
        }
    }
}

struct SessionSidebar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project
    let goBack: () -> Void
    @State private var isBackHovered = false
    @State private var isCreatingTask = false
    @State private var isCreatingGroup = false
    @State private var newTaskName = ""
    @State private var newGroupName = ""
    @State private var selectedGroupForNewTask: ProjectGroup?
    @FocusState private var isTaskFieldFocused: Bool
    @FocusState private var isGroupFieldFocused: Bool

    var sessions: [Session] {
        appState.sessionsFor(project: project)
    }

    var taskGroups: [ProjectGroup] {
        appState.taskGroupsFor(project: project)
    }

    var projectLinkedSessions: [Session] {
        sessions.filter { $0.isProjectLinked }
    }

    var standaloneTasks: [Session] {
        appState.standaloneSessions(for: project)
    }

    func createTask() {
        let name = newTaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isCreatingTask = false
            newTaskName = ""
            selectedGroupForNewTask = nil
            return
        }

        let newSession = appState.createSession(for: project, name: name, inGroup: selectedGroupForNewTask)
        windowState.activeSession = newSession
        isCreatingTask = false
        newTaskName = ""
        selectedGroupForNewTask = nil
    }

    func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isCreatingGroup = false
            newGroupName = ""
            return
        }

        _ = appState.createProjectGroup(for: project, name: name)
        isCreatingGroup = false
        newGroupName = ""
    }

    func handleTasksDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { reading, _ in
                    if let idString = reading as? String,
                       let sessionId = UUID(uuidString: idString),
                       let session = appState.sessions.first(where: { $0.id == sessionId }) {
                        DispatchQueue.main.async {
                            appState.moveSession(session, toGroup: nil)
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
                                            selectedGroupForNewTask = nil
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
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 14, weight: .semibold))
                                        Text("Task")
                                            .font(.system(size: 14, weight: .medium))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 12)
                                    .background(Color.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder.badge.plus")
                                            .font(.system(size: 14, weight: .semibold))
                                        Text("Project")
                                            .font(.system(size: 14, weight: .medium))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 12)
                                    .background(Color.purple)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)

                        // Active Projects Section (from ACTIVE-PROJECTS.md)
                        if !projectLinkedSessions.isEmpty {
                            Text("ACTIVE PROJECTS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.2)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)

                            LazyVStack(spacing: 4) {
                                ForEach(projectLinkedSessions) { session in
                                    TaskRow(session: session, project: project)
                                }
                            }
                        }

                        // Project Groups with their tasks
                        ForEach(taskGroups) { group in
                            ProjectGroupSection(group: group, project: project)
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
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let group: ProjectGroup
    let project: Project
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var isCreatingTask = false
    @State private var newTaskName = ""
    @FocusState private var isTaskFieldFocused: Bool

    var tasks: [Session] {
        appState.sessionsFor(taskGroup: group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Group header
            HStack(spacing: 8) {
                // Expand/collapse chevron
                Button {
                    appState.toggleProjectGroupExpanded(group)
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
                        appState.renameProjectGroup(group, name: editedName)
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

                // Actions on hover
                if isHovered {
                    HStack(spacing: 8) {
                        // Add task to group
                        Button {
                            isCreatingTask = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14))
                                .foregroundStyle(.blue)
                                .frame(width: 28, height: 28)
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
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        // Delete group
                        Button {
                            appState.deleteProjectGroup(group)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                editedName = group.name
                isEditing = true
            }
            .onTapGesture(count: 1) {
                appState.toggleProjectGroupExpanded(group)
            }
            .onHover { isHovered = $0 }
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

    private func handleDrop(providers: [NSItemProvider], toGroup: ProjectGroup?) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { reading, _ in
                    if let idString = reading as? String,
                       let sessionId = UUID(uuidString: idString),
                       let session = appState.sessions.first(where: { $0.id == sessionId }) {
                        DispatchQueue.main.async {
                            appState.moveSession(session, toGroup: toGroup)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func createTask() {
        let name = newTaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isCreatingTask = false
            newTaskName = ""
            return
        }

        let newSession = appState.createSession(for: project, name: name, inGroup: group)
        windowState.activeSession = newSession
        isCreatingTask = false
        newTaskName = ""
    }
}

struct TaskRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let session: Session
    let project: Project
    var indented: Bool = false  // For tasks inside groups
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var isResuming = false

    var isActive: Bool {
        windowState.activeSession?.id == session.id
    }

    var isWaiting: Bool {
        appState.waitingSessions.contains(session.id)
    }

    var isLogged: Bool {
        session.lastSessionSummary != nil && !session.lastSessionSummary!.isEmpty
    }

    var hasLog: Bool {
        session.hasLog
    }

    /// Status color: green (active/logged), orange (waiting), gray (inactive)
    var statusColor: Color {
        if isActive { return .green }
        if isWaiting { return .orange }
        if isLogged { return .green.opacity(0.6) }
        return Color.gray.opacity(0.4)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator with logged checkmark
            ZStack {
                if isActive {
                    Circle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 16, height: 16)
                } else if isWaiting {
                    Circle()
                        .fill(Color.orange.opacity(0.3))
                        .frame(width: 16, height: 16)
                }

                if isLogged && !isActive {
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
                    appState.updateSessionName(session, name: editedName)
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

                        // Show "waiting" badge when Claude needs input
                        if isWaiting {
                            Text("waiting")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        // Show "Logged" badge for tasks with summaries
                        if isLogged && !isWaiting {
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

            // Action buttons on hover
            if isHovered && !isEditing {
                HStack(spacing: 8) {
                    // Update/Resume button - only show if session has a log
                    if hasLog {
                        Button {
                            resumeTask()
                        } label: {
                            if isResuming {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.blue)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Resume this task - load context and get status update")
                    }

                    Button {
                        editedName = session.name
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        // Clear window's active session if we're deleting it
                        if windowState.activeSession?.id == session.id {
                            windowState.activeSession = nil
                        }
                        appState.deleteSession(session)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
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
}

struct TerminalHeader: View {
    @EnvironmentObject var appState: AppState
    let session: Session
    let project: Project
    @Binding var showLogSheet: Bool
    @State private var isLogHovered = false
    @State private var isSaveHovered = false
    @State private var showSavedConfirmation = false

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

                if let description = session.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            // Save Log button
            Button {
                saveLog()
            } label: {
                HStack(spacing: 5) {
                    if showSavedConfirmation {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text(showSavedConfirmation ? "Saved" : "Save")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(showSavedConfirmation ? .green : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(isSaveHovered ? 0.15 : 0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isSaveHovered = $0 }
            .help("Save conversation log for this session")

            // Log Task button - more prominent
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

    private func saveLog() {
        // Get the terminal controller and save the log
        if let controller = appState.terminalControllers[session.id] {
            controller.saveLog(for: session)

            // Show confirmation
            withAnimation {
                showSavedConfirmation = true
            }

            // Reset after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    showSavedConfirmation = false
                }
            }
        }
    }
}

struct TerminalArea: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project
    @State private var showLogSheet = false

    var body: some View {
        Group {
            if let session = windowState.activeSession {
                VStack(spacing: 0) {
                    TerminalHeader(session: session, project: project, showLogSheet: $showLogSheet)

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

    func saveLog() {
        guard canSave else { return }

        isSaving = true
        saveError = nil

        let estHrs = Double(estimatedHours) ?? 0.5
        let actHrs = Double(actualHours) ?? 0.5

        Task {
            // Save locally first - this is the critical part
            appState.updateSessionSummary(session, summary: billableDescription)

            // Sync to Google Sheets (optional, may fail)
            do {
                let result = try await GoogleSheetsService.shared.logTask(
                    workspace: project.name,
                    project: nil,  // TODO: Add project support
                    task: session.name,
                    billableDescription: billableDescription,
                    estimatedHours: estHrs,
                    actualHours: actHrs,
                    status: "completed",
                    notes: notes
                )

                await MainActor.run {
                    isSaving = false
                    savedSuccessfully = true  // Local save always succeeds at this point

                    if result.success {
                        // Full success - close immediately
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            isPresented = false
                        }
                    } else if result.needs_auth == true {
                        saveError = "Saved locally. Google Sheets not authorized."
                        // Still close after showing message
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isPresented = false
                        }
                    } else {
                        saveError = "Saved locally. Sheets sync: \(result.error ?? "unknown error")"
                        // Still close after showing message
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isPresented = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    savedSuccessfully = true  // Local save succeeded
                    saveError = "Saved locally. Sheets sync failed."
                    // Still close after showing message
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isPresented = false
                    }
                }
            }
        }
    }
}

// Preview available in Xcode only
