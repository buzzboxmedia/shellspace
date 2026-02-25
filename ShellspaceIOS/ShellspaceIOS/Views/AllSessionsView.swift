import SwiftUI

struct AllSessionsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""

    private var filteredSessions: [RemoteSession] {
        let active = viewModel.allActiveSessions
        guard !searchText.isEmpty else { return active }
        let query = searchText.lowercased()
        return active.filter {
            $0.name.lowercased().contains(query) ||
            $0.projectName.lowercased().contains(query) ||
            ($0.summary?.lowercased().contains(query) ?? false)
        }
    }

    private var groupedSessions: [(String, [RemoteSession])] {
        let grouped = Dictionary(grouping: filteredSessions) { $0.projectName }
        return grouped.sorted { $0.key < $1.key }
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
                } else if filteredSessions.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if filteredSessions.isEmpty {
                    ContentUnavailableView(
                        "No Active Sessions",
                        systemImage: "text.bubble",
                        description: Text("Start a session from the Projects tab")
                    )
                } else {
                    List {
                        ForEach(groupedSessions, id: \.0) { projectName, sessions in
                            Section(projectName) {
                                ForEach(sessions) { session in
                                    NavigationLink(value: session) {
                                        SessionListRow(session: session)
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
