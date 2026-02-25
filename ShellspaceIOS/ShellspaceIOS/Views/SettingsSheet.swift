import SwiftUI

struct SettingsSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Binding var isPresented: Bool
    var isInitialSetup: Bool = false

    @State private var hostInput = ""
    @State private var isTesting = false
    @State private var testResult: Bool?
    @State private var showManualEntry = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Discovered Macs (Bonjour)

                Section {
                    if viewModel.bonjourBrowser.isSearching && viewModel.bonjourBrowser.discoveredHosts.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Searching for Shellspace on your network...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(viewModel.bonjourBrowser.discoveredHosts) { host in
                        Button {
                            Task {
                                await viewModel.connectToDiscoveredHost(host)
                                if !isInitialSetup {
                                    isPresented = false
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .foregroundStyle(.primary)
                                    Text(host.host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isConnectedToHost(host) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if viewModel.bonjourBrowser.discoveredHosts.isEmpty && !viewModel.bonjourBrowser.isSearching {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(.secondary)
                            Text("No Macs found on this network")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Local Network")
                } footer: {
                    Text("Macs running Shellspace are discovered automatically via Bonjour.")
                }

                // MARK: - Manual Connection

                Section {
                    if showManualEntry || !viewModel.macHost.isEmpty {
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                            TextField("IP address or hostname", text: $hostInput)
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

                            Button("Connect") {
                                saveManualHost()
                            }
                            .fontWeight(.semibold)
                            .disabled(hostInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        if !viewModel.macHost.isEmpty {
                            Button("Clear Manual Host", role: .destructive) {
                                hostInput = ""
                                showManualEntry = false
                                viewModel.clearManualHost()
                            }
                        }
                    } else {
                        Button {
                            showManualEntry = true
                        } label: {
                            HStack {
                                Image(systemName: "keyboard")
                                    .foregroundStyle(.secondary)
                                Text("Enter IP address manually")
                            }
                        }
                    }
                } header: {
                    Text("Remote / Tailscale")
                } footer: {
                    if showManualEntry || !viewModel.macHost.isEmpty {
                        Text("Use this for Tailscale or when your Mac is on a different network. Enter the Tailscale hostname or IP address.")
                    } else {
                        Text("For connecting over Tailscale or to a Mac on a different network.")
                    }
                }

                // MARK: - Status

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

                        if viewModel.connectionState.isConnected {
                            HStack {
                                Text("Connected via")
                                Spacer()
                                Text(connectionModeLabel)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text("Host")
                                Spacer()
                                Text(viewModel.activeHost)
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
                        if viewModel.connectionState.isConnected {
                            Button("Done") {
                                isPresented = false
                            }
                            .fontWeight(.semibold)
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            // Save manual host if changed
                            if showManualEntry && !hostInput.isEmpty && hostInput != viewModel.macHost {
                                saveManualHost()
                            }
                            isPresented = false
                        }
                    }
                }
            }
            .onAppear {
                hostInput = viewModel.macHost
                showManualEntry = !viewModel.macHost.isEmpty
                // Ensure Bonjour is browsing when settings opens
                if !viewModel.bonjourBrowser.isSearching {
                    viewModel.bonjourBrowser.startBrowsing()
                }
            }
        }
    }

    // MARK: - Helpers

    private var connectionModeLabel: String {
        switch viewModel.connectionMode {
        case .none: return "Not connected"
        case .bonjour(let name): return "Bonjour (\(name))"
        case .manual: return "Manual"
        }
    }

    private func isConnectedToHost(_ host: DiscoveredHost) -> Bool {
        viewModel.connectionState.isConnected && viewModel.activeHost == host.host
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        let host = hostInput.trimmingCharacters(in: .whitespaces)
        testResult = await viewModel.testConnection(host: host)
        isTesting = false
    }

    private func saveManualHost() {
        let host = hostInput.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        viewModel.setManualHost(host)
    }
}
