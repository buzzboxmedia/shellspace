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
    case bonjour(hostName: String)   // Auto-discovered on local network
    case manual                       // User-entered IP / hostname
}

@Observable
final class AppViewModel {
    var connectionState: ConnectionState = .disconnected
    var connectionMode: ConnectionMode = .none
    var projects: [RemoteProject] = []
    var allSessions: [RemoteSession] = []
    var api: ShellspaceAPI?
    var wsManager: WebSocketManager?
    var selectedTab: AppTab = .inbox
    var showSettings = false
    var lastRefreshed: Date?

    /// Set by notification tap or deep link -- navigates to this session
    var pendingSessionId: String?

    /// Set to true to programmatically activate search in BrowseView
    var activateSearch = false

    // MARK: - Bonjour Discovery

    let bonjourBrowser = BonjourBrowser()

    /// Whether Bonjour auto-connect has been attempted this session
    private var bonjourAutoConnected = false

    /// Check launch arguments and UserDefaults for navigation
    func handleLaunchArguments() {
        var targetSessionId: String?
        var targetTab: String?

        // Check launch arguments
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-session"), idx + 1 < args.count {
            targetSessionId = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "-tab"), idx + 1 < args.count {
            targetTab = args[idx + 1]
        }

        // Check UserDefaults deep link (written by simctl for testing)
        if targetSessionId == nil, let deepLink = UserDefaults.standard.string(forKey: "pendingDeepLink"), !deepLink.isEmpty {
            targetSessionId = deepLink
            UserDefaults.standard.removeObject(forKey: "pendingDeepLink")
        }

        // Apply navigation
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

    private var refreshTask: Task<Void, Never>?
    private var wsObserveTask: Task<Void, Never>?
    private var bonjourWatchTask: Task<Void, Never>?

    /// Persisted manual host (empty means no manual override -- use Bonjour)
    var macHost: String = UserDefaults.standard.string(forKey: "macHost") ?? "" {
        didSet { UserDefaults.standard.set(macHost, forKey: "macHost") }
    }

    /// The host currently being used for the active connection (may differ from macHost if Bonjour)
    var activeHost: String = ""

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

    /// Whether the app should show the initial setup screen.
    /// Now returns false if Bonjour is actively searching or has found hosts.
    var needsSetup: Bool {
        macHost.isEmpty && !connectionState.isConnected && bonjourBrowser.discoveredHosts.isEmpty && !bonjourBrowser.isSearching
    }

    // MARK: - Connection

    /// Start Bonjour browsing and attempt connection.
    /// If a manual host is set, connects directly. Otherwise waits for Bonjour discovery.
    func startDiscoveryAndConnect() async {
        // Always start Bonjour browsing in the background
        bonjourBrowser.startBrowsing()

        if !macHost.isEmpty {
            // Manual host is set -- connect directly
            activeHost = macHost
            connectionMode = .manual
            await connectToHost(macHost)
        } else {
            // No manual host -- wait for Bonjour to find something
            connectionState = .connecting
            startBonjourWatcher()
        }
    }

    /// Connect to a specific host (IP or hostname).
    func connectToHost(_ host: String) async {
        guard !host.isEmpty else { return }
        activeHost = host
        connectionState = .connecting

        do {
            let newAPI = try ShellspaceAPI(host: host)
            let status = try await newAPI.status()
            guard status.status == "online" else {
                connectionState = .error("Server not online")
                return
            }
            api = newAPI
            connectionState = .connected
            await refresh()

            // Start WebSocket for real-time session updates
            let manager = WebSocketManager(host: host)
            manager.connectSessions()
            wsManager = manager
            startWebSocketObserver()

            startAutoRefresh()
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }

    /// Legacy connect method -- now delegates to startDiscoveryAndConnect
    func connectAndLoad() async {
        await startDiscoveryAndConnect()
    }

    /// Connect to a discovered Bonjour host
    func connectToDiscoveredHost(_ host: DiscoveredHost) async {
        disconnect()
        connectionMode = .bonjour(hostName: host.name)
        await connectToHost(host.host)
    }

    /// Set a manual host, save it, and connect
    func setManualHost(_ host: String) {
        macHost = host
        disconnect()
        connectionMode = .manual
        activeHost = host
        Task {
            await connectToHost(host)
        }
    }

    /// Clear the manual host (revert to Bonjour-only)
    func clearManualHost() {
        macHost = ""
        disconnect()
        bonjourAutoConnected = false
        Task {
            await startDiscoveryAndConnect()
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        wsObserveTask?.cancel()
        wsObserveTask = nil
        bonjourWatchTask?.cancel()
        bonjourWatchTask = nil
        wsManager?.disconnectAll()
        wsManager = nil
        api = nil
        projects = []
        allSessions = []
        connectionState = .disconnected
        connectionMode = .none
        activeHost = ""
    }

    // MARK: - Bonjour Watcher

    /// Watches for Bonjour discovery results and auto-connects to the first host found.
    private func startBonjourWatcher() {
        bonjourWatchTask?.cancel()
        bonjourWatchTask = Task { [weak self] in
            // Poll for discovered hosts (BonjourBrowser updates are @Observable)
            for _ in 0..<60 {  // Try for up to 30 seconds
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                guard let self else { return }

                if let first = self.bonjourBrowser.discoveredHosts.first, !self.bonjourAutoConnected {
                    self.bonjourAutoConnected = true
                    self.connectionMode = .bonjour(hostName: first.name)
                    await self.connectToHost(first.host)
                    return
                }
            }

            // Timed out -- no Bonjour hosts found
            await MainActor.run {
                if case .connecting = self?.connectionState {
                    self?.connectionState = .disconnected
                }
            }
        }
    }

    // MARK: - Data Loading

    func refresh() async {
        guard let api else { return }

        do {
            let fetchedProjects = try await api.projects()
            var all: [RemoteSession] = []
            for project in fetchedProjects {
                if let sessions = try? await api.sessions(projectId: project.id) {
                    all.append(contentsOf: sessions)
                }
            }
            let finalSessions = all
            await MainActor.run {
                self.projects = fetchedProjects
                self.allSessions = finalSessions
                self.lastRefreshed = Date()
            }
        } catch {
            if case .connected = connectionState {
                connectionState = .error("Refresh failed")
            }
        }
    }

    func createSession(projectId: String, name: String, description: String?) async -> RemoteSession? {
        guard let api else { return nil }
        do {
            let session = try await api.createSession(projectId: projectId, name: name, description: description)
            await refresh()
            return session
        } catch {
            return nil
        }
    }

    var lastSendError: String = ""

    func sendQuickReply(sessionId: String, message: String) async -> Bool {
        // Always use REST for input -- it supports auto-launching stopped sessions
        // and provides reliable delivery confirmation. WebSocket input can silently
        // fail if the session has no active terminal controller.
        guard let api else {
            lastSendError = "No API connection"
            return false
        }
        do {
            try await api.sendInput(sessionId: sessionId, message: message)
            lastSendError = ""
            return true
        } catch {
            lastSendError = "\(error)"
            return false
        }
    }

    // MARK: - WebSocket Observer

    private func startWebSocketObserver() {
        wsObserveTask?.cancel()
        wsObserveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                guard let self, let manager = self.wsManager else { continue }
                let wsSessions = manager.sessions
                if !wsSessions.isEmpty {
                    await MainActor.run {
                        self.allSessions = wsSessions
                        self.lastRefreshed = Date()
                    }
                }
            }
        }
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Duration = self?.wsManager != nil ? .seconds(30) : .seconds(5)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func testConnection(host: String) async -> Bool {
        do {
            let testAPI = try ShellspaceAPI(host: host)
            let status = try await testAPI.status()
            return status.status == "online"
        } catch {
            return false
        }
    }
}
