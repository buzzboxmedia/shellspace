import SwiftUI
import UserNotifications

@main
struct ShellspaceLiteApp: App {
    @State private var viewModel = AppViewModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
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

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let sessionId = userInfo["sessionId"] as? String {
            Task { @MainActor in
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
            LiteMainView()
                .environment(viewModel)
        }
    }
}

// MARK: - Main View (single screen, no tabs)

struct LiteMainView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        LiteSessionsView()
            .sheet(isPresented: $vm.showSettings) {
                SettingsSheet(isPresented: $vm.showSettings)
            }
            .task {
                if viewModel.selectedDeviceId != nil && !viewModel.connectionState.isConnected {
                    viewModel.connectToRelay()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                if viewModel.selectedDeviceId != nil && !viewModel.connectionState.isConnected {
                    viewModel.connectToRelay()
                }
            }
    }
}
