import Foundation
import Hummingbird
import NIOCore
import SwiftData

/// Embedded HTTP server for iOS companion app access over Tailscale.
/// Exposes projects, sessions, and terminal I/O on port 8847.
@MainActor
final class RemoteServer {
    static let port = 8847
    private var task: Task<Void, Never>?
    private weak var appState: AppState?
    private var modelContainer: ModelContainer?

    init() {}

    func start(appState: AppState, modelContainer: ModelContainer) {
        self.appState = appState
        self.modelContainer = modelContainer

        // Capture what we need for the detached task
        let server = self

        task = Task.detached {
            do {
                let router = await server.buildRouter()
                let app = Application(
                    router: router,
                    configuration: .init(address: .hostname("0.0.0.0", port: RemoteServer.port))
                )
                await MainActor.run {
                    DebugLog.log("[RemoteServer] Starting on port \(RemoteServer.port)")
                }
                try await app.runService()
            } catch {
                await MainActor.run {
                    DebugLog.log("[RemoteServer] Failed to start: \(error)")
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        DebugLog.log("[RemoteServer] Stopped")
    }

    // MARK: - Router

    private func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()

        let server = self

        // GET /api/status
        router.get("api/status") { _, _ -> Response in
            await server.handleStatus()
        }

        // GET /api/projects
        router.get("api/projects") { _, _ -> Response in
            await server.handleProjects()
        }

        // GET /api/projects/:id/sessions
        router.get("api/projects/{id}/sessions") { _, context -> Response in
            let id = context.parameters.get("id") ?? ""
            return await server.handleProjectSessions(projectId: id)
        }

        // GET /api/sessions/:id
        router.get("api/sessions/{id}") { _, context -> Response in
            let id = context.parameters.get("id") ?? ""
            return await server.handleSessionDetail(sessionId: id)
        }

        // GET /api/sessions/:id/terminal
        router.get("api/sessions/{id}/terminal") { _, context -> Response in
            let id = context.parameters.get("id") ?? ""
            return await server.handleTerminalContent(sessionId: id)
        }

        // POST /api/sessions/:id/input
        router.post("api/sessions/{id}/input") { request, context -> Response in
            let id = context.parameters.get("id") ?? ""
            let body = try await request.body.collect(upTo: 1024 * 64)
            return await server.handleTerminalInput(sessionId: id, body: body)
        }

        return router
    }

    // MARK: - Handlers

    private func handleStatus() -> Response {
        let controllers = appState?.terminalControllers ?? [:]
        let activeCount = controllers.values.filter { $0.terminalView?.process?.running == true }.count

        return jsonResponse([
            "status": "online",
            "version": "1.0.0",
            "app": "Shellspace",
            "active_sessions": activeCount,
            "total_controllers": controllers.count,
        ])
    }

    private func handleProjects() -> Response {
        guard let container = modelContainer else {
            return jsonResponse(["error": "No model container"], status: .internalServerError)
        }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
        guard let projects = try? context.fetch(descriptor) else {
            return jsonResponse(["error": "Failed to fetch projects"], status: .internalServerError)
        }

        let projectList: [[String: Any]] = projects.map { project in
            let activeSessions = project.sessions.filter { !$0.isCompleted && !$0.isHidden }
            let waitingSessions = activeSessions.filter { $0.isWaitingForInput }
            return [
                "id": project.id.uuidString,
                "name": project.name,
                "path": project.path,
                "icon": project.icon,
                "category": project.category.rawValue,
                "active_sessions": activeSessions.count,
                "waiting_sessions": waitingSessions.count,
            ]
        }

        return jsonResponse(["projects": projectList])
    }

    private func handleProjectSessions(projectId: String) -> Response {
        guard let container = modelContainer,
              let uuid = UUID(uuidString: projectId) else {
            return jsonResponse(["error": "Invalid project ID"], status: .badRequest)
        }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Project>()
        guard let projects = try? context.fetch(descriptor),
              let project = projects.first(where: { $0.id == uuid }) else {
            return jsonResponse(["error": "Project not found"], status: .notFound)
        }

        let sessionList: [[String: Any]] = project.sessions
            .filter { !$0.isHidden }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
            .map { sessionToJSON($0) }

        return jsonResponse(["sessions": sessionList])
    }

    private func handleSessionDetail(sessionId: String) -> Response {
        guard let session = findSession(sessionId) else {
            return jsonResponse(["error": "Session not found"], status: .notFound)
        }

        return jsonResponse(sessionToJSON(session))
    }

    private func handleTerminalContent(sessionId: String) -> Response {
        guard let uuid = UUID(uuidString: sessionId) else {
            return jsonResponse(["error": "Invalid session ID"], status: .badRequest)
        }

        let content = appState?.terminalControllers[uuid]?.getFullTerminalContent() ?? ""
        let isRunning = appState?.terminalControllers[uuid]?.terminalView?.process?.running == true

        return jsonResponse([
            "session_id": sessionId,
            "content": content,
            "is_running": isRunning,
        ])
    }

    private func handleTerminalInput(sessionId: String, body: ByteBuffer) -> Response {
        guard let uuid = UUID(uuidString: sessionId) else {
            return jsonResponse(["error": "Invalid session ID"], status: .badRequest)
        }

        guard let controller = appState?.terminalControllers[uuid] else {
            return jsonResponse(["error": "No terminal for this session"], status: .notFound)
        }

        guard let data = body.getData(at: body.readerIndex, length: body.readableBytes),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String else {
            return jsonResponse(["error": "Missing 'message' in body"], status: .badRequest)
        }

        controller.sendToTerminal(message + "\n")

        DebugLog.log("[RemoteServer] Sent input to session \(sessionId): \(message.prefix(50))")

        return jsonResponse(["status": "sent", "session_id": sessionId])
    }

    // MARK: - Helpers

    private func findSession(_ sessionId: String) -> Session? {
        guard let container = modelContainer,
              let uuid = UUID(uuidString: sessionId) else { return nil }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? context.fetch(descriptor) else { return nil }
        return sessions.first { $0.id == uuid }
    }

    private func sessionToJSON(_ session: Session) -> [String: Any] {
        let isRunning = appState?.terminalControllers[session.id]?.terminalView?.process?.running == true
        var json: [String: Any] = [
            "id": session.id.uuidString,
            "name": session.name,
            "project_path": session.projectPath,
            "created_at": ISO8601DateFormatter().string(from: session.createdAt),
            "last_accessed_at": ISO8601DateFormatter().string(from: session.lastAccessedAt),
            "is_completed": session.isCompleted,
            "is_hidden": session.isHidden,
            "is_waiting_for_input": session.isWaitingForInput,
            "has_been_launched": session.hasBeenLaunched,
            "is_running": isRunning,
        ]
        if let summary = session.lastSessionSummary { json["summary"] = summary }
        if let taskFolder = session.taskFolderPath { json["task_folder_path"] = taskFolder }
        if let briefing = session.parkerBriefing { json["parker_briefing"] = briefing }
        return json
    }

    private func jsonResponse(_ dict: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
        var response = Response(status: status)
        response.headers[.contentType] = "application/json"
        response.body = .init(byteBuffer: ByteBuffer(bytes: data))
        return response
    }
}
