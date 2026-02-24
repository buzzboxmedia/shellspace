import SwiftUI

struct BrowseView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            ProjectsListView()
                .navigationTitle("Projects")
                .navigationDestination(for: RemoteProject.self) { project in
                    SessionsListView(project: project)
                }
                .navigationDestination(for: RemoteSession.self) { session in
                    TerminalView(session: session)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
    }
}
