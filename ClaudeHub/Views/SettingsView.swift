import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "anthropic_api_key") ?? ""
    @State private var isAPIKeyVisible = false

    // Notification settings (bound to NotificationManager)
    @ObservedObject private var notificationManager = NotificationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Projects")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Main Projects Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("MAIN PROJECTS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addProject(isClient: false)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ForEach(appState.mainProjects) { project in
                    ProjectRow(project: project, isClient: false)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Client Projects Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CLIENTS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addProject(isClient: true)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)

                ForEach(appState.clientProjects) { project in
                    ProjectRow(project: project, isClient: true)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // API Key Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("API KEY")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !apiKey.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 16)

                HStack(spacing: 8) {
                    if isAPIKeyVisible {
                        TextField("sk-ant-...", text: $apiKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(6)
                    } else {
                        SecureField("sk-ant-...", text: $apiKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(6)
                    }

                    Button {
                        isAPIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        UserDefaults.standard.set(apiKey, forKey: "anthropic_api_key")
                    } label: {
                        Text("Save")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)

                Text("Used for auto-generating chat titles")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            }

            Divider()
                .padding(.vertical, 8)

            // Notifications Section
            VStack(alignment: .leading, spacing: 12) {
                Text("NOTIFICATIONS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 10) {
                    // Main toggle
                    Toggle("Notify when Claude is waiting", isOn: $notificationManager.notificationsEnabled)
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .padding(.horizontal, 16)

                    // Sub-options (indented, dimmed when disabled)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Style")
                                .font(.system(size: 12))
                                .foregroundStyle(notificationManager.notificationsEnabled ? .primary : .tertiary)

                            Spacer()

                            Picker("", selection: $notificationManager.notificationStyle) {
                                ForEach(NotificationStyle.allCases, id: \.self) { style in
                                    Text(style.rawValue).tag(style)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                            .disabled(!notificationManager.notificationsEnabled)
                        }

                        Toggle("Play sound", isOn: $notificationManager.playSound)
                            .font(.system(size: 12))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .foregroundStyle(notificationManager.notificationsEnabled ? .primary : .tertiary)
                            .disabled(!notificationManager.notificationsEnabled)

                        Toggle("Only when in background", isOn: $notificationManager.onlyWhenInBackground)
                            .font(.system(size: 12))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .foregroundStyle(notificationManager.notificationsEnabled ? .primary : .tertiary)
                            .disabled(!notificationManager.notificationsEnabled)
                    }
                    .padding(.leading, 24)
                    .padding(.horizontal, 16)
                }
            }

            Spacer()

            Divider()

            // About Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ABOUT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                HStack {
                    Text("ClaudeHub")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("v\(AppVersion.version)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)

                HStack {
                    Text("Build: \(AppVersion.buildHash)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Check for Updates") {
                        checkForUpdates()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()

            // Footer
            HStack {
                Text("Click + to add a folder from your Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 350, height: 580)
        .background(.ultraThinMaterial)
    }

    func checkForUpdates() {
        // Open GitHub releases page
        if let url = URL(string: "https://github.com/buzzboxmedia/claudehub/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    func addProject(isClient: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to add as a project"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                let name = url.lastPathComponent
                let path = url.path
                let icon = "folder.fill"

                let project = Project(name: name, path: path, icon: icon)

                if isClient {
                    appState.addClientProject(project)
                } else {
                    appState.addMainProject(project)
                }
            }
        }
    }
}

struct ProjectRow: View {
    @EnvironmentObject var appState: AppState
    let project: Project
    let isClient: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: project.icon)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))

                Text(displayPath(project.path))
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered {
                Button {
                    if isClient {
                        appState.removeClientProject(project)
                    } else {
                        appState.removeMainProject(project)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovered = $0 }
    }

    func displayPath(_ path: String) -> String {
        // Show just the last 2 path components for cleaner look
        let components = path.split(separator: "/")
        if components.count >= 2 {
            let lastTwo = components.suffix(2).joined(separator: "/")
            return ".../" + lastTwo
        }
        return path
    }
}

// Preview
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppState())
    }
}
