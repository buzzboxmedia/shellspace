import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Active sessions
            if !appState.sessions.isEmpty {
                Text("ACTIVE SESSIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(appState.sessions.prefix(5)) { session in
                    MenuBarSessionRow(session: session)
                }

                Divider()
                    .padding(.vertical, 4)
            }

            // Quick access to projects
            Text("NEW CHAT IN...")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(appState.mainProjects) { project in
                MenuBarProjectRow(project: project)
            }

            Divider()
                .padding(.vertical, 2)

            ForEach(appState.clientProjects) { project in
                MenuBarProjectRow(project: project)
            }

            Divider()
                .padding(.vertical, 4)

            Button("Quit Claude Hub") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 220)
        .padding(.vertical, 4)
    }
}

struct MenuBarSessionRow: View {
    @EnvironmentObject var appState: AppState
    let session: Session
    @State private var isHovered = false

    var projectName: String {
        let allProjects = appState.mainProjects + appState.clientProjects
        return allProjects.first { $0.path == session.projectPath }?.name ?? "Unknown"
    }

    var body: some View {
        Button {
            // Just open the app - user can select session in their preferred window
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.system(size: 12))
                        .lineLimit(1)

                    Text(projectName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovered ? Color.white.opacity(0.1) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct MenuBarProjectRow: View {
    @EnvironmentObject var appState: AppState
    let project: Project
    @State private var isHovered = false

    var body: some View {
        Button {
            // Just open the app - user can select project in their preferred window
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            HStack {
                Image(systemName: project.icon)
                    .font(.system(size: 11))
                    .frame(width: 16)

                Text(project.name)
                    .font(.system(size: 12))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(isHovered ? Color.white.opacity(0.1) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// Preview available in Xcode only
