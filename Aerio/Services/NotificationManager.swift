import Foundation
import UserNotifications
import AppKit
import os.log

private let logger = Logger(subsystem: "Aerio", category: "NotificationManager")

protocol NotificationProvider: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: NotificationProvider, @unchecked @retroactive Sendable {}

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    private let center: NotificationProvider
    private(set) var isAuthorized = false

    static let outboxSuccessCategory = "AERIO_OUTBOX_SUCCESS"
    static let outboxFailureCategory = "AERIO_OUTBOX_FAILURE"
    static let outboxRetryActionId = "AERIO_OUTBOX_RETRY"

    /// Callback fired when a notification is clicked. Provides (emailId, accountId).
    var onNotificationClick: ((String, String) -> Void)?

    /// Callback fired when user taps the Retry action on an outbox failure notification.
    var onOutboxRetry: ((UUID) -> Void)?

    init(center: NotificationProvider = UNUserNotificationCenter.current()) {
        self.center = center
        super.init()
        if let realCenter = center as? UNUserNotificationCenter {
            realCenter.delegate = self
            let retryAction = UNNotificationAction(
                identifier: Self.outboxRetryActionId,
                title: "Retry",
                options: [.foreground]
            )
            let failureCategory = UNNotificationCategory(
                identifier: Self.outboxFailureCategory,
                actions: [retryAction],
                intentIdentifiers: [],
                options: []
            )
            let successCategory = UNNotificationCategory(
                identifier: Self.outboxSuccessCategory,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
            realCenter.setNotificationCategories([failureCategory, successCategory])
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
            identifier: "aerio_\(accountId)_\(emailId)",
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

        if response.actionIdentifier == Self.outboxRetryActionId,
           let idString = userInfo["outboxItemId"] as? String,
           let uuid = UUID(uuidString: idString) {
            completionHandler()
            Task { @MainActor in
                onOutboxRetry?(uuid)
            }
            return
        }

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

/// Adapter from OutboxService's OutboxNotifying protocol to UNUserNotificationCenter.
/// Posts user-visible banners on outbox success and failure.
final class OutboxNotifier: OutboxNotifying {
    weak var manager: NotificationManager?

    init(manager: NotificationManager) {
        self.manager = manager
    }

    func notifySuccess(snapshot: OutboxItemSnapshot) async {
        let isAuthorized = await MainActor.run { manager?.isAuthorized ?? false }
        guard isAuthorized else { return }
        let isFrontmost = await MainActor.run { NSApp?.isActive == true }
        if isFrontmost { return }
        let content = UNMutableNotificationContent()
        content.title = "Sent"
        content.subtitle = snapshot.subject
        content.body = "to \(snapshot.recipientsPreview)"
        content.categoryIdentifier = NotificationManager.outboxSuccessCategory
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "outbox_success_\(snapshot.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func notifyFailure(snapshot: OutboxItemSnapshot, permanent: Bool) async {
        let isAuthorized = await MainActor.run { manager?.isAuthorized ?? false }
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Failed to send"
        content.subtitle = snapshot.subject
        let detail = snapshot.lastError ?? "Unknown error"
        content.body = permanent
            ? "\(detail) — Sign in again to retry."
            : "\(detail) — Tap Retry."
        content.categoryIdentifier = NotificationManager.outboxFailureCategory
        content.userInfo = ["outboxItemId": snapshot.id.uuidString]
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "outbox_failure_\(snapshot.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
