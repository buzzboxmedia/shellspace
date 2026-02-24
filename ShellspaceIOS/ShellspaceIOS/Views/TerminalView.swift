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
    @FocusState private var inputFocused: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    private static let ansiRegex = try! Regex("\\x1B\\[[0-9;]*[a-zA-Z]")

    var body: some View {
        VStack(spacing: 0) {
            // Terminal content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminalContent)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("terminalBottom")
                }
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

            Divider()

            // Quick action chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    QuickChip(label: "yes") { sendMessage("yes") }
                    QuickChip(label: "no") { sendMessage("no") }
                    QuickChip(label: "continue") { sendMessage("continue") }
                    QuickChip(label: "/clear") { sendMessage("/clear") }
                    QuickChip(label: "stop") { sendMessage("stop") }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)

            // Input bar
            HStack(spacing: 8) {
                TextField("Send to terminal...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { sendCurrentInput() }

                Button {
                    sendCurrentInput()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(inputText.isEmpty ? .gray : .blue)
                }
                .disabled(inputText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isLandscape ? .hidden : .automatic, for: .navigationBar)
        .overlay {
            if showSentToast {
                VStack {
                    Spacer()
                    SentConfirmation()
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            await loadTerminal()
            connectWebSocket()
        }
        .onDisappear {
            pollTask?.cancel()
            viewModel.wsManager?.disconnectTerminal()
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { break }
                guard let wsManager = viewModel.wsManager else { break }

                let wsContent = wsManager.terminalContent
                if !wsContent.isEmpty {
                    let stripped = wsContent.replacing(Self.ansiRegex, with: "")
                    if stripped != terminalContent {
                        terminalContent = stripped
                        isRunning = wsManager.terminalIsRunning
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
                if !useWebSocket { await loadTerminal() }
            }
        }
    }

    private func loadTerminal() async {
        guard let api = viewModel.api else { return }
        do {
            let response = try await api.terminalContent(sessionId: session.id)
            let stripped = response.content.replacing(Self.ansiRegex, with: "")
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
