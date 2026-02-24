import SwiftUI

struct SettingsSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Binding var isPresented: Bool
    var isInitialSetup: Bool = false

    @State private var hostInput = ""
    @State private var isTesting = false
    @State private var testResult: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)
                        TextField("Mac hostname or IP", text: $hostInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    if !hostInput.isEmpty {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            HStack {
                                if isTesting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else if let result = testResult {
                                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(result ? .green : .red)
                                }
                                Text(isTesting ? "Testing..." : "Test Connection")
                            }
                        }
                        .disabled(isTesting)
                    }
                } header: {
                    Text("Tailscale Connection")
                } footer: {
                    Text("Enter your Mac's Tailscale hostname (e.g. barons-mac-studio) or IP address. Shellspace must be running on the Mac.")
                }

                if !isInitialSetup {
                    Section("Status") {
                        HStack {
                            Text("Connection")
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
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isInitialSetup ? "Connect to Mac" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isInitialSetup {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Connect") {
                            saveAndConnect()
                        }
                        .disabled(hostInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if hostInput != viewModel.macHost && !hostInput.isEmpty {
                                saveAndConnect()
                            }
                            isPresented = false
                        }
                    }
                }
            }
            .onAppear {
                hostInput = viewModel.macHost
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        let host = hostInput.trimmingCharacters(in: .whitespaces)
        testResult = await viewModel.testConnection(host: host)
        isTesting = false
    }

    private func saveAndConnect() {
        let host = hostInput.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        viewModel.macHost = host
        viewModel.disconnect()
        Task {
            await viewModel.connectAndLoad()
        }
        if !isInitialSetup {
            isPresented = false
        }
    }
}
