import SwiftUI
import SwiftTerm
import AppKit

struct TerminalView: View {
    let session: Session
    @EnvironmentObject var appState: AppState
    @StateObject private var terminalController = TerminalController()

    var body: some View {
        SwiftTermView(controller: terminalController)
            .onAppear {
                terminalController.startClaude(in: session.projectPath, sessionId: session.id)
            }
            .onDisappear {
                // Don't terminate - keep running in background
            }
    }
}

// Controller to manage the terminal and process
class TerminalController: ObservableObject {
    var terminalView: LocalProcessTerminalView?
    private var currentSessionId: UUID?

    func startClaude(in directory: String, sessionId: UUID) {
        // Don't restart if already running for this session
        if currentSessionId == sessionId && terminalView != nil {
            return
        }

        currentSessionId = sessionId

        // Create terminal view if needed
        if terminalView == nil {
            terminalView = LocalProcessTerminalView(frame: .zero)
            configureTerminal()
        }

        // Find claude path
        let claudePath = findClaudePath()

        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin"

        let envArray = env.map { "\($0.key)=\($0.value)" }

        // Start claude process
        terminalView?.startProcess(
            executable: claudePath,
            args: [claudePath],
            environment: envArray,
            execName: "claude"
        )
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
        if let container = nsView as? TerminalContainerView,
           let terminalView = container.terminalView {
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
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
        // Forward all key events to the terminal
        if let terminal = terminalView {
            terminal.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let terminal = terminalView {
            terminal.keyUp(with: event)
        } else {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if let terminal = terminalView {
            terminal.flagsChanged(with: event)
        } else {
            super.flagsChanged(with: event)
        }
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

        // Make terminal first responder - this is the key line
        let success = window.makeFirstResponder(terminal)
        if !success {
            // If terminal won't accept, make container the responder
            // and we'll forward key events manually
            window.makeFirstResponder(self)
        }
    }
}

// Preview available in Xcode only
