import SwiftUI

struct SessionsListView: View {
    @Environment(AppViewModel.self) private var viewModel
    let project: RemoteProject

    @State private var taskFolders: [RemoteTaskFolder] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var showCreateSheet = false

    private var projectSessions: [RemoteSession] {
        viewModel.allSessions
            .filter { $0.projectPath == project.path && !$0.isHidden }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    private func sessionForTask(_ task: RemoteTaskFolder) -> RemoteSession? {
        projectSessions.first { $0.taskFolderPath == task.path }
    }

    // Sessions not linked to any known task folder
    private var orphanSessions: [RemoteSession] {
        let taskPaths = Set(taskFolders.map(\.path))
        return projectSessions.filter { session in
            guard let tfp = session.taskFolderPath else { return true }
            return !taskPaths.contains(tfp)
        }
    }

    // Combined filtered items
    private var filteredTasks: [RemoteTaskFolder] {
        guard !searchText.isEmpty else { return taskFolders.filter { !$0.isCompleted } }
        let query = searchText.lowercased()
        return taskFolders.filter { !$0.isCompleted }.filter {
            $0.displayName.lowercased().contains(query) ||
            ($0.description?.lowercased().contains(query) ?? false)
        }
    }

    private var completedTasks: [RemoteTaskFolder] {
        let completed = taskFolders.filter { $0.isCompleted }
        guard !searchText.isEmpty else { return completed }
        let query = searchText.lowercased()
        return completed.filter {
            $0.displayName.lowercased().contains(query) ||
            ($0.description?.lowercased().contains(query) ?? false)
        }
    }

    private var filteredOrphanSessions: [RemoteSession] {
        guard !searchText.isEmpty else { return orphanSessions }
        let query = searchText.lowercased()
        return orphanSessions.filter {
            $0.name.lowercased().contains(query) ||
            ($0.summary?.lowercased().contains(query) ?? false)
        }
    }

    private var hasContent: Bool {
        !filteredTasks.isEmpty || !completedTasks.isEmpty || !filteredOrphanSessions.isEmpty
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
            } else if !hasContent && searchText.isEmpty {
                ContentUnavailableView(
                    "No Tasks or Sessions",
                    systemImage: "folder",
                    description: Text("Tap + to create a new task")
                )
            } else if !hasContent && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    // Tasks (active)
                    if !filteredTasks.isEmpty {
                        ForEach(filteredTasks) { task in
                            taskRow(task)
                        }
                    }

                    // Orphan sessions (no task folder match)
                    if !filteredOrphanSessions.isEmpty {
                        Section("Sessions") {
                            ForEach(filteredOrphanSessions) { session in
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
            prompt: "Search tasks..."
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateSessionSheet(project: project) { newSession in
                // Reload tasks after creation
                Task {
                    await loadTasks()
                }
            }
        }
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
