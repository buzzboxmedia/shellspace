import SwiftUI

struct ProjectsListView: View {
    @Environment(AppViewModel.self) private var viewModel

    private var groupedProjects: [(String, [RemoteProject])] {
        let categories = ["main": "Main Projects", "client": "Clients", "dev": "Development"]
        let grouped = Dictionary(grouping: viewModel.projects) { $0.category }
        return ["main", "client", "dev"].compactMap { key in
            guard let projects = grouped[key], !projects.isEmpty else { return nil }
            return (categories[key] ?? key, projects)
        }
    }

    var body: some View {
        Group {
            if viewModel.projects.isEmpty && !viewModel.connectionState.isConnected {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "wifi.slash",
                    description: Text("Connect to your Mac to see projects")
                )
            } else if viewModel.projects.isEmpty {
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "folder",
                    description: Text("No projects found on your Mac")
                )
            } else {
                List {
                    ForEach(groupedProjects, id: \.0) { category, projects in
                        Section(category) {
                            ForEach(projects) { project in
                                NavigationLink(value: project) {
                                    ProjectRow(project: project)
                                }
                            }
                        }
                    }
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
    }
}

struct ProjectRow: View {
    let project: RemoteProject

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: project.icon)
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 12) {
                    if project.activeSessions > 0 {
                        Label("\(project.activeSessions) active", systemImage: "terminal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if project.waitingSessions > 0 {
                        Label("\(project.waitingSessions) waiting", systemImage: "bell.badge")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
