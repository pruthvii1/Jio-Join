import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    static let incomingCategoryIdentifier = "JIOJOIN_INCOMING_CALL"
    static let answerActionIdentifier = "JIOJOIN_ANSWER"
    static let declineActionIdentifier = "JIOJOIN_DECLINE"

    private let center = UNUserNotificationCenter.current()
    private let incomingIdentifier = "jiojoin.incoming"
    private var answerAction: (() -> Void)?
    private var declineAction: (() -> Void)?

    private override init() {
        super.init()
        center.delegate = self
        let answer = UNNotificationAction(
            identifier: Self.answerActionIdentifier,
            title: "Answer",
            options: []
        )
        let decline = UNNotificationAction(
            identifier: Self.declineActionIdentifier,
            title: "Decline",
            options: [.destructive]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.incomingCategoryIdentifier,
                actions: [answer, decline],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func configureCallActions(answer: @escaping () -> Void, decline: @escaping () -> Void) {
        answerAction = answer
        declineAction = decline
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationDescription() async -> String {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return "Allowed"
        case .denied: return "Blocked in System Settings"
        case .notDetermined: return "Not requested"
        case .provisional: return "Delivered quietly"
        case .ephemeral: return "Temporary permission"
        @unknown default: return "Unknown"
        }
    }

    func showIncomingCall(from caller: String) {
        guard UserDefaults.standard.object(forKey: "JioJoinNotificationsEnabled") as? Bool ?? true else { return }
        center.removeDeliveredNotifications(withIdentifiers: [incomingIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [incomingIdentifier])
        let content = UNMutableNotificationContent()
        content.title = "Incoming JioFiber call"
        content.body = caller
        content.sound = .default
        content.categoryIdentifier = Self.incomingCategoryIdentifier
        center.add(UNNotificationRequest(identifier: incomingIdentifier, content: content, trigger: nil))
    }

    func clearIncomingCall() {
        center.removeDeliveredNotifications(withIdentifiers: [incomingIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [incomingIdentifier])
    }

    func showMissedCall(from caller: String) {
        guard UserDefaults.standard.object(forKey: "JioJoinNotificationsEnabled") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Missed JioFiber call"
        content.body = caller
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "jiojoin.missed.\(UUID().uuidString)", content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action: (() -> Void)?
        switch response.actionIdentifier {
        case Self.answerActionIdentifier: action = answerAction
        case Self.declineActionIdentifier: action = declineAction
        default: action = nil
        }
        if let action { DispatchQueue.main.async(execute: action) }
        completionHandler()
    }
}
