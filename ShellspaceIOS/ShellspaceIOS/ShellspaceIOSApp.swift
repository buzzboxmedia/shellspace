import SwiftUI
import UserNotifications

@main
struct ShellspaceIOSApp: App {
    @State private var viewModel = AppViewModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    WebSocketManager.requestNotificationPermission()
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
                viewModel?.selectedTab = .waiting
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
