import SwiftUI

struct SearchResultsView: View {
    let query: String
    let sessions: [RemoteSession]
    let onSelect: (RemoteSession) -> Void

    private var filtered: [String: [RemoteSession]] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [:] }

        let matches = sessions
            .filter { !$0.isHidden }
            .filter {
                $0.name.localizedCaseInsensitiveContains(q)
                || $0.projectName.localizedCaseInsensitiveContains(q)
                || ($0.summary?.localizedCaseInsensitiveContains(q) ?? false)
            }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }

        return Dictionary(grouping: matches, by: \.projectName)
    }

    private var sortedGroups: [(String, [RemoteSession])] {
        filtered.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if sortedGroups.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(sortedGroups, id: \.0) { projectName, sessions in
                    Section(projectName) {
                        ForEach(sessions) { session in
                            Button {
                                onSelect(session)
                            } label: {
                                SearchResultRow(session: session)
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
        }
    }
}

struct SearchResultRow: View {
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
        if session.isCompleted { return .gray.opacity(0.5) }
        return .gray
    }
}
