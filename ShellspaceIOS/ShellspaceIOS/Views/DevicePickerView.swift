import SwiftUI

/// A device registered with the relay server (a Mac running Shellspace).
struct RelayDevice: Codable, Identifiable {
    let id: String
    let name: String
    let platform: String
    let isOnline: Bool
    let lastSeen: String?

    var relativeLastSeen: String {
        guard let lastSeen, let date = ISO8601DateFormatter().date(from: lastSeen) else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct DevicesResponse: Codable {
    let devices: [RelayDevice]
}

struct DevicePickerView: View {
    @Environment(AppViewModel.self) private var viewModel

    @State private var devices: [RelayDevice] = []
    @State private var isLoading = true
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading devices...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if !errorMessage.isEmpty {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") {
                            Task { await loadDevices() }
                        }
                    }
                } else if devices.isEmpty {
                    ContentUnavailableView {
                        Label("No Macs Found", systemImage: "desktopcomputer")
                    } description: {
                        Text("Install Shellspace on your Mac and sign in with the same account to connect.")
                    } actions: {
                        Button("Refresh") {
                            Task { await loadDevices() }
                        }
                    }
                } else {
                    List {
                        Section {
                            ForEach(devices) { device in
                                Button {
                                    selectDevice(device)
                                } label: {
                                    DeviceRow(device: device)
                                }
                            }
                        } header: {
                            Text("Your Macs")
                        } footer: {
                            Text("Tap a Mac to connect. Only online devices can be reached.")
                        }
                    }
                    .refreshable {
                        await loadDevices()
                    }
                }
            }
            .navigationTitle("Select Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign Out") {
                        viewModel.relayAuth.logout()
                    }
                    .foregroundStyle(.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadDevices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await loadDevices()
            }
        }
    }

    private func selectDevice(_ device: RelayDevice) {
        guard device.isOnline else { return }
        viewModel.selectDevice(device)
    }

    private func loadDevices() async {
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        do {
            let token = try await viewModel.relayAuth.validAccessToken()
            devices = try await fetchDevices(token: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchDevices(token: String) async throws -> [RelayDevice] {
        guard let url = URL(string: "\(RelayAuthManager.relayBaseURL)/api/devices") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            throw AuthError.serverError(http?.statusCode ?? 0, "Failed to fetch devices")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Handle both {devices: [...]} and bare array responses
        if let wrapped = try? decoder.decode(DevicesResponse.self, from: data) {
            return wrapped.devices
        }
        return try decoder.decode([RelayDevice].self, from: data)
    }
}

struct DeviceRow: View {
    let device: RelayDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: platformIcon)
                .font(.title2)
                .foregroundStyle(device.isOnline ? .blue : .gray)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(device.isOnline ? .primary : .secondary)

                HStack(spacing: 4) {
                    Text(device.platform.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !device.isOnline, !device.relativeLastSeen.isEmpty {
                        Text("- Last seen \(device.relativeLastSeen)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Online/offline indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(device.isOnline ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(device.isOnline ? "Online" : "Offline")
                    .font(.caption)
                    .foregroundStyle(device.isOnline ? .green : .secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(device.isOnline ? 1.0 : 0.6)
    }

    private var platformIcon: String {
        switch device.platform.lowercased() {
        case "macos", "mac": return "desktopcomputer"
        case "linux": return "server.rack"
        default: return "desktopcomputer"
        }
    }
}
