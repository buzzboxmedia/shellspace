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
    var selectedTab: AppTab = .waiting
    var showSettings = false
    var lastRefreshed: Date?

    private var refreshTask: Task<Void, Never>?

    var macHost: String {
        get { UserDefaults.standard.string(forKey: "macHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "macHost") }
    }

    var waitingSessions: [RemoteSession] {
        allSessions
            .filter { $0.isWaitingForInput && !$0.isCompleted && !$0.isHidden }
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
            startAutoRefresh()
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
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
            // Fetch all sessions across all projects
            var all: [RemoteSession] = []
            for project in fetchedProjects {
                if let sessions = try? await api.sessions(projectId: project.id) {
                    all.append(contentsOf: sessions)
                }
            }
            await MainActor.run {
                self.projects = fetchedProjects
                self.allSessions = all
                self.lastRefreshed = Date()
            }
        } catch {
            // Keep stale data, just update connection state if truly disconnected
            if case .connected = connectionState {
                connectionState = .error("Refresh failed")
            }
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

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
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
