import SwiftUI

struct BrowseView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    @State private var isSearchActive = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                ProjectsListView()

                if !searchText.isEmpty {
                    SearchResultsView(
                        query: searchText,
                        sessions: viewModel.allSessions,
                        onSelect: { session in
                            searchText = ""
                            isSearchActive = false
                            navigationPath.append(session)
                        }
                    )
                    .background(Color(UIColor.systemBackground))
                }
            }
            .navigationTitle("Projects")
            .searchable(
                text: $searchText,
                isPresented: $isSearchActive,
                placement: .navigationBarDrawer(displayMode: .always)
            )
            .navigationDestination(for: RemoteProject.self) { project in
                SessionsListView(project: project)
            }
            .navigationDestination(for: RemoteSession.self) { session in
                TerminalView(session: session)
                    .environment(viewModel)
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
            .onChange(of: viewModel.pendingSessionId) { _, sessionId in
                guard let sessionId else { return }
                if let session = viewModel.allSessions.first(where: { $0.id == sessionId }) {
                    viewModel.pendingSessionId = nil
                    navigationPath.append(session)
                } else {
                    viewModel.pendingSessionId = nil
                }
            }
            .onChange(of: viewModel.activateSearch) { _, activate in
                guard activate else { return }
                viewModel.activateSearch = false
                isSearchActive = true
            }
            .onAppear {
                if !navigationPath.isEmpty && viewModel.pendingSessionId == nil {
                    navigationPath = NavigationPath()
                }
                if let sessionId = viewModel.pendingSessionId,
                   let session = viewModel.allSessions.first(where: { $0.id == sessionId }) {
                    viewModel.pendingSessionId = nil
                    navigationPath.append(session)
                }
            }
        }
    }
}
