import Foundation

struct AppVersion {
    static let version = "1.3.0"
    static let buildHash = getBuildHash() ?? "unknown"

    private static func getBuildHash() -> String? {
        let possibleDirs = [
            NSHomeDirectory() + "/Code/claudehub",
            NSHomeDirectory() + "/code/claudehub"
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
