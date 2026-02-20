import Foundation

struct AppVersion {
    static let version = "1.3.0"

    /// Lazy-loaded build hash -- deferred from app startup so `git` doesn't block launch.
    /// Only resolved the first time the Settings view is opened.
    static var buildHash: String {
        if let cached = _buildHash { return cached }
        let resolved = getBuildHash() ?? "unknown"
        _buildHash = resolved
        return resolved
    }

    private static var _buildHash: String?

    private static func getBuildHash() -> String? {
        let possibleDirs = [
            NSHomeDirectory() + "/Code/shellspace",
            NSHomeDirectory() + "/code/shellspace"
        ]
        for dir in possibleDirs {
            guard FileManager.default.fileExists(atPath: dir + "/.git") else { continue }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["rev-parse", "--short", "HEAD"]
            task.currentDirectoryURL = URL(fileURLWithPath: dir)
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    return output
                }
            } catch {}
        }
        return nil
    }
}
