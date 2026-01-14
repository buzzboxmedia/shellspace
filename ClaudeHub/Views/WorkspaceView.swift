import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var appState: AppState
    let project: Project

    var sessions: [Session] {
        appState.sessionsFor(project: project)
    }

    func goBack() {
        withAnimation(.spring(response: 0.3)) {
            appState.selectedProject = nil
            appState.activeSession = nil
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
            // Auto-create a session if none exist for this project
            if appState.sessionsFor(project: project).isEmpty {
                let _ = appState.createSession(for: project)
            } else if appState.activeSession == nil {
                // Select the first session if none active
                appState.activeSession = appState.sessionsFor(project: project).first
            }
        }
    }
}

struct SessionSidebar: View {
    @EnvironmentObject var appState: AppState
    let project: Project
    let goBack: () -> Void
    @State private var isBackHovered = false

    var sessions: [Session] {
        appState.sessionsFor(project: project)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                // Header row - fixed height
                HStack {
                    Button(action: goBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 12))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isBackHovered ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .onHover { isBackHovered = $0 }

                    Spacer()

                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    // Balance spacer
                    Color.clear.frame(width: 60)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)

                Divider()

                // New Chat button
                Button {
                    let _ = appState.createSession(for: project)
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("New Chat")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)

                Divider()

                // Session list - fills remaining space
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sessions) { session in
                            SessionRow(session: session)
                        }
                    }
                    .padding(.vertical, 8)
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
    let session: Session
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editedName: String = ""

    var isActive: Bool {
        appState.activeSession?.id == session.id
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)

            if isEditing {
                TextField("Session name", text: $editedName, onCommit: {
                    appState.updateSessionName(session, name: editedName)
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            } else {
                Text(session.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            // Edit and delete buttons on hover
            if isHovered && !isEditing {
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
                    appState.deleteSession(session)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.blue.opacity(0.2) : (isHovered ? Color.white.opacity(0.1) : Color.clear))
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editedName = session.name
            isEditing = true
        }
        .onTapGesture(count: 1) {
            appState.activeSession = session
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct TerminalArea: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let session = appState.activeSession {
                TerminalView(session: session)
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
