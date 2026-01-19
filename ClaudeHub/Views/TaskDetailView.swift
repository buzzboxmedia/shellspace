import SwiftUI
import SwiftData

/// Detail panel for viewing and editing task information
struct TaskDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    let session: Session
    let project: Project
    @Binding var isPresented: Bool

    @State private var taskContent: TaskFileContent?
    @State private var isLoading = true
    @State private var isEditing = false
    @State private var editedDescription: String = ""

    /// Get client name from project path
    var clientName: String {
        // Extract client name from path like ~/Dropbox/Buzzbox/clients/INFAB
        let pathComponents = project.path.components(separatedBy: "/")
        if let clientsIndex = pathComponents.firstIndex(of: "clients"),
           clientsIndex + 1 < pathComponents.count {
            return pathComponents[clientsIndex + 1]
        }
        // Fallback to project name
        return project.name
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .font(.system(size: 18, weight: .semibold))

                    HStack(spacing: 12) {
                        // Status badge
                        statusBadge

                        // Priority badge
                        if let priority = taskContent?.priority {
                            priorityBadge(priority)
                        }

                        // Created date
                        if let created = taskContent?.created {
                            Text("Created \(created)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading task details...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Description section
                        descriptionSection

                        Divider()

                        // Session log section
                        sessionLogSection
                    }
                    .padding()
                }
            }

            Divider()

            // Footer with actions
            HStack {
                // Open in Claude button
                Button {
                    isPresented = false
                    // Session is already active, just close the detail view
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text("Continue in Terminal")
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                // Open task file
                if let filePath = taskContent?.filePath {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                            Text("Open File")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 550)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .onAppear {
            loadTaskContent()
        }
    }

    // MARK: - Subviews

    var statusBadge: some View {
        let status = taskContent?.status ?? "active"
        let color: Color = {
            switch status {
            case "done": return .green
            case "waiting": return .orange
            case "active": return .blue
            default: return .gray
            }
        }()

        return Text(status.capitalized)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    func priorityBadge(_ priority: String) -> some View {
        let color: Color = {
            switch priority.lowercased() {
            case "high": return .red
            case "medium": return .yellow
            case "low": return .gray
            default: return .gray
            }
        }()

        return Text(priority.capitalized)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Description")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    editedDescription = taskContent?.description ?? ""
                    isEditing.toggle()
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isEditing {
                TextEditor(text: $editedDescription)
                    .font(.system(size: 13))
                    .frame(minHeight: 80)
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )

                HStack {
                    Spacer()
                    Button("Cancel") {
                        isEditing = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button("Save") {
                        saveDescription()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text(taskContent?.description ?? session.sessionDescription ?? "No description")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var sessionLogSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session Log")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(taskContent?.sessions.count ?? 0) sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if let sessions = taskContent?.sessions, !sessions.isEmpty {
                ForEach(sessions.indices.reversed(), id: \.self) { index in
                    sessionEntryView(sessions[index])
                }
            } else if let summary = session.lastSessionSummary, !summary.isEmpty {
                // Fallback to session's stored summary
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest Summary")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("No session history yet. Work on this task with Claude to start building a log.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func sessionEntryView(_ entry: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Text(entry.date)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(entry.content)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    func loadTaskContent() {
        isLoading = true

        // Try to load from task file first
        taskContent = TaskFileService.shared.readTaskFile(
            clientName: clientName,
            taskName: session.name
        )

        // If no file exists, create initial content from session data
        if taskContent == nil {
            taskContent = TaskFileContent(
                title: session.name,
                status: session.isCompleted ? "done" : "active",
                priority: "medium",
                description: session.sessionDescription,
                sessions: []
            )
        }

        isLoading = false
    }

    func saveDescription() {
        // Update session's description
        session.sessionDescription = editedDescription
        taskContent?.description = editedDescription

        // Try to update the task file if it exists
        // For now, we'll create/update the file
        do {
            let filePath = TaskFileService.shared.taskFilePath(
                clientName: clientName,
                taskName: session.name
            )

            if FileManager.default.fileExists(atPath: filePath.path) {
                // Update existing file - for now just reload
                // TODO: Implement proper description update in TaskFileService
            } else {
                // Create the file
                _ = try TaskFileService.shared.createTaskFile(
                    clientName: clientName,
                    taskName: session.name,
                    description: editedDescription
                )
            }
        } catch {
            print("Failed to save task file: \(error)")
        }

        isEditing = false
    }
}
