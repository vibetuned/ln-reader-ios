import Foundation
import UserNotifications

/// Posts the "sleep timer expired" notification with Postpone / Dismiss actions
/// and routes the responses back (the iOS analog of Android's
/// SleepTimerNotifier + PostponeReceiver).
@MainActor
final class SleepTimerNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let categoryId = "SLEEP_TIMER_EXPIRED"
    private static let postponeActionId = "POSTPONE"
    private static let dismissActionId = "DISMISS"
    private static let requestId = "sleep-timer-expired"

    var onPostpone: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryId,
                actions: [
                    UNNotificationAction(identifier: Self.postponeActionId, title: "Postpone"),
                    UNNotificationAction(identifier: Self.dismissActionId, title: "Dismiss"),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func postExpired() {
        let content = UNMutableNotificationContent()
        content.title = "Sleep timer"
        content.body = "Playback paused. Shake to postpone."
        content.categoryIdentifier = Self.categoryId
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.requestId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func clearExpired() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestId])
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestId])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionId = response.actionIdentifier
        await MainActor.run {
            switch actionId {
            case Self.postponeActionId: onPostpone?()
            case Self.dismissActionId, UNNotificationDismissActionIdentifier: onDismiss?()
            default: break
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
