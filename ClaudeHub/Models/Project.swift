import Foundation

struct Project: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let icon: String

    var url: URL {
        URL(fileURLWithPath: path)
    }
}
