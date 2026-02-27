import SwiftUI

struct TerminalView: View {
    @Environment(AppViewModel.self) private var viewModel
    let session: RemoteSession

    @State private var terminalContent = ""
    @State private var isRunning = false
    @State private var inputText = ""
    @State private var isUserScrolledUp = false
    @State private var showSentToast = false
    @State private var sendError = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var useWebSocket = false
    @State private var connectionDotColor: Color = .gray
    @AppStorage("terminalFontSize") private var fontSize: Double = 14
    @FocusState private var inputFocused: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    private static let ansiRegex = try! Regex("\\x1B\\[[0-9;]*[a-zA-Z]")
    // Null bytes from SwiftTerm buffer (appear between characters, collapse spaces)
    private static let nullRegex = try! Regex("\\x00+")
    // Box-drawing and block element characters used by Claude's UI
    private static let decorativeRegex = try! Regex("[\\u2500-\\u259F]+")

    /// Strip ANSI/null/decorative chars and trim trailing blank lines
    private static func cleanContent(_ raw: String) -> String {
        let stripped = raw
            .replacing(nullRegex, with: " ")
            .replacing(ansiRegex, with: "")
            .replacing(decorativeRegex, with: "")
        // Trim trailing blank lines from terminal buffer
        var lines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.allSatisfy({ $0.isWhitespace }) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminalContent.isEmpty ? " " : terminalContent)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .id("terminalBottom")
                }
                .defaultScrollAnchor(.bottom)
                .background(Color(red: 0.1, green: 0.1, blue: 0.11))
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
                TextField("Send to terminal...", text: $inputText)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.white)
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
                        .font(.system(size: 32))
                        .foregroundStyle(inputText.isEmpty ? .gray.opacity(0.5) : .blue)
                }
                .disabled(inputText.isEmpty)
                .frame(width: 44, height: 44)
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
            if !sendError.isEmpty {
                VStack {
                    Text(sendError)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 8)
                    Spacer()
                }
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
            var cyclesSinceRESTFetch = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                guard let wsManager = viewModel.wsManager else { break }

                // Update connection color
                connectionDotColor = connectionColor
                cyclesSinceRESTFetch += 1

                let wsContent = wsManager.terminalContent
                if !wsContent.isEmpty {
                    wsEmptyCount = 0
                    let stripped = Self.cleanContent(wsContent)
                    if stripped != terminalContent {
                        terminalContent = stripped
                        isRunning = wsManager.terminalIsRunning
                        cyclesSinceRESTFetch = 0
                    }
                } else {
                    wsEmptyCount += 1
                }

                // REST safety net: fetch every 5s if WS isn't delivering new content
                if wsEmptyCount >= 10 || cyclesSinceRESTFetch >= 10 {
                    await loadTerminal()
                    wsEmptyCount = 0
                    cyclesSinceRESTFetch = 0
                }
            }
        }
    }

    // MARK: - Actions

    private func sendCurrentInput() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            sendError = "Input empty (raw: '\(inputText)')"
            return
        }
        inputText = ""
        sendMessage(text)
    }

    private func sendMessage(_ message: String) {
        Task {
            let success = await viewModel.sendQuickReply(sessionId: session.id, message: message)
            if success {
                sendError = ""
                withAnimation { showSentToast = true }
                try? await Task.sleep(for: .seconds(1))
                withAnimation { showSentToast = false }
                // Poll REST to catch Claude's response (typically 2-10s)
                for _ in 0..<8 {
                    await loadTerminal()
                    try? await Task.sleep(for: .seconds(2))
                }
            } else {
                sendError = "Error: \(viewModel.lastSendError)"
            }
        }
    }

    private func loadTerminal() async {
        guard let api = viewModel.api else { return }
        do {
            let response = try await api.terminalContent(sessionId: session.id)
            let stripped = Self.cleanContent(response.content)
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
