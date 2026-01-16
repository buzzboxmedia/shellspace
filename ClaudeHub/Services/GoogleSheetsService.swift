import Foundation

/// Service for syncing tasks to Google Sheets via Python script
class GoogleSheetsService {
    static let shared = GoogleSheetsService()

    private let scriptPath: String

    private init() {
        // Find the script relative to the executable or in common locations
        let possiblePaths = [
            Bundle.main.bundlePath + "/../scripts/sheets_sync.py",
            NSHomeDirectory() + "/Code/claudehub/scripts/sheets_sync.py",
            "/Users/baronmiller/Code/claudehub/scripts/sheets_sync.py"
        ]

        scriptPath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) }
            ?? possiblePaths.last!
    }

    struct LogResult: Codable {
        let success: Bool
        let spreadsheet_id: String?
        let url: String?
        let error: String?
        let needs_auth: Bool?
        let logged: LoggedTask?

        struct LoggedTask: Codable {
            let date: String
            let time: String
            let project: String
            let task: String
            let status: String
        }
    }

    /// Log a task to Google Sheets
    func logTask(
        project: String,
        task: String,
        status: String = "completed",
        notes: String
    ) async throws -> LogResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptPath,
            "log",
            "--project", project,
            "--task", task,
            "--status", status,
            "--notes", notes
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    // Try to parse stdout first, then stderr
                    let jsonData = outputData.isEmpty ? errorData : outputData

                    if let result = try? JSONDecoder().decode(LogResult.self, from: jsonData) {
                        continuation.resume(returning: result)
                    } else {
                        let output = String(data: jsonData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(returning: LogResult(
                            success: false,
                            spreadsheet_id: nil,
                            url: nil,
                            error: output,
                            needs_auth: nil,
                            logged: nil
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Check if authentication is set up
    func checkAuth() async -> Bool {
        let tokenPath = NSHomeDirectory() + "/.claudehub/sheets_token.json"
        return FileManager.default.fileExists(atPath: tokenPath)
    }

    /// Initialize the spreadsheet (creates if needed)
    func initSpreadsheet() async throws -> LogResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptPath, "init"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    let jsonData = outputData.isEmpty ? errorData : outputData

                    if let result = try? JSONDecoder().decode(LogResult.self, from: jsonData) {
                        continuation.resume(returning: result)
                    } else {
                        let output = String(data: jsonData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(returning: LogResult(
                            success: false,
                            spreadsheet_id: nil,
                            url: nil,
                            error: output,
                            needs_auth: nil,
                            logged: nil
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run the OAuth authorization flow (opens browser)
    func runAuthFlow() async throws -> LogResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptPath, "auth"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    let jsonData = outputData.isEmpty ? errorData : outputData

                    if let result = try? JSONDecoder().decode(LogResult.self, from: jsonData) {
                        continuation.resume(returning: result)
                    } else {
                        let output = String(data: jsonData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(returning: LogResult(
                            success: false,
                            spreadsheet_id: nil,
                            url: nil,
                            error: output,
                            needs_auth: nil,
                            logged: nil
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
