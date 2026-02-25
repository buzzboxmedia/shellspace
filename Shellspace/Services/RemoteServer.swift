import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import SwiftData
import WSCore

/// Embedded HTTP + WebSocket server for iOS companion app access over Tailscale.
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

        let server = self

        task = Task.detached {
            do {
                let router = await server.buildRouter()
                let wsRouter = await server.buildWebSocketRouter()
                let app = Application(
                    router: router,
                    server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
                    configuration: .init(address: .hostname("0.0.0.0", port: RemoteServer.port))
                )
                await MainActor.run {
                    DebugLog.log("[RemoteServer] Starting on port \(RemoteServer.port) (HTTP + WebSocket)")
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

    // MARK: - HTTP Router

    private func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()
        let server = self

        router.get("api/status") { _, _ -> Response in
            await server.handleStatus()
        }

        router.get("api/projects") { _, _ -> Response in
            await server.handleProjects()
        }

        router.get("api/projects/{id}/sessions") { _, context -> Response in
            let id = context.parameters.get("id") ?? ""
            return await server.handleProjectSessions(projectId: id)
        }

        router.get("api/projects/{id}/tasks") { _, context -> Response in
            let id = context.parameters.get("id") ?? ""
            return await server.handleProjectTasks(projectId: id)
        }

        router.get("api/sessions/{id}") { _, context -> Response in
            let id = context.parameters.get("id") ?? ""
            return await server.handleSessionDetail(sessionId: id)
        }

        router.get("api/sessions/{id}/terminal") { _, context -> Response in
            let id = context.parameters.get("id") ?? ""
            return await server.handleTerminalContent(sessionId: id)
        }

        router.post("api/sessions/{id}/input") { request, context -> Response in
            let id = context.parameters.get("id") ?? ""
            let body = try await request.body.collect(upTo: 1024 * 64)
            return await server.handleTerminalInput(sessionId: id, body: body)
        }

        return router
    }

    // MARK: - WebSocket Router

    private func buildWebSocketRouter() -> Router<BasicWebSocketRequestContext> {
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        let server = self

        // Terminal content stream for a specific session
        wsRouter.ws("ws/terminal/{sessionId}") { _, context in
            guard let sessionId = context.parameters.get("sessionId"),
                  let _ = UUID(uuidString: sessionId) else {
                return .dontUpgrade
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            let sessionId = context.requestContext.parameters.get("sessionId") ?? ""
            await server.handleTerminalWebSocket(sessionId: sessionId, inbound: inbound, outbound: outbound)
        }

        // Session state stream (waiting/running changes)
        wsRouter.ws("ws/sessions") { _, _ in
            .upgrade([:])
        } onUpgrade: { inbound, outbound, _ in
            await server.handleSessionsWebSocket(inbound: inbound, outbound: outbound)
        }

        return wsRouter
    }

    // MARK: - WebSocket Handlers

    private func handleTerminalWebSocket(
        sessionId: String,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard let uuid = UUID(uuidString: sessionId) else { return }

        DebugLog.log("[RemoteServer] WS connected: terminal \(sessionId)")

        var lastContentHash: Int = 0
        var lastIsRunning = false
        var lastIsWaiting = false

        // Send initial content immediately
        do {
            try await sendTerminalUpdate(
                uuid: uuid, sessionId: sessionId, outbound: outbound,
                lastContentHash: &lastContentHash, lastIsRunning: &lastIsRunning,
                lastIsWaiting: &lastIsWaiting, force: true
            )
        } catch { return }

        // Consume inbound messages (keeps connection alive, handles input)
        let inputTask = Task {
            for try await frame in inbound {
                if case .text = frame.opcode,
                   let text = frame.data.getString(at: frame.data.readerIndex, length: frame.data.readableBytes),
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String, type == "input",
                   let message = json["message"] as? String {
                    await MainActor.run {
                        self.appState?.terminalControllers[uuid]?.sendToTerminal(message + "\r")
                    }
                }
            }
        }

        // Poll terminal buffer every 500ms, send when content changes
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { break }
            do {
                try await sendTerminalUpdate(
                    uuid: uuid, sessionId: sessionId, outbound: outbound,
                    lastContentHash: &lastContentHash, lastIsRunning: &lastIsRunning,
                    lastIsWaiting: &lastIsWaiting, force: false
                )
            } catch { break }
        }

        inputTask.cancel()
        DebugLog.log("[RemoteServer] WS closed: terminal \(sessionId)")
    }

    private func sendTerminalUpdate(
        uuid: UUID, sessionId: String, outbound: WebSocketOutboundWriter,
        lastContentHash: inout Int, lastIsRunning: inout Bool, lastIsWaiting: inout Bool,
        force: Bool
    ) async throws {
        var content = appState?.terminalControllers[uuid]?.getFullTerminalContent() ?? ""
        let isRunning = appState?.terminalControllers[uuid]?.terminalView?.process?.running == true
        let isWaiting = findSession(sessionId)?.isWaitingForInput ?? false

        // Fall back to log file when live buffer is empty
        if content.isEmpty {
            let logPath = Session.centralLogsDir.appendingPathComponent("\(sessionId).log")
            if let logContent = try? String(contentsOf: logPath, encoding: .utf8) {
                content = logContent
            }
        }

        let contentHash = content.hashValue
        guard force || contentHash != lastContentHash || isRunning != lastIsRunning || isWaiting != lastIsWaiting else { return }

        lastContentHash = contentHash
        lastIsRunning = isRunning
        lastIsWaiting = isWaiting

        let message: [String: Any] = [
            "type": "terminal_update",
            "session_id": sessionId,
            "content": content,
            "is_running": isRunning,
            "is_waiting_for_input": isWaiting,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: data, encoding: .utf8) {
            try await outbound.write(.text(jsonString))
        }
    }

    private func handleSessionsWebSocket(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        DebugLog.log("[RemoteServer] WS connected: sessions stream")

        var lastStates: [String: (isRunning: Bool, isWaiting: Bool)] = [:]

        do {
            try await sendSessionsSnapshot(outbound: outbound, lastStates: &lastStates, force: true)
        } catch { return }

        let consumeTask = Task { for try await _ in inbound {} }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { break }
            do {
                try await sendSessionsSnapshot(outbound: outbound, lastStates: &lastStates, force: false)
            } catch { break }
        }

        consumeTask.cancel()
        DebugLog.log("[RemoteServer] WS closed: sessions stream")
    }

    private func sendSessionsSnapshot(
        outbound: WebSocketOutboundWriter,
        lastStates: inout [String: (isRunning: Bool, isWaiting: Bool)],
        force: Bool
    ) async throws {
        guard let container = modelContainer else { return }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Session>()
        guard let allSessions = try? context.fetch(descriptor) else { return }
        let sessions = allSessions.filter { !$0.isHidden }

        if !force {
            var changed = lastStates.count != sessions.count
            if !changed {
                for session in sessions {
                    let id = session.id.uuidString
                    let isRunning = appState?.terminalControllers[session.id]?.terminalView?.process?.running == true
                    if let old = lastStates[id] {
                        if old.isRunning != isRunning || old.isWaiting != session.isWaitingForInput {
                            changed = true; break
                        }
                    } else { changed = true; break }
                }
            }
            guard changed else { return }
        }

        lastStates = [:]
        for session in sessions {
            let isRunning = appState?.terminalControllers[session.id]?.terminalView?.process?.running == true
            lastStates[session.id.uuidString] = (isRunning, session.isWaitingForInput)
        }

        let sessionDicts = sessions.map { sessionToJSON($0) }
        let message: [String: Any] = ["type": "sessions_update", "sessions": sessionDicts]

        if let data = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: data, encoding: .utf8) {
            try await outbound.write(.text(jsonString))
        }
    }

    // MARK: - REST Handlers

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

    private func handleProjectTasks(projectId: String) -> Response {
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

        let tasks = TaskFolderService.shared.listAllTasks(for: project.path)
        let taskList: [[String: Any]] = tasks.map { task in
            var dict: [String: Any] = ["path": task.folderPath]
            if let title = task.title { dict["title"] = title }
            if let status = task.status { dict["status"] = status }
            if let created = task.created { dict["created"] = created }
            if let description = task.description { dict["description"] = description }
            return dict
        }

        return jsonResponse(["tasks": taskList])
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

        var content = appState?.terminalControllers[uuid]?.getFullTerminalContent() ?? ""
        let isRunning = appState?.terminalControllers[uuid]?.terminalView?.process?.running == true

        // Fall back to log file when live buffer is empty
        if content.isEmpty {
            let logPath = Session.centralLogsDir.appendingPathComponent("\(sessionId).log")
            if let logContent = try? String(contentsOf: logPath, encoding: .utf8) {
                content = logContent
            }
        }

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

        controller.sendToTerminal(message + "\r")
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
