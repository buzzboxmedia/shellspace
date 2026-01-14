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
                        terminalController.startClaude(
                            in: session.projectPath,
                            sessionId: session.id,
                            claudeSessionId: session.claudeSessionId,
                            parkerBriefing: session.parkerBriefing
                        )
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
    var projectPath: String?  // Store project path for screenshot saving
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

    func startClaude(in directory: String, sessionId: UUID, claudeSessionId: String? = nil, parkerBriefing: String? = nil) {
        logger.info("startClaude called for directory: \(directory), sessionId: \(sessionId), claudeSessionId: \(claudeSessionId ?? "none")")

        // Don't restart if already running for this session
        if currentSessionId == sessionId && terminalView != nil {
            logger.info("Claude already running for this session, skipping")
            return
        }

        currentSessionId = sessionId
        projectPath = directory  // Store for screenshot saving

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
                    self?.startClaudeCommand(in: directory, claudeSessionId: claudeSessionId)
                }
            } else {
                self?.startClaudeCommand(in: directory, claudeSessionId: claudeSessionId)
            }
        }
    }

    private func startClaudeCommand(in directory: String, claudeSessionId: String?) {
        // Always start fresh - don't try to resume old sessions that may not exist
        let claudeCommand = "cd '\(directory)' && claude\n"
        logger.info("Starting Claude session in: \(directory)")
        terminalView?.send(txt: claudeCommand)

        // Ensure terminal has focus after Claude starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if let terminal = self?.terminalView, let window = terminal.window {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(terminal)
            }
        }
    }

    private func configureTerminal() {
        guard let terminal = terminalView else { return }

        // Configure appearance
        terminal.configureNativeColors()

        // Disable mouse reporting so text selection works
        terminal.allowMouseReporting = false

        // Set up colors for dark terminal (slightly transparent for depth)
        terminal.nativeForegroundColor = NSColor(calibratedRed: 0.92, green: 0.92, blue: 0.94, alpha: 1.0)
        terminal.nativeBackgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 0.95)

        // Set font - SF Mono for cleaner look
        if let sfMono = NSFont(name: "SF Mono", size: 13) {
            terminal.font = sfMono
        } else {
            terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }

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

// SwiftUI wrapper for LocalProcessTerminalView
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
            containerView.controller = controller  // For screenshot path

            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: containerView.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])

            // Enable selection and URL detection
            containerView.configureForSelection()

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
    weak var controller: TerminalController?  // Reference to get project path
    private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "TerminalContainer")

    // URL regex for detecting any links (full URLs, domains, subdomains, paths)
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(https?://[^\s<>\"\'\]\)]+)|([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(/[^\s<>\"\'\]\)]*)?"#,
        options: [.caseInsensitive]
    )

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    private var isShowingHandCursor = false
    private var trackingArea: NSTrackingArea?
    private var clickMonitor: Any?
    private var dragMonitor: Any?
    private var mouseDownPoint: CGPoint?
    private var wasDragging = false

    // Configure terminal for selection and drag-drop
    func configureForSelection() {
        // Disable mouse reporting so selection works
        terminalView?.allowMouseReporting = false
        setupClickMonitor()
        setupDragDrop()
        setupKeyMonitor()
    }

    private func setupDragDrop() {
        // Register for file drag and drop
        registerForDraggedTypes([.fileURL, .png, .tiff, .pdf])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Accept file drops
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }

        // Insert each file path into terminal
        for url in urls {
            let path = url.path
            logger.info("File dropped: \(path)")
            terminalView?.send(txt: path + " ")
        }

        focusTerminal()
        return true
    }

    private func setupClickMonitor() {
        // Track mouse down position to detect drags vs clicks
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self = self else { return event }

            if event.type == .leftMouseDown {
                self.mouseDownPoint = event.locationInWindow
                self.wasDragging = false
            } else if event.type == .leftMouseDragged {
                // If mouse moved more than 5 pixels, it's a drag (selection)
                if let downPoint = self.mouseDownPoint {
                    let distance = hypot(event.locationInWindow.x - downPoint.x,
                                        event.locationInWindow.y - downPoint.y)
                    if distance > 5 {
                        self.wasDragging = true
                    }
                }
            }
            return event
        }

        // Monitor clicks to intercept URL clicks (but not selection drags)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self = self,
                  let terminal = self.terminalView,
                  let window = self.window,
                  event.window == window else {
                return event
            }

            // Don't open URL if user was dragging to select
            if self.wasDragging {
                self.wasDragging = false
                return event
            }

            // Check if click is within terminal bounds
            let locationInTerminal = terminal.convert(event.locationInWindow, from: nil)
            if terminal.bounds.contains(locationInTerminal) {
                if let url = self.detectURLAtPoint(locationInTerminal) {
                    self.logger.info("Opening URL: \(url)")
                    NSWorkspace.shared.open(url)
                    return nil  // Consume the event
                }
            }
            return event
        }
    }

    deinit {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursorForEvent(event)
        super.mouseMoved(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
    }

    private func updateCursorForEvent(_ event: NSEvent) {
        guard let terminal = terminalView else { return }
        let locationInTerminal = terminal.convert(event.locationInWindow, from: nil)

        if terminal.bounds.contains(locationInTerminal) && detectURLAtPoint(locationInTerminal) != nil {
            if !isShowingHandCursor {
                NSCursor.pointingHand.push()
                isShowingHandCursor = true
            }
        } else {
            if isShowingHandCursor {
                NSCursor.pop()
                isShowingHandCursor = false
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        super.mouseDown(with: event)
    }

    // Detect URL at a point in terminal coordinates
    private func detectURLAtPoint(_ point: CGPoint) -> URL? {
        guard let terminal = terminalView else { return nil }

        // Get terminal font metrics
        let font = terminal.font
        let charWidth = font.advancement(forGlyph: font.glyph(withName: "M")).width
        let lineHeight = font.ascender - font.descender + font.leading

        // Calculate approximate row/column
        let col = Int(point.x / charWidth)
        let row = Int((terminal.bounds.height - point.y) / lineHeight)

        // Get terminal content
        let data = terminal.getTerminal().getBufferAsData()
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")

        // Find the clicked line (approximate)
        guard row >= 0 && row < lines.count else { return nil }
        let clickedLine = lines[row]

        // Check if this line is a continuation of a URL from previous line
        // (starts with non-space characters that look like URL continuation)
        if row > 0 && !clickedLine.isEmpty && !clickedLine.hasPrefix(" ") {
            let prevLine = lines[row - 1].trimmingCharacters(in: .whitespaces)
            // Check if previous line ends with a partial URL
            if let lastUrlMatch = Self.urlPattern.matches(in: prevLine, options: [], range: NSRange(prevLine.startIndex..., in: prevLine)).last,
               let swiftRange = Range(lastUrlMatch.range, in: prevLine) {
                let urlEndCol = prevLine.distance(from: prevLine.startIndex, to: swiftRange.upperBound)
                // If URL ends near the end of line, it might continue
                if urlEndCol >= prevLine.count - 2 {
                    let partialUrl = String(prevLine[swiftRange])
                    // Get continuation from current line (until space or end)
                    let continuation = clickedLine.prefix(while: { !$0.isWhitespace })
                    var fullUrl = partialUrl + continuation

                    if !fullUrl.lowercased().hasPrefix("http://") && !fullUrl.lowercased().hasPrefix("https://") {
                        fullUrl = "https://" + fullUrl
                    }

                    // If clicked on this continuation line, return the full URL
                    if col < continuation.count {
                        logger.info("Found wrapped URL: \(fullUrl)")
                        return URL(string: fullUrl)
                    }
                }
            }
        }

        // Find URLs in this line
        let range = NSRange(clickedLine.startIndex..., in: clickedLine)
        let matches = Self.urlPattern.matches(in: clickedLine, options: [], range: range)

        // Check if click position is within any URL
        for match in matches {
            if let swiftRange = Range(match.range, in: clickedLine) {
                let startCol = clickedLine.distance(from: clickedLine.startIndex, to: swiftRange.lowerBound)
                let endCol = clickedLine.distance(from: clickedLine.startIndex, to: swiftRange.upperBound)

                if col >= startCol && col < endCol {
                    var urlString = String(clickedLine[swiftRange])

                    // Check if URL continues on next line
                    if endCol >= clickedLine.count - 2 && row + 1 < lines.count {
                        let nextLine = lines[row + 1]
                        if !nextLine.isEmpty && !nextLine.hasPrefix(" ") {
                            let continuation = nextLine.prefix(while: { !$0.isWhitespace })
                            urlString += continuation
                        }
                    }

                    // Add https:// if no protocol specified
                    if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
                        urlString = "https://" + urlString
                    }
                    logger.info("Found URL at click: \(urlString)")
                    return URL(string: urlString)
                }
            }
        }

        return nil
    }

    // Intercept Cmd+C and Cmd+V at the app level to beat SwiftTerm's keyDown
    private var keyMonitor: Any?

    func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  event.modifierFlags.contains(.command),
                  let terminal = self.terminalView,
                  event.window == self.window else {
                return event
            }

            switch event.charactersIgnoringModifiers {
            case "c":
                // Copy selected text before keyDown clears selection
                terminal.copy(self)
                return nil  // Consume event
            case "v":
                // Handle image paste
                if self.handleImagePaste() {
                    return nil
                }
            default:
                break
            }
            return event
        }
    }

    // Intercept Cmd+V for image paste (backup)
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

    // Check clipboard for image and save to project screenshots folder
    private func handleImagePaste() -> Bool {
        let pasteboard = NSPasteboard.general

        // Check if clipboard contains an image
        guard let image = NSImage(pasteboard: pasteboard) else {
            return false  // No image, let normal paste happen
        }

        logger.info("Detected image in clipboard, saving to project")

        // Convert to PNG data
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            logger.error("Failed to convert clipboard image to PNG")
            return false
        }

        // Determine save location - project folder or fallback to temp
        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileName = "screenshot-\(timestamp).png"

        var saveDir: URL = fileManager.temporaryDirectory
        if let projectPath = controller?.projectPath {
            let screenshotsDir = URL(fileURLWithPath: projectPath)
                .appendingPathComponent(".claudehub-screenshots")

            // Create screenshots folder if needed
            do {
                try fileManager.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
                saveDir = screenshotsDir
                logger.info("Using screenshots folder: \(screenshotsDir.path)")
            } catch {
                logger.error("Failed to create screenshots folder: \(error.localizedDescription)")
                // saveDir remains as temp directory
            }
        }

        let filePath = saveDir.appendingPathComponent(fileName)

        do {
            try pngData.write(to: filePath)
            logger.info("Saved clipboard image to: \(filePath.path)")

            // Insert file path into terminal
            terminalView?.send(txt: filePath.path)
            focusTerminal()
            return true
        } catch {
            logger.error("Failed to save clipboard image: \(error.localizedDescription)")
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        // Don't forward - just focus the terminal and let it handle keys directly
        focusTerminal()
    }

    override func keyUp(with event: NSEvent) {
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

        // Force terminal to be first responder - try multiple times
        for delay in [0.0, 0.1, 0.3, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                _ = window.makeFirstResponder(terminal)
            }
        }
    }
}

// Preview available in Xcode only
