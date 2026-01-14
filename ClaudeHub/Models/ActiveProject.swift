import Foundation

struct ActiveProject: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let stage: ProjectStage
    let deadline: String?
    let nextAction: String?
    let timeLogged: String?
    let notes: String?

    enum ProjectStage: String, CaseIterable {
        case intake = "Intake"
        case planning = "Planning"
        case designBuild = "Design/Build"
        case qa = "QA"
        case delivery = "Delivery"
        case awaitingApproval = "Awaiting Approval"
        case complete = "Complete"
        case billed = "Billed"

        var isActive: Bool {
            switch self {
            case .complete, .billed:
                return false
            default:
                return true
            }
        }
    }

    var isActive: Bool {
        stage.isActive
    }
}
