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
            TerminalArea()
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

    var sessions: [Session] {
        appState.sessionsFor(project: project)
    }

    var projectLinkedSessions: [Session] {
        sessions.filter { $0.isProjectLinked }
    }

    var generalSessions: [Session] {
        sessions.filter { !$0.isProjectLinked }
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

                // Session list - fills remaining space
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // New Chat button
                        Button {
                            let newSession = appState.createSession(for: project)
                            windowState.activeSession = newSession
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("New Chat")
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

                        // Active Projects Section
                        if !projectLinkedSessions.isEmpty {
                            Text("ACTIVE PROJECTS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.2)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)

                            LazyVStack(spacing: 4) {
                                ForEach(projectLinkedSessions) { session in
                                    SessionRow(session: session)
                                }
                            }
                        }

                        // General Chats Section
                        if !generalSessions.isEmpty {
                            Text("CHATS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.2)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)

                            LazyVStack(spacing: 4) {
                                ForEach(generalSessions) { session in
                                    SessionRow(session: session)
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
        .background(.ultraThinMaterial.opacity(0.5))
    }
}

struct SessionRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let session: Session
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editedName: String = ""

    var isActive: Bool {
        windowState.activeSession?.id == session.id
    }

    var body: some View {
        HStack(spacing: 10) {
            // Enhanced status indicator
            ZStack {
                if isActive {
                    Circle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 16, height: 16)
                }
                Circle()
                    .fill(isActive ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
            .frame(width: 16, height: 16)

            if isEditing {
                TextField("Session name", text: $editedName, onCommit: {
                    appState.updateSessionName(session, name: editedName)
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Show "Project" badge for linked sessions
                    if session.isProjectLinked {
                        Text("Project")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
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
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct TerminalHeader: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .shadow(color: Color.green.opacity(0.6), radius: 4)

            Text(session.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

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

    var body: some View {
        Group {
            if let session = windowState.activeSession {
                VStack(spacing: 0) {
                    TerminalHeader(session: session)
                    Divider()
                    TerminalView(session: session)
                }
            } else {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)

                    Text("Select a chat or start a new one")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.3))
            }
        }
    }
}

// Preview available in Xcode only
