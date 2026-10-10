import Foundation
import UIKit
import UserNotifications

/// Android polls `users/notifications/count?checked_at=` every 30 s while the app runs.
/// When the count rises it posts a system notification ("New Notification(s)" /
/// "You have N new notification(s).") that opens Notifications, and the bell badge
/// follows the count. This reproduces that with a local notification.
@MainActor
final class NotificationPoller: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var unread = 0
    /// Set when the user taps a notification; the app routes to Notifications.
    @Published var openNotificationsRequested = false

    private static let lastCountKey = "carezaar.notificationCount"
    private static let interval: Duration = .seconds(30)
    private var loop: Task<Void, Never>?
    private var translate: (String, String) -> String = { _, fallback in fallback }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func start(translate: @escaping (String, String) -> String) {
        self.translate = translate
        guard loop == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        unread = 0
    }

    /// Opening Notifications: everything up to now counts as seen.
    func markChecked() {
        NotificationsBadge.markChecked()
        UserDefaults.standard.set(0, forKey: Self.lastCountKey)
        unread = 0
    }

    func poll() async {
        guard TokenStore.shared.hasSession,
              let count = try? await UserService().notificationCount(checkedAt: NotificationsBadge.checkedAt) else { return }
        unread = count
        let previous = UserDefaults.standard.integer(forKey: Self.lastCountKey)
        guard count != previous else { return }
        UserDefaults.standard.set(count, forKey: Self.lastCountKey)
        guard count > previous else { return }
        let content = UNMutableNotificationContent()
        content.title = translate("general_notification_title", "New Notification(s)")
        content.body = translate("general_notification_message", "You have ??? new notification(s).")
            .replacingOccurrences(of: "???", with: String(count - previous))
        content.sound = .default
        let request = UNNotificationRequest(identifier: "carezaar.notifications", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // Android shows the notification even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.openNotificationsRequested = true }
        completionHandler()
    }
}
