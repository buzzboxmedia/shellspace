import SwiftUI
import SwiftTerm
import AppKit
import os.log

private let viewLogger = Logger(subsystem: "com.buzzbox.claudehub", category: "TerminalView")

struct TerminalView: View {
    let session: Session
    @EnvironmentObject var appState: AppState
    @State private var forceRefresh = false
    @State private var summarizationTimer: Timer?

    // Get controller from AppState so it persists when switching sessions
    var terminalController: TerminalController {
        appState.getOrCreateController(for: session)
    }

    var isStarted: Bool {
        terminalController.terminalView != nil
    }

    var body: some View {
        let _ = forceRefresh  // Force view to depend on this state
        ZStack {
            if isStarted {
                SwiftTermView(controller: terminalController)
                    .id(session.id)  // Ensure view updates when session changes
                    .onAppear {
                        startSummarizationCheck()
                    }
                    .onDisappear {
                        summarizationTimer?.invalidate()
                    }
            } else {
                // Show loading state while auto-starting
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))

                    Text("Starting Claude...")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(session.projectPath)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)))
                .onAppear {
                    viewLogger.info("TerminalView appeared for session: \(session.name), claudeSessionId: \(session.claudeSessionId ?? "none")")
                    // Auto-start Claude with delay to avoid fork crash
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        viewLogger.info("Starting Claude in: \(session.projectPath)")
                        terminalController.startClaude(in: session.projectPath, sessionId: session.id, claudeSessionId: session.claudeSessionId)
                        // Trigger view refresh and capture session ID
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            forceRefresh.toggle()
                        }
                        // After Claude starts, try to capture the session ID
                        if session.claudeSessionId == nil {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                captureClaudeSessionId()
                            }
                        }
                    }
                }
            }
        }
    }

    private func startSummarizationCheck() {
        viewLogger.info("Starting summarization check timer for session: \(session.name)")
        // Check every 5 seconds if we should summarize
        summarizationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            checkAndSummarize()
        }
    }

    private func captureClaudeSessionId() {
        // Convert project path to Claude's folder format
        let claudeProjectPath = session.projectPath.replacingOccurrences(of: "/", with: "-")
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

            // Update the session with the Claude session ID
            appState.updateClaudeSessionId(session, claudeSessionId: sessionId)
        } else {
            viewLogger.warning("No session files found in Claude projects directory")
        }
    }

    private func checkAndSummarize() {
        // Only summarize once per session
        guard !terminalController.hasSummarized else {
            viewLogger.debug("Already summarized this session, skipping")
            return
        }

        let content = terminalController.getTerminalContent()
        viewLogger.info("Checking terminal content: \(content.count) characters")

        // Look for signs that Claude has responded (at least 50 lines of content)
        let lineCount = content.components(separatedBy: "\n").count
        viewLogger.info("Terminal has \(lineCount) lines")

        // Check if there's meaningful content (Claude typically outputs a lot when it responds)
        if lineCount > 30 && content.contains("Claude") {
            viewLogger.info("Detected Claude response, triggering summarization")
            terminalController.hasSummarized = true
            summarizationTimer?.invalidate()

            ClaudeAPI.shared.summarizeChat(content: content) { title in
                if let title = title {
                    viewLogger.info("Received summary title: '\(title)'")
                    appState.updateSessionName(session, name: title)
                } else {
                    viewLogger.warning("Summarization returned nil")
                }
            }
        }
    }
}

// Controller to manage the terminal and process
class TerminalController: ObservableObject {
    @Published var terminalView: LocalProcessTerminalView?
    private var currentSessionId: UUID?
    var hasSummarized = false
    private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "TerminalController")

    // Get terminal content for summarization
    func getTerminalContent() -> String {
        guard let terminal = terminalView?.getTerminal() else {
            logger.warning("No terminal available for content extraction")
            return ""
        }

        // Use the public API to get buffer content
        let data = terminal.getBufferAsData()
        let content = String(data: data, encoding: .utf8) ?? ""

        // Limit to ~4000 characters for API call
        let truncated = String(content.suffix(4000))
        logger.info("Extracted \(truncated.count) characters from terminal (from \(content.count) total)")
        return truncated
    }

    func startClaude(in directory: String, sessionId: UUID, claudeSessionId: String? = nil) {
        logger.info("startClaude called for directory: \(directory), sessionId: \(sessionId), claudeSessionId: \(claudeSessionId ?? "none")")

        // Don't restart if already running for this session
        if currentSessionId == sessionId && terminalView != nil {
            logger.info("Claude already running for this session, skipping")
            return
        }

        currentSessionId = sessionId

        // Create terminal view if needed
        if terminalView == nil {
            logger.info("Creating new LocalProcessTerminalView")
            terminalView = LocalProcessTerminalView(frame: .zero)
            configureTerminal()
        }

        // Find claude path
        let claudePath = findClaudePath()
        logger.info("Found claude at: \(claudePath)")

        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = "\(NSHomeDirectory())/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin"

        let envArray = env.map { "\($0.key)=\($0.value)" }

        // Start bash shell
        logger.info("Starting bash shell")
        terminalView?.startProcess(
            executable: "/bin/bash",
            environment: envArray
        )

        // Send cd command to change directory, then start claude
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let claudeCommand: String
            if let resumeId = claudeSessionId {
                // Resume existing session
                claudeCommand = "cd '\(directory)' && claude --resume '\(resumeId)'\n"
                self?.logger.info("Resuming Claude session: \(resumeId)")
            } else {
                // Start new session
                claudeCommand = "cd '\(directory)' && claude\n"
                self?.logger.info("Starting new Claude session")
            }
            self?.terminalView?.send(txt: claudeCommand)
        }
    }

    private func configureTerminal() {
        guard let terminal = terminalView else { return }

        // Configure appearance
        terminal.configureNativeColors()

        // Set up colors for dark terminal
        terminal.nativeForegroundColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        terminal.nativeBackgroundColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)

        // Set font
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Set cursor style
        terminal.caretColor = NSColor.systemBlue
    }

    private func findClaudePath() -> String {
        let possiblePaths = [
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try to find via `which`
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
                return path
            }
        } catch {}

        return "/usr/local/bin/claude"
    }
}

// SwiftUI wrapper for SwiftTerm's LocalProcessTerminalView
struct SwiftTermView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        let containerView = TerminalContainerView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.12, alpha: 1.0).cgColor

        if controller.terminalView == nil {
            controller.terminalView = LocalProcessTerminalView(frame: .zero)
        }

        if let terminalView = controller.terminalView {
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(terminalView)
            containerView.terminalView = terminalView

            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: containerView.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])

            // Auto-focus the terminal
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Focus terminal when view updates
        if let container = nsView as? TerminalContainerView {
            container.focusTerminal()
        }
    }
}

// Container view that handles click-to-focus and key forwarding
class TerminalContainerView: NSView {
    weak var terminalView: LocalProcessTerminalView?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Don't forward - just focus the terminal and let it handle keys directly
        focusTerminal()
    }

    override func keyUp(with event: NSEvent) {
        // Consumed - terminal handles its own key events
    }

    override func flagsChanged(with event: NSEvent) {
        // Consumed - terminal handles its own key events
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Configure window to accept key events
        if let window = window {
            window.acceptsMouseMovedEvents = true
            window.makeKeyAndOrderFront(nil)
        }

        // Focus terminal when added to window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.focusTerminal()
        }
    }

    override func becomeFirstResponder() -> Bool {
        // When we become first responder, immediately pass to terminal
        DispatchQueue.main.async { [weak self] in
            self?.focusTerminal()
        }
        return true
    }

    func focusTerminal() {
        guard let terminal = terminalView, let window = window else { return }

        // Make this app active and frontmost
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Make window key
        window.makeKeyAndOrderFront(nil)

        // Make terminal first responder with slight delay to ensure view hierarchy is ready
        DispatchQueue.main.async {
            let success = window.makeFirstResponder(terminal)
            if !success {
                // If terminal won't accept, make container the responder
                window.makeFirstResponder(self)
            }
        }
    }
}

// Preview available in Xcode only
