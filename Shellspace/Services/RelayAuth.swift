import Foundation

/// Manages authentication with the Shellspace relay server (relay.shellspace.app).
/// Stores credentials in UserDefaults. Handles login, device registration, and token refresh.
final class RelayAuth: @unchecked Sendable {
    static let shared = RelayAuth()

    private let baseURL = "https://relay.shellspace.app"

    // MARK: - Stored Properties (UserDefaults)

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let email = "relay_email"
        static let accessToken = "relay_access_token"
        static let refreshToken = "relay_refresh_token"
        static let deviceId = "relay_device_id"
        static let userId = "relay_user_id"
        static let connectionMode = "relay_connection_mode"
    }

    var email: String? {
        get { defaults.string(forKey: Keys.email) }
        set { defaults.set(newValue, forKey: Keys.email) }
    }

    var accessToken: String? {
        get { defaults.string(forKey: Keys.accessToken) }
        set { defaults.set(newValue, forKey: Keys.accessToken) }
    }

    var refreshToken: String? {
        get { defaults.string(forKey: Keys.refreshToken) }
        set { defaults.set(newValue, forKey: Keys.refreshToken) }
    }

    var deviceId: String? {
        get { defaults.string(forKey: Keys.deviceId) }
        set { defaults.set(newValue, forKey: Keys.deviceId) }
    }

    var userId: String? {
        get { defaults.string(forKey: Keys.userId) }
        set { defaults.set(newValue, forKey: Keys.userId) }
    }

    /// Whether to use relay mode or local server mode
    var connectionMode: ConnectionMode {
        get {
            let raw = defaults.string(forKey: Keys.connectionMode) ?? "local"
            return ConnectionMode(rawValue: raw) ?? .local
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.connectionMode) }
    }

    var isAuthenticated: Bool {
        accessToken != nil && deviceId != nil
    }

    var isRelayMode: Bool {
        connectionMode == .relay
    }

    // MARK: - Connection Mode

    enum ConnectionMode: String {
        case local  // Hummingbird local server (Tailscale/LAN)
        case relay  // Outbound WebSocket to relay.shellspace.app
    }

    // MARK: - Auth Errors

    enum AuthError: Error, LocalizedError {
        case networkError(String)
        case invalidResponse
        case serverError(String)
        case notAuthenticated

        var errorDescription: String? {
            switch self {
            case .networkError(let msg): return "Network error: \(msg)"
            case .invalidResponse: return "Invalid server response"
            case .serverError(let msg): return "Server error: \(msg)"
            case .notAuthenticated: return "Not authenticated"
            }
        }
    }

    // MARK: - Login

    /// Login to the relay server. Returns user info on success.
    func login(email: String, password: String) async throws {
        let url = URL(string: "\(baseURL)/api/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError("Login failed (\(httpResponse.statusCode)): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String,
              let refresh = json["refreshToken"] as? String,
              let user = json["user"] as? [String: Any],
              let uid = user["id"] as? String else {
            throw AuthError.invalidResponse
        }

        self.email = email
        self.accessToken = token
        self.refreshToken = refresh
        self.userId = uid

        DebugLog.log("[RelayAuth] Login successful for \(email)")

        // Register device if we don't have one
        if self.deviceId == nil {
            try await registerDevice()
        }
    }

    // MARK: - Signup

    func signup(email: String, password: String) async throws {
        let url = URL(string: "\(baseURL)/api/auth/signup")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError("Signup failed (\(httpResponse.statusCode)): \(body)")
        }

        DebugLog.log("[RelayAuth] Signup successful for \(email)")

        // Now login to get tokens
        try await login(email: email, password: password)
    }

    // MARK: - Device Registration

    private func registerDevice() async throws {
        guard let token = accessToken else {
            throw AuthError.notAuthenticated
        }

        let deviceName = Host.current().localizedName ?? "Mac"
        let url = URL(string: "\(baseURL)/api/devices")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": deviceName,
            "platform": "macos"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError("Device registration failed (\(httpResponse.statusCode)): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse
        }

        // Support multiple response shapes: {device: {id: "..."}} or {id: "..."}
        let did: String
        if let device = json["device"] as? [String: Any], let deviceId = device["id"] as? String {
            did = deviceId
        } else if let directId = json["id"] as? String {
            did = directId
        } else {
            throw AuthError.invalidResponse
        }

        self.deviceId = did
        DebugLog.log("[RelayAuth] Device registered: \(did) (\(deviceName))")
    }

    // MARK: - Token Refresh

    /// Refresh the access token. Returns true if refresh succeeded.
    @discardableResult
    func refreshAccessToken() async throws -> Bool {
        guard let refresh = refreshToken else {
            throw AuthError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/api/auth/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refreshToken": refresh
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // Refresh failed - clear credentials
            DebugLog.log("[RelayAuth] Token refresh failed (\(httpResponse.statusCode)), clearing credentials")
            logout()
            return false
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["accessToken"] as? String else {
            throw AuthError.invalidResponse
        }

        self.accessToken = newToken
        if let newRefresh = json["refreshToken"] as? String {
            self.refreshToken = newRefresh
        }

        DebugLog.log("[RelayAuth] Token refreshed successfully")
        return true
    }

    // MARK: - Logout

    func logout() {
        email = nil
        accessToken = nil
        refreshToken = nil
        deviceId = nil
        userId = nil
        DebugLog.log("[RelayAuth] Logged out")
    }
}
