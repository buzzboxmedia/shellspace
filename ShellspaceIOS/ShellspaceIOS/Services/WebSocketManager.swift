import Foundation
import UserNotifications

/// Manages the WebSocket tunnel connection to a Mac through the relay server.
/// All communication (state updates, terminal content, input) is multiplexed
/// through a single tunnel WebSocket.
@Observable
final class WebSocketManager {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    // MARK: - Connection state

    var tunnelState: State = .disconnected

    // MARK: - State received from Mac via tunnel

    var sessions: [RemoteSession] = []
    var projects: [RemoteProject] = []

    // MARK: - Terminal stream (for active terminal view)

    var terminalContent: String = ""
    var terminalIsRunning: Bool = false
    var terminalIsWaiting: Bool = false
    var activeTerminalSessionId: String?

    // MARK: - Private

    private let deviceId: String
    private let authManager: RelayAuthManager
    private var tunnelTask: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?

    /// Tracks which sessions were waiting last time, so we only notify on transitions
    private var previouslyWaiting: Set<String> = []
    private var recentlyNotified: [String: Date] = [:]
    private let notifyCooldown: TimeInterval = 60

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(deviceId: String, authManager: RelayAuthManager) {
        self.deviceId = deviceId
        self.authManager = authManager
    }

    // MARK: - Tunnel Connection

    /// Connect the tunnel to the relay, which forwards to the target Mac.
    func connect() {
        disconnect()
        tunnelState = .connecting
        tunnelTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                do {
                    attempt = 0
                    try await self.runTunnel()
                    // Clean exit (server closed connection gracefully)
                    break
                } catch {
                    guard !Task.isCancelled else { break }
                    attempt += 1
                    let currentAttempt = attempt
                    await MainActor.run { self.tunnelState = .reconnecting(attempt: currentAttempt) }
                    let delay = min(30.0, pow(2.0, Double(currentAttempt - 1)))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            await MainActor.run { self.tunnelState = .disconnected }
        }
    }

    func disconnect() {
        tunnelTask?.cancel()
        tunnelTask = nil
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
        tunnelState = .disconnected
        activeTerminalSessionId = nil
    }

    // MARK: - Send Messages Through Tunnel

    /// Send a text command through the tunnel WebSocket.
    func send(_ payload: [String: Any]) -> Bool {
        guard let socket = activeSocket,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        socket.send(.string(text)) { _ in }
        return true
    }

    /// Send terminal input for a specific session.
    func sendInput(sessionId: String, message: String) -> Bool {
        return send([
            "type": "input",
            "sessionId": sessionId,
            "message": message
        ])
    }

    /// Send an image through the tunnel for a specific session.
    func sendImage(sessionId: String, imageData: Data, filename: String) -> Bool {
        return send([
            "type": "image",
            "sessionId": sessionId,
            "image": imageData.base64EncodedString(),
            "filename": filename
        ])
    }

    /// Request the Mac to start streaming terminal content for a session.
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

    /// Stop terminal streaming.
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

    /// Request the Mac to create a new session.
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

    /// Request a full state refresh from the Mac.
    func requestStateRefresh() {
        _ = send(["type": "request_state"])
    }

    // MARK: - Tunnel Loop

    private func runTunnel() async throws {
        let token = try await authManager.validAccessToken()

        let urlString = "wss://relay.shellspace.app/ws/tunnel/\(deviceId)?token=\(token)"
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }

        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()
        activeSocket = wsTask
        await MainActor.run { self.tunnelState = .connected }

        // Re-subscribe to terminal if we had an active session before reconnect
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
              let type = json["type"] as? String else { return }

        switch type {
        case "state_update":
            await handleStateUpdate(json)

        case "sessions_update":
            await handleSessionsUpdate(json)

        case "terminal_update":
            await handleTerminalUpdate(json)

        case "session_created":
            // Mac confirms a session was created; request full state refresh
            requestStateRefresh()

        case "error":
            let message = json["message"] as? String ?? "Unknown relay error"
            print("[WebSocketManager] Relay error: \(message)")

        case "pong":
            break // keepalive response

        default:
            break
        }
    }

    private func handleStateUpdate(_ json: [String: Any]) async {
        // Parse projects
        if let projectsArray = json["projects"] {
            if let projectsData = try? JSONSerialization.data(withJSONObject: projectsArray),
               let decoded = try? Self.decoder.decode([RemoteProject].self, from: projectsData) {
                await MainActor.run { self.projects = decoded }
            }
        }

        // Parse sessions
        if let sessionsArray = json["sessions"] {
            if let sessionsData = try? JSONSerialization.data(withJSONObject: sessionsArray),
               let decoded = try? Self.decoder.decode([RemoteSession].self, from: sessionsData) {
                await MainActor.run {
                    self.sessions = decoded
                    self.checkForNewWaitingSessions(decoded)
                }
            }
        }
    }

    private func handleSessionsUpdate(_ json: [String: Any]) async {
        guard let sessionsArray = json["sessions"],
              let sessionsData = try? JSONSerialization.data(withJSONObject: sessionsArray),
              let decoded = try? Self.decoder.decode([RemoteSession].self, from: sessionsData) else { return }

        await MainActor.run {
            self.sessions = decoded
            self.checkForNewWaitingSessions(decoded)
        }
    }

    private func handleTerminalUpdate(_ json: [String: Any]) async {
        let sessionId = json["sessionId"] as? String ?? json["session_id"] as? String
        // Only apply if this terminal update is for our subscribed session
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

    // MARK: - Local Notifications

    private func checkForNewWaitingSessions(_ sessions: [RemoteSession]) {
        let nowWaiting = Set(
            sessions
                .filter { $0.isWaitingForInput && !$0.isCompleted && !$0.isHidden }
                .map(\.id)
        )

        let newlyWaiting = nowWaiting.subtracting(previouslyWaiting)
        previouslyWaiting = nowWaiting

        let now = Date()
        recentlyNotified = recentlyNotified.filter { now.timeIntervalSince($0.value) < notifyCooldown }

        for sessionId in newlyWaiting {
            guard recentlyNotified[sessionId] == nil else { continue }
            recentlyNotified[sessionId] = now

            let session = sessions.first { $0.id == sessionId }
            let sessionName = session?.name ?? "A session"
            let projectName = session?.projectName ?? ""

            let content = UNMutableNotificationContent()
            content.title = "Waiting for input"
            content.body = projectName.isEmpty ? sessionName : "\(projectName) - \(sessionName)"
            content.sound = .default
            content.userInfo = ["sessionId": sessionId]

            let request = UNNotificationRequest(
                identifier: "waiting-\(sessionId)",
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Request notification permission. Call once at app startup.
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
