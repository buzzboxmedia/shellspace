import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.buzzbox.shellspace", category: "CompanionClient")

/// Connects this Mac as a tunnel client to another Mac's Shellspace instance
/// via the relay server. Same protocol as the iOS Lite app.
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

    // MARK: - State received from host Mac via tunnel

    var sessions: [RemoteSession] = []
    var projects: [RemoteProject] = []

    // MARK: - Terminal stream

    var terminalContent: String = ""
    var terminalIsRunning: Bool = false
    var terminalIsWaiting: Bool = false
    var activeTerminalSessionId: String?

    // MARK: - Private

    private var tunnelTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var tokenRefreshTask: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?

    private var previouslyWaiting: Set<String> = []

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: - Cache

    private static let cacheDir: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }()
    private static let projectsCacheURL = cacheDir.appendingPathComponent("companion_projects.json")
    private static let sessionsCacheURL = cacheDir.appendingPathComponent("companion_sessions.json")

    init() {
        loadCachedData()
    }

    // MARK: - Connect / Disconnect

    func connect() {
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

    private func handleStateUpdate(_ json: [String: Any]) async {
        if let projectsArray = json["projects"] {
            do {
                let projectsData = try JSONSerialization.data(withJSONObject: projectsArray)
                let decoded = try Self.decoder.decode([RemoteProject].self, from: projectsData)
                await MainActor.run { self.projects = decoded }
                logger.info("State update: \(decoded.count) projects")
            } catch {
                logger.error("Projects decode error: \(error.localizedDescription)")
            }
        }

        if let sessionsArray = json["sessions"] {
            do {
                let sessionsData = try JSONSerialization.data(withJSONObject: sessionsArray)
                let decoded = try Self.decoder.decode([RemoteSession].self, from: sessionsData)
                await MainActor.run {
                    self.sessions = decoded
                    self.checkForNewWaitingSessions(decoded)
                }
                logger.info("State update: \(decoded.count) sessions")
            } catch {
                logger.error("Sessions decode error: \(error.localizedDescription)")
            }
        }

        saveCache()
    }

    private func handleSessionsUpdate(_ json: [String: Any]) async {
        guard let sessionsArray = json["sessions"] else { return }
        do {
            let sessionsData = try JSONSerialization.data(withJSONObject: sessionsArray)
            let decoded = try Self.decoder.decode([RemoteSession].self, from: sessionsData)
            await MainActor.run {
                self.sessions = decoded
                self.checkForNewWaitingSessions(decoded)
            }
        } catch {
            logger.error("Sessions update decode error: \(error.localizedDescription)")
        }
        saveCache()
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

    private func checkForNewWaitingSessions(_ sessions: [RemoteSession]) {
        let nowWaiting = Set(
            sessions
                .filter { $0.isWaitingForInput && !$0.isCompleted && !$0.isHidden }
                .map(\.id)
        )

        let newlyWaiting = nowWaiting.subtracting(previouslyWaiting)
        previouslyWaiting = nowWaiting

        for sessionId in newlyWaiting {
            let session = sessions.first { $0.id == sessionId }
            let sessionName = session?.name ?? "A session"
            let projectName = session?.projectName ?? ""

            let content = UNMutableNotificationContent()
            content.title = "Waiting for input"
            content.body = projectName.isEmpty ? sessionName : "\(projectName) — \(sessionName)"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "companion-waiting-\(sessionId)",
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
                logger.info("Proactive token refresh succeeded, reconnecting")
                activeSocket?.cancel(with: .goingAway, reason: nil)
            } catch {
                logger.warning("Proactive token refresh failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cache

    private func loadCachedData() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.projectsCacheURL),
           let cached = try? decoder.decode([RemoteProject].self, from: data) {
            projects = cached
        }
        if let data = try? Data(contentsOf: Self.sessionsCacheURL),
           let cached = try? decoder.decode([RemoteSession].self, from: data) {
            sessions = cached
        }
    }

    private func saveCache() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(projects) {
            try? data.write(to: Self.projectsCacheURL)
        }
        if let data = try? encoder.encode(sessions) {
            try? data.write(to: Self.sessionsCacheURL)
        }
    }
}
