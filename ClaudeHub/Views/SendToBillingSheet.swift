import SwiftUI
import SwiftData

struct SendToBillingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let project: Project

    @State private var taskDescription = ""
    @State private var estimatedHours = ""
    @State private var actualHours = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    // Task content from TASK.md
    @State private var taskContent: TaskContent?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Send to Billing")
                        .font(.system(size: 18, weight: .semibold))

                    Text(session.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            if isLoading {
                VStack {
                    ProgressView()
                        .padding()
                    Text("Analyzing task and estimating hours...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Work completed summary
                        if let content = taskContent {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("WORK COMPLETED")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(1)

                                if !content.progressEntries.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(content.progressEntries.suffix(5)) { entry in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text(entry.date)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.tertiary)
                                                    .frame(width: 80, alignment: .leading)

                                                Text(entry.content.prefix(100) + (entry.content.count > 100 ? "..." : ""))
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.primary)
                                            }
                                        }
                                    }
                                } else {
                                    Text("No progress entries recorded")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Divider()
                        }

                        // Billable description
                        VStack(alignment: .leading, spacing: 6) {
                            Text("BILLABLE DESCRIPTION")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1)

                            TextEditor(text: $taskDescription)
                                .font(.system(size: 12))
                                .frame(minHeight: 80)
                                .padding(8)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }

                        // Hours
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ESTIMATED HOURS")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(1)

                                TextField("0.0", text: $estimatedHours)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(8)
                                    .frame(width: 80)
                                    .background(Color.white.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                Text("Industry standard")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("ACTUAL HOURS")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(1)

                                TextField("0.0", text: $actualHours)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(8)
                                    .frame(width: 80)
                                    .background(Color.white.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                Text("From session time")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }

                        if let success = successMessage {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(success)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    .padding()
                }

                // Send button
                HStack {
                    Spacer()

                    Button {
                        sendToBilling()
                    } label: {
                        HStack(spacing: 6) {
                            if isSending {
                                ProgressView()
                                    .scaleEffect(0.6)
                            }
                            Text("Send to Billing")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending || taskDescription.isEmpty)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .frame(width: 500, height: 550)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .onAppear {
            loadTaskAndEstimate()
        }
    }

    private func loadTaskAndEstimate() {
        isLoading = true

        Task {
            // Try to load task content from folder
            if let folderPath = session.taskFolderPath {
                let folderURL = URL(fileURLWithPath: folderPath)
                taskContent = TaskFolderService.shared.readTask(at: folderURL)
            }

            // Generate estimate using Claude
            await generateEstimate()

            await MainActor.run {
                isLoading = false
            }
        }
    }

    private func generateEstimate() async {
        // Build context from task content and session
        var context = "Task: \(session.name)\n"

        if let desc = session.sessionDescription ?? taskContent?.description {
            context += "Description: \(desc)\n"
        }

        if let content = taskContent {
            if !content.progressEntries.isEmpty {
                context += "\nProgress:\n"
                for entry in content.progressEntries {
                    context += "- \(entry.date): \(entry.content)\n"
                }
            }
        }

        // Use Claude to estimate hours and generate description
        let prompt = """
        Based on this task, provide:
        1. A professional billable description (2-3 sentences for an invoice)
        2. Estimated hours based on industry agency standards for this type of work

        Task context:
        \(context)

        Respond in this exact format:
        DESCRIPTION: [your description]
        ESTIMATED: [number of hours as decimal, e.g., 2.5]
        """

        // For now, use simple defaults - Claude API integration can be added later
        await MainActor.run {
            // Default description from task
            if taskDescription.isEmpty {
                if let desc = taskContent?.description, !desc.isEmpty, desc != "No description provided." {
                    taskDescription = desc
                } else {
                    taskDescription = "Completed work on \(session.name)."
                }
            }

            // Default estimates
            if estimatedHours.isEmpty {
                estimatedHours = "1.0"
            }
            if actualHours.isEmpty {
                // Try to calculate from progress entries
                actualHours = "1.0"
            }
        }
    }

    private func sendToBilling() {
        isSending = true
        errorMessage = nil

        Task {
            do {
                let estHrs = Double(estimatedHours) ?? 1.0
                let actHrs = Double(actualHours) ?? estHrs

                let result = try await GoogleSheetsService.shared.logBilling(
                    client: project.name,
                    project: session.taskGroup?.name,
                    task: session.name,
                    description: taskDescription,
                    estHours: estHrs,
                    actualHours: actHrs,
                    status: "billed"
                )

                await MainActor.run {
                    isSending = false
                    if result.success {
                        successMessage = "Sent to billing spreadsheet"
                        // Update task status
                        if let folderPath = session.taskFolderPath {
                            try? TaskFolderService.shared.updateTaskStatus(
                                at: URL(fileURLWithPath: folderPath),
                                status: "billed",
                                estimatedHours: estimatedHours,
                                actualHours: actualHours
                            )
                        }
                        // Close after a moment
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            dismiss()
                        }
                    } else {
                        errorMessage = result.error ?? "Failed to send to billing"
                    }
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}
