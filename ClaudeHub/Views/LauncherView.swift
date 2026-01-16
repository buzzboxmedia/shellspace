import SwiftUI

struct LauncherView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    @State private var showSettings = false

    /// Open the Buzzbox Task Log spreadsheet
    private func openTaskLogSpreadsheet() {
        let idFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudehub/task_log_sheet_id.txt")

        if let spreadsheetId = try? String(contentsOf: idFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            let url = URL(string: "https://docs.google.com/spreadsheets/d/\(spreadsheetId)")!
            NSWorkspace.shared.open(url)
        } else {
            // No spreadsheet yet - open Google Sheets home
            NSWorkspace.shared.open(URL(string: "https://sheets.google.com")!)
        }
    }

    var body: some View {
        ZStack {
            // Glass background
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 40) {
                // Header with settings button
                HStack {
                    Spacer()
                    Text("Claude Hub")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .overlay(alignment: .trailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }

                VStack(spacing: 32) {
                    // Main Projects Section
                    VStack(alignment: .leading, spacing: 20) {
                        Text("PROJECTS")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(1.5)

                        HStack(spacing: 16) {
                            ForEach(appState.mainProjects) { project in
                                ProjectCard(project: project)
                            }
                        }
                    }

                    // Clients Section
                    VStack(alignment: .leading, spacing: 20) {
                        Text("CLIENTS")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(1.5)

                        HStack(spacing: 16) {
                            ForEach(appState.clientProjects) { project in
                                ProjectCard(project: project)
                            }
                        }
                    }

                    Divider()
                        .padding(.vertical, 8)

                    // Development Section (ClaudeHub itself)
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("DEVELOPMENT")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.orange)
                                .tracking(1.5)

                            Spacer()

                            // Link to Task Log spreadsheet
                            Button {
                                openTaskLogSpreadsheet()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "tablecells")
                                        .font(.system(size: 12))
                                    Text("Task Log")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help("Open Buzzbox Task Log in Google Sheets")
                        }

                        HStack(spacing: 16) {
                            ForEach(appState.devProjects) { project in
                                ProjectCard(project: project)
                            }
                        }
                    }
                }
            }
            .padding(48)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

struct ProjectCard: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var windowState: WindowState
    let project: Project
    @State private var isHovered = false

    /// Count of sessions waiting for user input (not total sessions)
    var waitingCount: Int {
        appState.waitingCountFor(project: project)
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                windowState.selectedProject = project
            }
        } label: {
            VStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: project.icon)
                        .font(.system(size: 36))
                        .foregroundStyle(.primary)

                    // Show badge only when sessions need attention
                    if waitingCount > 0 {
                        Text("\(waitingCount)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.orange)
                            .clipShape(Circle())
                            .offset(x: 10, y: -10)
                    }
                }

                Text(project.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 120, height: 120)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 16 : 10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// NSVisualEffectView wrapper for glass effect
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// Preview available in Xcode only
