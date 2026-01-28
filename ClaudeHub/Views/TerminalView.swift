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
    @State private var autoSaveTimer: Timer?

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
                        startAutoSave()
                    }
                    .onDisappear {
                        summarizationTimer?.invalidate()
                        autoSaveTimer?.invalidate()
                        // Save log when leaving the view
                        terminalController.saveLog(for: session)
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
                        Text("Starting Claude...")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(red: 0.85, green: 0.88, blue: 0.95))

                        Text(session.projectPath)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 0.5, green: 0.55, blue: 0.65))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.11, alpha: 1.0)))
                .onAppear {
                    viewLogger.info("TerminalView appeared for session: \(session.name), claudeSessionId: \(session.claudeSessionId ?? "none")")
                    // Auto-start Claude with delay to avoid fork crash
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        viewLogger.info("Starting Claude in: \(session.projectPath)")
                        terminalController.startClaude(
                            in: session.projectPath,
                            sessionId: session.id,
                            claudeSessionId: session.claudeSessionId,
                            parkerBriefing: session.parkerBriefing,
                            taskFolderPath: session.taskFolderPath,
                            hasBeenLaunched: session.hasBeenLaunched
                        )
                        // Mark session as launched (for --continue logic on reopening)
                        session.hasBeenLaunched = true
                        // Start waiting state monitor
                        terminalController.startWaitingStateMonitor(session: session, appState: appState)
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

    private func startAutoSave() {
        viewLogger.info("Starting auto-save timer for session: \(session.name)")
        // Auto-save log every 30 seconds
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            terminalController.saveLog(for: session)
        }
    }

    private func captureClaudeSessionId() {
        // Use task folder path if available (matches where Claude was started)
        let workingPath = session.taskFolderPath ?? session.projectPath
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

    private func checkAndSummarize() {
        // Don't auto-rename user-named tasks
        guard !session.userNamed else {
            viewLogger.debug("User-named task, skipping auto-rename")
            terminalController.hasSummarized = true
            return
        }

        // Only summarize once per session
        guard !terminalController.hasSummarized else {
            viewLogger.debug("Already summarized this session, skipping")
            return
        }

        let content = terminalController.getTerminalContent()
        viewLogger.info("Checking terminal content: \(content.count) characters")

        let lineCount = content.components(separatedBy: "\n").count
        viewLogger.info("Terminal has \(lineCount) lines")

        // Wait for some content to appear
        guard lineCount > 10 else { return }

        // Try to extract user's first input and send to Claude for a title
        if let userInput = extractUserInput(from: content) {
            viewLogger.info("Extracted user input: '\(userInput)'")
            terminalController.hasSummarized = true
            summarizationTimer?.invalidate()

            // Send user's input to Claude to generate a smart title
            ClaudeAPI.shared.generateTitle(from: userInput) { title in
                if let title = title {
                    viewLogger.info("Claude generated title: '\(title)'")
                    session.name = title  // SwiftData auto-saves
                } else {
                    // Fallback: use cleaned up input directly
                    let fallbackTitle = self.cleanupTitle(userInput)
                    viewLogger.info("Using fallback title: '\(fallbackTitle)'")
                    session.name = fallbackTitle  // SwiftData auto-saves
                }
            }
            return
        }

        // Fallback: if we have Claude response but couldn't extract input, use full content
        if lineCount > 30 && content.contains("Claude") {
            viewLogger.info("Falling back to full content summarization")
            terminalController.hasSummarized = true
            summarizationTimer?.invalidate()

            ClaudeAPI.shared.summarizeChat(content: content) { title in
                if let title = title {
                    viewLogger.info("Received summary title: '\(title)'")
                    session.name = title  // SwiftData auto-saves
                } else {
                    viewLogger.warning("Summarization returned nil")
                }
            }
        }
    }

    /// Extract the user's first input from terminal content
    private func extractUserInput(from content: String) -> String? {
        let lines = content.components(separatedBy: "\n")

        // Look for the user's input after Claude's prompt
        // Claude Code shows ">" or "❯" when waiting for input
        var foundPrompt = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            if trimmed.isEmpty { continue }

            // Look for Claude's input prompt
            if trimmed.hasPrefix(">") || trimmed.hasPrefix("❯") {
                // The text after the prompt is user input
                let afterPrompt = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if !afterPrompt.isEmpty && afterPrompt.count > 3 {
                    return String(afterPrompt)
                }
                foundPrompt = true
                continue
            }

            // If we found a prompt, the next non-empty line is likely user input
            if foundPrompt && !trimmed.isEmpty {
                // Skip lines that look like Claude output
                if trimmed.hasPrefix("Claude") || trimmed.hasPrefix("●") || trimmed.hasPrefix("⏺") {
                    continue
                }
                if trimmed.count > 5 {
                    return trimmed
                }
            }
        }

        return nil
    }

    /// Clean up user input to make a good title
    private func cleanupTitle(_ input: String) -> String {
        var title = input

        // Remove common prefixes
        let prefixes = ["help me ", "please ", "can you ", "i need to ", "i want to "]
        for prefix in prefixes {
            if title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
                break
            }
        }

        // Capitalize first letter
        if let first = title.first {
            title = first.uppercased() + title.dropFirst()
        }

        // Truncate if too long (max ~50 chars)
        if title.count > 50 {
            // Try to break at a word boundary
            if let spaceIndex = title.prefix(50).lastIndex(of: " ") {
                title = String(title[..<spaceIndex]) + "..."
            } else {
                title = String(title.prefix(47)) + "..."
            }
        }

        return title
    }
}

// Controller to manage the terminal and process
class TerminalController: ObservableObject {
    @Published var terminalView: ClaudeHubTerminalView?
    private var currentSessionId: UUID?
    var hasSummarized = false
    var projectPath: String?  // Store project path for screenshot saving
    private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "TerminalController")

    // Waiting state detection
    private var waitingStateTimer: Timer?
    private var lastTerminalContent: String = ""
    private var contentUnchangedCount: Int = 0
    private weak var appState: AppState?
    var currentSession: Session?  // Made internal for AppState access

    /// Callback when waiting state changes
    var onWaitingStateChanged: ((Bool) -> Void)?

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

    // MARK: - Waiting State Detection

    /// Start monitoring for Claude waiting state
    func startWaitingStateMonitor(session: Session, appState: AppState) {
        self.currentSession = session
        self.appState = appState
        self.lastTerminalContent = ""
        self.contentUnchangedCount = 0

        // Poll every 2 seconds
        waitingStateTimer?.invalidate()
        waitingStateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkWaitingState()
        }
        logger.info("Started waiting state monitor for session: \(session.name)")
    }

    /// Stop monitoring waiting state
    func stopWaitingStateMonitor() {
        waitingStateTimer?.invalidate()
        waitingStateTimer = nil
        logger.info("Stopped waiting state monitor")
    }

    /// Check if Claude is waiting for input or actively working
    private func checkWaitingState() {
        let content = getTerminalContent()

        // Check if content has changed
        if content == lastTerminalContent {
            contentUnchangedCount += 1

            // Content stable - Claude stopped outputting
            if let session = currentSession {
                appState?.clearSessionWorking(session)
            }
        } else {
            contentUnchangedCount = 0
            lastTerminalContent = content

            // Content changed - Claude is actively working
            if let session = currentSession {
                appState?.markSessionWorking(session)
            }
        }

        // If content unchanged for 2+ checks (~4 seconds) and shows prompt, mark as waiting
        if contentUnchangedCount >= 2 && isClaudePromptVisible(in: content) {
            if let session = currentSession {
                // Get project name from path for notification
                let projectName = URL(fileURLWithPath: session.projectPath).lastPathComponent
                appState?.markSessionWaiting(session, projectName: projectName)
                onWaitingStateChanged?(true)
            }
        }
    }

    /// Check if Claude's input prompt is visible at the end of terminal output
    private func isClaudePromptVisible(in content: String) -> Bool {
        let lines = content.components(separatedBy: "\n")

        // Check last few non-empty lines for prompt
        let recentLines = lines.suffix(10).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        for line in recentLines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Claude Code prompt patterns
            if trimmed.hasPrefix(">") || trimmed.hasPrefix("❯") {
                // Make sure it's not just showing a prompt with text (user typing)
                let afterPrompt = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if afterPrompt.isEmpty {
                    logger.debug("Found empty Claude prompt - waiting for input")
                    return true
                }
            }

            // Also check for the full prompt line pattern (e.g., "> " at start)
            if trimmed == ">" || trimmed == "❯" {
                return true
            }
        }

        return false
    }

    /// Notify that user is interacting (typing, etc.)
    func userInteracted() {
        contentUnchangedCount = 0
        if let session = currentSession {
            appState?.clearSessionWaiting(session)
        }
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
        === ClaudeHub Session Log ===
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

    func startClaude(in directory: String, sessionId: UUID, claudeSessionId: String? = nil, parkerBriefing: String? = nil, taskFolderPath: String? = nil, hasBeenLaunched: Bool = false) {
        logger.info("startClaude called for directory: \(directory), sessionId: \(sessionId), claudeSessionId: \(claudeSessionId ?? "none")")
        logger.info("DEBUG: currentSessionId=\(String(describing: self.currentSessionId)), terminalView=\(self.terminalView != nil ? "exists" : "nil")")

        // Don't restart if already running for this session
        if currentSessionId == sessionId && terminalView != nil {
            logger.info("Claude already running for this session, skipping")
            return
        }

        logger.info("DEBUG: Will start new Claude session (currentSessionId mismatch or no terminalView)")

        currentSessionId = sessionId
        projectPath = directory  // Store for screenshot saving

        // Create terminal view if needed
        if terminalView == nil {
            logger.info("Creating new ClaudeHubTerminalView")
            let terminal = ClaudeHubTerminalView(frame: .zero)
            terminal.projectPath = directory
            terminalView = terminal
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
        env["BASH_SILENCE_DEPRECATION_WARNING"] = "1"

        let envArray = env.map { "\($0.key)=\($0.value)" }

        // Start zsh shell
        logger.info("Starting zsh shell")
        terminalView?.startProcess(
            executable: "/bin/zsh",
            environment: envArray
        )

        // Send commands with optional Parker briefing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // If there's a Parker briefing, echo it first
            if let briefing = parkerBriefing {
                let escapedBriefing = briefing.replacingOccurrences(of: "'", with: "'\\''")
                self?.terminalView?.send(txt: "echo '\(escapedBriefing)'\n")
                self?.logger.info("Echoed Parker briefing")

                // Small delay before starting Claude so briefing is visible
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startClaudeCommand(in: directory, claudeSessionId: claudeSessionId, taskFolderPath: taskFolderPath, hasBeenLaunched: hasBeenLaunched)
                }
            } else {
                self?.startClaudeCommand(in: directory, claudeSessionId: claudeSessionId, taskFolderPath: taskFolderPath, hasBeenLaunched: hasBeenLaunched)
            }
        }
    }

    private func startClaudeCommand(in directory: String, claudeSessionId: String?, taskFolderPath: String? = nil, hasBeenLaunched: Bool = false) {
        // Use task folder as working directory if available (enables per-task session isolation)
        let workingDir = taskFolderPath ?? directory

        // Check for existing Claude session
        let hasExistingSession = checkForExistingSession(in: workingDir)

        // Debug logging
        logger.info("DEBUG startClaudeCommand: hasBeenLaunched=\(hasBeenLaunched), taskFolderPath=\(taskFolderPath ?? "nil"), hasExistingSession=\(hasExistingSession)")
        print("DEBUG: hasBeenLaunched=\(hasBeenLaunched), taskFolderPath=\(taskFolderPath ?? "nil"), hasExistingSession=\(hasExistingSession)")

        // Continue if there's a task folder with an existing Claude session
        // (the presence of a session file is the reliable indicator, not hasBeenLaunched flag)
        let shouldContinue = taskFolderPath != nil && hasExistingSession

        let claudeCommand: String
        if shouldContinue {
            claudeCommand = "cd '\(workingDir)' && claude --continue --dangerously-skip-permissions\n"
            logger.info("Starting Claude in: \(workingDir) with --continue (task has been launched before)")
            print("DEBUG: Using --continue")
        } else {
            claudeCommand = "cd '\(workingDir)' && claude --dangerously-skip-permissions\n"
            logger.info("Starting Claude in: \(workingDir) (new session or first launch)")
            print("DEBUG: Starting fresh (no --continue)")
        }
        terminalView?.send(txt: claudeCommand)

        // Ensure terminal has focus after Claude starts (only if no text field is active)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if let terminal = self?.terminalView, let window = terminal.window {
                // Don't steal focus if user is typing in a text field
                if let responder = window.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return
                }
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

        // Check if the directory exists and has any .jsonl files
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: claudeProjectsDir),
              let files = try? fileManager.contentsOfDirectory(atPath: claudeProjectsDir) else {
            return false
        }

        let hasSessionFiles = files.contains { $0.hasSuffix(".jsonl") }
        logger.info("Checking for existing session in \(claudeProjectsDir): \(hasSessionFiles ? "found" : "none")")
        return hasSessionFiles
    }

    private func configureTerminal() {
        guard let terminal = terminalView else { return }

        // Configure appearance
        terminal.configureNativeColors()

        // Disable mouse reporting so text selection works
        terminal.allowMouseReporting = false

        // ClaudeHub custom theme - matches the glass UI with blue accents
        // Background: Deep blue-grey to complement the glass aesthetic
        terminal.nativeBackgroundColor = NSColor(
            calibratedRed: 0.075, green: 0.082, blue: 0.11, alpha: 0.98
        )

        // Foreground: Soft blue-white for easy reading
        terminal.nativeForegroundColor = NSColor(
            calibratedRed: 0.85, green: 0.88, blue: 0.95, alpha: 1.0
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
        if let sfMono = NSFont(name: "SF Mono", size: 13.5) {
            terminal.font = sfMono
        } else {
            terminal.font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        }

        // Install custom ANSI color palette matching ClaudeHub theme
        installClaudeHubColorPalette(terminal: terminal)
    }

    /// Custom 16-color ANSI palette designed to match ClaudeHub's glass UI
    private func installClaudeHubColorPalette(terminal: ClaudeHubTerminalView) {
        let terminalCore = terminal.getTerminal()

        // ClaudeHub palette - blue-tinted with purple/cyan accents
        let palette: [SwiftTerm.Color] = [
            // 0: Black (deep blue-grey)
            SwiftTerm.Color(red: 18, green: 22, blue: 30),
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
            // 7: White (soft grey)
            SwiftTerm.Color(red: 200, green: 208, blue: 220),

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
            SwiftTerm.Color(red: 230, green: 235, blue: 245),
        ]

        terminalCore.installPalette(colors: palette)
        logger.info("Installed ClaudeHub color palette")
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

// MARK: - ClaudeHubTerminalView (subclass eliminates container view, fixing text selection)

/// Subclass of LocalProcessTerminalView that adds ClaudeHub features directly,
/// eliminating the container view that was intercepting mouse events and breaking selection.
class ClaudeHubTerminalView: LocalProcessTerminalView {
    var projectPath: String?
    private let chLogger = Logger(subsystem: "com.buzzbox.claudehub", category: "ClaudeHubTerminal")

    // URL regex for detecting any links (full URLs, domains, subdomains, paths)
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(https?://[^\s<>\"\'\]\)]+)|([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(/[^\s<>\"\'\]\)]*)?"#,
        options: [.caseInsensitive]
    )

    // File path patterns - absolute paths, home paths, and filenames with extensions
    private static let filePathPattern = try! NSRegularExpression(
        pattern: #"(~?/[^\s<>\"\'\]\)]+)|([a-zA-Z0-9_-]+\.[a-zA-Z0-9]{1,10})"#,
        options: []
    )

    private var isShowingHandCursor = false
    private var keyMonitor: Any?

    // MARK: - Setup

    func configureClaudeHub() {
        allowMouseReporting = false
        setupDragDrop()
        setupKeyMonitor()
        setupMouseMoveMonitor()
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
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeHub-drops-\(UUID().uuidString)")
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

    // MARK: - Key Monitor (Cmd+C copy, Cmd+V image paste, Cmd+A select all, Cmd+K clear)

    func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  event.modifierFlags.contains(.command),
                  event.window == self.window else {
                return event
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
                .appendingPathComponent(".claudehub-screenshots")

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

    // MARK: - Mouse Cursor for URLs
    // Note: Can't override mouseMoved (not open in SwiftTerm), so we use a local event monitor

    private var mouseMoveMonitor: Any?

    func setupMouseMoveMonitor() {
        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self = self, event.window == self.window else { return event }
            let locationInSelf = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(locationInSelf) && self.detectURLAtPoint(locationInSelf) != nil {
                if !self.isShowingHandCursor {
                    NSCursor.pointingHand.push()
                    self.isShowingHandCursor = true
                }
            } else {
                if self.isShowingHandCursor {
                    NSCursor.pop()
                    self.isShowingHandCursor = false
                }
            }
            return event
        }
    }

    // MARK: - Focus Management

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window = window {
            window.acceptsMouseMovedEvents = true
            window.makeKeyAndOrderFront(nil)
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

    // MARK: - URL Detection

    private func detectURLAtPoint(_ point: CGPoint) -> URL? {
        let font = self.font
        let charWidth = font.advancement(forGlyph: font.glyph(withName: "M")).width
        let lineHeight = font.ascender - font.descender + font.leading

        let col = Int(point.x / charWidth)
        // SwiftTerm uses non-flipped coordinates (origin bottom-left)
        let screenRow = Int((frame.height - point.y) / lineHeight)

        let terminalCore = getTerminal()
        let data = terminalCore.getBufferAsData()
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")

        let scrollOffset = terminalCore.buffer.yDisp
        let row = scrollOffset + screenRow

        guard row >= 0 && row < lines.count else { return nil }
        let clickedLine = lines[row]

        // Check if this line is a continuation of a URL from previous line
        if row > 0 && !clickedLine.isEmpty && !clickedLine.hasPrefix(" ") {
            let prevLine = lines[row - 1].trimmingCharacters(in: .whitespaces)
            if let lastUrlMatch = Self.urlPattern.matches(in: prevLine, options: [], range: NSRange(prevLine.startIndex..., in: prevLine)).last,
               let swiftRange = Range(lastUrlMatch.range, in: prevLine) {
                let urlEndCol = prevLine.distance(from: prevLine.startIndex, to: swiftRange.upperBound)
                if urlEndCol >= prevLine.count - 2 {
                    let partialUrl = String(prevLine[swiftRange])
                    let continuation = clickedLine.prefix(while: { !$0.isWhitespace })
                    var fullUrl = partialUrl + continuation

                    if !fullUrl.lowercased().hasPrefix("http://") && !fullUrl.lowercased().hasPrefix("https://") {
                        fullUrl = "https://" + fullUrl
                    }

                    if col < continuation.count {
                        chLogger.info("Found wrapped URL: \(fullUrl)")
                        return URL(string: fullUrl)
                    }
                }
            }
        }

        // Find URLs in this line
        let range = NSRange(clickedLine.startIndex..., in: clickedLine)
        let matches = Self.urlPattern.matches(in: clickedLine, options: [], range: range)

        for match in matches {
            if let swiftRange = Range(match.range, in: clickedLine) {
                let startCol = clickedLine.distance(from: clickedLine.startIndex, to: swiftRange.lowerBound)
                let endCol = clickedLine.distance(from: clickedLine.startIndex, to: swiftRange.upperBound)

                if col >= startCol && col < endCol {
                    var urlString = String(clickedLine[swiftRange])

                    if endCol >= clickedLine.count - 2 && row + 1 < lines.count {
                        let nextLine = lines[row + 1]
                        if !nextLine.isEmpty && !nextLine.hasPrefix(" ") {
                            let continuation = nextLine.prefix(while: { !$0.isWhitespace })
                            urlString += continuation
                        }
                    }

                    if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
                        urlString = "https://" + urlString
                    }
                    chLogger.info("Found URL at click: \(urlString)")
                    return URL(string: urlString)
                }
            }
        }

        return nil
    }

    // MARK: - Cleanup

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - SwiftUI Wrapper (no container view — terminal is embedded directly)

struct SwiftTermView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController

    func makeNSView(context: Context) -> ClaudeHubTerminalView {
        if controller.terminalView == nil {
            let terminal = ClaudeHubTerminalView(frame: .zero)
            controller.terminalView = terminal
        }

        let terminalView = controller.terminalView!

        // Disable mouse reporting so text selection works
        terminalView.allowMouseReporting = false

        // Configure appearance
        terminalView.configureNativeColors()

        // Configure ClaudeHub features (drag-drop, key monitor)
        terminalView.configureClaudeHub()

        // Auto-focus after a delay (but don't steal from text fields)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            terminalView.focusTerminal()
        }

        return terminalView
    }

    func updateNSView(_ nsView: ClaudeHubTerminalView, context: Context) {
        // Don't steal focus on every update
    }
}

// Preview available in Xcode only
