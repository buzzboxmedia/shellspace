import SwiftUI

struct AllSessionsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""

    /// Projects that have at least one active (non-completed, non-hidden) session
    private var activeProjects: [RemoteProject] {
        let activeProjectPaths = Set(
            viewModel.allActiveSessions.map { $0.projectPath }
        )
        return viewModel.projects
            .filter { activeProjectPaths.contains($0.path) }
            .sorted { $0.name < $1.name }
    }

    private var filteredProjects: [RemoteProject] {
        guard !searchText.isEmpty else { return activeProjects }
        let query = searchText.lowercased()
        return activeProjects.filter {
            $0.name.lowercased().contains(query)
        }
    }

    /// For search: sessions matching the query across all active sessions
    private var filteredSessions: [RemoteSession] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return viewModel.allActiveSessions.filter {
            $0.name.lowercased().contains(query) ||
            ($0.summary?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if viewModel.allActiveSessions.isEmpty && !viewModel.connectionState.isConnected {
                    ContentUnavailableView(
                        "Not Connected",
                        systemImage: "wifi.slash",
                        description: Text("Connect to your Mac to see sessions")
                    )
                } else if filteredProjects.isEmpty && filteredSessions.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if activeProjects.isEmpty {
                    ContentUnavailableView(
                        "No Active Sessions",
                        systemImage: "text.bubble",
                        description: Text("Start a session from the Projects tab")
                    )
                } else {
                    List {
                        // When searching, also show matching sessions directly
                        if !filteredSessions.isEmpty {
                            Section("Sessions") {
                                ForEach(filteredSessions) { session in
                                    NavigationLink(value: session) {
                                        SessionListRow(session: session)
                                    }
                                }
                            }
                        }

                        // Projects with active sessions
                        if !filteredProjects.isEmpty {
                            Section(searchText.isEmpty ? "" : "Projects") {
                                ForEach(filteredProjects) { project in
                                    NavigationLink(value: project) {
                                        ActiveProjectRow(
                                            project: project,
                                            sessions: sessionsForProject(project)
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .refreshable {
                        await viewModel.refresh()
                    }
                }
            }
            .navigationTitle("Sessions")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always)
            )
            .navigationDestination(for: RemoteProject.self) { project in
                SessionsListView(project: project)
            }
            .navigationDestination(for: RemoteSession.self) { session in
                TerminalView(session: session)
                    .environment(viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onChange(of: viewModel.pendingSessionId) { _, sessionId in
                guard let sessionId else { return }
                viewModel.pendingSessionId = nil
                if let session = viewModel.allSessions.first(where: { $0.id == sessionId }) {
                    navigationPath.append(session)
                }
            }
            .onChange(of: viewModel.activateSearch) { _, activate in
                guard activate else { return }
                viewModel.activateSearch = false
            }
        }
    }

    private func sessionsForProject(_ project: RemoteProject) -> [RemoteSession] {
        viewModel.allActiveSessions.filter { $0.projectPath == project.path }
    }
}

// MARK: - Active Project Row

struct ActiveProjectRow: View {
    let project: RemoteProject
    let sessions: [RemoteSession]

    private var waitingCount: Int {
        sessions.filter { $0.isWaitingForInput }.count
    }

    private var runningCount: Int {
        sessions.filter { $0.isRunning && !$0.isWaitingForInput }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: project.icon)
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 12) {
                    Label("\(sessions.count) session\(sessions.count == 1 ? "" : "s")", systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if waitingCount > 0 {
                        Label("\(waitingCount) waiting", systemImage: "bell.badge")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            if waitingCount > 0 {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
            } else if runningCount > 0 {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SessionListRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let summary = session.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(session.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if session.isWaitingForInput {
                Image(systemName: "bell.badge.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        if session.isWaitingForInput { return .orange }
        if session.isRunning { return .green }
        return .gray
    }
}
