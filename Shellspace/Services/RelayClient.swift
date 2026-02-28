import Foundation
import SwiftData

/// Outbound WebSocket client that connects to the Shellspace relay server.
/// Replaces the inbound Hummingbird server for remote iOS access.
/// One multiplexed WebSocket carries all session updates and input.
final class RelayClient: @unchecked Sendable {
    private weak var appState: AppState?
    private var modelContainer: ModelContainer?

    private var webSocketTask: URLSessionWebSocketTask?
    private var pollingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    /// Sessions currently being auto-launched (prevents double-send)
    @MainActor private var autoLaunchingSessionIds: Set<UUID> = []

    // MARK: - Connection State

    enum ConnectionState: String {
        case disconnected
        case connecting
        case authenticated
        case connected
    }

    /// Observable connection state for UI binding
    @MainActor private(set) var state: ConnectionState = .disconnected {
        didSet {
            DebugLog.log("[RelayClient] State: \(oldValue.rawValue) -> \(state.rawValue)")
            appState?.relayConnectionState = state
        }
    }

    // MARK: - Reconnect Backoff

    private var reconnectAttempts = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var shouldReconnect = true

    private var reconnectDelay: TimeInterval {
        let delay = min(pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        return delay
    }

    // MARK: - Polling State (per-session change detection)

    private var lastTerminalHashes: [String: Int] = [:]
    private var lastRunningStates: [String: Bool] = [:]
    private var lastWaitingStates: [String: Bool] = [:]
    private var lastSessionsHash: Int = 0

    init() {}

    // MARK: - Connect

    @MainActor
    func connect(appState: AppState, modelContainer: ModelContainer) {
        self.appState = appState
        self.modelContainer = modelContainer

        guard RelayAuth.shared.isAuthenticated else {
            DebugLog.log("[RelayClient] Not authenticated, skipping connect")
            return
        }

        shouldReconnect = true
        startConnection()
    }

    @MainActor
    func disconnect() {
        shouldReconnect = false
        tearDown()
        state = .disconnected
        DebugLog.log("[RelayClient] Disconnected (user-initiated)")
    }

    // MARK: - Connection Lifecycle

    @MainActor
    private func startConnection() {
        guard let token = RelayAuth.shared.accessToken,
              let deviceId = RelayAuth.shared.deviceId else {
            DebugLog.log("[RelayClient] Missing token or deviceId")
            state = .disconnected
            return
        }

        state = .connecting

        // Build WebSocket URL
        let urlString = "wss://relay.shellspace.app/ws/device/\(deviceId)?token=\(token)"
        guard let url = URL(string: urlString) else {
            DebugLog.log("[RelayClient] Invalid WebSocket URL")
            state = .disconnected
            return
        }

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        self.webSocketTask = ws
        ws.resume()

        DebugLog.log("[RelayClient] WebSocket connecting to relay (device: \(deviceId))")

        // Start receiving messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Start polling terminal buffers
        pollingTask = Task { [weak self] in
            await self?.pollingLoop()
        }

        // Start heartbeat
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }

        state = .connected
        reconnectAttempts = 0
    }

    @MainActor
    private func tearDown() {
        pollingTask?.cancel()
        pollingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        // Reset polling state
        lastTerminalHashes = [:]
        lastRunningStates = [:]
        lastWaitingStates = [:]
        lastSessionsHash = 0
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        guard shouldReconnect else { return }

        reconnectAttempts += 1
        let delay = reconnectDelay

        Task { @MainActor in
            self.state = .disconnected
            DebugLog.log("[RelayClient] Reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")

            self.reconnectTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }

                // Try refreshing the token before reconnecting
                if self.reconnectAttempts > 1 {
                    do {
                        try await RelayAuth.shared.refreshAccessToken()
                    } catch {
                        await MainActor.run {
                            DebugLog.log("[RelayClient] Token refresh failed: \(error)")
                        }
                    }
                }

                await MainActor.run {
                    self.tearDown()
                    self.startConnection()
                }
            }
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        guard let ws = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    await handleInboundMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleInboundMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                await MainActor.run {
                    DebugLog.log("[RelayClient] Receive error: \(error)")
                }
                // Connection dropped - reconnect
                scheduleReconnect()
                return
            }
        }
    }

    private func handleInboundMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            await MainActor.run {
                DebugLog.log("[RelayClient] Received unparseable message: \(text.prefix(100))")
            }
            return
        }

        switch type {
        case "input":
            guard let sessionId = json["session_id"] as? String,
                  let message = json["message"] as? String else {
                await MainActor.run { DebugLog.log("[RelayClient] Invalid input message") }
                return
            }
            await handleInput(sessionId: sessionId, message: message)

        case "create_session":
            guard let projectId = json["project_id"] as? String,
                  let name = json["name"] as? String else {
                await MainActor.run { DebugLog.log("[RelayClient] Invalid create_session message") }
                return
            }
            let description = json["description"] as? String
            await handleCreateSession(projectId: projectId, name: name, description: description)

        case "image_upload":
            guard let sessionId = json["session_id"] as? String,
                  let base64 = json["image"] as? String else {
                await MainActor.run { DebugLog.log("[RelayClient] Invalid image_upload message") }
                return
            }
            let filename = json["filename"] as? String
            await handleImageUpload(sessionId: sessionId, base64: base64, filename: filename)

        case "request_state":
            await sendStateUpdate()

        case "request_sessions":
            await sendSessionsUpdate(force: true)

        case "request_terminal":
            if let sessionId = json["session_id"] as? String {
                await sendTerminalUpdate(sessionId: sessionId, force: true)
            }

        case "ping":
            await sendMessage(["type": "pong"])

        default:
            await MainActor.run {
                DebugLog.log("[RelayClient] Unknown message type: \(type)")
            }
        }
    }

    // MARK: - Input Handling

    private func handleInput(sessionId: String, message: String) async {
        guard let uuid = UUID(uuidString: sessionId) else { return }

        await MainActor.run {
            DebugLog.log("[RelayClient] Input received for \(sessionId): \(message.prefix(50))")
        }

        // Skip if this session is currently being auto-launched
        let isAutoLaunching = await MainActor.run { autoLaunchingSessionIds.contains(uuid) }
        if isAutoLaunching {
            await MainActor.run {
                DebugLog.log("[RelayClient] Skipping input (auto-launch in progress): \(sessionId)")
            }
            return
        }

        // Fast path: controller exists and process is running
        let sent = await MainActor.run {
            if let controller = appState?.terminalControllers[uuid],
               controller.terminalView?.process?.running == true {
                controller.sendToTerminal(message)
                DebugLog.log("[RelayClient] Sent to running session \(sessionId)")
                return true
            }
            return false
        }

        if !sent {
            await MainActor.run {
                autoLaunchingSessionIds.insert(uuid)
                DebugLog.log("[RelayClient] Session not running, auto-launching \(sessionId)")
            }
            await autoLaunchAndSend(uuid: uuid, sessionId: sessionId, message: message)
        }
    }

    // MARK: - Create Session

    private func handleCreateSession(projectId: String, name: String, description: String?) async {
        guard let container = modelContainer,
              let projectUUID = UUID(uuidString: projectId) else {
            await MainActor.run { DebugLog.log("[RelayClient] Invalid project ID for create_session") }
            return
        }

        let result: [String: Any]? = await MainActor.run {
            let mainContext = container.mainContext
            let descriptor = FetchDescriptor<Project>()
            guard let projects = try? mainContext.fetch(descriptor),
                  let project = projects.first(where: { $0.id == projectUUID }) else {
                return nil
            }

            // Create task folder
            guard let taskFolderURL = try? TaskFolderService.shared.createTask(
                projectPath: project.path,
                projectName: project.name,
                subProjectName: nil,
                taskName: name,
                description: description
            ) else { return nil }

            // Create session
            let session = Session(
                name: name,
                projectPath: project.path,
                createdAt: Date(),
                userNamed: true,
                activeProjectName: project.name,
                parkerBriefing: nil
            )
            session.taskFolderPath = taskFolderURL.path
            project.sessions.append(session)
            try? mainContext.save()

            DebugLog.log("[RelayClient] Created session: \(session.id.uuidString) for task: \(name)")

            return [
                "id": session.id.uuidString,
                "name": session.name,
                "project_path": session.projectPath,
                "task_folder_path": taskFolderURL.path,
            ] as [String: Any]
        }

        if let result {
            await sendMessage([
                "type": "session_created",
                "session": result
            ])
            // Also send updated sessions list
            await sendSessionsUpdate(force: true)
        }
    }

    // MARK: - Image Upload

    private func handleImageUpload(sessionId: String, base64: String, filename: String?) async {
        guard let uuid = UUID(uuidString: sessionId),
              let imageData = Data(base64Encoded: base64) else { return }

        let fname = filename ?? "photo.jpg"

        // Get project path
        let projectPath: String? = await MainActor.run {
            findSession(sessionId)?.projectPath
        }

        // Save image
        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let ext = (fname as NSString).pathExtension.isEmpty ? "jpg" : (fname as NSString).pathExtension
        let savedFileName = "screenshot-\(timestamp).\(ext)"

        var saveDir = fileManager.temporaryDirectory
        if let projectPath {
            let screenshotsDir = URL(fileURLWithPath: projectPath)
                .appendingPathComponent(".shellspace-screenshots")
            do {
                try fileManager.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
                saveDir = screenshotsDir
            } catch {
                await MainActor.run { DebugLog.log("[RelayClient] Failed to create screenshots dir: \(error)") }
            }
        }

        let filePath = saveDir.appendingPathComponent(savedFileName)
        do {
            try imageData.write(to: filePath)
        } catch {
            await MainActor.run { DebugLog.log("[RelayClient] Failed to save image: \(error)") }
            return
        }

        await MainActor.run { DebugLog.log("[RelayClient] Saved image: \(filePath.path)") }

        // Send file path to terminal
        let sent = await MainActor.run {
            if let controller = appState?.terminalControllers[uuid],
               controller.terminalView?.process?.running == true {
                controller.sendToTerminal(filePath.path)
                return true
            }
            return false
        }

        if !sent {
            await autoLaunchAndSend(uuid: uuid, sessionId: sessionId, message: filePath.path)
        }
    }

    // MARK: - Polling Loop (Outbound Updates)

    private func pollingLoop() async {
        // Send initial state (projects + sessions)
        await sendStateUpdate()

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { break }

            // Send terminal updates for all active sessions
            await sendAllTerminalUpdates()

            // Send sessions update every 2 seconds (check every 4th poll)
            // We track this with a simple counter
        }
    }

    private var pollCount = 0

    private func sendAllTerminalUpdates() async {
        pollCount += 1

        let sessionIds: [String] = await MainActor.run {
            guard let container = modelContainer else { return [] }
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Session>()
            guard let sessions = try? context.fetch(descriptor) else { return [] }
            return sessions
                .filter { !$0.isHidden && !$0.isCompleted }
                .map { $0.id.uuidString }
        }

        for sessionId in sessionIds {
            await sendTerminalUpdate(sessionId: sessionId, force: false)
        }

        // Sessions snapshot every 2 seconds (every 4th poll at 500ms)
        if pollCount % 4 == 0 {
            await sendSessionsUpdate(force: false)
        }
    }

    private func sendTerminalUpdate(sessionId: String, force: Bool) async {
        guard let uuid = UUID(uuidString: sessionId) else { return }

        let (content, isRunning, isWaiting) = await MainActor.run {
            var c = appState?.terminalControllers[uuid]?.getFullTerminalContent() ?? ""
            let running = appState?.terminalControllers[uuid]?.terminalView?.process?.running == true
            let waiting = findSession(sessionId)?.isWaitingForInput ?? false

            // Fall back to log file when live buffer is empty
            if c.isEmpty {
                let logPath = Session.centralLogsDir.appendingPathComponent("\(sessionId).log")
                if let logContent = try? String(contentsOf: logPath, encoding: .utf8) {
                    c = logContent
                }
            }

            return (c, running, waiting)
        }

        let contentHash = content.hashValue
        let prevHash = lastTerminalHashes[sessionId]
        let prevRunning = lastRunningStates[sessionId]
        let prevWaiting = lastWaitingStates[sessionId]

        guard force || contentHash != prevHash || isRunning != prevRunning || isWaiting != prevWaiting else {
            return
        }

        lastTerminalHashes[sessionId] = contentHash
        lastRunningStates[sessionId] = isRunning
        lastWaitingStates[sessionId] = isWaiting

        await sendMessage([
            "type": "terminal_update",
            "session_id": sessionId,
            "content": content,
            "is_running": isRunning,
            "is_waiting_for_input": isWaiting,
        ])
    }

    private func sendSessionsUpdate(force: Bool) async {
        let sessionDicts: [[String: Any]]? = await MainActor.run {
            guard let container = modelContainer else { return nil }

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Session>()
            guard let allSessions = try? context.fetch(descriptor) else { return nil }
            let sessions = allSessions.filter { !$0.isHidden }

            // Quick hash to detect changes
            let currentHash = sessions.map { s in
                let isRunning = appState?.terminalControllers[s.id]?.terminalView?.process?.running == true
                return "\(s.id):\(isRunning):\(s.isWaitingForInput):\(s.isCompleted)"
            }.joined().hashValue

            guard force || currentHash != lastSessionsHash else { return nil }
            lastSessionsHash = currentHash

            return sessions.map { session in
                sessionToJSON(session)
            }
        }

        guard let sessionDicts else { return }

        await sendMessage([
            "type": "sessions_update",
            "sessions": sessionDicts
        ])
    }

    // MARK: - State Update (projects + sessions)

    private func sendStateUpdate() async {
        let (projectDicts, sessionDicts) = await MainActor.run {
            guard let container = modelContainer else { return (nil as [[String: Any]]?, nil as [[String: Any]]?) }
            let context = ModelContext(container)

            // Fetch projects
            let projectDescriptor = FetchDescriptor<Project>()
            let projects = (try? context.fetch(projectDescriptor)) ?? []
            let projectsList = projects.map { project -> [String: Any] in
                let activeSessions = project.sessions.filter { !$0.isHidden && !$0.isCompleted }
                let waitingSessions = activeSessions.filter { $0.isWaitingForInput }
                return [
                    "id": project.id.uuidString,
                    "name": project.name,
                    "path": project.path,
                    "icon": project.icon,
                    "category": project.category.rawValue,
                    "active_sessions": activeSessions.count,
                    "waiting_sessions": waitingSessions.count,
                ]
            }

            // Fetch sessions
            let sessionDescriptor = FetchDescriptor<Session>()
            let allSessions = (try? context.fetch(sessionDescriptor)) ?? []
            let sessionsList = allSessions.filter { !$0.isHidden }.map { session in
                sessionToJSON(session)
            }

            return (projectsList, sessionsList)
        }

        guard let projectDicts, let sessionDicts else { return }

        await sendMessage([
            "type": "state_update",
            "projects": projectDicts,
            "sessions": sessionDicts,
        ])
    }

    // MARK: - Heartbeat

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { break }
            await sendMessage(["type": "ping"])
        }
    }

    // MARK: - Send Message

    private func sendMessage(_ dict: [String: Any]) async {
        guard let ws = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        do {
            try await ws.send(.string(jsonString))
        } catch {
            await MainActor.run {
                DebugLog.log("[RelayClient] Send error: \(error)")
            }
            // Connection likely dropped
            scheduleReconnect()
        }
    }

    // MARK: - Auto-launch

    /// Auto-launch a stopped session and send input. Identical logic to RemoteServer.
    private func autoLaunchAndSend(uuid: UUID, sessionId: String, message: String) async {
        guard let container = modelContainer, let appState = appState else {
            await MainActor.run { DebugLog.log("[RelayClient] Auto-launch failed: no container/appState") }
            return
        }

        let controller = await MainActor.run {
            let mainContext = container.mainContext
            let descriptor = FetchDescriptor<Session>()
            guard let sessions = try? mainContext.fetch(descriptor),
                  let session = sessions.first(where: { $0.id == uuid }) else {
                return nil as TerminalController?
            }

            let ctrl = appState.getOrCreateController(for: session)

            ctrl.startClaude(
                in: session.projectPath,
                sessionId: session.id,
                claudeSessionId: session.claudeSessionId,
                parkerBriefing: session.parkerBriefing,
                taskFolderPath: session.taskFolderPath,
                hasBeenLaunched: session.hasBeenLaunched
            )

            if let terminal = ctrl.terminalView {
                terminal.frame = NSRect(x: 0, y: 0, width: 960, height: 480)
                terminal.getTerminal().resize(cols: 120, rows: 40)
            }

            session.hasBeenLaunched = true
            try? mainContext.save()

            return ctrl
        }

        guard let controller else {
            await MainActor.run { DebugLog.log("[RelayClient] Auto-launch failed: session not found \(sessionId)") }
            return
        }

        // Wait for buffer to stabilize (previous session content finishes loading)
        var lastLength = 0
        var stableCount = 0
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(300))
            let currentLength = await MainActor.run { controller.getFullTerminalContent().count }
            if currentLength == lastLength && currentLength > 0 {
                stableCount += 1
                if stableCount >= 2 { break }
            } else {
                stableCount = 0
            }
            lastLength = currentLength
        }
        let stableLength = lastLength
        await MainActor.run { DebugLog.log("[RelayClient] Buffer stabilized at \(stableLength) chars for \(sessionId)") }

        // Wait for new content beyond the stabilized buffer (Claude has started)
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(500))
            let content = await MainActor.run { controller.getFullTerminalContent() }
            if content.count > stableLength + 10 {
                await MainActor.run { DebugLog.log("[RelayClient] New content detected for \(sessionId)") }
                break
            }
        }

        // Brief pause for Claude to render its prompt
        try? await Task.sleep(for: .seconds(1))

        // Check if someone else already handled this
        let alreadyHandled = await MainActor.run { autoLaunchingSessionIds.contains(uuid) == false }
        if alreadyHandled {
            await MainActor.run { DebugLog.log("[RelayClient] Auto-launch cancelled (already handled): \(sessionId)") }
            return
        }

        await MainActor.run {
            controller.sendToTerminal(message)
            DebugLog.log("[RelayClient] Auto-launched and sent input to \(sessionId): \(message.prefix(50))")
        }

        // Keep lock briefly so queued frames don't double-send
        try? await Task.sleep(for: .seconds(2))
        await MainActor.run { autoLaunchingSessionIds.remove(uuid) }
    }

    // MARK: - Helpers

    @MainActor
    private func findSession(_ sessionId: String) -> Session? {
        guard let container = modelContainer,
              let uuid = UUID(uuidString: sessionId) else { return nil }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? context.fetch(descriptor) else { return nil }
        return sessions.first { $0.id == uuid }
    }

    @MainActor
    private func sessionToJSON(_ session: Session) -> [String: Any] {
        let isRunning = appState?.terminalControllers[session.id]?.terminalView?.process?.running == true
        var json: [String: Any] = [
            "id": session.id.uuidString,
            "name": session.name,
            "project_path": session.projectPath,
            "created_at": ISO8601DateFormatter().string(from: session.createdAt),
            "last_accessed_at": ISO8601DateFormatter().string(from: session.lastAccessedAt),
            "is_completed": session.isCompleted,
            "is_hidden": session.isHidden,
            "is_waiting_for_input": session.isWaitingForInput,
            "has_been_launched": session.hasBeenLaunched,
            "is_running": isRunning,
        ]
        if let summary = session.lastSessionSummary { json["summary"] = summary }
        if let taskFolder = session.taskFolderPath { json["task_folder_path"] = taskFolder }
        if let briefing = session.parkerBriefing { json["parker_briefing"] = briefing }
        return json
    }
}
