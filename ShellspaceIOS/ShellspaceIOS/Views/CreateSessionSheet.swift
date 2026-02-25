import SwiftUI

struct CreateSessionSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    let project: RemoteProject
    var onCreate: ((RemoteSession) -> Void)?

    @State private var taskName = ""
    @State private var taskDescription = ""
    @State private var isCreating = false

    private var canCreate: Bool {
        !taskName.trimmingCharacters(in: .whitespaces).isEmpty && !isCreating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What are you working on?", text: $taskName)
                        .textInputAutocapitalization(.sentences)

                    ZStack(alignment: .topLeading) {
                        if taskDescription.isEmpty {
                            Text("Details (optional)")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 0)
                        }
                        TextEditor(text: $taskDescription)
                            .frame(minHeight: 100)
                    }
                } header: {
                    Label(project.name, systemImage: project.icon)
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createTask()
                    }
                    .disabled(!canCreate)
                }
            }
            .interactiveDismissDisabled(isCreating)
        }
    }

    private func createTask() {
        let name = taskName.trimmingCharacters(in: .whitespaces)
        let desc = taskDescription.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        isCreating = true
        Task {
            if let session = await viewModel.createSession(
                projectId: project.id,
                name: name,
                description: desc.isEmpty ? nil : desc
            ) {
                onCreate?(session)
            }
            isCreating = false
            dismiss()
        }
    }
}
