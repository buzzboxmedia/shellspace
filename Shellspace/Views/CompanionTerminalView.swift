import SwiftUI

/// Read-only terminal viewer for companion mode.
/// Shows terminal content streamed from the host Mac via relay.
struct CompanionTerminalView: View {
    let session: Session
    @Bindable var client: CompanionClient
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    private var projectName: String {
        session.project?.name ?? session.activeProjectName ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(client.terminalContent.isEmpty ? "Connecting to terminal..." : client.terminalContent)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("terminal-bottom")
                }
                .background(Color(NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.11, alpha: 1.0)))
                .onChange(of: client.terminalContent) {
                    withAnimation(.none) {
                        proxy.scrollTo("terminal-bottom", anchor: .bottom)
                    }
                }
            }

            // Status bar + input
            VStack(spacing: 0) {
                Divider()

                // Status indicators
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(projectName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()

                // Input field
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)

                    TextField("Send input...", text: $inputText)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .focused($inputFocused)
                        .onSubmit {
                            sendInput()
                        }

                    if !inputText.isEmpty {
                        Button(action: sendInput) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
        }
        .onAppear {
            client.subscribeTerminal(sessionId: session.id.uuidString)
            inputFocused = true
        }
        .onDisappear {
            client.unsubscribeTerminal()
        }
    }

    private var statusColor: Color {
        if client.terminalIsWaiting { return .orange }
        if client.terminalIsRunning { return .green }
        return .gray
    }

    private var statusText: String {
        if client.terminalIsWaiting { return "Waiting for input" }
        if client.terminalIsRunning { return "Running" }
        return "Idle"
    }

    private func sendInput() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        _ = client.sendInput(sessionId: session.id.uuidString, message: text + "\n")
        inputText = ""
    }
}
