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

    // MARK: - Project Visibility Filter

    /// Project IDs that are hidden. When empty, all projects are visible.
    var hiddenProjectIds: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "hiddenProjectIds") ?? []
        return Set(saved)
    }() {
        didSet {
            UserDefaults.standard.set(Array(hiddenProjectIds), forKey: "hiddenProjectIds")
        }
    }

    /// Projects filtered by visibility settings
    var visibleProjects: [RemoteProject] {
        if hiddenProjectIds.isEmpty { return projects }
        return projects.filter { !hiddenProjectIds.contains($0.id) }
    }

    /// Sessions filtered to only include those from visible projects
    var visibleSessions: [RemoteSession] {
        if hiddenProjectIds.isEmpty { return allSessions }
        let visiblePaths = Set(visibleProjects.map { $0.path })
        return allSessions.filter { visiblePaths.contains($0.projectPath) }
    }

    func toggleProjectVisibility(_ projectId: String) {
        if hiddenProjectIds.contains(projectId) {
            hiddenProjectIds.remove(projectId)
        } else {
            hiddenProjectIds.insert(projectId)
        }
    }

    func isProjectVisible(_ projectId: String) -> Bool {
        !hiddenProjectIds.contains(projectId)
    }

    // MARK: - Local Cache

    private static let cacheDir: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }()
    private static let projectsCacheURL = cacheDir.appendingPathComponent("cached_projects.json")
    private static let sessionsCacheURL = cacheDir.appendingPathComponent("cached_sessions.json")

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
        visibleSessions
            .filter { $0.isWaitingForInput && !$0.isCompleted && !$0.isHidden }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var allActiveSessions: [RemoteSession] {
        visibleSessions
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
        projects = []
        allSessions = []
        lastRefreshed = nil
        clearCache()
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
        // Preserve projects/allSessions so cached data stays visible during reconnects
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
