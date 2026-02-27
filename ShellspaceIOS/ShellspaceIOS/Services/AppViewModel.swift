import SwiftUI

enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case error(String)

    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        case .error: return .red
        }
    }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// How the connection to the Mac was established.
enum ConnectionMode: Equatable {
    case none
    case relay(deviceName: String)     // Connected through relay server
    case bonjour(hostName: String)     // Auto-discovered on local network (legacy)
    case manual                        // User-entered IP / hostname (legacy)
}

@Observable
final class AppViewModel {
    var connectionState: ConnectionState = .disconnected
    var connectionMode: ConnectionMode = .none
    var projects: [RemoteProject] = []
    var allSessions: [RemoteSession] = []
    var wsManager: WebSocketManager?
    var selectedTab: AppTab = .inbox
    var showSettings = false
    var lastRefreshed: Date?

    /// Set by notification tap or deep link -- navigates to this session
    var pendingSessionId: String?

    /// Set to true to programmatically activate search in BrowseView
    var activateSearch = false

    // MARK: - Auth

    let relayAuth = RelayAuthManager()

    // MARK: - Device Selection

    var selectedDeviceId: String? = UserDefaults.standard.string(forKey: "selectedDeviceId") {
        didSet {
            if let id = selectedDeviceId {
                UserDefaults.standard.set(id, forKey: "selectedDeviceId")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedDeviceId")
            }
        }
    }

    var selectedDeviceName: String? = UserDefaults.standard.string(forKey: "selectedDeviceName") {
        didSet {
            if let name = selectedDeviceName {
                UserDefaults.standard.set(name, forKey: "selectedDeviceName")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedDeviceName")
            }
        }
    }

    var waitingSessions: [RemoteSession] {
        allSessions
            .filter { $0.isWaitingForInput && !$0.isCompleted && !$0.isHidden }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var allActiveSessions: [RemoteSession] {
        allSessions
            .filter { !$0.isCompleted && !$0.isHidden }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    // MARK: - App State

    /// Which screen should the app show?
    enum AppScreen {
        case login
        case devicePicker
        case main
    }

    var currentScreen: AppScreen {
        if !relayAuth.isLoggedIn {
            return .login
        }
        if selectedDeviceId == nil {
            return .devicePicker
        }
        return .main
    }

    // MARK: - Launch Arguments

    func handleLaunchArguments() {
        var targetSessionId: String?
        var targetTab: String?

        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-session"), idx + 1 < args.count {
            targetSessionId = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "-tab"), idx + 1 < args.count {
            targetTab = args[idx + 1]
        }

        if targetSessionId == nil, let deepLink = UserDefaults.standard.string(forKey: "pendingDeepLink"), !deepLink.isEmpty {
            targetSessionId = deepLink
            UserDefaults.standard.removeObject(forKey: "pendingDeepLink")
        }

        if let sessionId = targetSessionId {
            selectedTab = .sessions
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                self.pendingSessionId = sessionId
            }
        } else if let tab = targetTab {
            switch tab {
            case "browse", "projects": selectedTab = .projects
            case "waiting", "inbox": selectedTab = .inbox
            case "sessions": selectedTab = .sessions
            default: break
            }
        }
    }

    private var wsObserveTask: Task<Void, Never>?

    // MARK: - Device Selection & Connection

    /// Called from DevicePickerView when user taps a device.
    func selectDevice(_ device: RelayDevice) {
        selectedDeviceId = device.id
        selectedDeviceName = device.name
        connectToRelay()
    }

    /// Disconnect and go back to device picker.
    func disconnectDevice() {
        disconnect()
        selectedDeviceId = nil
        selectedDeviceName = nil
    }

    /// Connect to the selected device via relay tunnel.
    func connectToRelay() {
        guard let deviceId = selectedDeviceId else { return }
        disconnect()
        connectionState = .connecting
        connectionMode = .relay(deviceName: selectedDeviceName ?? deviceId)

        let manager = WebSocketManager(deviceId: deviceId, authManager: relayAuth)
        manager.connect()
        wsManager = manager
        startWebSocketObserver()
    }

    func disconnect() {
        wsObserveTask?.cancel()
        wsObserveTask = nil
        wsManager?.disconnect()
        wsManager = nil
        projects = []
        allSessions = []
        connectionState = .disconnected
        connectionMode = .none
    }

    // MARK: - Data from WebSocket

    /// Observe the WebSocket manager for state/session/project updates.
    private func startWebSocketObserver() {
        wsObserveTask?.cancel()
        wsObserveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                guard let self, let manager = self.wsManager else { continue }

                // Mirror tunnel state to connection state
                await MainActor.run {
                    switch manager.tunnelState {
                    case .connected:
                        if !self.connectionState.isConnected {
                            self.connectionState = .connected
                        }
                    case .connecting:
                        if case .disconnected = self.connectionState {
                            self.connectionState = .connecting
                        }
                    case .reconnecting(let attempt):
                        self.connectionState = .connecting
                        if attempt > 3 {
                            self.connectionState = .error("Reconnecting (attempt \(attempt))...")
                        }
                    case .disconnected:
                        if self.connectionState.isConnected {
                            self.connectionState = .error("Connection lost")
                        }
                    }
                }

                // Ingest sessions and projects from the tunnel
                let wsSessions = manager.sessions
                let wsProjects = manager.projects
                if !wsSessions.isEmpty || !wsProjects.isEmpty {
                    await MainActor.run {
                        if !wsSessions.isEmpty {
                            self.allSessions = wsSessions
                        }
                        if !wsProjects.isEmpty {
                            self.projects = wsProjects
                        }
                        self.lastRefreshed = Date()
                    }
                }
            }
        }
    }

    // MARK: - Actions Through Tunnel

    func refresh() async {
        wsManager?.requestStateRefresh()
    }

    func createSession(projectId: String, name: String, description: String?) async -> RemoteSession? {
        guard let ws = wsManager else { return nil }
        let sent = ws.createSession(projectId: projectId, name: name, description: description)
        guard sent else { return nil }

        // Wait briefly for the Mac to respond with the created session
        try? await Task.sleep(for: .seconds(1))
        return allSessions.first { $0.name == name }
    }

    var lastSendError: String = ""

    func sendQuickReply(sessionId: String, message: String) async -> Bool {
        guard let ws = wsManager else {
            lastSendError = "No connection"
            return false
        }
        let sent = ws.sendInput(sessionId: sessionId, message: message)
        if sent {
            lastSendError = ""
        } else {
            lastSendError = "Failed to send through tunnel"
        }
        return sent
    }

    func sendImage(sessionId: String, imageData: Data, filename: String) async -> Bool {
        guard let ws = wsManager else { return false }
        return ws.sendImage(sessionId: sessionId, imageData: imageData, filename: filename)
    }
}
