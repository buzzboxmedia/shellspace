import SwiftUI

/// Main view when Shellspace is in companion mode.
/// Shows remote projects and sessions from the host Mac via relay tunnel.
struct CompanionLauncherView: View {
    @Bindable var client: CompanionClient
    @State private var selectedSession: RemoteSession?
    @State private var selectedProjectPath: String?
    @State private var showSettings = false

    private var visibleSessions: [RemoteSession] {
        client.sessions
            .filter { !$0.isCompleted && !$0.isHidden }
            .sorted { ($0.lastAccessedDate ?? .distantPast) > ($1.lastAccessedDate ?? .distantPast) }
    }

    private var filteredSessions: [RemoteSession] {
        if let path = selectedProjectPath {
            return visibleSessions.filter { $0.projectPath == path }
        }
        return visibleSessions
    }

    private var waitingSessions: [RemoteSession] {
        visibleSessions.filter { $0.isWaitingForInput }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let session = selectedSession {
                CompanionTerminalView(session: session, client: client)
                    .id(session.id)
            } else {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                connectionStatus
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { client.requestStateRefresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .frame(minWidth: 500, minHeight: 400)
        }
        .onAppear {
            if client.tunnelState == .disconnected {
                client.connect()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSession) {
            // Waiting sessions section
            if !waitingSessions.isEmpty {
                Section {
                    ForEach(waitingSessions) { session in
                        sessionRow(session)
                            .tag(session)
                    }
                } header: {
                    Label("Waiting", systemImage: "hand.raised.fill")
                        .foregroundColor(.orange)
                }
            }

            // Projects
            ForEach(client.projects) { project in
                Section {
                    let projectSessions = filteredSessions(for: project)
                    if projectSessions.isEmpty {
                        Text("No active sessions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(projectSessions) { session in
                            sessionRow(session)
                                .tag(session)
                        }
                    }
                } header: {
                    projectHeader(project)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 240)
        .navigationTitle("Companion")
    }

    private func filteredSessions(for project: RemoteProject) -> [RemoteSession] {
        visibleSessions.filter { $0.projectPath == project.path }
    }

    private func sessionRow(_ session: RemoteSession) -> some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(sessionStatusColor(session))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if session.isWaitingForInput {
                        Text("Waiting")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    } else if session.isRunning {
                        Text("Running")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }

                    Text(session.relativeTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func projectHeader(_ project: RemoteProject) -> some View {
        HStack(spacing: 6) {
            Text(project.icon)
                .font(.system(size: 14))
            Text(project.name)
                .font(.headline)

            Spacer()

            if project.waitingSessions > 0 {
                Text("\(project.waitingSessions)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange))
            }
        }
    }

    private func sessionStatusColor(_ session: RemoteSession) -> Color {
        if session.isWaitingForInput { return .orange }
        if session.isRunning { return .green }
        return .gray
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            if client.tunnelState == .disconnected || client.tunnelState == .connecting {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Connecting to host...")
                    .font(.title3)
                    .foregroundColor(.secondary)
            } else if client.projects.isEmpty {
                Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No projects from host")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("Make sure Shellspace is running on your Mac Studio")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("Select a session")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connection Status

    private var connectionStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            Text(connectionLabel)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var connectionColor: Color {
        switch client.tunnelState {
        case .connected: return .green
        case .connecting: return .yellow
        case .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

    private var connectionLabel: String {
        switch client.tunnelState {
        case .connected:
            return RelayAuth.shared.companionDeviceName ?? "Connected"
        case .connecting:
            return "Connecting..."
        case .reconnecting(let attempt):
            return "Reconnecting (\(attempt))..."
        case .disconnected:
            return "Disconnected"
        }
    }
}
