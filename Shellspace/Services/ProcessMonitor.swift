import Foundation
import os.log

private let logger = Logger(subsystem: "com.buzzbox.shellspace", category: "ProcessMonitor")

/// Process state for a Claude session
enum SessionProcessState: Equatable {
    case running    // claude process found for this directory
    case stopped    // no claude process found
}

/// Lightweight service that checks if a `claude` process is running for a session's working directory.
/// Uses `pgrep -f` to match processes by command-line arguments.
/// Results are cached briefly (2s) to avoid hammering ps on every SwiftUI update cycle.
final class ProcessMonitor {
    static let shared = ProcessMonitor()

    /// Cache entry: result + timestamp
    private struct CacheEntry {
        let state: SessionProcessState
        let checkedAt: Date
    }

    /// Directory path -> cached result
    private var cache: [String: CacheEntry] = [:]

    /// How long cache entries are valid (seconds)
    private let cacheTTL: TimeInterval = 2.0

    private let queue = DispatchQueue(label: "com.buzzbox.shellspace.processmonitor", qos: .utility)

    private init() {}

    /// Check if a `claude` process is running for the given directory.
    /// This is safe to call from the main thread -- shell execution happens synchronously
    /// but is fast (pgrep typically completes in <10ms).
    func isClaudeRunning(for directory: String) -> SessionProcessState {
        let normalizedDir = normalizePath(directory)

        // Check cache first
        if let cached = cache[normalizedDir],
           Date().timeIntervalSince(cached.checkedAt) < cacheTTL {
            return cached.state
        }

        let state = checkProcess(for: normalizedDir)
        cache[normalizedDir] = CacheEntry(state: state, checkedAt: Date())
        return state
    }

    /// Invalidate cached state for a directory (e.g., after launching a process)
    func invalidateCache(for directory: String) {
        let normalizedDir = normalizePath(directory)
        cache.removeValue(forKey: normalizedDir)
    }

    /// Clear entire cache
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    /// Normalize path by resolving symlinks for consistent matching
    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Run `pgrep -f` to check for claude processes matching this directory
    private func checkProcess(for directory: String) -> SessionProcessState {
        // Use pgrep to find any process whose command line contains "claude" and the directory path.
        // pgrep -f matches against the full command line.
        // We search for processes that have both "claude" and the directory in their args.
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "claude.*\(directory)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            // pgrep exit code 0 = found matches, 1 = no matches
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n")
                    .filter { !$0.isEmpty }

                if !pids.isEmpty {
                    logger.debug("Claude process found for \(directory): PIDs \(pids.joined(separator: ", "))")
                    return .running
                }
            }
        } catch {
            logger.error("Failed to run pgrep: \(error.localizedDescription)")
        }

        return .stopped
    }
}
