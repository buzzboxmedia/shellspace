import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Session Priority Scoring

struct SessionPriority: Comparable, Identifiable {
    let session: Session
    let score: Int
    let reason: String      // "Waiting on you", "Stale 2h", "Working..."
    let accentColor: Color  // orange (waiting), red (stale), blue (active)

    var id: UUID { session.id }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.score < rhs.score }
}

/// Extract last meaningful terminal line for a session (what Claude is saying/asking)
func terminalSnippet(for session: Session, appState: AppState) -> String {
    guard let controller = appState.terminalControllers[session.id],
          let content = controller.terminalView?.getTerminal().getBufferAsData(),
          let text = String(data: content, encoding: .utf8) else {
        return ""
    }

    let ansiPattern = try! NSRegularExpression(pattern: "\\x1b\\[[0-9;]*[a-zA-Z]|\\x1b\\][^\\x07]*\\x07|\\x1b[^\\[\\]][a-zA-Z]")
    let prefixPattern = try! NSRegularExpression(pattern: "^[>\u{276F}\u{203A}\u{25B6}]+\\s*")
    let lines = text.components(separatedBy: .newlines)
        .map { line in
            let range = NSRange(line.startIndex..., in: line)
            var cleaned = ansiPattern.stringByReplacingMatches(in: line, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            let cleanedRange = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = prefixPattern.stringByReplacingMatches(in: cleaned, range: cleanedRange, withTemplate: "")
            return cleaned
        }
        .filter { line in
            guard !line.isEmpty else { return false }
            let lower = line.lowercased()
            if lower.contains("bypass permissions") || lower.contains("shift+tab to cycle") ||
               lower.contains("permissions on") || lower.contains("bypasspermission") {
                return false
            }
            if line == ">" || line == "$" || line == "%" { return false }
            return true
        }

    return lines.last ?? ""
}

/// Relative time string (compact)
func relativeTimeString(from date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    return "\(Int(interval / 86400))d ago"
}

// MARK: - Launcher View

struct LauncherView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState

    @Query(sort: \Project.name) private var allProjects: [Project]
    @Query(filter: #Predicate<Session> { !$0.isCompleted }) private var allSessions: [Session]

    @State private var showSettings = false
    @State private var showCleanup = false
    @State private var showAddProject = false
    @State private var draggedProject: Project?

    // "Cleared today" game stats
    @AppStorage("clearedToday") private var clearedToday: Int = 0
    @AppStorage("clearedDate") private var clearedDate: String = ""

    /// All sessions that should appear in Mission Control, scored and sorted
    private var prioritizedSessions: [SessionPriority] {
        let now = Date()

        var results: [SessionPriority] = []

        for session in allSessions {
            guard !session.isCompleted else { continue }

            let isRunning = appState.terminalControllers[session.id]?.terminalView?.process?.running == true
            let isWaiting = session.isWaitingForInput && !session.isHidden

            // Must be either waiting or running to appear
            guard isWaiting || isRunning else { continue }

            let staleness = now.timeIntervalSince(session.lastAccessedAt)

            let score: Int
            let reason: String
            let color: Color

            if isWaiting {
                score = 100
                reason = "Waiting on you"
                color = .orange
            } else if staleness > 7200 { // >2h
                score = 80
                let hours = Int(staleness / 3600)
                reason = "Stale \(hours)h"
                color = Color(red: 0.85, green: 0.25, blue: 0.25)
            } else if staleness > 1800 { // >30min
                score = 60
                let mins = Int(staleness / 60)
                reason = "Idle \(mins)m"
                color = Color(red: 0.90, green: 0.55, blue: 0.20)
            } else if staleness > 600 { // >10min
                score = 40
                let mins = Int(staleness / 60)
                reason = "Idle \(mins)m"
                color = .yellow
            } else {
                score = 10
                reason = "Working..."
                color = .blue
            }

            results.append(SessionPriority(
                session: session,
                score: score,
                reason: reason,
                accentColor: color
            ))
        }

        return results.sorted(by: >)
    }

    /// Check and reset cleared counter at midnight
    private func checkClearedDate() {
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        if clearedDate != today {
            clearedToday = 0
            clearedDate = today
        }
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

    var displayProjects: [Project] {
        let order = savedOrder
        guard !order.isEmpty else { return allProjects.map { $0 } }
        return allProjects.sorted { a, b in
            let indexA = order.firstIndex(of: a.path) ?? Int.max
            let indexB = order.firstIndex(of: b.path) ?? Int.max
            return indexA < indexB
        }
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 16)
    ]

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 40) {
                    // Header
                    HStack {
                        Spacer()
                        Text("Shellspace")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .overlay(alignment: .leading) {
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

                    // MARK: - Mission Control
                    if !prioritizedSessions.isEmpty {
                        MissionControlSection(
                            sessions: prioritizedSessions,
                            clearedToday: clearedToday
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: - Subagent Processes
                    if !appState.orphanProcesses.isEmpty {
                        OrphanProcessSection(processes: appState.orphanProcesses)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: - Project Grid
                    VStack(spacing: 36) {
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
        .onAppear {
            checkClearedDate()
        }
    }
}

// MARK: - Mission Control Section

struct MissionControlSection: View {
    @EnvironmentObject var appState: AppState
    let sessions: [SessionPriority]
    let clearedToday: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.cyan)

                Text("Mission Control")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.92, green: 0.93, blue: 0.95))

                Text("\(sessions.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.cyan))

                Spacer()

                if clearedToday > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                        Text("\(clearedToday) cleared")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                }
            }

            // Hero card for top priority
            if let first = sessions.first {
                NextUpCard(priority: first)
            }

            // Remaining items as compact rows
            if sessions.count > 1 {
                VStack(spacing: 2) {
                    ForEach(Array(sessions.dropFirst())) { priority in
                        MissionRow(priority: priority)
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.cyan.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Next Up Hero Card

struct NextUpCard: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let priority: SessionPriority

    @State private var isHovered = false
    @State private var sentText: String?
    @State private var glowPulse = false

    private var session: Session { priority.session }

    private var projectName: String {
        session.project?.name ?? URL(fileURLWithPath: session.projectPath).lastPathComponent
    }

    private var projectIcon: String {
        session.project?.icon ?? "folder.fill"
    }

    private var snippet: String {
        terminalSnippet(for: session, appState: appState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top bar: NEXT UP label + staleness
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("NEXT UP")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(priority.accentColor)

                Spacer()

                // Staleness badge
                Text(priority.reason)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(priority.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(priority.accentColor.opacity(0.15)))
            }

            // Session info
            HStack(spacing: 12) {
                Image(systemName: projectIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 0.75, green: 0.78, blue: 0.85))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(projectName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(red: 0.92, green: 0.93, blue: 0.95))

                    Text(session.name)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.70, green: 0.72, blue: 0.78))
                        .lineLimit(1)
                }

                Spacer()

                Text(relativeTimeString(from: session.lastAccessedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.50, green: 0.52, blue: 0.58))
            }

            // Terminal snippet (what Claude is saying)
            if !snippet.isEmpty {
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(priority.accentColor.opacity(0.5))
                        .frame(width: 3)

                    Text(snippet)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color(red: 0.80, green: 0.83, blue: 0.90))
                        .lineLimit(3)
                        .padding(.leading, 10)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }

            // Quick-reply chips (only if waiting for input)
            if session.isWaitingForInput {
                HStack(spacing: 8) {
                    if let sent = sentText {
                        Text(sent)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    } else {
                        InboxChip(icon: "checkmark", hint: "yes") { sendReply("yes") }
                        InboxChip(icon: "xmark", hint: "no") { sendReply("no") }
                        InboxChip(icon: "arrow.right", hint: "continue") { sendReply("continue") }
                        InboxChip(icon: "stop.fill", hint: "stop", isDestructive: true) { sendReply("stop") }
                    }

                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.14, green: 0.15, blue: 0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(priority.accentColor.opacity(glowPulse ? 0.5 : 0.25), lineWidth: 2)
                )
                .shadow(color: priority.accentColor.opacity(glowPulse ? 0.2 : 0.08), radius: glowPulse ? 12 : 6)
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { navigateToSession() }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
    }

    private func sendReply(_ text: String) {
        if text == "stop" {
            withAnimation {
                appState.removeController(for: session)
                session.isWaitingForInput = false
            }
            return
        }

        if let controller = appState.terminalControllers[session.id],
           controller.terminalView?.process?.running == true {
            controller.sendToTerminal(text)
            controller.idleTickCount = -25
            withAnimation { sentText = "Sent \u{2713}" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { sentText = nil }
            }
        } else {
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

// MARK: - Mission Row (compact queue item)

struct MissionRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let priority: SessionPriority

    @State private var isHovered = false
    @State private var sentText: String?

    private var session: Session { priority.session }

    private var projectName: String {
        session.project?.name ?? URL(fileURLWithPath: session.projectPath).lastPathComponent
    }

    private var projectIcon: String {
        session.project?.icon ?? "folder.fill"
    }

    private var snippet: String {
        terminalSnippet(for: session, appState: appState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Priority dot
                Circle()
                    .fill(priority.accentColor)
                    .frame(width: 8, height: 8)

                Image(systemName: projectIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color(red: 0.65, green: 0.67, blue: 0.72))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(projectName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(red: 0.88, green: 0.89, blue: 0.92))

                        if session.isHidden {
                            Text("hidden")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                    }

                    Text(session.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.65, green: 0.67, blue: 0.72))
                        .lineLimit(1)
                }

                Spacer()

                // Reason badge
                Text(priority.reason)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(priority.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(priority.accentColor.opacity(0.12)))

                // Quick actions on hover
                if isHovered {
                    if session.isWaitingForInput {
                        if let sent = sentText {
                            Text(sent)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                                .transition(.opacity)
                        } else {
                            HStack(spacing: 4) {
                                MiniChip(icon: "checkmark", color: .orange) { sendReply("yes") }
                                MiniChip(icon: "xmark", color: .orange) { sendReply("no") }
                                MiniChip(icon: "arrow.right", color: .orange) { sendReply("continue") }
                            }
                        }
                    }

                    // Dismiss button
                    Button {
                        withAnimation {
                            session.isWaitingForInput = false
                            appState.removeController(for: session)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.50, green: 0.52, blue: 0.58))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .transition(.opacity)
                }

                Text(relativeTimeString(from: session.lastAccessedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.50, green: 0.52, blue: 0.58))
                    .frame(width: 50, alignment: .trailing)
            }

            // Terminal snippet on hover or if waiting
            let snip = snippet
            if !snip.isEmpty && (isHovered || session.isWaitingForInput) {
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(priority.accentColor.opacity(0.4))
                        .frame(width: 2)

                    Text(snip)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(red: 0.75, green: 0.78, blue: 0.85))
                        .lineLimit(1)
                        .padding(.leading, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { navigateToSession() }
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
            controller.idleTickCount = -25
            withAnimation { sentText = "Sent \u{2713}" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { sentText = nil }
            }
        } else {
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

/// Tiny inline action chip for mission rows
struct MiniChip: View {
    let icon: String
    let color: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isHovered ? color : color.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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

    var runningCount: Int {
        project.sessions.filter { appState.terminalControllers[$0.id]?.terminalView?.process?.running == true }.count
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: project.icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.primary)

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

// MARK: - Shared Quick-Reply Chips

struct InboxChip: View {
    let icon: String
    let hint: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    private var accentColor: Color {
        isDestructive ? Color(red: 0.80, green: 0.22, blue: 0.22) : .orange
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered ? accentColor : accentColor.opacity(0.25))
                )
        }
        .buttonStyle(.plain)
        .help(hint)
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

// MARK: - Orphan Process Section (subagents not managed by Shellspace)

struct OrphanProcessSection: View {
    let processes: [OrphanClaudeProcess]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.purple)

                Text("Subagents")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.92, green: 0.93, blue: 0.95))

                Text("\(processes.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.purple))

                Spacer()

                if processes.count > 1 {
                    Button {
                        for process in processes {
                            kill(process.pid, SIGTERM)
                        }
                    } label: {
                        Text("Stop All")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color(red: 0.80, green: 0.22, blue: 0.22).opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 2) {
                ForEach(processes) { process in
                    OrphanProcessRow(process: process)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.13, green: 0.14, blue: 0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.purple.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

struct OrphanProcessRow: View {
    let process: OrphanClaudeProcess
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.purple)
                .frame(width: 8, height: 8)

            Image(systemName: "terminal")
                .font(.system(size: 16))
                .foregroundStyle(Color(red: 0.65, green: 0.67, blue: 0.72))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(process.directoryName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.88, green: 0.89, blue: 0.92))

                Text("PID \(process.pid)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.65, green: 0.67, blue: 0.72))
            }

            Spacer()

            if isHovered {
                Button {
                    kill(process.pid, SIGTERM)
                } label: {
                    Text("Stop")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(red: 0.80, green: 0.22, blue: 0.22).opacity(0.25)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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
