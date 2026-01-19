import Foundation

/// Service for logging billing entries to Google Sheets
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

    struct BillingResult: Codable {
        let success: Bool
        let spreadsheet_id: String?
        let url: String?
        let error: String?
        let logged: LoggedEntry?

        struct LoggedEntry: Codable {
            let date: String
            let client: String
            let project: String?
            let task: String
            let description: String
            let est_hours: Double
            let actual_hours: Double
            let status: String
        }
    }

    /// Log a billing entry to Google Sheets
    func logBilling(
        client: String,
        project: String?,
        task: String,
        description: String,
        estHours: Double,
        actualHours: Double,
        status: String = "billed"
    ) async throws -> BillingResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptPath,
            "log",
            "--workspace", client,
            "--project", project ?? "",
            "--task", task,
            "--description", description,
            "--est-hours", String(estHours),
            "--actual-hours", String(actualHours),
            "--status", status
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

                    if let result = try? JSONDecoder().decode(BillingResult.self, from: jsonData) {
                        continuation.resume(returning: result)
                    } else {
                        let output = String(data: jsonData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(returning: BillingResult(
                            success: false,
                            spreadsheet_id: nil,
                            url: nil,
                            error: output,
                            logged: nil
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Initialize the billing spreadsheet (creates if needed)
    func initSpreadsheet() async throws -> BillingResult {
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

                    if let result = try? JSONDecoder().decode(BillingResult.self, from: jsonData) {
                        continuation.resume(returning: result)
                    } else {
                        let output = String(data: jsonData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(returning: BillingResult(
                            success: false,
                            spreadsheet_id: nil,
                            url: nil,
                            error: output,
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
