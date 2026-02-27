import SwiftUI

struct SettingsSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Binding var isPresented: Bool

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
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("2.0.0")
                            .foregroundStyle(.secondary)
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
