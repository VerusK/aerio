import XCTest
import UserNotifications
@testable import Aerio

final class MockNotificationProvider: NotificationProvider, @unchecked Sendable {
    var authorizationGranted = true
    var authorizationError: Error?
    var addedRequests: [UNNotificationRequest] = []
    var addError: Error?

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        if let error = authorizationError { throw error }
        return authorizationGranted
    }

    func add(_ request: UNNotificationRequest) async throws {
        if let error = addError { throw error }
        addedRequests.append(request)
    }
}

@MainActor
final class NotificationManagerTests: XCTestCase {

    // MARK: - Permission

    func testRequestPermissionGranted() async {
        let provider = MockNotificationProvider()
        provider.authorizationGranted = true
        let manager = NotificationManager(center: provider)

        await manager.requestPermission()
        XCTAssertTrue(manager.isAuthorized)
    }

    func testRequestPermissionDenied() async {
        let provider = MockNotificationProvider()
        provider.authorizationGranted = false
        let manager = NotificationManager(center: provider)

        await manager.requestPermission()
        XCTAssertFalse(manager.isAuthorized)
    }

    func testRequestPermissionError() async {
        let provider = MockNotificationProvider()
        provider.authorizationError = NSError(domain: "test", code: 1)
        let manager = NotificationManager(center: provider)

        await manager.requestPermission()
        XCTAssertFalse(manager.isAuthorized)
    }

    // MARK: - Notification Content

    func testShowNotificationContent() async {
        let provider = MockNotificationProvider()
        provider.authorizationGranted = true
        let manager = NotificationManager(center: provider)
        await manager.requestPermission()

        manager.showNotification(
            from: "Alice",
            subject: "Hello",
            snippet: "This is a test message",
            emailId: "msg123",
            accountId: "acc456"
        )

        // Wait briefly for the Task inside showNotification to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(provider.addedRequests.count, 1)
        let request = provider.addedRequests.first!
        XCTAssertEqual(request.content.title, "Alice")
        XCTAssertEqual(request.content.subtitle, "Hello")
        XCTAssertEqual(request.content.body, "This is a test message")
        XCTAssertEqual(request.content.userInfo["emailId"] as? String, "msg123")
        XCTAssertEqual(request.content.userInfo["accountId"] as? String, "acc456")
        XCTAssertEqual(request.identifier, "aerio_acc456_msg123")
    }

    func testShowNotificationNotAuthorized() async {
        let provider = MockNotificationProvider()
        provider.authorizationGranted = false
        let manager = NotificationManager(center: provider)
        await manager.requestPermission()

        manager.showNotification(
            from: "Alice",
            subject: "Hello",
            snippet: "Test",
            emailId: "msg123",
            accountId: "acc456"
        )

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(provider.addedRequests.isEmpty)
    }

    func testShowNotificationTruncatesLongSnippet() async {
        let provider = MockNotificationProvider()
        provider.authorizationGranted = true
        let manager = NotificationManager(center: provider)
        await manager.requestPermission()

        let longSnippet = String(repeating: "a", count: 200)
        manager.showNotification(
            from: "Bob",
            subject: "Long",
            snippet: longSnippet,
            emailId: "msg1",
            accountId: "acc1"
        )

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.addedRequests.first?.content.body.count, 100)
    }

    // MARK: - Trigger Conditions (newInboxUnreadEmails)

    func testNewInboxUnreadEmailsFiltersCorrectly() {
        let inboxUnread = Email(msgId: "1", from: "A", subject: "S", date: Date(), snippet: "",
                                isRead: false, accountId: "acc", folder: .inbox)
        let inboxRead = Email(msgId: "2", from: "B", subject: "S", date: Date(), snippet: "",
                              isRead: true, accountId: "acc", folder: .inbox)
        let sentUnread = Email(msgId: "3", from: "C", subject: "S", date: Date(), snippet: "",
                               isRead: false, accountId: "acc", folder: .sent)
        let existingUnread = Email(msgId: "4", from: "D", subject: "S", date: Date(), snippet: "",
                                   isRead: false, accountId: "acc", folder: .inbox)

        let newEmails = [inboxUnread, inboxRead, sentUnread, existingUnread]
        let previousIds: Set<String> = ["4"] // existingUnread already known

        let result = NotificationManager.newInboxUnreadEmails(
            newEmails: newEmails,
            previousEmailIds: previousIds
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.msgId, "1")
    }

    func testNewInboxUnreadEmailsEmptyWhenAllExisting() {
        let email = Email(msgId: "1", from: "A", subject: "S", date: Date(), snippet: "",
                          isRead: false, accountId: "acc", folder: .inbox)

        let result = NotificationManager.newInboxUnreadEmails(
            newEmails: [email],
            previousEmailIds: ["1"]
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testNewInboxUnreadEmailsEmptyWhenNoEmails() {
        let result = NotificationManager.newInboxUnreadEmails(
            newEmails: [],
            previousEmailIds: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Notification Click

    func testOnNotificationClickCallback() async {
        let provider = MockNotificationProvider()
        let manager = NotificationManager(center: provider)

        var receivedEmailId: String?
        var receivedAccountId: String?
        manager.onNotificationClick = { emailId, accountId in
            receivedEmailId = emailId
            receivedAccountId = accountId
        }

        // Simulate the callback directly since we can't easily create UNNotificationResponse
        manager.onNotificationClick?("msg123", "acc456")

        XCTAssertEqual(receivedEmailId, "msg123")
        XCTAssertEqual(receivedAccountId, "acc456")
    }
}
