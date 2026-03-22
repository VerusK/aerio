import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "AgMail", category: "NotificationManager")

protocol NotificationProvider: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: NotificationProvider, @unchecked @retroactive Sendable {}

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    private let center: NotificationProvider
    private(set) var isAuthorized = false

    /// Callback fired when a notification is clicked. Provides (emailId, accountId).
    var onNotificationClick: ((String, String) -> Void)?

    init(center: NotificationProvider = UNUserNotificationCenter.current()) {
        self.center = center
        super.init()
        if let realCenter = center as? UNUserNotificationCenter {
            realCenter.delegate = self
        }
    }

    func requestPermission() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            logger.debug("Notification permission \(granted ? "granted" : "denied")")
        } catch {
            logger.error("Failed to request notification permission: \(error.localizedDescription)")
        }
    }

    func showNotification(from sender: String, subject: String, snippet: String, emailId: String, accountId: String) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = sender
        content.subtitle = subject
        content.body = String(snippet.prefix(100))
        content.userInfo = ["emailId": emailId, "accountId": accountId]
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "agmail_\(accountId)_\(emailId)",
            content: content,
            trigger: nil
        )

        Task {
            do {
                try await center.add(request)
                logger.debug("Notification sent for email \(emailId)")
            } catch {
                logger.error("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    /// Determine which emails from a sync result are new inbox+unread and should trigger notifications.
    static func newInboxUnreadEmails(newEmails: [Email], previousEmailIds: Set<String>) -> [Email] {
        newEmails.filter { email in
            email.folder == .inbox
            && !email.isRead
            && !previousEmailIds.contains(email.msgId)
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let emailId = userInfo["emailId"] as? String,
              let accountId = userInfo["accountId"] as? String else {
            completionHandler()
            return
        }

        completionHandler()
        Task { @MainActor in
            onNotificationClick?(emailId, accountId)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound])
    }
}
