import XCTest
@testable import AgMail

@MainActor
final class UnifiedMailboxTests: XCTestCase {

    private func makeEmail(
        msgId: String = "msg1",
        from: String = "sender@test.com",
        subject: String = "Test",
        date: Date = Date(),
        isRead: Bool = false,
        accountId: String = "acc1",
        folder: Folder = .inbox
    ) -> Email {
        Email(
            msgId: msgId,
            from: from,
            subject: subject,
            date: date,
            snippet: "snippet",
            isRead: isRead,
            accountId: accountId,
            folder: folder
        )
    }

    private func makeManager() -> (AccountManager, GmailAPIManager) {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let am = AccountManager(defaults: defaults)
        let oauth = OAuthManager()
        let api = GmailAPIManager(accountManager: am, oauthManager: oauth)
        return (am, api)
    }

    // MARK: - Merge from multiple accounts

    func testMergeEmailsFromMultipleAccounts() {
        let (_, api) = makeManager()
        let mailbox = UnifiedMailbox(apiManager: api)

        let now = Date()
        let email1 = makeEmail(msgId: "m1", date: now.addingTimeInterval(-100), accountId: "acc1", folder: .inbox)
        let email2 = makeEmail(msgId: "m2", date: now.addingTimeInterval(-50), accountId: "acc2", folder: .inbox)
        let email3 = makeEmail(msgId: "m3", date: now, accountId: "acc1", folder: .inbox)

        api.emailsByAccount["acc1"] = [email1, email3]
        api.emailsByAccount["acc2"] = [email2]

        let merged = mailbox.emails(for: .inbox)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].msgId, "m3")
        XCTAssertEqual(merged[1].msgId, "m2")
        XCTAssertEqual(merged[2].msgId, "m1")
    }

    // MARK: - Sorting

    func testEmailsSortedByDateDescending() {
        let (_, api) = makeManager()
        let mailbox = UnifiedMailbox(apiManager: api)

        let now = Date()
        let oldest = makeEmail(msgId: "old", date: now.addingTimeInterval(-1000), folder: .inbox)
        let middle = makeEmail(msgId: "mid", date: now.addingTimeInterval(-500), folder: .inbox)
        let newest = makeEmail(msgId: "new", date: now, folder: .inbox)

        api.emailsByAccount["acc1"] = [middle, oldest, newest]

        let result = mailbox.emails(for: .inbox)
        XCTAssertEqual(result.map(\.msgId), ["new", "mid", "old"])
    }

    // MARK: - Unread counts

    func testUnreadCountPerFolder() {
        let (_, api) = makeManager()
        let mailbox = UnifiedMailbox(apiManager: api)

        api.emailsByAccount["acc1"] = [
            makeEmail(msgId: "m1", isRead: false, accountId: "acc1", folder: .inbox),
            makeEmail(msgId: "m2", isRead: true, accountId: "acc1", folder: .inbox),
            makeEmail(msgId: "m3", isRead: false, accountId: "acc1", folder: .trash),
        ]
        api.emailsByAccount["acc2"] = [
            makeEmail(msgId: "m4", isRead: false, accountId: "acc2", folder: .inbox),
            makeEmail(msgId: "m5", isRead: false, accountId: "acc2", folder: .spam),
        ]

        XCTAssertEqual(mailbox.unreadCount(for: .inbox), 2)
        XCTAssertEqual(mailbox.unreadCount(for: .trash), 1)
        XCTAssertEqual(mailbox.unreadCount(for: .spam), 1)
        XCTAssertEqual(mailbox.unreadCount(for: .archive), 0)
        XCTAssertEqual(mailbox.unreadCount(for: .drafts), 0)
    }

    func testUnreadCountPerFolderPerAccount() {
        let (_, api) = makeManager()
        let mailbox = UnifiedMailbox(apiManager: api)

        api.emailsByAccount["acc1"] = [
            makeEmail(msgId: "m1", isRead: false, accountId: "acc1", folder: .inbox),
            makeEmail(msgId: "m2", isRead: false, accountId: "acc1", folder: .inbox),
        ]
        api.emailsByAccount["acc2"] = [
            makeEmail(msgId: "m3", isRead: false, accountId: "acc2", folder: .inbox),
        ]

        XCTAssertEqual(mailbox.unreadCount(for: .inbox, accountId: "acc1"), 2)
        XCTAssertEqual(mailbox.unreadCount(for: .inbox, accountId: "acc2"), 1)
    }

    // MARK: - Filter by account

    func testEmailsFilteredByAccount() {
        let (_, api) = makeManager()
        let mailbox = UnifiedMailbox(apiManager: api)

        api.emailsByAccount["acc1"] = [
            makeEmail(msgId: "m1", accountId: "acc1", folder: .inbox),
        ]
        api.emailsByAccount["acc2"] = [
            makeEmail(msgId: "m2", accountId: "acc2", folder: .inbox),
        ]

        let acc1Emails = mailbox.emails(for: .inbox, accountId: "acc1")
        XCTAssertEqual(acc1Emails.count, 1)
        XCTAssertEqual(acc1Emails[0].msgId, "m1")

        let allEmails = mailbox.emails(for: .inbox)
        XCTAssertEqual(allEmails.count, 2)
    }

    // MARK: - Filter by folder

    func testEmailsFilteredByFolder() {
        let (_, api) = makeManager()
        let mailbox = UnifiedMailbox(apiManager: api)

        api.emailsByAccount["acc1"] = [
            makeEmail(msgId: "m1", folder: .inbox),
            makeEmail(msgId: "m2", folder: .trash),
            makeEmail(msgId: "m3", folder: .spam),
        ]

        XCTAssertEqual(mailbox.emails(for: .inbox).count, 1)
        XCTAssertEqual(mailbox.emails(for: .trash).count, 1)
        XCTAssertEqual(mailbox.emails(for: .spam).count, 1)
        XCTAssertEqual(mailbox.emails(for: .archive).count, 0)
    }

    // MARK: - Empty state

    func testEmptyMailbox() {
        let (_, api) = makeManager()
        let mailbox = UnifiedMailbox(apiManager: api)

        XCTAssertEqual(mailbox.emails(for: .inbox).count, 0)
        XCTAssertEqual(mailbox.unreadCount(for: .inbox), 0)
    }
}
