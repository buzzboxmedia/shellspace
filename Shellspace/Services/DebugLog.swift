import Foundation

/// File-based debug logger that writes to ~/Library/Logs/Shellspace/debug.log
/// Use this instead of print() to capture output from the GUI app.
enum DebugLog {
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Shellspace")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        // Also print to stdout (visible when launched from terminal)
        print(line, terminator: "")

        // Append to file (visible always)
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Clear the log file (call on app launch)
    static func clear() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }
}
