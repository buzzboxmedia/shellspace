import SwiftUI

// MARK: - Save Note Popover

struct SaveNotePopover: View {
    let session: Session
    let project: Project
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var noteText: String = ""
    @State private var isSaving = false
    @FocusState private var isTextFieldFocused: Bool

    var canSave: Bool {
        !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("Progress Note")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            // Text input
            TextEditor(text: $noteText)
                .font(.system(size: 13))
                .frame(minHeight: 80, maxHeight: 120)
                .padding(8)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .focused($isTextFieldFocused)

            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    saveNote()
                } label: {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 80)
                    } else {
                        Text("Save to Task")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private func saveNote() {
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }

        isSaving = true

        // Append to TASK.md
        if let taskFolderPath = session.taskFolderPath {
            let folderURL = URL(fileURLWithPath: taskFolderPath)
            let taskFile = folderURL.appendingPathComponent("TASK.md")

            if FileManager.default.fileExists(atPath: taskFile.path) {
                do {
                    var content = try String(contentsOf: taskFile, encoding: .utf8)

                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
                    let timestamp = dateFormatter.string(from: Date())

                    content += "\n### \(timestamp)\n\(note)\n"
                    try content.write(to: taskFile, atomically: true, encoding: .utf8)

                    // Update session's last progress saved time
                    session.lastProgressSavedAt = Date()

                    isSaving = false
                    onSave()
                } catch {
                    print("Failed to save progress note: \(error)")
                    isSaving = false
                }
            } else {
                isSaving = false
            }
        } else {
            // No task folder linked - create a summary in the session
            session.lastSessionSummary = note
            session.lastProgressSavedAt = Date()
            isSaving = false
            onSave()
        }
    }
}

// MARK: - Progress Reminder Toast

struct ProgressReminderToast: View {
    let onAddNote: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false
    @State private var opacity: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pin.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)

            Text("Save progress?")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            Button {
                onAddNote()
            } label: {
                Text("Add Note")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                opacity = 1
            }
        }
    }

    func dismiss() {
        withAnimation(.easeIn(duration: 0.2)) {
            opacity = 0
        }
    }
}

// MARK: - Unsaved Progress Alert

struct UnsavedProgressAlert: View {
    let sessionName: String
    let onDontSave: () -> Void
    let onAddNote: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Save progress before closing?")
                .font(.system(size: 16, weight: .semibold))

            Text("You haven't saved a note for \"\(sessionName)\" this session.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Don't Save") {
                    onDontSave()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button("Add Note & Close") {
                    onAddNote()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 320)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Save Note Sheet (for close prompt)

struct SaveNoteSheetWrapper: View {
    let session: Session
    let project: Project
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var noteText: String = ""
    @State private var isSaving = false
    @FocusState private var isTextFieldFocused: Bool

    var canSave: Bool {
        !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save Progress Note")
                        .font(.system(size: 16, weight: .semibold))
                    Text(session.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onCancel()
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

            // Content
            VStack(alignment: .leading, spacing: 16) {
                Text("What did you accomplish in this session?")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                TextEditor(text: $noteText)
                    .font(.system(size: 13))
                    .frame(minHeight: 100, maxHeight: 150)
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .focused($isTextFieldFocused)
            }
            .padding()

            Divider()

            // Footer
            HStack {
                Button("Skip") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    saveNote()
                } label: {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 100)
                    } else {
                        Text("Save & Close")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 400, height: 320)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private func saveNote() {
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }

        isSaving = true

        // Append to TASK.md
        if let taskFolderPath = session.taskFolderPath {
            let folderURL = URL(fileURLWithPath: taskFolderPath)
            let taskFile = folderURL.appendingPathComponent("TASK.md")

            if FileManager.default.fileExists(atPath: taskFile.path) {
                do {
                    var content = try String(contentsOf: taskFile, encoding: .utf8)

                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
                    let timestamp = dateFormatter.string(from: Date())

                    content += "\n### \(timestamp)\n\(note)\n"
                    try content.write(to: taskFile, atomically: true, encoding: .utf8)

                    // Update session's last progress saved time
                    session.lastProgressSavedAt = Date()

                    isSaving = false
                    onSave()
                } catch {
                    print("Failed to save progress note: \(error)")
                    isSaving = false
                }
            } else {
                isSaving = false
                onSave()
            }
        } else {
            // No task folder - save to session summary
            session.lastSessionSummary = note
            session.lastProgressSavedAt = Date()
            isSaving = false
            onSave()
        }
    }
}

// MARK: - Progress Note Manager

/// Manages the 15-minute reminder timer for each session
class ProgressNoteManager: ObservableObject {
    static let shared = ProgressNoteManager()

    /// Sessions that have dismissed the reminder this cycle
    @Published var dismissedReminders: Set<UUID> = []

    /// The reminder interval (15 minutes)
    let reminderInterval: TimeInterval = 15 * 60

    private init() {}

    /// Check if a session should show the progress reminder
    func shouldShowReminder(for session: Session) -> Bool {
        // Don't show if dismissed this cycle
        guard !dismissedReminders.contains(session.id) else {
            return false
        }

        // Don't show for completed sessions
        guard !session.isCompleted else {
            return false
        }

        // Check if 15 minutes have passed since last save
        let lastSave = session.lastProgressSavedAt ?? session.createdAt
        let elapsed = Date().timeIntervalSince(lastSave)

        return elapsed >= reminderInterval
    }

    /// Mark reminder as dismissed for this cycle
    func dismissReminder(for session: Session) {
        dismissedReminders.insert(session.id)

        // Reset after 15 minutes so it can show again
        DispatchQueue.main.asyncAfter(deadline: .now() + reminderInterval) { [weak self] in
            self?.dismissedReminders.remove(session.id)
        }
    }

    /// Reset dismissed state when user saves a note
    func noteSaved(for session: Session) {
        dismissedReminders.remove(session.id)
    }
}
