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
    private var generation = 0
    private var checkedRevision = 0
    private var polling = false
    private var requestedPermission = false
    private let service: UserService
    private let tokens: any SessionTokenStorage
    private let defaults: UserDefaults
    private let sleep: (Duration) async throws -> Void
    private let requestPermission: () -> Void
    private let deliver: (UNNotificationRequest) async throws -> Void
    private var translate: (String, String) -> String = { _, fallback in fallback }

    init(service: UserService = UserService(), tokens: any SessionTokenStorage = TokenStore.shared,
         defaults: UserDefaults = .standard,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         requestPermission: @escaping () -> Void = {
             UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
         },
         deliver: @escaping (UNNotificationRequest) async throws -> Void = {
             try await UNUserNotificationCenter.current().add($0)
         }) {
        self.service = service
        self.tokens = tokens
        self.defaults = defaults
        self.sleep = sleep
        self.requestPermission = requestPermission
        self.deliver = deliver
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func start(translate: @escaping (String, String) -> String) {
        self.translate = translate
        guard loop == nil else { return }
        if !requestedPermission {
            requestedPermission = true
            // Permission is optional on iOS. Refusal never blocks the timer or app.
            requestPermission()
        }
        generation += 1
        let started = generation
        let sleep = self.sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(Self.interval) }
                catch { return }
                guard !Task.isCancelled, let self, self.generation == started else { return }
                await self.poll()
            }
        }
    }

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        unread = 0
        openNotificationsRequested = false
        defaults.set(0, forKey: Self.lastCountKey)
    }

    /// Opening Notifications: everything up to now counts as seen.
    func markChecked() {
        checkedRevision += 1
        NotificationsBadge.markChecked()
        defaults.set(0, forKey: Self.lastCountKey)
        unread = 0
    }

    func poll() async {
        guard loop != nil, tokens.hasSession, !polling, !Task.isCancelled else { return }
        let started = generation
        let checked = checkedRevision
        polling = true
        defer { polling = false }
        guard let count = try? await service.notificationCount(checkedAt: NotificationsBadge.checkedAt),
              !Task.isCancelled, loop != nil, generation == started,
              checkedRevision == checked, tokens.hasSession else { return }
        unread = count
        let previous = defaults.integer(forKey: Self.lastCountKey)
        guard count != previous else { return }
        defaults.set(count, forKey: Self.lastCountKey)
        guard count > previous else { return }
        let content = UNMutableNotificationContent()
        content.title = translate("general_notification_title", "New Notification(s)")
        content.body = translate("general_notification_message", "You have ??? new notification(s).")
            .replacingOccurrences(of: "???", with: String(count - previous))
        content.sound = .default
        let request = UNNotificationRequest(identifier: "carezaar.notifications", content: content, trigger: nil)
        try? await deliver(request)
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
