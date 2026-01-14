import Foundation
import os.log

class ActiveProjectsParser {
    private let logger = Logger(subsystem: "com.buzzbox.claudehub", category: "ActiveProjectsParser")

    /// Parse ACTIVE-PROJECTS.md and return active projects (excluding Complete/Billed)
    func parseActiveProjects(at projectPath: String) -> [ActiveProject] {
        let filePath = "\(projectPath)/ACTIVE-PROJECTS.md"

        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            logger.info("No ACTIVE-PROJECTS.md found at \(filePath)")
            return []
        }

        logger.info("Parsing ACTIVE-PROJECTS.md at \(filePath)")
        return parseProjects(from: content)
    }

    private func parseProjects(from content: String) -> [ActiveProject] {
        var projects: [ActiveProject] = []

        // Split by ## headings (project sections)
        let sections = content.components(separatedBy: "\n## ")

        for section in sections.dropFirst() {  // Skip header before first ##
            // Skip comment blocks (template examples)
            if section.hasPrefix("<!--") || section.contains("- **Stage:** Intake | Planning") {
                continue
            }

            guard let project = parseProjectSection(section) else { continue }

            // Only include active projects
            if project.isActive {
                projects.append(project)
                logger.info("Found active project: \(project.name) [\(project.stage.rawValue)]")
            } else {
                logger.info("Skipping completed project: \(project.name) [\(project.stage.rawValue)]")
            }
        }

        return projects
    }

    private func parseProjectSection(_ section: String) -> ActiveProject? {
        let lines = section.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }

        // Project name is the first line (after ##)
        let name = firstLine.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Parse metadata fields
        var stage: ActiveProject.ProjectStage = .intake
        var deadline: String?
        var nextAction: String?
        var timeLogged: String?
        var notes: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("- **Stage:**") {
                let value = extractValue(from: trimmed, prefix: "- **Stage:**")
                stage = parseStage(value)
            } else if trimmed.hasPrefix("- **Deadline:**") {
                deadline = extractValue(from: trimmed, prefix: "- **Deadline:**")
            } else if trimmed.hasPrefix("- **Next action:**") {
                nextAction = extractValue(from: trimmed, prefix: "- **Next action:**")
            } else if trimmed.hasPrefix("- **Time logged:**") {
                timeLogged = extractValue(from: trimmed, prefix: "- **Time logged:**")
            } else if trimmed.hasPrefix("- **Notes:**") {
                notes = extractValue(from: trimmed, prefix: "- **Notes:**")
            }
        }

        return ActiveProject(
            name: name,
            stage: stage,
            deadline: deadline,
            nextAction: nextAction,
            timeLogged: timeLogged,
            notes: notes
        )
    }

    private func extractValue(from line: String, prefix: String) -> String {
        let value = line.replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "" : value
    }

    private func parseStage(_ stageString: String) -> ActiveProject.ProjectStage {
        // Handle compound stages like "Planning → Design/Build" or "Design/Build → INFAB Review"
        // Take the last stage mentioned (rightmost after →)
        let components = stageString.components(separatedBy: "→")
        let lastStage = (components.last ?? stageString).trimmingCharacters(in: .whitespaces)

        // Try exact match first
        for stage in ActiveProject.ProjectStage.allCases {
            if lastStage.lowercased().contains(stage.rawValue.lowercased()) {
                return stage
            }
        }

        // Special case handling
        if lastStage.lowercased().contains("review") || lastStage.lowercased().contains("awaiting") {
            return .awaitingApproval
        }
        if lastStage.lowercased().contains("build") || lastStage.lowercased().contains("design") {
            return .designBuild
        }

        return .intake  // Default
    }
}
