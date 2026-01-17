import Foundation
import CloudKit

/// Service for communicating with Mac via Tailscale
actor QuickReplyService {
    static let shared = QuickReplyService()

    // Tailscale server settings
    private let port: Int = 8847
    private let defaultMacHost = "barons-mac-studio.tail0277a9.ts.net"

    private var macHost: String {
        UserDefaults.standard.string(forKey: "mac_tailscale_ip") ?? defaultMacHost
    }

    private var baseURL: String {
        "http://\(macHost):\(port)"
    }

    // MARK: - API Methods

    /// Send a quick reply to a session
    func send(reply: String, to session: Session) async throws {
        guard !macHost.isEmpty else {
            throw ServerError.notConfigured
        }

        let url = URL(string: "\(baseURL)/api/sessions/\(session.id.uuidString)/reply")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body = ["message": reply]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw ServerError.requestFailed(errorBody?["error"] as? String ?? "Unknown error")
        }
    }

    /// Get server status
    func getStatus() async throws -> ServerStatus {
        guard !macHost.isEmpty else {
            throw ServerError.notConfigured
        }

        let url = URL(string: "\(baseURL)/api/status")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ServerError.requestFailed("Server not responding")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        return ServerStatus(
            isOnline: true,
            version: json?["version"] as? String ?? "unknown",
            waitingSessions: json?["waiting_sessions"] as? Int ?? 0,
            activeSessions: json?["active_sessions"] as? Int ?? 0
        )
    }

    /// Get active sessions from Mac
    func getSessions() async throws -> [[String: Any]] {
        guard !macHost.isEmpty else {
            throw ServerError.notConfigured
        }

        let url = URL(string: "\(baseURL)/api/sessions")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ServerError.requestFailed("Failed to fetch sessions")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["sessions"] as? [[String: Any]] ?? []
    }

    /// Get terminal content for a session
    func getTerminalContent(sessionId: UUID) async throws -> String {
        guard !macHost.isEmpty else {
            throw ServerError.notConfigured
        }

        let url = URL(string: "\(baseURL)/api/sessions/\(sessionId.uuidString)/terminal")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ServerError.requestFailed("Failed to fetch terminal")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["content"] as? String ?? ""
    }

    /// Mark a session as complete
    func completeSession(_ session: Session) async throws {
        guard !macHost.isEmpty else {
            throw ServerError.notConfigured
        }

        let url = URL(string: "\(baseURL)/api/sessions/\(session.id.uuidString)/complete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ServerError.requestFailed("Failed to complete session")
        }
    }

    // MARK: - Configuration

    func setMacHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: "mac_tailscale_ip")
    }

    func getMacHost() -> String {
        macHost
    }

    func getDefaultHost() -> String {
        defaultMacHost
    }

    // MARK: - CloudKit Fallback (for when not on Tailscale)

    private let cloudKitContainer = CKContainer(identifier: "iCloud.com.buzzbox.claudehub")

    func sendViaCloudKit(reply: String, to session: Session) async throws {
        let record = CKRecord(recordType: "QuickReply")
        record["sessionId"] = session.id.uuidString
        record["sessionName"] = session.name
        record["message"] = reply
        record["timestamp"] = Date()
        record["processed"] = false

        try await cloudKitContainer.privateCloudDatabase.save(record)
    }

    func checkCloudKitStatus() async throws -> CKAccountStatus {
        try await cloudKitContainer.accountStatus()
    }
}

// MARK: - Types

struct ServerStatus {
    let isOnline: Bool
    let version: String
    let waitingSessions: Int
    let activeSessions: Int
}

enum ServerError: LocalizedError {
    case notConfigured
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Mac IP not configured. Go to Settings to set your Tailscale IP."
        case .requestFailed(let message):
            return message
        }
    }
}

// MARK: - Connection Status View

import SwiftUI

struct ConnectionStatusView: View {
    @State private var status: ServerStatus?
    @State private var isChecking = false
    @State private var error: String?
    @State private var macHost: String = ""
    @State private var isUsingDefault = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Connection Status
            HStack {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("barons-mac-studio")
                        .font(.subheadline.bold())

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isChecking {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button("Test") {
                        Task { await checkStatus() }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }

            // Stats when connected
            if let status = status, status.isOnline {
                HStack(spacing: 20) {
                    Label("\(status.activeSessions) active", systemImage: "terminal")
                    Label("\(status.waitingSessions) waiting", systemImage: "bell.badge")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            Task {
                macHost = await QuickReplyService.shared.getMacHost()
                await checkStatus()
            }
        }
    }

    var statusIcon: String {
        if isChecking { return "arrow.triangle.2.circlepath" }
        if let error = error { return "exclamationmark.triangle" }
        if status?.isOnline == true { return "checkmark.circle" }
        return "circle.dashed"
    }

    var statusColor: Color {
        if let _ = error { return .red }
        if status?.isOnline == true { return .green }
        return .gray
    }

    var statusText: String {
        if isChecking { return "Connecting via Tailscale..." }
        if let error = error { return error }
        if let status = status, status.isOnline {
            return "Connected - ClaudeHub v\(status.version)"
        }
        return "Tap Test to connect"
    }

    func checkStatus() async {
        isChecking = true
        error = nil

        do {
            status = try await QuickReplyService.shared.getStatus()
        } catch {
            self.error = error.localizedDescription
            self.status = nil
        }

        isChecking = false
    }
}

#Preview {
    ConnectionStatusView()
        .padding()
}
