import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import SwiftData
import WSCore

/// Embedded HTTP + WebSocket server for iOS companion app access over Tailscale or local network.
/// Exposes projects, sessions, and terminal I/O on port 8847.
/// Advertises via Bonjour (_shellspace._tcp) for auto-discovery by the iOS companion app.
final class RemoteServer: @unchecked Sendable {
    static let port = 8847
    private var task: Task<Void, Never>?
    private weak var appState: AppState?
    private var modelContainer: ModelContainer?

    /// Sessions currently being auto-launched (prevents double-send from WS fast path)
    @MainActor private var autoLaunchingSessionIds: Set<UUID> = []

    // Bonjour advertisement (NetService is deprecated but is the only way to advertise
    // a service on a port already bound by another server without port conflicts)
    @available(macOS, deprecated: 13.0)
    private var bonjourService: NetService?

    init() {}

    @MainActor
    func start(appState: AppState, modelContainer: ModelContainer) {
        self.appState = appState
        self.modelContainer = modelContainer

        let server = self

        task = Task.detached {
            do {
                let router = server.buildRouter()
                let wsRouter = server.buildWebSocketRouter()
                let app = Application(
                    router: router,
                    server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
                    configuration: .init(address: .hostname("0.0.0.0", port: RemoteServer.port))
                )
                await MainActor.run {
                    DebugLog.log("[RemoteServer] Starting on port \(RemoteServer.port) (HTTP + WebSocket)")
                    server.startBonjourAdvertising()
                }
                try await app.runService()
            } catch {
                await MainActor.run {
                    DebugLog.log("[RemoteServer] Failed to start: \(error)")
                }
            }
        }
    }

    @MainActor
    func stop() {
        stopBonjourAdvertising()
        task?.cancel()
        task = nil
        DebugLog.log("[RemoteServer] Stopped")
    }

    // MARK: - Bonjour Advertising

    @MainActor
    private func startBonjourAdvertising() {
        let name = Host.current().localizedName ?? "Shellspace"
        let service = NetService(
            domain: "",
            type: "_shellspace._tcp.",
            name: name,
            port: Int32(RemoteServer.port)
        )
        service.publish()
        bonjourService = service
        DebugLog.log("[RemoteServer] Bonjour: advertising '\(name)' as _shellspace._tcp on port \(RemoteServer.port)")
    }

    @MainActor
    private func stopBonjourAdvertising() {
        bonjourService?.stop()
        bonjourService = nil
        DebugLog.log("[RemoteServer] Bonjour: stopped advertising")
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
            return server.handleProjectTasks(projectId: id)
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

        router.post("api/sessions") { request, _ -> Response in
            let body = try await request.body.collect(upTo: 1024 * 64)
            return await server.handleCreateSession(body: body)
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

        await MainActor.run { DebugLog.log("[RemoteServer] WS connected: terminal \(sessionId)") }

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
        let inputTask = Task { [weak self] in
            for try await frame in inbound {
                if case .text = frame.opcode,
                   let text = frame.data.getString(at: frame.data.readerIndex, length: frame.data.readableBytes),
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String, type == "input",
                   let message = json["message"] as? String {
                    guard let self else { continue }
                    await MainActor.run {
                        DebugLog.log("[RemoteServer] WS input received: \(message.prefix(50))")
                    }

                    // Skip if this session is currently being auto-launched (prevents double-send)
                    let isAutoLaunching = await MainActor.run { self.autoLaunchingSessionIds.contains(uuid) }
                    if isAutoLaunching {
                        await MainActor.run { DebugLog.log("[RemoteServer] WS skipping (auto-launch in progress): \(sessionId)") }
                        continue
                    }

                    // Try fast path: controller exists and process is running
                    let sent = await MainActor.run {
                        if let controller = self.appState?.terminalControllers[uuid],
                           controller.terminalView?.process?.running == true {
                            controller.sendToTerminal(message)
                            DebugLog.log("[RemoteServer] WS sent to running session \(sessionId)")
                            return true
                        }
                        return false
                    }
                    if !sent {
                        await MainActor.run {
                            self.autoLaunchingSessionIds.insert(uuid)
                            DebugLog.log("[RemoteServer] WS session not running, auto-launching \(sessionId)")
                        }
                        await self.autoLaunchAndSend(uuid: uuid, sessionId: sessionId, message: message)
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
        await MainActor.run { DebugLog.log("[RemoteServer] WS closed: terminal \(sessionId)") }
    }

    private func sendTerminalUpdate(
        uuid: UUID, sessionId: String, outbound: WebSocketOutboundWriter,
        lastContentHash: inout Int, lastIsRunning: inout Bool, lastIsWaiting: inout Bool,
        force: Bool
    ) async throws {
        let (content, isRunning, isWaiting) = await MainActor.run {
            var c = appState?.terminalControllers[uuid]?.getFullTerminalContent() ?? ""
            let running = appState?.terminalControllers[uuid]?.terminalView?.process?.running == true
            let waiting = findSession(sessionId)?.isWaitingForInput ?? false

            // Fall back to log file when live buffer is empty
            if c.isEmpty {
                let logPath = Session.centralLogsDir.appendingPathComponent("\(sessionId).log")
                if let logContent = try? String(contentsOf: logPath, encoding: .utf8) {
                    c = logContent
                }
            }

            return (c, running, waiting)
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
        await MainActor.run { DebugLog.log("[RemoteServer] WS connected: sessions stream") }

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
        await MainActor.run { DebugLog.log("[RemoteServer] WS closed: sessions stream") }
    }

    private func sendSessionsSnapshot(
        outbound: WebSocketOutboundWriter,
        lastStates: inout [String: (isRunning: Bool, isWaiting: Bool)],
        force: Bool
    ) async throws {
        let sessionDicts: [[String: Any]]? = await MainActor.run {
            guard let container = modelContainer else { return nil }

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Session>()
            guard let allSessions = try? context.fetch(descriptor) else { return nil }
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
                guard changed else { return nil }
            }

            lastStates = [:]
            for session in sessions {
                let isRunning = appState?.terminalControllers[session.id]?.terminalView?.process?.running == true
                lastStates[session.id.uuidString] = (isRunning, session.isWaitingForInput)
            }

            return sessions.map { sessionToJSON($0) }
        }

        guard let sessionDicts else { return }

        let message: [String: Any] = ["type": "sessions_update", "sessions": sessionDicts]

        if let data = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: data, encoding: .utf8) {
            try await outbound.write(.text(jsonString))
        }
    }

    // MARK: - REST Handlers

    private func handleStatus() async -> Response {
        let (activeCount, totalCount) = await MainActor.run {
            let controllers = appState?.terminalControllers ?? [:]
            let active = controllers.values.filter { $0.terminalView?.process?.running == true }.count
            return (active, controllers.count)
        }

        return jsonResponse([
            "status": "online",
            "version": "1.0.0",
            "app": "Shellspace",
            "active_sessions": activeCount,
            "total_controllers": totalCount,
        ])
    }

    private func handleProjects() async -> Response {
        let projectList: [[String: Any]]? = await MainActor.run {
            guard let container = modelContainer else { return nil }

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
            guard let projects = try? context.fetch(descriptor) else { return nil }

            return projects.map { project in
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
                ] as [String: Any]
            }
        }

        guard let projectList else {
            return jsonResponse(["error": "Failed to fetch projects"], status: .internalServerError)
        }
        return jsonResponse(["projects": projectList])
    }

    private func handleProjectSessions(projectId: String) async -> Response {
        let sessionList: [[String: Any]]? = await MainActor.run {
            guard let container = modelContainer,
                  let uuid = UUID(uuidString: projectId) else { return nil }

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Project>()
            guard let projects = try? context.fetch(descriptor),
                  let project = projects.first(where: { $0.id == uuid }) else { return nil }

            return project.sessions
                .filter { !$0.isHidden }
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .map { sessionToJSON($0) }
        }

        guard let sessionList else {
            return jsonResponse(["error": "Project not found"], status: .notFound)
        }
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

    private func handleSessionDetail(sessionId: String) async -> Response {
        let json: [String: Any]? = await MainActor.run {
            guard let session = findSession(sessionId) else { return nil }
            return sessionToJSON(session)
        }

        guard let json else {
            return jsonResponse(["error": "Session not found"], status: .notFound)
        }
        return jsonResponse(json)
    }

    private func handleTerminalContent(sessionId: String) async -> Response {
        guard let uuid = UUID(uuidString: sessionId) else {
            return jsonResponse(["error": "Invalid session ID"], status: .badRequest)
        }

        let (content, isRunning) = await MainActor.run {
            var c = appState?.terminalControllers[uuid]?.getFullTerminalContent() ?? ""
            let running = appState?.terminalControllers[uuid]?.terminalView?.process?.running == true

            // Fall back to log file when live buffer is empty
            if c.isEmpty {
                let logPath = Session.centralLogsDir.appendingPathComponent("\(sessionId).log")
                if let logContent = try? String(contentsOf: logPath, encoding: .utf8) {
                    c = logContent
                }
            }

            return (c, running)
        }

        return jsonResponse([
            "session_id": sessionId,
            "content": content,
            "is_running": isRunning,
        ])
    }

    private func handleCreateSession(body: ByteBuffer) async -> Response {
        guard let container = modelContainer else {
            return jsonResponse(["error": "No model container"], status: .internalServerError)
        }

        guard let data = body.getData(at: body.readerIndex, length: body.readableBytes),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projectId = json["projectId"] as? String,
              let name = json["name"] as? String, !name.isEmpty else {
            return jsonResponse(["error": "Missing projectId or name"], status: .badRequest)
        }

        let description = json["description"] as? String

        guard let projectUUID = UUID(uuidString: projectId) else {
            return jsonResponse(["error": "Invalid project ID"], status: .badRequest)
        }

        // All SwiftData + TaskFolder work on main thread
        let result: [String: Any]? = await MainActor.run {
            let mainContext = container.mainContext
            let descriptor = FetchDescriptor<Project>()
            guard let projects = try? mainContext.fetch(descriptor),
                  let project = projects.first(where: { $0.id == projectUUID }) else {
                return nil
            }

            // Create task folder via TaskFolderService
            guard let taskFolderURL = try? TaskFolderService.shared.createTask(
                projectPath: project.path,
                projectName: project.name,
                subProjectName: nil,
                taskName: name,
                description: description
            ) else {
                return nil
            }

            // Create a new session linked to the task folder
            let session = Session(
                name: name,
                projectPath: project.path,
                createdAt: Date(),
                userNamed: true,
                activeProjectName: project.name,
                parkerBriefing: nil
            )
            session.taskFolderPath = taskFolderURL.path
            project.sessions.append(session)
            try? mainContext.save()

            return [
                "id": session.id.uuidString,
                "name": session.name,
                "project_path": session.projectPath,
                "created_at": ISO8601DateFormatter().string(from: session.createdAt),
                "last_accessed_at": ISO8601DateFormatter().string(from: session.lastAccessedAt),
                "is_completed": false,
                "is_hidden": false,
                "is_waiting_for_input": false,
                "has_been_launched": false,
                "is_running": false,
                "task_folder_path": taskFolderURL.path,
            ] as [String: Any]
        }

        guard let result else {
            return jsonResponse(["error": "Failed to create session"], status: .internalServerError)
        }

        await MainActor.run { DebugLog.log("[RemoteServer] Created session: \(result["id"] ?? "") for task: \(name)") }
        return jsonResponse(["session": result])
    }

    private func handleTerminalInput(sessionId: String, body: ByteBuffer) async -> Response {
        guard let uuid = UUID(uuidString: sessionId) else {
            return jsonResponse(["error": "Invalid session ID"], status: .badRequest)
        }

        // Parse body first (fail fast)
        guard let data = body.getData(at: body.readerIndex, length: body.readableBytes),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String else {
            return jsonResponse(["error": "Missing 'message' in body"], status: .badRequest)
        }

        // Fast path: controller exists and process is running
        let sent = await MainActor.run {
            if let controller = appState?.terminalControllers[uuid],
               controller.terminalView?.process?.running == true {
                controller.sendToTerminal(message)
                DebugLog.log("[RemoteServer] Sent input to session \(sessionId): \(message.prefix(50))")
                return true
            }
            return false
        }

        if sent {
            return jsonResponse(["status": "sent", "session_id": sessionId])
        }

        // Auto-launch: no controller or process not running
        await autoLaunchAndSend(uuid: uuid, sessionId: sessionId, message: message)
        return jsonResponse(["status": "launched_and_sent", "session_id": sessionId])
    }

    // MARK: - Auto-launch

    /// Auto-launch a stopped session and send input. Shared by REST and WebSocket handlers.
    private func autoLaunchAndSend(uuid: UUID, sessionId: String, message: String) async {
        guard let container = modelContainer, let appState = appState else {
            await MainActor.run { DebugLog.log("[RemoteServer] Auto-launch failed: no container/appState") }
            return
        }

        let controller = await MainActor.run {
            let mainContext = container.mainContext
            let descriptor = FetchDescriptor<Session>()
            guard let sessions = try? mainContext.fetch(descriptor),
                  let session = sessions.first(where: { $0.id == uuid }) else {
                return nil as TerminalController?
            }

            let ctrl = appState.getOrCreateController(for: session)

            ctrl.startClaude(
                in: session.projectPath,
                sessionId: session.id,
                claudeSessionId: session.claudeSessionId,
                parkerBriefing: session.parkerBriefing,
                taskFolderPath: session.taskFolderPath,
                hasBeenLaunched: session.hasBeenLaunched
            )

            if let terminal = ctrl.terminalView {
                terminal.frame = NSRect(x: 0, y: 0, width: 960, height: 480)
                terminal.getTerminal().resize(cols: 120, rows: 40)
            }

            session.hasBeenLaunched = true
            try? mainContext.save()

            return ctrl
        }

        guard let controller else {
            await MainActor.run { DebugLog.log("[RemoteServer] Auto-launch failed: session not found \(sessionId)") }
            return
        }

        // Wait for buffer to stabilize (previous session content finishes loading)
        var lastLength = 0
        var stableCount = 0
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(300))
            let currentLength = await MainActor.run { controller.getFullTerminalContent().count }
            if currentLength == lastLength && currentLength > 0 {
                stableCount += 1
                if stableCount >= 2 { break } // 2 stable checks = 600ms stable
            } else {
                stableCount = 0
            }
            lastLength = currentLength
        }
        let stableLength = lastLength
        await MainActor.run { DebugLog.log("[RemoteServer] Buffer stabilized at \(stableLength) chars for session \(sessionId)") }

        // Wait for ANY new content beyond the stabilized buffer (Claude has started)
        for _ in 0..<30 { // Up to 15 seconds
            try? await Task.sleep(for: .milliseconds(500))
            let content = await MainActor.run { controller.getFullTerminalContent() }
            if content.count > stableLength + 10 {
                await MainActor.run { DebugLog.log("[RemoteServer] New content detected for session \(sessionId), waiting for render...") }
                break
            }
        }

        // Brief pause to let Claude finish rendering its prompt
        try? await Task.sleep(for: .seconds(1))

        // Check if someone else already sent this message while we were waiting
        let alreadyHandled = await MainActor.run { autoLaunchingSessionIds.contains(uuid) == false }
        if alreadyHandled {
            await MainActor.run { DebugLog.log("[RemoteServer] Auto-launch cancelled (session already handled): \(sessionId)") }
            return
        }

        await MainActor.run {
            controller.sendToTerminal(message)
            DebugLog.log("[RemoteServer] Auto-launched and sent input to session \(sessionId): \(message.prefix(50))")
        }

        // Keep the lock active briefly so queued WS frames don't double-send
        try? await Task.sleep(for: .seconds(2))
        await MainActor.run { autoLaunchingSessionIds.remove(uuid) }
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

    @MainActor
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
