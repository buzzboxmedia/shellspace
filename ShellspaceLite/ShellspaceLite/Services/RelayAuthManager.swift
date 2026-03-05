import Foundation

enum AuthError: LocalizedError {
    case invalidURL
    case invalidCredentials
    case networkError(String)
    case serverError(Int, String)
    case tokenExpired
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .invalidCredentials: return "Invalid email or password"
        case .networkError(let msg): return msg
        case .serverError(_, let msg): return msg
        case .tokenExpired: return "Session expired. Please log in again."
        case .notAuthenticated: return "Not logged in"
        }
    }
}

struct AuthUser: Codable {
    let id: String
    let email: String
}

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: AuthUser
}

/// Manages authentication with the Shellspace relay server.
/// Stores tokens in UserDefaults and handles automatic token refresh.
@Observable
final class RelayAuthManager {
    static let relayBaseURL = "https://relay.shellspace.app"

    var isLoggedIn: Bool = false
    var currentUser: AuthUser?
    var isLoading: Bool = false

    private(set) var accessToken: String? {
        didSet { UserDefaults.standard.set(accessToken, forKey: "relay_accessToken") }
    }
    private var refreshTokenValue: String? {
        didSet { UserDefaults.standard.set(refreshTokenValue, forKey: "relay_refreshToken") }
    }

    private let session: URLSession
    private var refreshTask: Task<String, Error>?

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)

        // Restore persisted auth state
        self.accessToken = UserDefaults.standard.string(forKey: "relay_accessToken")
        self.refreshTokenValue = UserDefaults.standard.string(forKey: "relay_refreshToken")

        if let token = accessToken, !token.isEmpty {
            self.isLoggedIn = true
            self.currentUser = AuthUser(
                id: UserDefaults.standard.string(forKey: "relay_userId") ?? "",
                email: UserDefaults.standard.string(forKey: "relay_email") ?? ""
            )
        }
    }

    // MARK: - Public API

    func login(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }

        let body: [String: Any] = ["email": email, "password": password]
        let response: AuthResponse = try await post("api/auth/login", body: body)
        applyAuthResponse(response)
    }

    func signup(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }

        let body: [String: Any] = ["email": email, "password": password]
        let response: AuthResponse = try await post("api/auth/signup", body: body)
        applyAuthResponse(response)
    }

    func deleteAccount() async throws {
        let token = try await validAccessToken()
        guard let url = URL(string: "\(Self.relayBaseURL)/api/auth/account") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = parseErrorMessage(data) ?? "Failed to delete account"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AuthError.serverError(code, message)
        }
        await MainActor.run { logout() }
    }

    func logout() {
        accessToken = nil
        refreshTokenValue = nil
        isLoggedIn = false
        currentUser = nil
        refreshTask = nil

        UserDefaults.standard.removeObject(forKey: "relay_accessToken")
        UserDefaults.standard.removeObject(forKey: "relay_refreshToken")
        UserDefaults.standard.removeObject(forKey: "relay_userId")
        UserDefaults.standard.removeObject(forKey: "relay_email")
        UserDefaults.standard.removeObject(forKey: "selectedDeviceId")
        UserDefaults.standard.removeObject(forKey: "selectedDeviceName")
    }

    /// Returns a valid access token, refreshing if needed.
    /// Thread-safe: coalesces concurrent refresh calls into a single request.
    func validAccessToken() async throws -> String {
        guard let token = accessToken, !token.isEmpty else {
            throw AuthError.notAuthenticated
        }

        // Check if token expires within the next 60 seconds
        if let exp = decodeJWTExpiration(token), exp.timeIntervalSinceNow < 60 {
            return try await refreshAccessToken()
        }

        return token
    }

    // MARK: - Token Refresh

    /// Refresh the access token. Coalesces concurrent calls.
    func refreshAccessToken() async throws -> String {
        // If a refresh is already in flight, await that instead of firing another
        if let existing = refreshTask {
            return try await existing.value
        }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw AuthError.notAuthenticated }
            guard let refresh = self.refreshTokenValue, !refresh.isEmpty else {
                await MainActor.run { self.logout() }
                throw AuthError.tokenExpired
            }

            do {
                let body: [String: Any] = ["refreshToken": refresh]
                let response: AuthResponse = try await self.post("api/auth/refresh", body: body)
                await MainActor.run {
                    self.applyAuthResponse(response)
                }
                return response.accessToken
            } catch {
                await MainActor.run { self.logout() }
                throw AuthError.tokenExpired
            }
        }

        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    // MARK: - JWT Helpers

    /// Decode the `exp` claim from a JWT without verifying the signature.
    private func decodeJWTExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
        // Pad base64 to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(contentsOf: String(repeating: "=", count: 4 - remainder))
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Network Helpers

    private func post<T: Codable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: "\(Self.relayBaseURL)/\(path)") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200...299:
            return try Self.decoder.decode(T.self, from: data)
        case 401:
            throw AuthError.invalidCredentials
        case 400...499:
            let message = parseErrorMessage(data) ?? "Request failed (\(http.statusCode))"
            throw AuthError.serverError(http.statusCode, message)
        default:
            let message = parseErrorMessage(data) ?? "Server error (\(http.statusCode))"
            throw AuthError.serverError(http.statusCode, message)
        }
    }

    private func parseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["error"] as? String ?? json["message"] as? String
    }

    private func applyAuthResponse(_ response: AuthResponse) {
        accessToken = response.accessToken
        refreshTokenValue = response.refreshToken
        currentUser = response.user
        isLoggedIn = true

        // Persist user info for restore on next launch
        UserDefaults.standard.set(response.user.id, forKey: "relay_userId")
        UserDefaults.standard.set(response.user.email, forKey: "relay_email")
    }
}
