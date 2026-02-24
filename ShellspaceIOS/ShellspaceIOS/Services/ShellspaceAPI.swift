import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case serverError(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .serverError(let msg): return msg
        case .notConnected: return "Not connected to Mac"
        }
    }
}

final class ShellspaceAPI: Sendable {
    let baseURL: URL
    private let session: URLSession

    private static var sharedDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(host: String) throws {
        guard let url = URL(string: "http://\(host):8847") else {
            throw APIError.invalidURL
        }
        self.baseURL = url
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Endpoints

    func status() async throws -> ServerStatus {
        try await get("api/status")
    }

    func projects() async throws -> [RemoteProject] {
        let response: ProjectsResponse = try await get("api/projects")
        return response.projects
    }

    func sessions(projectId: String) async throws -> [RemoteSession] {
        let response: SessionsResponse = try await get("api/projects/\(projectId)/sessions")
        return response.sessions
    }

    func sessionDetail(id: String) async throws -> RemoteSession {
        try await get("api/sessions/\(id)")
    }

    func terminalContent(sessionId: String) async throws -> TerminalResponse {
        try await get("api/sessions/\(sessionId)/terminal")
    }

    func sendInput(sessionId: String, message: String) async throws {
        let url = baseURL.appending(path: "api/sessions/\(sessionId)/input")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": message])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError("Failed to send input")
        }
    }

    // MARK: - Helpers

    private func get<T: Codable>(_ path: String) async throws -> T {
        let url = baseURL.appending(path: path)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError("Server returned error")
        }
        return try Self.sharedDecoder.decode(T.self, from: data)
    }
}
