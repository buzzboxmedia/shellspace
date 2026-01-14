import Foundation

class ParkerBriefingGenerator {

    /// Generate a Parker-style briefing for an active project
    func generateBriefing(for project: ActiveProject, clientName: String) -> String {
        var lines: [String] = []

        // Parker's greeting
        lines.append("Parker here. Here's where we are on \"\(project.name)\":")
        lines.append("")

        // Stage
        lines.append("  Stage: \(project.stage.rawValue)")

        // Deadline (if set)
        if let deadline = project.deadline, !deadline.isEmpty, deadline.lowercased() != "tbd" {
            lines.append("  Deadline: \(deadline)")
        }

        // Next action (key info)
        if let nextAction = project.nextAction, !nextAction.isEmpty {
            lines.append("  Next action: \(nextAction)")
        }

        // Notes (if helpful)
        if let notes = project.notes, !notes.isEmpty {
            lines.append("  Notes: \(notes)")
        }

        lines.append("")
        lines.append("Ready when you are.")

        return lines.joined(separator: "\n")
    }
}
