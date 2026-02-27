import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LauncherView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState

    // Fetch all projects, sorted by name
    @Query(sort: \Project.name) private var allProjects: [Project]
    @Query private var allSessions: [Session]

    @State private var showSettings = false
    @State private var showCleanup = false
    @State private var showAddProject = false
    @State private var draggedProject: Project?

    /// Sessions that are waiting for user input (idle Claude processes)
    private var waitingSessions: [Session] {
        allSessions.filter { $0.isWaitingForInput && !$0.isHidden && !$0.isCompleted }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    /// Sessions with running processes that are NOT waiting for input (actively working)
    private var runningSessions: [Session] {
        let waitingIds = Set(waitingSessions.map { $0.id })
        return allSessions.filter { session in
            !session.isHidden && !session.isCompleted
            && appState.terminalControllers[session.id]?.terminalView?.process?.running == true
            && !waitingIds.contains(session.id)
        }.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    // Persisted order for dashboard
    @AppStorage("dashboardOrder") private var orderData: Data = Data()

    private var savedOrder: [String] {
        (try? JSONDecoder().decode([String].self, from: orderData)) ?? []
    }

    private func saveOrder(_ paths: [String]) {
        if let data = try? JSONEncoder().encode(paths) {
            orderData = data
        }
        ProjectSyncService.shared.exportProjects(from: modelContext)
    }

    // All projects sorted by persisted order
    var displayProjects: [Project] {
        let order = savedOrder
        guard !order.isEmpty else { return allProjects.map { $0 } }
        return allProjects.sorted { a, b in
            let indexA = order.firstIndex(of: a.path) ?? Int.max
            let indexB = order.firstIndex(of: b.path) ?? Int.max
            return indexA < indexB
        }
    }

    // Adaptive grid that responds to window width
    private let gridColumns = [
        GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 16)
    ]

    var body: some View {
        ZStack {
            // Glass background
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 40) {
                    // Header with settings button and running sessions indicator
                    HStack {
                        Spacer()
                        Text("Shellspace")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .overlay(alignment: .leading) {
                        // Show running sessions indicator
                        if !appState.terminalControllers.isEmpty {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 8, height: 8)
                                Text("\(appState.terminalControllers.count) running")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.leading, 8)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 12) {
                            Button {
                                showCleanup = true
                            } label: {
                                Image(systemName: "tray.full.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Manage Sessions")

                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                                SettingsView()
                                    .environmentObject(appState)
                            }
                        }
                        .padding(.trailing, 8)
                    }

                    // MARK: - Inbox (Sessions Waiting for Input)
                    if !waitingSessions.isEmpty {
                        InboxSection(sessions: waitingSessions)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: - Active Sessions (Running but not waiting)
                    if !runningSessions.isEmpty {
                        ActiveSessionsSection(sessions: runningSessions)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    VStack(spacing: 36) {
                        // All projects in a single grid
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Spacer()

                                Button {
                                    showAddProject = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 14, weight: .medium))
                                        Text("Add")
                                            .font(.system(size: 14, weight: .medium))
                                    }
                                    .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }

                            if displayProjects.isEmpty {
                                Text("No projects yet. Click Add to get started.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 20)
                            } else {
                                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                                    ForEach(displayProjects) { project in
                                        ProjectCard(project: project)
                                            .onDrag {
                                                draggedProject = project
                                                return NSItemProvider(object: project.path as NSString)
                                            }
                                            .onDrop(of: [.text], delegate: DashboardDropDelegate(
                                                targetProject: project,
                                                allProjects: displayProjects,
                                                draggedProject: $draggedProject,
                                                saveOrder: saveOrder
                                            ))
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(48)
            }
        }
        .sheet(isPresented: $showCleanup) {
            SessionCleanupView()
        }
        .sheet(isPresented: $showAddProject) {
            AddProjectSheet()
        }
    }
}

// MARK: - Dashboard Drop Delegate

struct DashboardDropDelegate: DropDelegate {
    let targetProject: Project
    let allProjects: [Project]
    @Binding var draggedProject: Project?
    let saveOrder: ([String]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedProject = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedProject,
              dragged.path != targetProject.path,
              let fromIndex = allProjects.firstIndex(where: { $0.path == dragged.path }),
              let toIndex = allProjects.firstIndex(where: { $0.path == targetProject.path }) else {
            return
        }

        var paths = allProjects.map { $0.path }
        let movedPath = paths.remove(at: fromIndex)
        paths.insert(movedPath, at: toIndex)

        withAnimation(.easeInOut(duration: 0.2)) {
            saveOrder(paths)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Project Card

struct ProjectCard: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var showEditProject = false

    /// Count of sessions with active terminal controllers (running in background)
    var runningCount: Int {
        project.sessions.filter { appState.terminalControllers[$0.id] != nil }.count
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: project.icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.primary)

                // Show blue dot for running sessions
                if runningCount > 0 {
                    Circle()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: 10, height: 10)
                        .offset(x: 5, y: -5)
                }
            }

            Text(project.name)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(width: 120, height: 120)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 16 : 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            // Delete button on hover
            if isHovered {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.ultraThinMaterial).frame(width: 20, height: 20))
                }
                .buttonStyle(.plain)
                .offset(x: -4, y: 4)
                .transition(.opacity)
            }
        }
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3)) {
                windowState.selectedProject = project
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("Open") {
                withAnimation(.spring(response: 0.3)) {
                    windowState.selectedProject = project
                }
            }

            Button("Edit Project...") {
                showEditProject = true
            }

            Divider()

            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
            }

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }

            Divider()

            Button("Remove...", role: .destructive) {
                showDeleteConfirm = true
            }
        }
        .sheet(isPresented: $showEditProject) {
            ProjectSheet(editing: project)
        }
        .alert("Remove \(project.name)?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                modelContext.delete(project)
                ProjectSyncService.shared.exportProjects(from: modelContext)
            }
        } message: {
            Text("This removes it from Shellspace. Your files on disk are not affected.")
        }
    }

}

// MARK: - Active Sessions Section

struct ActiveSessionsSection: View {
    @EnvironmentObject var appState: AppState
    let sessions: [Session]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("Running")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.92, green: 0.93, blue: 0.95))

                Text("\(sessions.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.blue))
            }

            // Session rows
            VStack(spacing: 2) {
                ForEach(sessions, id: \.id) { session in
                    ActiveSessionRow(session: session)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.13, green: 0.14, blue: 0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.blue.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

struct ActiveSessionRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let session: Session

    @State private var isHovered = false
    @State private var isPulsing = false

    private var projectName: String {
        session.project?.name ?? URL(fileURLWithPath: session.projectPath).lastPathComponent
    }

    private var projectIcon: String {
        session.project?.icon ?? "folder.fill"
    }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(session.lastAccessedAt)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing blue dot (actively working)
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)
                .shadow(color: .blue.opacity(0.6), radius: isPulsing ? 5 : 2)
                .scaleEffect(isPulsing ? 1.2 : 1.0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                }

            Image(systemName: projectIcon)
                .font(.system(size: 16))
                .foregroundStyle(Color(red: 0.65, green: 0.67, blue: 0.72))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(projectName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.88, green: 0.89, blue: 0.92))

                Text(session.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.65, green: 0.67, blue: 0.72))
                    .lineLimit(1)
            }

            Spacer()

            Text("Working...")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 0.95))

            Text(relativeTime)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.50, green: 0.52, blue: 0.58))
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let project = session.project {
                withAnimation(.spring(response: 0.3)) {
                    windowState.selectedProject = project
                    windowState.activeSession = session
                    windowState.userTappedSession = true
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Inbox Section

struct InboxSection: View {
    @EnvironmentObject var appState: AppState
    let sessions: [Session]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Waiting for Input")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.92, green: 0.93, blue: 0.95))

                Text("\(sessions.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange))
            }

            // Session rows
            VStack(spacing: 2) {
                ForEach(sessions, id: \.id) { session in
                    InboxRow(session: session)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.13, green: 0.14, blue: 0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.orange.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

struct InboxRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let session: Session

    @State private var sentText: String?  // Shows "Sent ✓" confirmation
    @State private var isHovered = false

    private var projectName: String {
        session.project?.name ?? URL(fileURLWithPath: session.projectPath).lastPathComponent
    }

    private var projectIcon: String {
        session.project?.icon ?? "folder.fill"
    }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(session.lastAccessedAt)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    /// Last meaningful lines from the terminal buffer — shows what Claude is asking
    private var terminalSnippet: String {
        guard let controller = appState.terminalControllers[session.id],
              let content = controller.terminalView?.getTerminal().getBufferAsData(),
              let text = String(data: content, encoding: .utf8) else {
            return ""
        }

        // Get last non-empty lines, strip ANSI escape codes
        let ansiPattern = try! NSRegularExpression(pattern: "\\x1b\\[[0-9;]*[a-zA-Z]|\\x1b\\][^\\x07]*\\x07|\\x1b[^\\[\\]][a-zA-Z]")
        let lines = text.components(separatedBy: .newlines)
            .map { line in
                let range = NSRange(line.startIndex..., in: line)
                return ansiPattern.stringByReplacingMatches(in: line, range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }

        // Take last 3 lines
        let tail = lines.suffix(3)
        return tail.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: dot + icon + name + time
            HStack(spacing: 12) {
                InboxPulsingDot()

                Image(systemName: projectIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color(red: 0.65, green: 0.67, blue: 0.72))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(projectName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(red: 0.88, green: 0.89, blue: 0.92))

                    Text(session.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.65, green: 0.67, blue: 0.72))
                        .lineLimit(1)
                }

                Spacer()

                Text(relativeTime)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.50, green: 0.52, blue: 0.58))
            }

            // Terminal snippet — what Claude is saying/asking
            let snippet = terminalSnippet
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.75, green: 0.78, blue: 0.85))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
                    )
                    .padding(.leading, 44)  // Align with text (dot + icon width)
            }

            // Quick-reply chips row
            HStack(spacing: 6) {
                Spacer()
                    .frame(width: 38)  // Align with text

                if let sent = sentText {
                    Text(sent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    InboxChip(label: "yes") { sendReply("yes") }
                    InboxChip(label: "no") { sendReply("no") }
                    InboxChip(label: "continue") { sendReply("continue") }
                    InboxChip(label: "stop") { sendReply("stop") }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            navigateToSession()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private func sendReply(_ text: String) {
        if let controller = appState.terminalControllers[session.id],
           controller.terminalView?.process?.running == true {
            controller.sendToTerminal(text)
            withAnimation {
                sentText = "Sent \u{2713}"
            }
            // Remove confirmation after 1.5s
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    sentText = nil
                }
            }
        } else {
            // Process not running — navigate to session to relaunch
            navigateToSession()
        }
    }

    private func navigateToSession() {
        if let project = session.project {
            withAnimation(.spring(response: 0.3)) {
                windowState.selectedProject = project
                windowState.activeSession = session
                windowState.userTappedSession = true
            }
        }
    }
}

struct InboxChip: View {
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    private var isDestructive: Bool { label == "stop" }

    private var accentColor: Color {
        isDestructive ? Color(red: 0.80, green: 0.22, blue: 0.22) : .orange
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isHovered ? accentColor : accentColor.opacity(0.25))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

struct InboxPulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.orange)
            .frame(width: 8, height: 8)
            .shadow(color: .orange.opacity(0.6), radius: isPulsing ? 6 : 2)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// NSVisualEffectView wrapper for glass effect
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// Preview available in Xcode only
