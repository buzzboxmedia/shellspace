import SwiftUI
import SwiftTerm
import AppKit
import Speech
import os.log

private let viewLogger = Logger(subsystem: "com.buzzbox.shellspace", category: "TerminalView")

// MARK: - Speech Recognition Service

class SpeechService: ObservableObject {
    static let shared = SpeechService()

    @Published var isListening = false
    @Published var transcript = ""
    @Published var pendingSend = false
    @Published var remainingTime: TimeInterval = 60

    // Accumulated transcript for keyboard toggle mode (Option+D)
    private var accumulatedTranscript = ""
    // Current session's transcript (gets appended to accumulated on stop)
    private var currentSessionTranscript = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var countdownTimer: Timer?
    private let logger = Logger(subsystem: "com.buzzbox.shellspace", category: "SpeechService")

    /// Progress from 1.0 (full) to 0.0 (empty) for timer ring
    var timerProgress: Double {
        max(0, remainingTime / 60.0)
    }

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.logger.info("Speech recognition authorized")
                    completion(true)
                case .denied, .restricted, .notDetermined:
                    self.logger.warning("Speech recognition not authorized: \(String(describing: status))")
                    completion(false)
                @unknown default:
                    completion(false)
                }
            }
        }
    }

    /// Start listening. If accumulate=true (keyboard mode), appends to existing transcript.
    func startListening(accumulate: Bool = false) {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            logger.error("Speech recognizer not available")
            return
        }

        // Stop any existing audio session (but don't clear accumulated if accumulating)
        stopAudioEngine()

        do {
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                logger.error("Unable to create recognition request")
                return
            }

            recognitionRequest.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                self.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            DispatchQueue.main.async {
                self.isListening = true
                self.remainingTime = 60
                self.currentSessionTranscript = ""
                // Show accumulated + current in transcript display
                self.transcript = self.accumulatedTranscript
            }

            // Start countdown timer
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.remainingTime -= 0.1
                    if self.remainingTime <= 0 {
                        self.logger.info("60s limit reached, auto-stopping")
                        self.stopListening(send: false)
                    }
                }
            }

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }

                if let error = error {
                    self.logger.error("Recognition error: \(error.localizedDescription)")
                    if (error as NSError).code == 1110 {
                        return
                    }
                }

                if let result = result {
                    DispatchQueue.main.async {
                        self.currentSessionTranscript = result.bestTranscription.formattedString
                        // Display accumulated + current
                        if self.accumulatedTranscript.isEmpty {
                            self.transcript = self.currentSessionTranscript
                        } else {
                            self.transcript = self.accumulatedTranscript + " " + self.currentSessionTranscript
                        }
                    }
                }
            }

            logger.info("Started listening (accumulate=\(accumulate)) - speak now")

        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            stopListening(send: false)
        }
    }

    /// Stop audio engine without changing transcript state
    private func stopAudioEngine() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    /// Stop recording. If send=true, immediately paste to terminal. If send=false, hold transcript for later paste.
    func stopListening(send: Bool) {
        stopAudioEngine()

        // Append current session to accumulated
        if !currentSessionTranscript.isEmpty {
            if accumulatedTranscript.isEmpty {
                accumulatedTranscript = currentSessionTranscript
            } else {
                accumulatedTranscript += " " + currentSessionTranscript
            }
            currentSessionTranscript = ""
        }

        let finalTranscript = accumulatedTranscript

        DispatchQueue.main.async {
            self.isListening = false
            self.transcript = finalTranscript

            if send && !finalTranscript.isEmpty {
                // Immediate send (e.g. push-to-talk release or button)
                self.transcript = ""
                self.accumulatedTranscript = ""
                self.pendingSend = false
                self.logger.info("Posting transcript to terminal: \(finalTranscript)")
                NotificationCenter.default.post(
                    name: .sendDictationToTerminal,
                    object: finalTranscript
                )
            } else if !finalTranscript.isEmpty {
                // Hold transcript for Option+F paste (keyboard mode)
                self.pendingSend = true
                self.logger.info("Transcript ready to paste (\(finalTranscript.count) chars)")
            } else {
                self.transcript = ""
                self.pendingSend = false
            }
        }
    }

    /// Paste the held transcript into the terminal (Option+F)
    func pasteTranscript() {
        guard !transcript.isEmpty else {
            logger.info("No transcript to paste")
            return
        }
        let text = transcript
        logger.info("Pasting transcript to terminal: \(text)")
        NotificationCenter.default.post(
            name: .sendDictationToTerminal,
            object: text
        )
        transcript = ""
        accumulatedTranscript = ""
        pendingSend = false
    }

    func confirmSend() {
        pendingSend = false
        logger.info("Confirming send - posting Enter")
        NotificationCenter.default.post(
            name: .sendDictationToTerminal,
            object: "\r"
        )
    }

    /// Start listening for button mode (no accumulation, sends immediately on stop)
    func startListeningIfAuthorized() {
        guard !isListening else { return }
        // Button mode: clear any accumulated transcript, start fresh
        accumulatedTranscript = ""
        currentSessionTranscript = ""
        requestAuthorization { authorized in
            if authorized {
                self.startListening(accumulate: false)
            } else {
                self.logger.warning("Speech recognition not authorized")
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
            }
        }
    }

    /// Option+D: first press starts, second press stops (holds transcript for Option+F)
    /// Accumulates across multiple recordings until Option+F sends
    func toggleListening() {
        if isListening {
            stopListening(send: false)
        } else {
            // Don't clear - accumulate mode preserves existing transcript
            pendingSend = false
            requestAuthorization { authorized in
                if authorized {
                    self.startListening(accumulate: true)
                } else {
                    self.logger.warning("Speech recognition not authorized")
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
                }
            }
        }
    }

    /// Clear accumulated transcript (e.g., user wants to start fresh)
    func clearTranscript() {
        transcript = ""
        accumulatedTranscript = ""
        currentSessionTranscript = ""
        pendingSend = false
        logger.info("Transcript cleared")
    }
}

struct TerminalView: View {
    let session: Session
    @EnvironmentObject var appState: AppState
    @State private var forceRefresh = false
    @State private var showTerminal = false  // Delay showing terminal until Claude initializes
    @ObservedObject private var speechService = SpeechService.shared

    // Get controller from AppState so it persists when switching sessions
    var terminalController: TerminalController {
        appState.getOrCreateController(for: session)
    }

    // Check if terminal exists AND process is still alive
    var terminalAlreadyExists: Bool {
        terminalController.terminalView?.process?.running == true
    }

    // Show terminal immediately if it already exists, or wait for showTerminal after init
    var isStarted: Bool {
        terminalAlreadyExists || showTerminal
    }

    var body: some View {
        let _ = forceRefresh  // Force view to depend on this state
        let _ = DebugLog.log("[TerminalView] body: session=\(session.name), isStarted=\(isStarted), showTerminal=\(showTerminal)")
        ZStack {
            if isStarted {
                SwiftTermView(controller: terminalController)
                    .id(session.id)  // Ensure view updates when session changes
                    .onDisappear {
                        // Save log when leaving the view
                        terminalController.saveLog(for: session)
                    }

                // Floating mic bar - bottom right with transcript
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Spacer()

                        // Live transcript (while recording) or held transcript (ready to paste)
                        if speechService.isListening || speechService.pendingSend {
                            HStack(spacing: 8) {
                                if speechService.isListening && speechService.transcript.isEmpty {
                                    Text("Listening...")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .italic()
                                } else if !speechService.transcript.isEmpty {
                                    Text(speechService.transcript)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white)
                                        .lineLimit(3)
                                    if speechService.pendingSend {
                                        Text("⌥S to send")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, 4)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(maxWidth: 400, alignment: .trailing)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                            .animation(.easeInOut(duration: 0.2), value: speechService.isListening)
                            .animation(.easeInOut(duration: 0.2), value: speechService.pendingSend)
                        }

                        TalkButton(speechService: speechService)
                    }
                    .padding(16)
                }
            } else {
                // Show loading state while auto-starting
                VStack(spacing: 24) {
                    ZStack {
                        // Animated glow behind spinner
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 80, height: 80)
                            .blur(radius: 20)

                        ProgressView()
                            .scaleEffect(1.8)
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0.4, green: 0.6, blue: 1.0)))
                    }

                    VStack(spacing: 8) {
                        Text("Initializing Claude...")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color(red: 0.85, green: 0.88, blue: 0.95))

                        Text(session.name)
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 0.5, green: 0.55, blue: 0.65))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.11, alpha: 1.0)))
            }
        }
        .onAppear {
            DebugLog.log("[TerminalView] onAppear: \(session.name)")
            ensureClaudeStarted()
        }
        .task(id: session.id) {
            await MainActor.run {
                DebugLog.log("[TerminalView] .task(id:): \(session.name)")
                ensureClaudeStarted()
            }
        }
    }

    /// Start Claude if not already running — called from both onAppear and .task for reliability
    private func ensureClaudeStarted() {
        DebugLog.log("[ensureClaude] session=\(session.name), showTerminal=\(showTerminal), processRunning=\(terminalController.terminalView?.process?.running == true)")

        if terminalController.terminalView?.process?.running == true {
            DebugLog.log("[ensureClaude]   Already running — show immediately")
            showTerminal = true
            return
        }

        guard !showTerminal else {
            DebugLog.log("[ensureClaude]   Already started (showTerminal=true) — skip")
            return
        }

        DebugLog.log("[ensureClaude]   Starting Claude in: \(session.taskFolderPath ?? session.projectPath)")
        terminalController.startClaude(
            in: session.projectPath,
            sessionId: session.id,
            claudeSessionId: session.claudeSessionId,
            parkerBriefing: session.parkerBriefing,
            taskFolderPath: session.taskFolderPath,
            hasBeenLaunched: session.hasBeenLaunched
        )
        session.hasBeenLaunched = true
        showTerminal = true
        DebugLog.log("[ensureClaude]   DONE — showTerminal=true")

        if session.claudeSessionId == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                captureClaudeSessionId()
            }
        }
    }

    private func captureClaudeSessionId() {
        // Use task folder path if available (matches where Claude was started)
        // Resolve symlinks to match Claude CLI's internal path resolution
        let workingPath = (session.taskFolderPath ?? session.projectPath).canonicalPath
        // Convert path to Claude's folder format (slashes become hyphens)
        let claudeProjectPath = workingPath.replacingOccurrences(of: "/", with: "-")
        let claudeProjectsDir = "\(NSHomeDirectory())/.claude/projects/\(claudeProjectPath)"

        viewLogger.info("Looking for Claude session in: \(claudeProjectsDir)")

        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: claudeProjectsDir) else {
            viewLogger.warning("Could not read Claude projects directory")
            return
        }

        // Find the most recently modified .jsonl file
        var latestFile: (name: String, date: Date)?
        for file in files where file.hasSuffix(".jsonl") {
            let filePath = "\(claudeProjectsDir)/\(file)"
            if let attrs = try? fileManager.attributesOfItem(atPath: filePath),
               let modDate = attrs[.modificationDate] as? Date {
                if latestFile == nil || modDate > latestFile!.date {
                    latestFile = (file, modDate)
                }
            }
        }

        if let latest = latestFile {
            // Extract UUID from filename (remove .jsonl extension)
            let sessionId = String(latest.name.dropLast(6))  // Remove ".jsonl"
            viewLogger.info("Captured Claude session ID: \(sessionId)")

            // Update the session with the Claude session ID (SwiftData auto-saves)
            session.claudeSessionId = sessionId
        } else {
            viewLogger.warning("No session files found in Claude projects directory")
        }
    }
}

// MARK: - Talk Button (tap to toggle, hold to push-to-talk)
//
// Quick tap: toggle recording on/off (stop sends transcript)
// Hold (>0.3s): push-to-talk — starts on press, stops+sends on release
// Shortcuts: Option+R to record, Option+S to send, Option+X to cancel

struct TalkButton: View {
    @ObservedObject var speechService: SpeechService
    @State private var pressStartTime: Date?
    @State private var wasListeningOnPress = false
    @State private var isPressed: Bool = false
    @State private var isHovered: Bool = false

    private let holdThreshold: TimeInterval = 0.3

    /// Timer ring color - transitions from red to orange to amber as time runs out
    private var timerColor: SwiftUI.Color {
        let remaining = speechService.remainingTime
        if remaining > 15 {
            return SwiftUI.Color.red.opacity(0.6)
        } else if remaining > 5 {
            return SwiftUI.Color.orange.opacity(0.8)
        } else {
            return SwiftUI.Color(red: 1.0, green: 0.4, blue: 0.0) // Amber/urgent
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Timer ring — drains clockwise as 60s limit approaches
                if speechService.isListening {
                    // Background track (faint)
                    Circle()
                        .stroke(Color.red.opacity(0.15), lineWidth: 3)
                        .frame(width: 60, height: 60)

                    // Progress arc (drains from full to empty)
                    Circle()
                        .trim(from: 0, to: speechService.timerProgress)
                        .stroke(
                            timerColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(-90)) // Start at 12 o'clock
                        .animation(.linear(duration: 0.1), value: speechService.timerProgress)
                }

                Circle()
                    .fill(speechService.isListening ? Color.red : Color(red: 0.25, green: 0.45, blue: 0.85))
                    .frame(width: 48, height: 48)
                    .shadow(
                        color: speechService.isListening ? Color.red.opacity(0.5) : Color.blue.opacity(0.4),
                        radius: 8
                    )
                    .scaleEffect(isPressed ? 0.88 : 1.0)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.6), value: isPressed)

                Image(systemName: speechService.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .scaleEffect(isPressed ? 0.88 : 1.0)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.6), value: isPressed)
            }
            .contentShape(Circle())
            // onHover gives instant cursor feedback without polling
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressStartTime == nil else { return }
                        pressStartTime = Date()
                        wasListeningOnPress = speechService.isListening
                        isPressed = true

                        if !speechService.isListening {
                            speechService.startListeningIfAuthorized()
                        }
                    }
                    .onEnded { _ in
                        let holdDuration = pressStartTime.map { Date().timeIntervalSince($0) } ?? 0
                        pressStartTime = nil
                        isPressed = false

                        if holdDuration > holdThreshold {
                            // Long press (push-to-talk): stop and send
                            speechService.stopListening(send: true)
                        } else {
                            // Quick tap
                            if wasListeningOnPress {
                                // Was already recording — stop and send
                                speechService.stopListening(send: true)
                            }
                            // else: started on press, leave running (toggle mode)
                        }
                        wasListeningOnPress = false
                    }
            )
            .help("Tap to toggle / Hold for push-to-talk")
        }
    }
}

// Controller to manage the terminal and process
class TerminalController: ObservableObject {
    @Published var terminalView: ShellspaceTerminalView?
    private var currentSessionId: UUID?
    var projectPath: String?  // Store project path for screenshot saving
    private let logger = Logger(subsystem: "com.buzzbox.shellspace", category: "TerminalController")

    // MARK: - Pop-Out to Terminal.app

    /// Opens the session in Terminal.app using `claude --continue`
    func popOutToTerminal(workingDir: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(workingDir)' && claude --continue"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                logger.error("AppleScript error: \(error)")
            } else {
                logger.info("Opened Terminal.app for: \(workingDir)")
            }
        }
    }

    // Font size management
    private static let defaultFontSize: CGFloat = 13
    private static let minFontSize: CGFloat = 8
    private static let maxFontSize: CGFloat = 32
    var fontSize: CGFloat = defaultFontSize

    func increaseFontSize() {
        fontSize = min(fontSize + 1, Self.maxFontSize)
        updateFont()
    }

    func decreaseFontSize() {
        fontSize = max(fontSize - 1, Self.minFontSize)
        updateFont()
    }

    func resetFontSize() {
        fontSize = Self.defaultFontSize
        updateFont()
    }

    private func updateFont() {
        guard let terminal = terminalView else { return }
        if let sfMono = NSFont(name: "SF Mono", size: fontSize) {
            terminal.font = sfMono
        } else {
            terminal.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        logger.info("Font size changed to: \(self.fontSize)")
    }

    // MARK: - Voice Dictation

    func toggleDictation() {
        SpeechService.shared.toggleListening()
    }

    // MARK: - Log Management

    /// Save the current terminal content to a log file (centralized in Dropbox)
    func saveLog(for session: Session) {
        let content = getFullTerminalContent()
        guard !content.isEmpty else {
            logger.info("No content to save for session: \(session.name)")
            return
        }

        // Use centralized logs directory in Dropbox
        let logsDir = Session.centralLogsDir

        // Create logs directory if needed
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create logs directory: \(error.localizedDescription)")
            return
        }

        let logPath = session.logPath

        // Write log with timestamp header
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let readableDate = dateFormatter.string(from: Date())

        let header = """
        === Shellspace Session Log ===
        Session: \(session.name)
        Project: \(session.projectPath)
        Saved: \(readableDate)
        ID: \(session.id.uuidString)
        =====================================

        """

        let fullContent = header + content

        do {
            try fullContent.write(to: logPath, atomically: true, encoding: .utf8)
            logger.info("Saved log for session '\(session.name)' to: \(logPath.path)")

            // Update session with log info (SwiftData auto-saves)
            session.logFilePath = logPath.path
            session.lastLogSavedAt = Date()
        } catch {
            logger.error("Failed to save log: \(error.localizedDescription)")
        }
    }

    /// Get the full terminal content (not truncated)
    func getFullTerminalContent() -> String {
        guard let terminal = terminalView?.getTerminal() else {
            logger.warning("No terminal available for content extraction")
            return ""
        }

        let data = terminal.getBufferAsData()
        let content = String(data: data, encoding: .utf8) ?? ""
        logger.info("Extracted \(content.count) characters from terminal (full)")
        return content
    }

    /// Send text to the terminal (for the Update button)
    func sendToTerminal(_ text: String) {
        terminalView?.send(txt: text)
    }

    func startClaude(in directory: String, sessionId: UUID, claudeSessionId: String? = nil, parkerBriefing: String? = nil, taskFolderPath: String? = nil, hasBeenLaunched: Bool = false) {
        DebugLog.log("[startClaude] directory=\(directory), sessionId=\(sessionId), hasBeenLaunched=\(hasBeenLaunched), taskFolderPath=\(taskFolderPath ?? "nil")")
        logger.info("startClaude called for directory: \(directory), sessionId: \(sessionId)")

        // Don't restart if already running for this session (check process is alive)
        if currentSessionId == sessionId && terminalView != nil {
            if terminalView?.process?.running == true {
                DebugLog.log("[startClaude]   Already running for this session — skipping")
                logger.info("Claude already running for this session, skipping")
                return
            }
            // Process is dead - clear terminal so we can restart
            DebugLog.log("[startClaude]   Process dead — restarting")
            logger.info("Previous Claude process exited, restarting")
            terminalView = nil
        }

        currentSessionId = sessionId
        projectPath = directory

        // Create terminal view
        if terminalView == nil {
            let terminal = ShellspaceTerminalView(frame: .zero)
            terminal.projectPath = directory
            terminalView = terminal
            configureTerminal()
        }

        // Use task folder if it exists on disk, otherwise fall back to project directory
        let workingDir: String
        if let taskFolder = taskFolderPath, FileManager.default.fileExists(atPath: taskFolder) {
            workingDir = taskFolder
        } else {
            workingDir = directory
        }
        let hasExistingSession = checkForExistingSession(in: workingDir)
        // Only continue if this session was previously launched AND has an existing Claude session.
        // New tasks (hasBeenLaunched=false) should always start fresh, even if the fallback
        // directory has an old conversation.
        let shouldContinue = hasExistingSession && hasBeenLaunched
        let claudePath = findClaudePath()

        DebugLog.log("[startClaude]   workingDir=\(workingDir), hasExistingSession=\(hasExistingSession), hasBeenLaunched=\(hasBeenLaunched), shouldContinue=\(shouldContinue)")
        logger.info("Claude at: \(claudePath), workingDir: \(workingDir), continue=\(shouldContinue)")

        // Build claude args
        var claudeArgs = [String]()
        if shouldContinue { claudeArgs.append("--continue") }
        claudeArgs.append("--dangerously-skip-permissions")

        // Write a minimal startup script: cd + exec claude (no .zshrc sourcing)
        let scriptDir = FileManager.default.temporaryDirectory.appendingPathComponent("shellspace")
        try? FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        let scriptPath = scriptDir.appendingPathComponent("start-\(sessionId.uuidString).sh")

        var scriptLines = ["#!/bin/zsh", "cd '\(workingDir)' 2>/dev/null || cd '\(directory)'"]
        if let briefing = parkerBriefing {
            scriptLines.append("echo '\(briefing.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        scriptLines.append("exec '\(claudePath)' \(claudeArgs.map { "'\($0)'" }.joined(separator: " "))")

        try? scriptLines.joined(separator: "\n").appending("\n").write(to: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // Environment: inherit user env, ensure nvm path + terminal support
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["HOME"] = NSHomeDirectory()
        // Remove CLAUDECODE so Claude doesn't think it's a nested session
        env.removeValue(forKey: "CLAUDECODE")
        let nvmBin = "\(NSHomeDirectory())/.nvm/versions/node/v22.22.0/bin"
        if let path = env["PATH"], !path.contains(nvmBin) {
            env["PATH"] = "\(nvmBin):\(path)"
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // Launch: zsh runs the script which cd's and exec's claude
        logger.info("Launching startup script: \(scriptPath.path)")
        terminalView?.startProcess(
            executable: "/bin/zsh",
            args: [scriptPath.path],
            environment: envArray
        )

        // Focus terminal after Claude starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if let terminal = self?.terminalView, let window = terminal.window {
                if let responder = window.firstResponder,
                   responder is NSTextView || responder is NSTextField { return }
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(terminal)
            }
        }
    }

    /// Check if there's an existing Claude session for the given directory
    private func checkForExistingSession(in directory: String) -> Bool {
        // Resolve symlinks to get the real path (Claude does this internally)
        let resolvedPath = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        // Convert path to Claude's folder format (slashes become hyphens)
        let claudeProjectPath = resolvedPath.replacingOccurrences(of: "/", with: "-")
        let claudeProjectsDir = "\(NSHomeDirectory())/.claude/projects/\(claudeProjectPath)"

        DebugLog.log("[checkExisting] directory=\(directory)")
        DebugLog.log("[checkExisting]   resolvedPath=\(resolvedPath)")
        DebugLog.log("[checkExisting]   claudeProjectsDir=\(claudeProjectsDir)")

        // Check if the directory exists and has any .jsonl files
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: claudeProjectsDir),
              let files = try? fileManager.contentsOfDirectory(atPath: claudeProjectsDir) else {
            DebugLog.log("[checkExisting]   FOLDER NOT FOUND or empty")
            return false
        }

        let hasSessionFiles = files.contains { $0.hasSuffix(".jsonl") }
        DebugLog.log("[checkExisting]   files=\(files.count), hasJsonl=\(hasSessionFiles)")
        logger.info("Checking for existing session in \(claudeProjectsDir): \(hasSessionFiles ? "found" : "none")")
        return hasSessionFiles
    }

    func configureTerminal() {
        guard let terminal = terminalView else { return }

        // Configure appearance
        terminal.configureNativeColors()

        // Disable mouse reporting so text selection works
        terminal.allowMouseReporting = false

        // Shellspace custom theme - dark neutral grey
        terminal.nativeBackgroundColor = NSColor(
            calibratedRed: 0.1, green: 0.1, blue: 0.11, alpha: 1.0
        )

        // Foreground: Near-white for crisp input text
        terminal.nativeForegroundColor = NSColor(
            calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0
        )

        // Selection: Matches the app's blue accent
        terminal.selectedTextBackgroundColor = NSColor(
            calibratedRed: 0.25, green: 0.45, blue: 0.85, alpha: 0.45
        )

        // Cursor: Blue accent to match the UI
        terminal.caretColor = NSColor(
            calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 1.0
        )

        // Set font - SF Mono for cleaner look, slightly larger for readability
        if let sfMono = NSFont(name: "SF Mono", size: 15.5) {
            terminal.font = sfMono
        } else {
            terminal.font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        }

        // Install custom ANSI color palette matching Shellspace theme
        installShellspaceColorPalette(terminal: terminal)
    }

    /// Custom 16-color ANSI palette designed to match Shellspace's glass UI
    private func installShellspaceColorPalette(terminal: ShellspaceTerminalView) {
        let terminalCore = terminal.getTerminal()

        // Shellspace palette - blue-tinted with purple/cyan accents
        let palette: [SwiftTerm.Color] = [
            // 0: Black (dark neutral grey matching terminal background)
            SwiftTerm.Color(red: 26, green: 26, blue: 28),
            // 1: Red (warm coral)
            SwiftTerm.Color(red: 255, green: 107, blue: 107),
            // 2: Green (mint)
            SwiftTerm.Color(red: 98, green: 209, blue: 150),
            // 3: Yellow (warm gold)
            SwiftTerm.Color(red: 255, green: 203, blue: 107),
            // 4: Blue (vibrant blue - primary accent)
            SwiftTerm.Color(red: 102, green: 153, blue: 255),
            // 5: Magenta (soft purple)
            SwiftTerm.Color(red: 199, green: 146, blue: 234),
            // 6: Cyan (bright teal)
            SwiftTerm.Color(red: 102, green: 217, blue: 239),
            // 7: White (pure white for crisp input text)
            SwiftTerm.Color(red: 255, green: 255, blue: 255),

            // 8-15: Bright variants
            // 8: Bright Black (medium grey)
            SwiftTerm.Color(red: 90, green: 99, blue: 117),
            // 9: Bright Red
            SwiftTerm.Color(red: 255, green: 134, blue: 134),
            // 10: Bright Green
            SwiftTerm.Color(red: 152, green: 232, blue: 186),
            // 11: Bright Yellow
            SwiftTerm.Color(red: 255, green: 218, blue: 143),
            // 12: Bright Blue
            SwiftTerm.Color(red: 138, green: 180, blue: 255),
            // 13: Bright Magenta
            SwiftTerm.Color(red: 214, green: 175, blue: 243),
            // 14: Bright Cyan
            SwiftTerm.Color(red: 150, green: 232, blue: 248),
            // 15: Bright White
            SwiftTerm.Color(red: 255, green: 255, blue: 255),
        ]

        terminalCore.installPalette(colors: palette)
        logger.info("Installed Shellspace color palette")
    }

    /// Cached claude path -- resolved once per app session to avoid repeated shell calls
    private static var cachedClaudePath: String?

    private func findClaudePath() -> String {
        if let cached = Self.cachedClaudePath { return cached }

        let possiblePaths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                Self.cachedClaudePath = path
                return path
            }
        }

        // Try to find via `which` (synchronous, but only runs once)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["claude"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                Self.cachedClaudePath = path
                return path
            }
        } catch {}

        let fallback = "/usr/local/bin/claude"
        Self.cachedClaudePath = fallback
        return fallback
    }
}

// MARK: - ShellspaceTerminalView (subclass eliminates container view, fixing text selection)

/// Subclass of LocalProcessTerminalView that adds Shellspace features directly,
/// eliminating the container view that was intercepting mouse events and breaking selection.
class ShellspaceTerminalView: LocalProcessTerminalView {
    var projectPath: String?
    private let chLogger = Logger(subsystem: "com.buzzbox.shellspace", category: "ShellspaceTerminal")
    private(set) var keyMonitor: Any?

    // MARK: - Setup

    private var dictationObserver: Any?

    func configureShellspace() {
        allowMouseReporting = false
        setupDragDrop()
        setupKeyMonitor()
        setupDictationListener()
    }

    private func setupDictationListener() {
        dictationObserver = NotificationCenter.default.addObserver(
            forName: .sendDictationToTerminal,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let transcript = notification.object as? String,
                  self.window?.isKeyWindow == true else { return }
            self.chLogger.info("Dictation received via notification: \(transcript)")
            self.send(txt: transcript)
        }
    }


    private func setupDragDrop() {
        registerForDraggedTypes([.fileURL, .png, .tiff, .pdf] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    // MARK: - Drag and Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hasFiles = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasPromises = sender.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        if hasFiles || hasPromises {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Try file promises first (Mail, etc.)
        if let promises = sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            handleFilePromises(promises)
            return true
        }

        // Fall back to regular file URLs
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }

        for url in urls {
            let path = url.path
            chLogger.info("File dropped: \(path)")
            send(txt: path + " ")
        }

        focusTerminal()
        return true
    }

    private func handleFilePromises(_ promises: [NSFilePromiseReceiver]) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Shellspace-drops-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let group = DispatchGroup()
        var receivedURLs: [URL] = []

        for promise in promises {
            group.enter()
            promise.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: .main) { [weak self] url, error in
                if let error = error {
                    self?.chLogger.error("Failed to receive promised file: \(error.localizedDescription)")
                } else {
                    receivedURLs.append(url)
                    self?.chLogger.info("Received promised file: \(url.path)")
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            for url in receivedURLs {
                self?.send(txt: url.path + " ")
            }
            self?.focusTerminal()
        }
    }

    // MARK: - Key Monitor (Cmd+C copy, Cmd+V image paste, Cmd+A select all, Cmd+K clear, Cmd+Shift+D dictate)

    func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  event.modifierFlags.contains(.command),
                  event.window == self.window else {
                return event
            }

            // Check for Cmd+Shift+D (dictation)
            if event.modifierFlags.contains(.shift) && event.charactersIgnoringModifiers == "d" {
                SpeechService.shared.toggleListening()
                return nil
            }

            switch event.charactersIgnoringModifiers {
            case "c":
                if self.copySelectedText() {
                    return nil
                }
                return event
            case "a":
                self.selectAll(self)
                self.chLogger.info("Select all triggered")
                return nil
            case "k":
                let terminalObj = self.getTerminal()
                terminalObj.resetToInitialState()
                self.setNeedsDisplay(self.bounds)
                self.chLogger.info("Terminal cleared")
                return nil
            case "v":
                if self.handleImagePaste() {
                    return nil
                }
            default:
                break
            }
            return event
        }
    }

    private func copySelectedText() -> Bool {
        let previousContent = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        copy(self)

        if let newContent = NSPasteboard.general.string(forType: .string),
           !newContent.isEmpty {
            chLogger.info("Copied \(newContent.count) characters to clipboard")
            return true
        }

        if let previous = previousContent {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(previous, forType: .string)
        }

        chLogger.info("No text selected to copy")
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        if event.charactersIgnoringModifiers == "v" {
            if handleImagePaste() {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleImagePaste() -> Bool {
        let pasteboard = NSPasteboard.general

        guard let image = NSImage(pasteboard: pasteboard) else {
            return false
        }

        chLogger.info("Detected image in clipboard, saving to project")

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            chLogger.error("Failed to convert clipboard image to PNG")
            return false
        }

        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileName = "screenshot-\(timestamp).png"

        var saveDir: URL = fileManager.temporaryDirectory
        if let projectPath = projectPath {
            let screenshotsDir = URL(fileURLWithPath: projectPath)
                .appendingPathComponent(".shellspace-screenshots")

            do {
                try fileManager.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
                saveDir = screenshotsDir
                chLogger.info("Using screenshots folder: \(screenshotsDir.path)")
            } catch {
                chLogger.error("Failed to create screenshots folder: \(error.localizedDescription)")
            }
        }

        let filePath = saveDir.appendingPathComponent(fileName)

        do {
            try pngData.write(to: filePath)
            chLogger.info("Saved clipboard image to: \(filePath.path)")
            send(txt: filePath.path)
            focusTerminal()
            return true
        } catch {
            chLogger.error("Failed to save clipboard image: \(error.localizedDescription)")
            return false
        }
    }

    // Mouse move monitor removed - it was triggering needsDisplay on every pixel of mouse
    // movement, causing continuous full terminal redraws. SwiftTerm handles its own cursor
    // rendering and mouse tracking internally.

    // MARK: - Focus Management

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window = window {
            window.acceptsMouseMovedEvents = true
            window.makeKeyAndOrderFront(nil)

            // Window is ready for mouse tracking
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, let window = self.window else { return }
            if let responder = window.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return
            }
            self.focusTerminal()
        }
    }

    func focusTerminal() {
        guard let window = window else { return }

        if let currentResponder = window.firstResponder,
           currentResponder !== self,
           currentResponder is NSTextView || currentResponder is NSTextField {
            chLogger.debug("Not stealing focus from text input")
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(self)
    }

    // MARK: - Scroll to Bottom

    /// Scrolls the terminal to show the most recent output
    func scrollToEnd() {
        // scroll(toPosition: 1.0) scrolls to the bottom (most recent output)
        scroll(toPosition: 1.0)
    }
    // MARK: - Cleanup

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dictationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - SwiftUI Wrapper

struct SwiftTermView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        if controller.terminalView == nil {
            let terminal = ShellspaceTerminalView(frame: .zero)
            controller.terminalView = terminal
            controller.configureTerminal()
        }

        let terminalView = controller.terminalView!

        // Configure Shellspace features (drag-drop, key monitor, dictation)
        // Skip if already configured (view can be re-made when switching sessions)
        if terminalView.keyMonitor == nil {
            terminalView.configureShellspace()
        }

        // When returning a cached terminal view, it needs to be refreshed
        // Force a redraw to ensure content is visible
        terminalView.needsDisplay = true
        terminalView.needsLayout = true

        // Scroll to bottom and focus with staggered delays
        // First scroll quickly to show content, then scroll again after layout completes
        DispatchQueue.main.async {
            terminalView.scrollToEnd()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            terminalView.scrollToEnd()
            terminalView.needsDisplay = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            terminalView.focusTerminal()
        }

        return terminalView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // When the view is updated (e.g., becoming visible again after switching),
        // ensure it's scrolled to the bottom and redrawn
        guard let terminalView = controller.terminalView else { return }

        // Schedule scroll after layout pass completes
        DispatchQueue.main.async {
            terminalView.scrollToEnd()
            terminalView.needsDisplay = true
        }
    }
}

// Preview available in Xcode only
