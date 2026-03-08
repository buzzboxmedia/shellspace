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
        static let companionDeviceId = "relay_companion_device_id"
        static let companionDeviceName = "relay_companion_device_name"
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

    var isCompanionMode: Bool {
        connectionMode == .companion
    }

    // MARK: - Companion Mode (connect as tunnel client to another Mac)

    var companionDeviceId: String? {
        get { defaults.string(forKey: Keys.companionDeviceId) }
        set { defaults.set(newValue, forKey: Keys.companionDeviceId) }
    }

    var companionDeviceName: String? {
        get { defaults.string(forKey: Keys.companionDeviceName) }
        set { defaults.set(newValue, forKey: Keys.companionDeviceName) }
    }

    // MARK: - Connection Mode

    enum ConnectionMode: String {
        case local      // Hummingbird local server (Tailscale/LAN)
        case relay      // Outbound WebSocket to relay.shellspace.app (HOST)
        case companion  // Tunnel client to another Mac's relay (CLIENT)
    }

    // MARK: - Device Listing (for companion device picker)

    struct RelayDevice: Codable, Identifiable {
        let id: String
        let name: String
        let platform: String?
        let online: Bool
        let shared: Bool?
    }

    /// List devices available to this user (owned + shared)
    func listDevices() async throws -> [RelayDevice] {
        guard let token = accessToken else {
            throw AuthError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/api/devices")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError("List devices failed: \(body)")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Response may be {devices: [...]} or [...]
        if let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devicesArray = wrapper["devices"] {
            let devicesData = try JSONSerialization.data(withJSONObject: devicesArray)
            return try decoder.decode([RelayDevice].self, from: devicesData)
        }

        return try decoder.decode([RelayDevice].self, from: data)
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
            // Refresh failed - only clear the access token, NOT the refresh token or deviceId.
            // A transient server error or race condition shouldn't require full re-login.
            DebugLog.log("[RelayAuth] Token refresh failed (\(httpResponse.statusCode)), clearing access token only")
            self.accessToken = nil
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

    // MARK: - Device Sharing

    /// Share this device with another user by email
    func shareDevice(email targetEmail: String) async throws -> (userId: String, email: String) {
        guard let token = accessToken, let devId = deviceId else {
            throw AuthError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/api/devices/\(devId)/share")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": targetEmail])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError("Share failed (\(httpResponse.statusCode)): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = json["userId"] as? String,
              let email = json["email"] as? String else {
            throw AuthError.invalidResponse
        }

        DebugLog.log("[RelayAuth] Device shared with \(email) (\(uid))")
        return (uid, email)
    }

    /// Revoke device sharing for a user
    func revokeDeviceShare(userId targetUserId: String) async throws {
        guard let token = accessToken, let devId = deviceId else {
            throw AuthError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/api/devices/\(devId)/shares/\(targetUserId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError("Revoke failed (\(httpResponse.statusCode)): \(body)")
        }

        DebugLog.log("[RelayAuth] Device share revoked for \(targetUserId)")
    }

    /// List current device shares
    func listDeviceShares() async throws -> [(userId: String, email: String)] {
        guard let token = accessToken, let devId = deviceId else {
            throw AuthError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/api/devices/\(devId)/shares")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return []
        }

        guard let shares = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return shares.compactMap { share in
            guard let uid = share["user_id"] as? String,
                  let email = share["email"] as? String else { return nil }
            return (uid, email)
        }
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
