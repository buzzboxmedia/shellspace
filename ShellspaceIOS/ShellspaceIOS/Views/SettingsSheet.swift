import SwiftUI

struct SettingsSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Binding var isPresented: Bool

    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteError = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Connection

                Section("Connection") {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.connectionState.color)
                                .frame(width: 8, height: 8)
                            Text(viewModel.connectionState.label)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if viewModel.connectionState.isConnected {
                        HStack {
                            Text("Connected via")
                            Spacer()
                            Text(connectionModeLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let deviceName = viewModel.selectedDeviceName {
                        HStack {
                            Text("Mac")
                            Spacer()
                            Text(deviceName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let lastRefreshed = viewModel.lastRefreshed {
                        HStack {
                            Text("Last Updated")
                            Spacer()
                            Text(lastRefreshed, style: .relative)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - Device

                Section("Device") {
                    Button {
                        viewModel.disconnectDevice()
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.blue)
                            Text("Switch Mac")
                        }
                    }

                    if !viewModel.connectionState.isConnected {
                        Button {
                            viewModel.connectToRelay()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(.blue)
                                Text("Reconnect")
                            }
                        }
                    }
                }

                // MARK: - Account

                Section("Account") {
                    if let user = viewModel.relayAuth.currentUser {
                        HStack {
                            Text("Email")
                            Spacer()
                            Text(user.email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        viewModel.disconnect()
                        viewModel.relayAuth.logout()
                        isPresented = false
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            if isDeletingAccount {
                                ProgressView()
                                    .tint(.red)
                                Text("Deleting...")
                            } else {
                                Text("Delete Account")
                            }
                        }
                        .foregroundStyle(.red)
                    }
                    .disabled(isDeletingAccount)
                }

                if !deleteError.isEmpty {
                    Section {
                        Text(deleteError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("2.0.0")
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: URL(string: "https://shellspace.app/privacy.html")!) {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
            .alert("Delete Account?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Forever", role: .destructive) {
                    Task {
                        isDeletingAccount = true
                        deleteError = ""
                        do {
                            try await viewModel.relayAuth.deleteAccount()
                            viewModel.disconnect()
                            isPresented = false
                        } catch {
                            deleteError = error.localizedDescription
                        }
                        isDeletingAccount = false
                    }
                }
            } message: {
                Text("This will permanently delete your account, all devices, and all data. This cannot be undone.")
            }
        }
    }

    private var connectionModeLabel: String {
        switch viewModel.connectionMode {
        case .none: return "Not connected"
        case .relay(let name): return "Relay (\(name))"
        case .bonjour(let name): return "Bonjour (\(name))"
        case .manual: return "Direct"
        }
    }
}
