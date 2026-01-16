import Foundation
import UserNotifications
import AppKit
import os.log

private let notificationLogger = Logger(subsystem: "com.buzzbox.claudehub", category: "NotificationManager")

/// Notification style options
enum NotificationStyle: String, CaseIterable, Codable {
    case banner = "Banner"
    case alert = "Alert"
    case none = "None"
}

/// Manages macOS notifications and dock badges for Claude waiting states
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    // Settings (persisted via UserDefaults)
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var notificationStyle: NotificationStyle {
        didSet { UserDefaults.standard.set(notificationStyle.rawValue, forKey: "notificationStyle") }
    }
    @Published var playSound: Bool {
        didSet { UserDefaults.standard.set(playSound, forKey: "notificationPlaySound") }
    }
    @Published var onlyWhenInBackground: Bool {
        didSet { UserDefaults.standard.set(onlyWhenInBackground, forKey: "notificationOnlyBackground") }
    }

    // Track which sessions we've already notified about (to avoid spam)
    private var notifiedSessions: Set<UUID> = []

    private init() {
        // Load settings from UserDefaults
        self.notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        self.notificationStyle = NotificationStyle(rawValue: UserDefaults.standard.string(forKey: "notificationStyle") ?? "") ?? .banner
        self.playSound = UserDefaults.standard.object(forKey: "notificationPlaySound") as? Bool ?? false
        self.onlyWhenInBackground = UserDefaults.standard.object(forKey: "notificationOnlyBackground") as? Bool ?? true

        requestPermissionIfNeeded()
    }

    /// Request notification permissions on first launch
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error = error {
                        notificationLogger.error("Notification permission error: \(error.localizedDescription)")
                    } else {
                        notificationLogger.info("Notification permission granted: \(granted)")
                    }
                }
            }
        }
    }

    /// Send notification that Claude is waiting for input
    func notifyClaudeWaiting(sessionId: UUID, sessionName: String, projectName: String) {
        guard notificationsEnabled else { return }
        guard notificationStyle != .none else {
            // Still update dock badge even if notifications are disabled
            return
        }

        // Check if we should only notify when in background
        if onlyWhenInBackground && NSApp.isActive {
            notificationLogger.debug("Skipping notification - app is active")
            return
        }

        // Don't spam notifications for the same session
        guard !notifiedSessions.contains(sessionId) else {
            notificationLogger.debug("Already notified for session: \(sessionId)")
            return
        }

        notifiedSessions.insert(sessionId)

        let content = UNMutableNotificationContent()
        content.title = "Claude is waiting"
        content.body = "\(sessionName) in \(projectName)"
        content.categoryIdentifier = "CLAUDE_WAITING"

        if playSound {
            content.sound = .default
        }

        // Create request with unique identifier
        let request = UNNotificationRequest(
            identifier: "claude-waiting-\(sessionId.uuidString)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                notificationLogger.error("Failed to send notification: \(error.localizedDescription)")
            } else {
                notificationLogger.info("Sent notification for session: \(sessionName)")
            }
        }
    }

    /// Clear notification state when user views session
    func clearNotification(for sessionId: UUID) {
        notifiedSessions.remove(sessionId)

        // Remove any pending notifications for this session
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["claude-waiting-\(sessionId.uuidString)"]
        )
    }

    /// Update the dock badge with total waiting count
    func updateDockBadge(count: Int) {
        DispatchQueue.main.async {
            if count > 0 {
                NSApp.dockTile.badgeLabel = "\(count)"
            } else {
                NSApp.dockTile.badgeLabel = nil
            }
        }
    }

    /// Clear all notifications (e.g., when app becomes active)
    func clearAllNotifications() {
        notifiedSessions.removeAll()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
