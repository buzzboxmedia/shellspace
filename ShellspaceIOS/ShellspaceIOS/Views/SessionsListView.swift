import SwiftUI

struct SessionsListView: View {
    @Environment(AppViewModel.self) private var viewModel
    let project: RemoteProject

    @State private var taskFolders: [RemoteTaskFolder] = []
    @State private var searchText = ""
    @State private var isLoading = true

    private var projectSessions: [RemoteSession] {
        viewModel.allSessions
            .filter { $0.projectPath == project.path && !$0.isHidden }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    // Map task folder paths to linked sessions
    private func sessionForTask(_ task: RemoteTaskFolder) -> RemoteSession? {
        projectSessions.first { $0.taskFolderPath == task.path }
    }

    // Sessions not linked to any task folder
    private var unlinkedSessions: [RemoteSession] {
        let taskPaths = Set(taskFolders.map(\.path))
        return projectSessions.filter { session in
            session.taskFolderPath == nil || !taskPaths.contains(session.taskFolderPath!)
        }
    }

    // Filtered results
    private var filteredTasks: [RemoteTaskFolder] {
        guard !searchText.isEmpty else { return taskFolders }
        let query = searchText.lowercased()
        return taskFolders.filter {
            $0.displayName.lowercased().contains(query) ||
            ($0.description?.lowercased().contains(query) ?? false)
        }
    }

    private var filteredUnlinkedSessions: [RemoteSession] {
        guard !searchText.isEmpty else { return unlinkedSessions }
        let query = searchText.lowercased()
        return unlinkedSessions.filter {
            $0.name.lowercased().contains(query) ||
            ($0.summary?.lowercased().contains(query) ?? false)
        }
    }

    private var activeTasks: [RemoteTaskFolder] {
        filteredTasks.filter { !$0.isCompleted }
    }

    private var completedTasks: [RemoteTaskFolder] {
        filteredTasks.filter { $0.isCompleted }
    }

    private var hasContent: Bool {
        !activeTasks.isEmpty || !completedTasks.isEmpty || !filteredUnlinkedSessions.isEmpty
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading tasks...")
            } else if !hasContent && searchText.isEmpty {
                ContentUnavailableView(
                    "No Tasks or Sessions",
                    systemImage: "folder",
                    description: Text("No tasks or sessions for \(project.name)")
                )
            } else if !hasContent && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    // Active tasks
                    if !activeTasks.isEmpty {
                        Section("Active") {
                            ForEach(activeTasks) { task in
                                taskRow(task)
                            }
                        }
                    }

                    // Unlinked sessions
                    if !filteredUnlinkedSessions.isEmpty {
                        Section("Sessions") {
                            ForEach(filteredUnlinkedSessions) { session in
                                NavigationLink(value: session) {
                                    SessionRow(session: session)
                                }
                            }
                        }
                    }

                    // Completed tasks
                    if !completedTasks.isEmpty {
                        Section("Completed") {
                            ForEach(completedTasks) { task in
                                taskRow(task)
                            }
                        }
                    }
                }
                .refreshable {
                    await loadTasks()
                    await viewModel.refresh()
                }
            }
        }
        .navigationTitle(project.name)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "What are you working on?"
        )
        .task {
            await loadTasks()
        }
    }

    @ViewBuilder
    private func taskRow(_ task: RemoteTaskFolder) -> some View {
        let linkedSession = sessionForTask(task)

        if let session = linkedSession {
            NavigationLink(value: session) {
                TaskFolderRow(task: task, linkedSession: session)
            }
        } else {
            TaskFolderRow(task: task, linkedSession: nil)
        }
    }

    private func loadTasks() async {
        guard let api = viewModel.api else {
            isLoading = false
            return
        }
        do {
            taskFolders = try await api.tasks(projectId: project.id)
        } catch {
            // Silently fall back to showing sessions only
        }
        isLoading = false
    }
}

// MARK: - Task Folder Row

struct TaskFolderRow: View {
    let task: RemoteTaskFolder
    let linkedSession: RemoteSession?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline)
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let description = task.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let status = task.status {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(statusColor)
                    }
                    if let created = task.created {
                        Text(created)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if let session = linkedSession {
                if session.isWaitingForInput {
                    Image(systemName: "bell.badge.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if session.isRunning {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        if task.isCompleted { return "checkmark.folder.fill" }
        if linkedSession?.isRunning == true { return "folder.fill.badge.gearshape" }
        if linkedSession != nil { return "folder.fill" }
        return "folder"
    }

    private var iconColor: Color {
        if task.isCompleted { return .gray }
        if linkedSession?.isWaitingForInput == true { return .orange }
        if linkedSession?.isRunning == true { return .green }
        if linkedSession != nil { return .blue }
        return .secondary
    }

    private var statusColor: Color {
        switch task.status?.lowercased() {
        case "active": return .blue
        case "done", "completed": return .gray
        default: return .secondary
        }
    }
}

// MARK: - Session Row (kept for unlinked sessions)

struct SessionRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let summary = session.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(session.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if session.isWaitingForInput {
                Image(systemName: "bell.badge.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        if session.isWaitingForInput { return .orange }
        if session.isRunning { return .green }
        if session.isCompleted { return .gray.opacity(0.5) }
        return .gray
    }
}
