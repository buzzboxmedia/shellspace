import Foundation
import SwiftData
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.buzzbox.shellspace", category: "CompanionClient")

/// Connects this Mac as a tunnel client to another Mac's Shellspace instance
/// via the relay server. Syncs relay data into SwiftData so regular views work.
@Observable
final class CompanionClient {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    // MARK: - Connection state

    var tunnelState: State = .disconnected

    // MARK: - Running session tracking (from relay terminal updates)

    var runningSessionIds: Set<UUID> = []

    // MARK: - Terminal stream (for active viewing)

    var terminalContent: String = ""
    var terminalIsRunning: Bool = false
    var terminalIsWaiting: Bool = false
    var activeTerminalSessionId: String?

    // MARK: - References

    private weak var appState: AppState?
    private var modelContainer: ModelContainer?

    // MARK: - Private

    private var tunnelTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var tokenRefreshTask: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?

    private var previouslyWaiting: Set<UUID> = []

    init() {}

    // MARK: - Connect / Disconnect

    func connect(appState: AppState, modelContainer: ModelContainer) {
        self.appState = appState
        self.modelContainer = modelContainer

        guard let deviceId = RelayAuth.shared.companionDeviceId,
              let token = RelayAuth.shared.accessToken else {
            logger.error("Cannot connect: no companion device or access token")
            return
        }

        disconnect()
        tunnelState = .connecting
        logger.info("Connecting to host device: \(deviceId)")

        tunnelTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                do {
                    attempt = 0
                    try await self.runTunnel(deviceId: deviceId)
                    break // clean exit
                } catch {
                    guard !Task.isCancelled else { break }
                    attempt += 1
                    let currentAttempt = attempt
                    await MainActor.run { self.tunnelState = .reconnecting(attempt: currentAttempt) }
                    logger.warning("Tunnel disconnected (attempt \(currentAttempt)): \(error.localizedDescription)")

                    let delay = min(30.0, pow(2.0, Double(currentAttempt - 1)))
                    try? await Task.sleep(for: .seconds(delay))

                    // Refresh token before reconnecting
                    _ = try? await RelayAuth.shared.refreshAccessToken()
                }
            }
            await MainActor.run { self.tunnelState = .disconnected }
        }
    }

    func disconnect() {
        tunnelTask?.cancel()
        tunnelTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
        tunnelState = .disconnected
        activeTerminalSessionId = nil
    }

    // MARK: - Send Messages Through Tunnel

    @discardableResult
    func send(_ payload: [String: Any]) -> Bool {
        guard let socket = activeSocket,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        socket.send(.string(text)) { _ in }
        return true
    }

    func sendInput(sessionId: String, message: String) -> Bool {
        return send([
            "type": "input",
            "sessionId": sessionId,
            "message": message
        ])
    }

    func subscribeTerminal(sessionId: String) {
        activeTerminalSessionId = sessionId
        terminalContent = ""
        terminalIsRunning = false
        terminalIsWaiting = false
        _ = send([
            "type": "subscribe_terminal",
            "sessionId": sessionId
        ])
    }

    func unsubscribeTerminal() {
        if let sessionId = activeTerminalSessionId {
            _ = send([
                "type": "unsubscribe_terminal",
                "sessionId": sessionId
            ])
        }
        activeTerminalSessionId = nil
        terminalContent = ""
        terminalIsRunning = false
        terminalIsWaiting = false
    }

    func createSession(projectId: String, name: String, description: String?) -> Bool {
        var payload: [String: Any] = [
            "type": "create_session",
            "projectId": projectId,
            "name": name
        ]
        if let description, !description.isEmpty {
            payload["description"] = description
        }
        return send(payload)
    }

    func requestStateRefresh() {
        _ = send(["type": "request_state"])
    }

    // MARK: - Tunnel Loop

    private func runTunnel(deviceId: String) async throws {
        guard let token = RelayAuth.shared.accessToken else {
            throw RelayAuth.AuthError.notAuthenticated
        }

        let urlString = "wss://relay.shellspace.app/ws/tunnel/\(deviceId)?token=\(token)"
        guard let url = URL(string: urlString) else { return }

        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()
        activeSocket = wsTask
        await MainActor.run { self.tunnelState = .connected }
        logger.info("Tunnel connected to \(deviceId)")

        // Start heartbeat
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }

        // Start token refresh
        tokenRefreshTask?.cancel()
        tokenRefreshTask = Task { [weak self] in
            await self?.tokenRefreshLoop()
        }

        // Re-subscribe to terminal if we had one before reconnect
        if let sessionId = activeTerminalSessionId {
            _ = send(["type": "subscribe_terminal", "sessionId": sessionId])
        }

        // Request initial state
        requestStateRefresh()

        while !Task.isCancelled {
            let message = try await wsTask.receive()
            switch message {
            case .string(let text):
                await parseTunnelMessage(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    await parseTunnelMessage(text)
                }
            @unknown default:
                break
            }
        }

        activeSocket = nil
        wsTask.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Message Parsing

    private func parseTunnelMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "state_update":
            await handleStateUpdate(json)

        case "sessions_update":
            await handleSessionsUpdate(json)

        case "terminal_update":
            await handleTerminalUpdate(json)

        case "session_created":
            requestStateRefresh()

        case "error":
            let message = json["message"] as? String ?? "Unknown relay error"
            logger.error("Relay error: \(message)")

        case "pong":
            break

        default:
            break
        }
    }

    // MARK: - SwiftData Sync

    private func handleStateUpdate(_ json: [String: Any]) async {
        if let projectsArray = json["projects"] as? [[String: Any]] {
            await syncProjects(projectsArray)
        }
        if let sessionsArray = json["sessions"] as? [[String: Any]] {
            await syncSessions(sessionsArray)
        }
    }

    private func handleSessionsUpdate(_ json: [String: Any]) async {
        guard let sessionsArray = json["sessions"] as? [[String: Any]] else { return }
        await syncSessions(sessionsArray)
    }

    @MainActor
    private func syncProjects(_ projectsArray: [[String: Any]]) {
        guard let container = modelContainer else { return }
        let context = container.mainContext

        for proj in projectsArray {
            guard let idStr = proj["id"] as? String,
                  let uuid = UUID(uuidString: idStr),
                  let name = proj["name"] as? String,
                  let path = proj["path"] as? String else { continue }

            let icon = proj["icon"] as? String ?? "folder"
            let categoryRaw = proj["category"] as? String ?? "main"
            let category = ProjectCategory(rawValue: categoryRaw) ?? .main

            // Find existing project by ID
            let descriptor = FetchDescriptor<Project>(predicate: #Predicate<Project> { p in p.id == uuid })
            if let existing = (try? context.fetch(descriptor))?.first {
                existing.name = name
                existing.icon = icon
            } else {
                let project = Project(name: name, path: path, icon: icon, category: category)
                project.id = uuid
                context.insert(project)
            }
        }

        try? context.save()
        logger.info("Synced \(projectsArray.count) projects to SwiftData")
    }

    @MainActor
    private func syncSessions(_ sessionsArray: [[String: Any]]) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let isoFormatter = ISO8601DateFormatter()

        var newRunningIds: Set<UUID> = []

        for sess in sessionsArray {
            guard let idStr = sess["id"] as? String,
                  let uuid = UUID(uuidString: idStr),
                  let name = sess["name"] as? String,
                  let projectPath = sess["project_path"] as? String else { continue }

            let isRunning = sess["is_running"] as? Bool ?? false
            let isWaiting = sess["is_waiting_for_input"] as? Bool ?? false
            let isCompleted = sess["is_completed"] as? Bool ?? false
            let isHidden = sess["is_hidden"] as? Bool ?? false
            let hasBeenLaunched = sess["has_been_launched"] as? Bool ?? true

            if isRunning { newRunningIds.insert(uuid) }

            // Find existing session by ID
            var descriptor = FetchDescriptor<Session>(predicate: #Predicate<Session> { s in s.id == uuid })
            descriptor.fetchLimit = 1

            if let existing = (try? context.fetch(descriptor))?.first {
                existing.name = name
                existing.isWaitingForInput = isWaiting
                existing.isCompleted = isCompleted
                existing.isHidden = isHidden
                existing.hasBeenLaunched = hasBeenLaunched
                if let summary = sess["summary"] as? String { existing.lastSessionSummary = summary }
                if let briefing = sess["parker_briefing"] as? String { existing.parkerBriefing = briefing }
                if let accessedStr = sess["last_accessed_at"] as? String,
                   let date = isoFormatter.date(from: accessedStr) {
                    existing.lastAccessedAt = date
                }
            } else {
                let session = Session(name: name, projectPath: projectPath)
                session.id = uuid
                session.isWaitingForInput = isWaiting
                session.isCompleted = isCompleted
                session.isHidden = isHidden
                session.hasBeenLaunched = hasBeenLaunched
                if let summary = sess["summary"] as? String { session.lastSessionSummary = summary }
                if let briefing = sess["parker_briefing"] as? String { session.parkerBriefing = briefing }
                if let taskFolder = sess["task_folder_path"] as? String { session.taskFolderPath = taskFolder }
                if let createdStr = sess["created_at"] as? String {
                    session.createdAt = isoFormatter.date(from: createdStr) ?? Date()
                }
                if let accessedStr = sess["last_accessed_at"] as? String {
                    session.lastAccessedAt = isoFormatter.date(from: accessedStr) ?? Date()
                }
                context.insert(session)

                // Link to project
                let projectDescriptor = FetchDescriptor<Project>(predicate: #Predicate<Project> { p in p.path == projectPath })
                if let project = (try? context.fetch(projectDescriptor))?.first {
                    session.project = project
                }
            }
        }

        runningSessionIds = newRunningIds
        appState?.companionRunningSessionIds = newRunningIds
        try? context.save()

        // Check for new waiting sessions (notifications)
        checkForNewWaitingSessions(context: context)

        logger.info("Synced \(sessionsArray.count) sessions to SwiftData (\(newRunningIds.count) running)")
    }

    private func handleTerminalUpdate(_ json: [String: Any]) async {
        let sessionId = json["sessionId"] as? String ?? json["session_id"] as? String
        guard sessionId == nil || sessionId == activeTerminalSessionId else { return }

        let content = json["content"] as? String ?? ""
        let isRunning = json["is_running"] as? Bool ?? json["isRunning"] as? Bool ?? false
        let isWaiting = json["is_waiting_for_input"] as? Bool ?? json["isWaitingForInput"] as? Bool ?? false

        await MainActor.run {
            self.terminalContent = content
            self.terminalIsRunning = isRunning
            self.terminalIsWaiting = isWaiting
        }
    }

    // MARK: - Notifications

    @MainActor
    private func checkForNewWaitingSessions(context: ModelContext) {
        let descriptor = FetchDescriptor<Session>(predicate: #Predicate<Session> { s in
            s.isWaitingForInput && !s.isCompleted && !s.isHidden
        })
        let waitingSessions = (try? context.fetch(descriptor)) ?? []
        let nowWaiting = Set(waitingSessions.map(\.id))

        let newlyWaiting = nowWaiting.subtracting(previouslyWaiting)
        previouslyWaiting = nowWaiting

        for session in waitingSessions where newlyWaiting.contains(session.id) {
            let content = UNMutableNotificationContent()
            content.title = "Waiting for input"
            content.body = session.project?.name.isEmpty == false
                ? "\(session.project!.name) — \(session.name)"
                : session.name
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "companion-waiting-\(session.id.uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Heartbeat

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let ws = activeSocket else { break }

            ws.sendPing { [weak self] error in
                if error != nil {
                    self?.activeSocket?.cancel(with: .abnormalClosure, reason: nil)
                }
            }
        }
    }

    // MARK: - Token Refresh

    private func tokenRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(600)) // every 10 min
            guard !Task.isCancelled else { break }

            do {
                try await RelayAuth.shared.refreshAccessToken()
                logger.info("Proactive token refresh succeeded (stored for next reconnect)")
                // Don't cancel the socket — the token is only used during
                // the WebSocket upgrade handshake. Existing connection is fine.
            } catch {
                logger.warning("Proactive token refresh failed: \(error.localizedDescription)")
            }
        }
    }
}
