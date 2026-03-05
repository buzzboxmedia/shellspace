import SwiftUI

struct LiteSessionsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var navigationPath = NavigationPath()
    @State private var showCreateSheet = false
    @State private var sentSessionId: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if !viewModel.connectionState.isConnected && viewModel.activeSessions.isEmpty {
                    ContentUnavailableView(
                        "Not Connected",
                        systemImage: "wifi.slash",
                        description: Text("Connect to your Mac to see sessions")
                    )
                } else if viewModel.activeSessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "text.bubble",
                        description: Text("Tap + to start a new session")
                    )
                } else {
                    List {
                        // Waiting sessions at top
                        if !viewModel.waitingSessions.isEmpty {
                            Section("Waiting for Input") {
                                ForEach(viewModel.waitingSessions) { session in
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
                            }
                        }

                        // All active sessions
                        let nonWaiting = viewModel.activeSessions.filter { !$0.isWaitingForInput }
                        if !nonWaiting.isEmpty {
                            Section("Active") {
                                ForEach(nonWaiting) { session in
                                    NavigationLink(value: session) {
                                        LiteSessionRow(session: session)
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
            .navigationTitle(viewModel.displayTitle)
            .navigationDestination(for: RemoteSession.self) { session in
                TerminalView(session: session)
                    .environment(viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Connection status dot
                    Button {
                        viewModel.showSettings = true
                    } label: {
                        Circle()
                            .fill(viewModel.connectionState.color)
                            .frame(width: 10, height: 10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Connection: \(viewModel.connectionState.label)")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            viewModel.showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }

                        Button {
                            showCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(viewModel.primaryProject == nil)
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                if let project = viewModel.primaryProject {
                    CreateSessionSheet(project: project) { newSession in
                        Task { await viewModel.refresh() }
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
        }
    }
}

// MARK: - Waiting Session Row (with pulsing dot + quick reply chips)

struct WaitingSessionRow: View {
    let session: RemoteSession
    let onQuickReply: (String) -> Void
    let showSentConfirmation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: pulsing dot + session name + time
            HStack(spacing: 8) {
                PulsingDot()
                VStack(alignment: .leading, spacing: 2) {
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

// MARK: - Lite Session Row (simple, no project name since we're locked)

struct LiteSessionRow: View {
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

            if session.isRunning {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        if session.isRunning { return .green }
        if session.isCompleted { return .gray.opacity(0.5) }
        return .gray
    }
}
