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
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

            // Terminal area
            TerminalArea(project: project)
                .frame(minWidth: 500)
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
    @State private var newTaskName = ""
    @FocusState private var isTaskFieldFocused: Bool

    var sessions: [Session] {
        appState.sessionsFor(project: project)
    }

    var projectLinkedSessions: [Session] {
        sessions.filter { $0.isProjectLinked }
    }

    var taskSessions: [Session] {
        sessions.filter { !$0.isProjectLinked }
    }

    func createTask() {
        let name = newTaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isCreatingTask = false
            newTaskName = ""
            return
        }

        let newSession = appState.createSession(for: project, name: name)
        windowState.activeSession = newSession
        isCreatingTask = false
        newTaskName = ""
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                // Header row - fixed height
                VStack(alignment: .leading, spacing: 12) {
                    // Back button - subtle
                    Button(action: goBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .medium))
                            Text("Back")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isBackHovered ? Color.white.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { isBackHovered = $0 }

                    // Project name with icon - prominent
                    HStack(spacing: 10) {
                        Image(systemName: project.icon)
                            .font(.system(size: 20))
                            .foregroundStyle(.primary)

                        Text(project.name)
                            .font(.system(size: 18, weight: .semibold))
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
                        // New Task button/input
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
                            .padding(.horizontal, 12)
                            .onAppear { isTaskFieldFocused = true }
                        } else {
                            Button {
                                isCreatingTask = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("New Task")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                        }

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

                        // Tasks Section
                        if !taskSessions.isEmpty {
                            Text("TASKS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.2)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)

                            LazyVStack(spacing: 4) {
                                ForEach(taskSessions) { session in
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

struct TaskRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let session: Session
    let project: Project
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editedName: String = ""

    var isActive: Bool {
        windowState.activeSession?.id == session.id
    }

    var isWaiting: Bool {
        appState.waitingSessions.contains(session.id)
    }

    var isLogged: Bool {
        session.lastSessionSummary != nil && !session.lastSessionSummary!.isEmpty
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
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.name)
                            .font(.system(size: 13))
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

            // Edit and delete buttons on hover
            if isHovered && !isEditing {
                HStack(spacing: 6) {
                    Button {
                        editedName = session.name
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
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
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        .padding(.horizontal, 8)
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
    }
}

struct TerminalHeader: View {
    @EnvironmentObject var appState: AppState
    let session: Session
    let project: Project
    @Binding var showLogSheet: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .shadow(color: Color.green.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let description = session.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            // Log Task button
            Button {
                showLogSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11))
                    Text("Log Task")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.blue.opacity(0.15))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Text("Running")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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
                    Divider()
                    TerminalView(session: session)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                .padding(12)
                .sheet(isPresented: $showLogSheet) {
                    LogTaskSheet(session: session, project: project, isPresented: $showLogSheet)
                }
            } else {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)

                    Text("Select a task or create a new one")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.3))
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
    @State private var notes: String = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var savedSuccessfully = false

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
            VStack(alignment: .leading, spacing: 12) {
                Text("What did you accomplish? What's next?")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                TextEditor(text: $notes)
                    .font(.system(size: 13))
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )

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
                .disabled(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding()
        }
        .frame(width: 450, height: 350)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .onAppear {
            // Pre-fill with existing summary if any
            if let existing = session.lastSessionSummary {
                notes = existing
            }
        }
    }

    func saveLog() {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNotes.isEmpty else { return }

        isSaving = true
        saveError = nil

        Task {
            // Save locally
            appState.updateSessionSummary(session, summary: trimmedNotes)

            // Sync to Google Sheets
            do {
                let result = try await GoogleSheetsService.shared.logTask(
                    project: project.name,
                    task: session.name,
                    status: "completed",
                    notes: trimmedNotes
                )

                await MainActor.run {
                    isSaving = false
                    if result.success {
                        savedSuccessfully = true
                        // Close after a brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            isPresented = false
                        }
                    } else if result.needs_auth == true {
                        saveError = "Google Sheets not authorized. Run: python3 ~/Code/claudehub/scripts/sheets_sync.py auth"
                    } else {
                        // Still saved locally, just note the sync issue
                        saveError = "Saved locally. Google Sheets sync: \(result.error ?? "unknown error")"
                        savedSuccessfully = true
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    // Still saved locally
                    saveError = "Saved locally. Google Sheets sync failed: \(error.localizedDescription)"
                    savedSuccessfully = true
                }
            }
        }
    }
}

// Preview available in Xcode only
