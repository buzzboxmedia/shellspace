import SwiftUI
import UserNotifications

@main
struct ShellspaceIOSApp: App {
    @State private var viewModel = AppViewModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Handle shellspace:// deep links
    /// - shellspace://browse -- switch to Browse tab
    /// - shellspace://waiting -- switch to Waiting tab
    /// - shellspace://session/{id} -- open terminal for session
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
            RootView()
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

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Root View (auth routing)

struct RootView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        switch viewModel.currentScreen {
        case .login:
            LoginView()
                .environment(viewModel)
        case .devicePicker:
            DevicePickerView()
                .environment(viewModel)
        case .main:
            ContentView()
                .environment(viewModel)
        }
    }
}

// MARK: - Main Content (tabs)

struct ContentView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

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
        .sheet(isPresented: $vm.showSettings) {
            SettingsSheet(isPresented: $vm.showSettings)
        }
        .task {
            // Auto-connect to relay if we have a selected device
            if viewModel.selectedDeviceId != nil && !viewModel.connectionState.isConnected {
                viewModel.connectToRelay()
            }
            viewModel.handleLaunchArguments()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Reconnect if needed when coming back to foreground
            if viewModel.selectedDeviceId != nil && !viewModel.connectionState.isConnected {
                viewModel.connectToRelay()
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
