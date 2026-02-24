import SwiftUI

@main
struct ShellspaceIOSApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
        }
    }
}

struct ContentView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        Group {
            if viewModel.macHost.isEmpty {
                SettingsSheet(isPresented: .constant(true), isInitialSetup: true)
            } else {
                TabView(selection: $vm.selectedTab) {
                    WaitingView()
                        .tabItem {
                            Label("Waiting", systemImage: "bell.badge")
                        }
                        .badge(viewModel.waitingSessions.count)
                        .tag(AppTab.waiting)

                    BrowseView()
                        .tabItem {
                            Label("Browse", systemImage: "folder")
                        }
                        .tag(AppTab.browse)
                }
                .overlay(alignment: .topTrailing) {
                    ConnectionDot()
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                }
                .sheet(isPresented: $vm.showSettings) {
                    SettingsSheet(isPresented: $vm.showSettings)
                }
                .task {
                    await viewModel.connectAndLoad()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    Task { await viewModel.refresh() }
                }
            }
        }
    }
}

enum AppTab: Hashable {
    case waiting
    case browse
}

struct ConnectionDot: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        Button {
            viewModel.showSettings = true
        } label: {
            Circle()
                .fill(viewModel.connectionState.color)
                .frame(width: 10, height: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection: \(viewModel.connectionState.label)")
    }
}
