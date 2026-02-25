import SwiftUI
import UserNotifications

@main
struct ShellspaceIOSApp: App {
    @State private var viewModel = AppViewModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Handle shellspace:// deep links
    /// - shellspace://browse — switch to Browse tab
    /// - shellspace://waiting — switch to Waiting tab
    /// - shellspace://session/{id} — open terminal for session
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "shellspace" else { return }
        let host = url.host ?? ""
        switch host {
        case "browse", "projects":
            viewModel.selectedTab = .projects
        case "waiting", "inbox":
            viewModel.selectedTab = .inbox
        case "sessions":
            viewModel.selectedTab = .sessions
        case "session":
            let sessionId = url.pathComponents.dropFirst().first ?? ""
            guard !sessionId.isEmpty else { return }
            viewModel.selectedTab = .sessions
            viewModel.pendingSessionId = sessionId
        default:
            break
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    WebSocketManager.requestNotificationPermission()
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }
}

/// Handles notification taps to deep-link into sessions.
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var viewModel: AppViewModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Called when user taps a notification while app is in foreground or background.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let sessionId = userInfo["sessionId"] as? String {
            Task { @MainActor in
                viewModel?.selectedTab = .inbox
                viewModel?.pendingSessionId = sessionId
            }
        }
        completionHandler()
    }

    /// Show notifications even when app is in foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
                            Label("Inbox", systemImage: "bell.badge")
                        }
                        .badge(viewModel.waitingSessions.count)
                        .tag(AppTab.inbox)

                    AllSessionsView()
                        .tabItem {
                            Label("Sessions", systemImage: "text.bubble")
                        }
                        .tag(AppTab.sessions)

                    BrowseView()
                        .tabItem {
                            Label("Projects", systemImage: "folder")
                        }
                        .tag(AppTab.projects)
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
                    viewModel.handleLaunchArguments()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    Task { await viewModel.refresh() }
                }
            }
        }
    }
}

enum AppTab: Hashable {
    case inbox
    case sessions
    case projects
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
