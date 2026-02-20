import Foundation

/// Category for organizing projects in the UI
enum ProjectCategory: String, Codable, CaseIterable {
    case main
    case client
    case dev

    var displayName: String {
        switch self {
        case .main: return "Main Projects"
        case .client: return "Clients"
        case .dev: return "Development"
        }
    }
}
