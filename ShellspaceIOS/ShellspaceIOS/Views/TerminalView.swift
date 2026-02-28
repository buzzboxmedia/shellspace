import SwiftUI
import PhotosUI

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
    @State private var connectionDotColor: Color = .gray
    @State private var showImageSourcePicker = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isUploadingImage = false
    @State private var speechService = SpeechService()
    @AppStorage("terminalFontSize") private var fontSize: Double = 14
    @FocusState private var inputFocused: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    private static let ansiRegex = try! Regex("\\x1B\\[[0-9;]*[a-zA-Z]")
    private static let nullRegex = try! Regex("\\x00+")
    private static let decorativeRegex = try! Regex("[\\u2500-\\u259F]+")

    /// Strip ANSI/null/decorative chars and trim trailing blank lines
    private static func cleanContent(_ raw: String) -> String {
        let stripped = raw
            .replacing(nullRegex, with: " ")
            .replacing(ansiRegex, with: "")
            .replacing(decorativeRegex, with: "")
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
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .id("terminalBottom")
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
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

            // Quick action chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    TerminalChip(label: "stop", isDestructive: true) { sendMessage("stop") }
                    TerminalChip(label: "/compact", isDestructive: true) { sendMessage("/compact") }

                    Divider()
                        .frame(height: 20)
                        .overlay(Color.gray.opacity(0.4))

                    TerminalChip(label: "yes") { sendMessage("yes") }
                    TerminalChip(label: "no") { sendMessage("no") }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(white: 0.1))

            // Transcript preview (shown while recording or with unsent transcript)
            if speechService.isListening || !speechService.transcript.isEmpty {
                HStack(spacing: 8) {
                    if speechService.isListening {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .opacity(0.8)
                    }
                    Text(speechService.transcript.isEmpty ? "Listening..." : speechService.transcript)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(speechService.isListening ? .white : .white.opacity(0.8))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !speechService.isListening && !speechService.transcript.isEmpty {
                        Button {
                            speechService.clearTranscript()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.gray)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(speechService.isListening ? Color.red.opacity(0.15) : Color(white: 0.12))
            }

            // Input bar
            HStack(spacing: 8) {
                Button {
                    showImageSourcePicker = true
                } label: {
                    if isUploadingImage {
                        ProgressView()
                            .tint(.gray)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.gray.opacity(0.8))
                            .frame(width: 32, height: 32)
                    }
                }
                .disabled(isUploadingImage)

                Button {
                    handleMicTap()
                } label: {
                    Image(systemName: speechService.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 20))
                        .foregroundStyle(speechService.isListening ? .red : .gray.opacity(0.8))
                        .frame(width: 32, height: 32)
                }

                TextField("Send to terminal...", text: $inputText, axis: .vertical)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .lineLimit(1...5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { sendCurrentInput() }

                Button {
                    sendCurrentInput()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(inputText.isEmpty && speechService.transcript.isEmpty ? .gray.opacity(0.5) : .blue)
                }
                .disabled(inputText.isEmpty && speechService.transcript.isEmpty)
                .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.1))
        }
        .confirmationDialog("Send Image", isPresented: $showImageSourcePicker) {
            Button("Take Photo") { showCamera = true }
            Button("Choose from Library") { showPhotoPicker = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task { await handleSelectedPhoto(newItem) }
            selectedPhotoItem = nil
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image in
                showCamera = false
                guard let image else { return }
                Task { await uploadImage(image) }
            }
            .ignoresSafeArea()
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
                    Button {
                        UIPasteboard.general.string = terminalContent
                        withAnimation { showSentToast = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            withAnimation { showSentToast = false }
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
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
            subscribeToTerminal()
            startTerminalObserver()
        }
        .onDisappear {
            pollTask?.cancel()
            viewModel.wsManager?.unsubscribeTerminal()
        }
    }

    // MARK: - Terminal Subscription

    private func subscribeToTerminal() {
        viewModel.wsManager?.subscribeTerminal(sessionId: session.id)
    }

    private func startTerminalObserver() {
        pollTask?.cancel()
        pollTask = Task {
            var wasConnected = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                guard let wsManager = viewModel.wsManager else { break }

                let isConnected = wsManager.tunnelState == .connected

                // Re-subscribe after reconnect so the Mac starts streaming
                if isConnected && !wasConnected {
                    wsManager.subscribeTerminal(sessionId: session.id)
                }
                wasConnected = isConnected

                let wsContent = wsManager.terminalContent
                if !wsContent.isEmpty {
                    let stripped = Self.cleanContent(wsContent)
                    if stripped != terminalContent {
                        terminalContent = stripped
                        isRunning = wsManager.terminalIsRunning
                    }
                }

                // Update connection color
                switch wsManager.tunnelState {
                case .connected: connectionDotColor = .green
                case .connecting, .reconnecting: connectionDotColor = .yellow
                case .disconnected: connectionDotColor = .red
                }
            }
        }
    }

    // MARK: - Actions

    private func handleMicTap() {
        if speechService.isListening {
            // Stop recording — transcript stays visible for review
            speechService.stopListening()
        } else if !speechService.transcript.isEmpty {
            // Has unsent transcript — send it
            let text = speechService.transcript
            speechService.clearTranscript()
            sendMessage(text)
        } else {
            // Start recording
            speechService.requestAuthorization()
            speechService.startListening()
        }
    }

    private func sendCurrentInput() {
        // Prefer speech transcript if text field is empty
        if inputText.trimmingCharacters(in: .whitespaces).isEmpty && !speechService.transcript.isEmpty {
            let text = speechService.transcript
            speechService.clearTranscript()
            sendMessage(text)
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
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
            } else {
                sendError = "Error: \(viewModel.lastSendError)"
            }
        }
    }

    // MARK: - Image Upload

    private func handleSelectedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            sendError = "Failed to load selected photo"
            return
        }
        await uploadImage(image)
    }

    private func uploadImage(_ image: UIImage) async {
        guard let jpegData = image.jpegData(compressionQuality: 0.7) else {
            sendError = "Failed to compress image"
            return
        }

        isUploadingImage = true
        defer { isUploadingImage = false }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "photo-\(timestamp).jpg"

        let success = await viewModel.sendImage(
            sessionId: session.id,
            imageData: jpegData,
            filename: filename
        )

        if success {
            sendError = ""
            withAnimation { showSentToast = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showSentToast = false }
        } else {
            sendError = "Image upload failed"
        }
    }
}

// MARK: - Camera View (UIImagePickerController wrapper)

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
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
