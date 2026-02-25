import SwiftUI

struct TerminalView: View {
    @Environment(AppViewModel.self) private var viewModel
    let session: RemoteSession

    @State private var terminalContent = ""
    @State private var isRunning = false
    @State private var inputText = ""
    @State private var isUserScrolledUp = false
    @State private var showSentToast = false
    @State private var pollTask: Task<Void, Never>?
    @State private var useWebSocket = false
    @State private var connectionDotColor: Color = .gray
    @AppStorage("terminalFontSize") private var fontSize: Double = 14
    @FocusState private var inputFocused: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    private static let ansiRegex = try! Regex("\\x1B\\[[0-9;]*[a-zA-Z]")
    // Strip box-drawing, block elements, braille, and other decorative Unicode
    private static let decorativeRegex = try! Regex("[\\u2500-\\u257F\\u2580-\\u259F\\u2800-\\u28FF\\u2190-\\u21FF\\u25A0-\\u25FF\\u2700-\\u27BF\\u2E80-\\u2EFF\\u3000-\\u303F]+")

    var body: some View {
        VStack(spacing: 0) {
            // Terminal content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminalContent.isEmpty ? " " : terminalContent)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .id("terminalBottom")
                }
                .defaultScrollAnchor(.bottom)
                .background(Color.black)
                .onChange(of: terminalContent) {
                    if !isUserScrolledUp {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("terminalBottom", anchor: .bottom)
                        }
                    }
                }
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.height > 10 {
                                isUserScrolledUp = true
                            }
                        }
                )
                .overlay(alignment: .bottomTrailing) {
                    if isUserScrolledUp {
                        Button {
                            isUserScrolledUp = false
                            withAnimation {
                                proxy.scrollTo("terminalBottom", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(12)
                        }
                    }
                }
            }

            // Quick action chips - dark themed
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    TerminalChip(label: "stop", isDestructive: true) { sendMessage("stop") }
                    TerminalChip(label: "/clear", isDestructive: true) { sendMessage("/clear") }

                    Divider()
                        .frame(height: 20)
                        .overlay(Color.gray.opacity(0.4))

                    TerminalChip(label: "yes") { sendMessage("yes") }
                    TerminalChip(label: "no") { sendMessage("no") }
                    TerminalChip(label: "continue") { sendMessage("continue") }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(white: 0.1))

            // Input bar - dark themed
            HStack(spacing: 8) {
                TextField("Send to terminal...", text: $inputText, axis: .vertical)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(2...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(minHeight: 52)
                    .background(Color(white: 0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { sendCurrentInput() }

                Button {
                    sendCurrentInput()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(inputText.isEmpty ? .gray.opacity(0.5) : .blue)
                }
                .disabled(inputText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.1))
        }
        .toolbarBackground(Color(white: 0.1), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle(session.projectName + " / " + session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isLandscape ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button { fontSize = max(8, fontSize - 2) } label: {
                        Image(systemName: "textformat.size.smaller")
                            .font(.caption)
                    }
                    Button { fontSize = min(24, fontSize + 2) } label: {
                        Image(systemName: "textformat.size.larger")
                            .font(.caption)
                    }
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .overlay {
            if showSentToast {
                VStack {
                    Spacer()
                    SentConfirmation()
                        .padding(12)
                        .background(Color(white: 0.2))
                        .clipShape(Capsule())
                        .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            connectionDotColor = connectionColor
            await loadTerminal()
            connectWebSocket()
        }
        .onDisappear {
            pollTask?.cancel()
            viewModel.wsManager?.disconnectTerminal()
        }
    }

    private var connectionColor: Color {
        guard let ws = viewModel.wsManager else { return .gray }
        switch ws.terminalState {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

    // MARK: - WebSocket

    private func connectWebSocket() {
        guard let wsManager = viewModel.wsManager else {
            startPolling()
            return
        }

        wsManager.connectTerminal(sessionId: session.id)
        useWebSocket = true
        startWebSocketObserver()
    }

    private func startWebSocketObserver() {
        pollTask?.cancel()
        pollTask = Task {
            var wsEmptyCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                guard let wsManager = viewModel.wsManager else { break }

                // Update connection color
                connectionDotColor = connectionColor

                let wsContent = wsManager.terminalContent
                if !wsContent.isEmpty {
                    wsEmptyCount = 0
                    let stripped = wsContent.replacing(Self.ansiRegex, with: "").replacing(Self.decorativeRegex, with: "")
                    if stripped != terminalContent {
                        terminalContent = stripped
                        isRunning = wsManager.terminalIsRunning
                    }
                } else {
                    wsEmptyCount += 1
                    // WebSocket not delivering content — fall back to REST polling
                    if wsEmptyCount >= 10 {
                        await loadTerminal()
                        wsEmptyCount = 5 // Poll every ~2.5s going forward
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func sendCurrentInput() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        sendMessage(text)
    }

    private func sendMessage(_ message: String) {
        Task {
            let success = await viewModel.sendQuickReply(sessionId: session.id, message: message)
            if success {
                withAnimation { showSentToast = true }
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { showSentToast = false }
                // Always refresh via REST after sending
                await loadTerminal()
            }
        }
    }

    private func loadTerminal() async {
        guard let api = viewModel.api else { return }
        do {
            let response = try await api.terminalContent(sessionId: session.id)
            let stripped = response.content.replacing(Self.ansiRegex, with: "").replacing(Self.decorativeRegex, with: "")
            await MainActor.run {
                terminalContent = stripped
                isRunning = response.isRunning
            }
        } catch {}
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await loadTerminal()
            }
        }
    }
}

// MARK: - Terminal Chip (dark themed)

struct TerminalChip: View {
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(isDestructive ? .red.opacity(0.9) : .white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isDestructive ? Color.red.opacity(0.15) : Color.white.opacity(0.1))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        isDestructive ? Color.red.opacity(0.3) : Color.white.opacity(0.2),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }
}
