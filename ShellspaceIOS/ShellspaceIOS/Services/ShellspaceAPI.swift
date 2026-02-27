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
