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

@Observable
final class AppViewModel {
    var connectionState: ConnectionState = .disconnected
    var projects: [RemoteProject] = []
    var allSessions: [RemoteSession] = []
    var api: ShellspaceAPI?
    var wsManager: WebSocketManager?
    var selectedTab: AppTab = .inbox
    var showSettings = false
    var lastRefreshed: Date?

    /// Set by notification tap or deep link — navigates to this session
    var pendingSessionId: String?

    /// Set to true to programmatically activate search in BrowseView
    var activateSearch = false

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

    var macHost: String = UserDefaults.standard.string(forKey: "macHost") ?? "" {
        didSet { UserDefaults.standard.set(macHost, forKey: "macHost") }
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

    // MARK: - Connection

    func connectAndLoad() async {
        guard !macHost.isEmpty else { return }
        connectionState = .connecting

        do {
            let newAPI = try ShellspaceAPI(host: macHost)
            let status = try await newAPI.status()
            guard status.status == "online" else {
                connectionState = .error("Server not online")
                return
            }
            api = newAPI
            connectionState = .connected
            await refresh()

            // Start WebSocket for real-time session updates
            let manager = WebSocketManager(host: macHost)
            manager.connectSessions()
            wsManager = manager
            startWebSocketObserver()

            startAutoRefresh()
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        wsObserveTask?.cancel()
        wsObserveTask = nil
        wsManager?.disconnectAll()
        wsManager = nil
        api = nil
        projects = []
        allSessions = []
        connectionState = .disconnected
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

    func sendQuickReply(sessionId: String, message: String) async -> Bool {
        guard let api else { return false }
        do {
            try await api.sendInput(sessionId: sessionId, message: message)
            return true
        } catch {
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
