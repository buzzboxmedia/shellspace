import Foundation
import UserNotifications

/// Manages WebSocket connections to the Shellspace Mac server.
/// Streams terminal content and session state with auto-reconnect.
/// Fires local notifications when sessions start waiting for input.
@Observable
final class WebSocketManager {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    // MARK: - Terminal stream

    var terminalState: State = .disconnected
    var terminalContent: String = ""
    var terminalIsRunning: Bool = false
    var terminalIsWaiting: Bool = false

    // MARK: - Sessions stream

    var sessionsState: State = .disconnected
    var sessions: [RemoteSession] = []

    // MARK: - Private

    private let host: String
    private var terminalTask: Task<Void, Never>?
    private var sessionsTask: Task<Void, Never>?

    /// Tracks which sessions were waiting last time, so we only notify on transitions
    private var previouslyWaiting: Set<String> = []
    /// Don't re-notify the same session within this window
    private var recentlyNotified: [String: Date] = [:]
    private let notifyCooldown: TimeInterval = 60

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(host: String) {
        self.host = host
    }

    // MARK: - Terminal WebSocket

    func connectTerminal(sessionId: String) {
        disconnectTerminal()
        terminalState = .connecting
        terminalTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                do {
                    attempt = 0
                    try await runTerminalSocket(sessionId: sessionId)
                    break
                } catch {
                    guard !Task.isCancelled else { break }
                    attempt += 1
                    let currentAttempt = attempt
                    await MainActor.run { self.terminalState = .reconnecting(attempt: currentAttempt) }
                    let delay = min(15.0, pow(2.0, Double(currentAttempt - 1)))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            await MainActor.run { self.terminalState = .disconnected }
        }
    }

    func disconnectTerminal() {
        terminalTask?.cancel()
        terminalTask = nil
        terminalState = .disconnected
    }

    /// Send input to the terminal via the active WebSocket connection.
    func sendTerminalInput(_ message: String) -> Bool {
        guard let ws = activeTerminalSocket else { return false }
        let payload: [String: Any] = ["type": "input", "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return false }
        ws.send(.string(text)) { _ in }
        return true
    }

    private var activeTerminalSocket: URLSessionWebSocketTask?

    private func runTerminalSocket(sessionId: String) async throws {
        guard let url = URL(string: "ws://\(host):8847/ws/terminal/\(sessionId)") else {
            throw APIError.invalidURL
        }
        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()
        activeTerminalSocket = wsTask
        await MainActor.run { self.terminalState = .connected }

        while !Task.isCancelled {
            let message = try await wsTask.receive()
            if case .string(let text) = message { parseTerminalMessage(text) }
        }
        activeTerminalSocket = nil
        wsTask.cancel(with: .goingAway, reason: nil)
    }

    private func parseTerminalMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "terminal_update" else { return }

        let content = json["content"] as? String ?? ""
        let isRunning = json["is_running"] as? Bool ?? false
        let isWaiting = json["is_waiting_for_input"] as? Bool ?? false

        Task { @MainActor in
            self.terminalContent = content
            self.terminalIsRunning = isRunning
            self.terminalIsWaiting = isWaiting
        }
    }

    // MARK: - Sessions WebSocket

    func connectSessions() {
        disconnectSessions()
        sessionsState = .connecting
        sessionsTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                do {
                    attempt = 0
                    try await runSessionsSocket()
                    break
                } catch {
                    guard !Task.isCancelled else { break }
                    attempt += 1
                    let currentAttempt = attempt
                    await MainActor.run { self.sessionsState = .reconnecting(attempt: currentAttempt) }
                    let delay = min(15.0, pow(2.0, Double(currentAttempt - 1)))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            await MainActor.run { self.sessionsState = .disconnected }
        }
    }

    func disconnectSessions() {
        sessionsTask?.cancel()
        sessionsTask = nil
        sessionsState = .disconnected
    }

    private func runSessionsSocket() async throws {
        guard let url = URL(string: "ws://\(host):8847/ws/sessions") else {
            throw APIError.invalidURL
        }
        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()
        await MainActor.run { self.sessionsState = .connected }

        while !Task.isCancelled {
            let message = try await wsTask.receive()
            if case .string(let text) = message { parseSessionsMessage(text) }
        }
        wsTask.cancel(with: .goingAway, reason: nil)
    }

    private func parseSessionsMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "sessions_update",
              let sessionsArray = json["sessions"] else { return }

        guard let sessionsData = try? JSONSerialization.data(withJSONObject: sessionsArray),
              let decoded = try? Self.decoder.decode([RemoteSession].self, from: sessionsData) else { return }

        Task { @MainActor in
            self.sessions = decoded
            self.checkForNewWaitingSessions(decoded)
        }
    }

    // MARK: - Local Notifications

    /// Detects sessions that just started waiting and fires a local notification.
    private func checkForNewWaitingSessions(_ sessions: [RemoteSession]) {
        let nowWaiting = Set(
            sessions
                .filter { $0.isWaitingForInput && !$0.isCompleted && !$0.isHidden }
                .map(\.id)
        )

        let newlyWaiting = nowWaiting.subtracting(previouslyWaiting)
        previouslyWaiting = nowWaiting

        // Clean up old cooldowns
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
                trigger: nil // Deliver immediately
            )

            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Request notification permission. Call once at app startup.
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Cleanup

    func disconnectAll() {
        disconnectTerminal()
        disconnectSessions()
    }
}
