import SwiftUI

struct WaitingView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var sentSessionId: String?
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if viewModel.waitingSessions.isEmpty {
                    ContentUnavailableView(
                        "All Clear",
                        systemImage: "checkmark.circle",
                        description: Text("No sessions waiting for input")
                    )
                } else {
                    List(viewModel.waitingSessions) { session in
                        NavigationLink(value: session) {
                            WaitingSessionRow(
                                session: session,
                                onQuickReply: { message in
                                    Task {
                                        let success = await viewModel.sendQuickReply(
                                            sessionId: session.id,
                                            message: message
                                        )
                                        if success {
                                            sentSessionId = session.id
                                            try? await Task.sleep(for: .seconds(1.5))
                                            if sentSessionId == session.id {
                                                sentSessionId = nil
                                            }
                                        }
                                    }
                                },
                                showSentConfirmation: sentSessionId == session.id
                            )
                        }
                    }
                    .refreshable {
                        await viewModel.refresh()
                    }
                }
            }
            .navigationTitle("Waiting")
            .navigationDestination(for: RemoteSession.self) { session in
                TerminalView(session: session)
                    .environment(viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.activateSearch = true
                        viewModel.selectedTab = .sessions
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
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
                // Find matching session and navigate to it
                if let session = viewModel.waitingSessions.first(where: { $0.id == sessionId })
                    ?? viewModel.allSessions.first(where: { $0.id == sessionId }) {
                    navigationPath.append(session)
                }
            }
        }
    }
}

struct WaitingSessionRow: View {
    let session: RemoteSession
    let onQuickReply: (String) -> Void
    let showSentConfirmation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: pulsing dot + project/session name + time
            HStack(spacing: 8) {
                PulsingDot()
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                Spacer()
                Text(session.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Summary if available
            if let summary = session.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Quick reply chips
            if !showSentConfirmation {
                HStack(spacing: 8) {
                    QuickChip(label: "yes") { onQuickReply("yes") }
                    QuickChip(label: "no") { onQuickReply("no") }
                    QuickChip(label: "stop", isDestructive: true) { onQuickReply("stop") }
                    QuickChip(label: "/compact", isDestructive: true) { onQuickReply("/compact") }
                }
            } else {
                SentConfirmation()
            }
        }
        .padding(.vertical, 4)
    }
}

struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.orange)
            .frame(width: 10, height: 10)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

struct QuickChip: View {
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    private let navy = Color(red: 0.012, green: 0.169, blue: 0.263)

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(isDestructive ? .red : navy)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isDestructive ? Color.red.opacity(0.08) : navy.opacity(0.08))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isDestructive ? Color.red.opacity(0.3) : navy.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct SentConfirmation: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Sent")
                .font(.caption)
                .foregroundStyle(.green)
        }
        .transition(.scale.combined(with: .opacity))
    }
}
