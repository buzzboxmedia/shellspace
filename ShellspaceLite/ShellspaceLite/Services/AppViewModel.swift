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
    case relay(deviceName: String)
    case bonjour(hostName: String)
    case manual
}

@Observable
final class AppViewModel {
    var connectionState: ConnectionState = .disconnected
    var connectionMode: ConnectionMode = .none
    var projects: [RemoteProject] = []
    var allSessions: [RemoteSession] = []
    var wsManager: WebSocketManager?
    var showSettings = false
    var lastRefreshed: Date?

    // MARK: - Project Access (server-filtered per user)

    /// The primary project to show (first project from server-filtered list)
    var primaryProject: RemoteProject? {
        projects.first
    }

    /// Display title - uses primary project name or "Shellspace"
    var displayTitle: String {
        if projects.count == 1 {
            return projects.first?.name ?? "Shellspace"
        }
        return "Shellspace"
    }

    /// All visible sessions (already filtered by server per user assignments)
    var projectSessions: [RemoteSession] {
        let projectPaths = Set(projects.map { $0.path })
        return allSessions
            .filter { projectPaths.contains($0.projectPath) && !$0.isHidden }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var waitingSessions: [RemoteSession] {
        projectSessions
            .filter { $0.isWaitingForInput && !$0.isCompleted }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var activeSessions: [RemoteSession] {
        projectSessions
            .filter { !$0.isCompleted }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    // MARK: - Local Cache

    private static let cacheDir: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }()
    private static let projectsCacheURL = cacheDir.appendingPathComponent("cached_projects_lite.json")
    private static let sessionsCacheURL = cacheDir.appendingPathComponent("cached_sessions_lite.json")

    init() {
        loadCachedData()
    }

    private func loadCachedData() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.projectsCacheURL),
           let cached = try? decoder.decode([RemoteProject].self, from: data) {
            projects = cached
        }
        if let data = try? Data(contentsOf: Self.sessionsCacheURL),
           let cached = try? decoder.decode([RemoteSession].self, from: data) {
            allSessions = cached
        }
        if let date = UserDefaults.standard.object(forKey: "lastCacheDate") as? Date {
            lastRefreshed = date
        }
    }

    private func saveCache() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(projects) {
            try? data.write(to: Self.projectsCacheURL)
        }
        if let data = try? encoder.encode(allSessions) {
            try? data.write(to: Self.sessionsCacheURL)
        }
        UserDefaults.standard.set(Date(), forKey: "lastCacheDate")
    }

    private func clearCache() {
        try? FileManager.default.removeItem(at: Self.projectsCacheURL)
        try? FileManager.default.removeItem(at: Self.sessionsCacheURL)
        UserDefaults.standard.removeObject(forKey: "lastCacheDate")
    }

    /// Set by notification tap -- navigates to this session
    var pendingSessionId: String?

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

    // MARK: - App State

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

    private var wsObserveTask: Task<Void, Never>?

    // MARK: - Device Selection & Connection

    func selectDevice(_ device: RelayDevice) {
        selectedDeviceId = device.id
        selectedDeviceName = device.name
        connectToRelay()
    }

    /// Auto-select single online device (skip device picker if only one device)
    func autoSelectSingleDevice(_ devices: [RelayDevice]) {
        let onlineDevices = devices.filter { $0.online }
        if onlineDevices.count == 1, let device = onlineDevices.first {
            selectDevice(device)
        }
    }

    func disconnectDevice() {
        disconnect()
        selectedDeviceId = nil
        selectedDeviceName = nil
        projects = []
        allSessions = []
        lastRefreshed = nil
        clearCache()
    }

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
        connectionState = .disconnected
        connectionMode = .none
    }

    // MARK: - Data from WebSocket

    private func startWebSocketObserver() {
        wsObserveTask?.cancel()
        wsObserveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                guard let self, let manager = self.wsManager else { continue }

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
                        self.saveCache()
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
