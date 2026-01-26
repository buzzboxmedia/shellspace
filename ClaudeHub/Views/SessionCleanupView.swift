import SwiftUI
import SwiftData

struct SessionCleanupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Session.createdAt, order: .reverse) private var allSessions: [Session]

    @State private var selectedSessions: Set<UUID> = []
    @State private var filterOption: FilterOption = .all
    @State private var showDeleteConfirm = false

    enum FilterOption: String, CaseIterable {
        case all = "All"
        case active = "Active"
        case completed = "Completed"
        case old = "Older than 7 days"
    }

    var filteredSessions: [Session] {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        switch filterOption {
        case .all:
            return allSessions
        case .active:
            return allSessions.filter { !$0.isCompleted }
        case .completed:
            return allSessions.filter { $0.isCompleted }
        case .old:
            return allSessions.filter { $0.createdAt < sevenDaysAgo }
        }
    }

    var groupedByProject: [(String, [Session])] {
        let grouped = Dictionary(grouping: filteredSessions) { session in
            URL(fileURLWithPath: session.projectPath).lastPathComponent
        }
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Sessions")
                    .font(.system(size: 20, weight: .semibold))

                Spacer()

                Picker("Filter", selection: $filterOption) {
                    ForEach(FilterOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 400)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()
            .background(.ultraThinMaterial)

            // Selection toolbar
            HStack {
                Text("\(filteredSessions.count) sessions")
                    .foregroundStyle(.secondary)

                if !selectedSessions.isEmpty {
                    Text("• \(selectedSessions.count) selected")
                        .foregroundStyle(.blue)
                }

                Spacer()

                Button("Select All") {
                    selectedSessions = Set(filteredSessions.map { $0.id })
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Button("Select None") {
                    selectedSessions.removeAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Divider()
                    .frame(height: 20)

                Button {
                    markSelectedComplete()
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .disabled(selectedSessions.isEmpty)

                Button {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .foregroundStyle(.red)
                .disabled(selectedSessions.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.2))

            // Session list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedByProject, id: \.0) { projectName, sessions in
                        ProjectSessionGroup(
                            projectName: projectName,
                            sessions: sessions,
                            selectedSessions: $selectedSessions
                        )
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .alert("Delete \(selectedSessions.count) sessions?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSelected()
            }
        } message: {
            Text("This will permanently delete the selected sessions and their task folders.")
        }
    }

    private func markSelectedComplete() {
        for session in allSessions where selectedSessions.contains(session.id) {
            session.isCompleted = true
            session.completedAt = Date()
        }
        selectedSessions.removeAll()
    }

    private func deleteSelected() {
        for session in allSessions where selectedSessions.contains(session.id) {
            // Delete task folder if exists
            if let taskPath = session.taskFolderPath {
                try? FileManager.default.removeItem(atPath: taskPath)
            }
            modelContext.delete(session)
        }
        selectedSessions.removeAll()
    }
}

struct ProjectSessionGroup: View {
    let projectName: String
    let sessions: [Session]
    @Binding var selectedSessions: Set<UUID>

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Project header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text(projectName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("(\(sessions.count))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Select all in project
                    Button("Select All") {
                        for session in sessions {
                            selectedSessions.insert(session.id)
                        }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(sessions) { session in
                        SessionCleanupRow(
                            session: session,
                            isSelected: selectedSessions.contains(session.id),
                            onToggle: {
                                if selectedSessions.contains(session.id) {
                                    selectedSessions.remove(session.id)
                                } else {
                                    selectedSessions.insert(session.id)
                                }
                            }
                        )
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding()
        .background(Color.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SessionCleanupRow: View {
    let session: Session
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var claudeSummary: String?

    var ageText: String {
        let days = Calendar.current.dateComponents([.day], from: session.createdAt, to: Date()).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        return "\(days) days ago"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button {
                onToggle()
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            // Status indicator
            Circle()
                .fill(session.isCompleted ? Color.green : Color.blue)
                .frame(width: 8, height: 8)

            // Session info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if session.isCompleted {
                        Text("Completed")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                // Summary or description
                if let summary = claudeSummary ?? session.sessionDescription {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Age
            Text(ageText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
        .onAppear {
            loadClaudeSummary()
        }
    }

    private func loadClaudeSummary() {
        // Try to get summary from Claude's session index
        guard let taskPath = session.taskFolderPath ?? Optional(session.projectPath) else { return }

        let discovered = ClaudeSessionDiscovery.shared.discoverSessions(for: taskPath)
        if let match = discovered.first(where: {
            session.claudeSessionId == $0.id || $0.summary.localizedCaseInsensitiveContains(session.name)
        }) {
            claudeSummary = match.summary.isEmpty ? match.firstPrompt : match.summary
        } else if let first = discovered.first {
            // Use most recent session summary as fallback
            claudeSummary = first.summary.isEmpty ? first.firstPrompt : first.summary
        }
    }
}

#Preview {
    SessionCleanupView()
}
