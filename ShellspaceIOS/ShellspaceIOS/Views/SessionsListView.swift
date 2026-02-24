import SwiftUI

struct SessionsListView: View {
    @Environment(AppViewModel.self) private var viewModel
    let project: RemoteProject

    private var projectSessions: [RemoteSession] {
        viewModel.allSessions
            .filter { $0.projectPath == project.path && !$0.isHidden }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var body: some View {
        Group {
            if projectSessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("No active sessions for \(project.name)")
                )
            } else {
                List(projectSessions) { session in
                    NavigationLink(value: session) {
                        SessionRow(session: session)
                    }
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationTitle(project.name)
    }
}

struct SessionRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
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
        if session.isCompleted { return .gray.opacity(0.5) }
        return .gray
    }
}
