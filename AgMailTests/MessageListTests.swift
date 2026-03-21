import XCTest
@testable import AgMail

@MainActor
final class MessageListTests: XCTestCase {

    private func makeTestEnvironment() -> (AccountManager, GmailScraperManager, UnifiedMailbox) {
        let defaults = UserDefaults(suiteName: "MessageListTests-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let scraperManager = GmailScraperManager(accountManager: accountManager)
        let mailbox = UnifiedMailbox(scraperManager: scraperManager)
        return (accountManager, scraperManager, mailbox)
    }

    private func makeSampleEmails() -> (Account, Account, [Email]) {
        let acc1 = Account(id: "acc1", email: "alice@gmail.com", displayName: "Alice", color: .blue)
        let acc2 = Account(id: "acc2", email: "bob@gmail.com", displayName: "Bob", color: .red)

        let now = Date()
        let emails = [
            Email(msgId: "m1", from: "sender1@test.com", subject: "Hello", date: now.addingTimeInterval(-100), snippet: "Preview 1", isRead: false, accountId: "acc1", folder: .inbox),
            Email(msgId: "m2", from: "sender2@test.com", subject: "Meeting", date: now.addingTimeInterval(-200), snippet: "Preview 2", isRead: true, accountId: "acc1", folder: .inbox),
            Email(msgId: "m3", from: "sender3@test.com", subject: "Report", date: now, snippet: "Preview 3", isRead: false, accountId: "acc2", folder: .inbox),
            Email(msgId: "m4", from: "sender4@test.com", subject: "Spam msg", date: now.addingTimeInterval(-50), snippet: "Spam preview", isRead: false, accountId: "acc1", folder: .spam),
            Email(msgId: "m5", from: "sender5@test.com", subject: "Trashed", date: now.addingTimeInterval(-300), snippet: "Trash preview", isRead: true, accountId: "acc2", folder: .trash),
        ]
        return (acc1, acc2, emails)
    }

    // MARK: - Filtering tests

    func testFilteredEmailsShowsOnlySelectedFolder() {
        let (accountManager, scraperManager, mailbox) = makeTestEnvironment()
        let (acc1, acc2, emails) = makeSampleEmails()
        accountManager.addAccount(acc1)
        accountManager.addAccount(acc2)

        scraperManager.emailsByAccount["acc1"] = emails.filter { $0.accountId == "acc1" }
        scraperManager.emailsByAccount["acc2"] = emails.filter { $0.accountId == "acc2" }

        let inboxEmails = mailbox.emails(for: .inbox)
        XCTAssertEqual(inboxEmails.count, 3, "Should show 3 inbox emails from both accounts")

        let spamEmails = mailbox.emails(for: .spam)
        XCTAssertEqual(spamEmails.count, 1, "Should show 1 spam email")
        XCTAssertEqual(spamEmails.first?.subject, "Spam msg")

        let trashEmails = mailbox.emails(for: .trash)
        XCTAssertEqual(trashEmails.count, 1, "Should show 1 trash email")
    }

    func testFilteredEmailsByAccount() {
        let (accountManager, scraperManager, mailbox) = makeTestEnvironment()
        let (acc1, acc2, emails) = makeSampleEmails()
        accountManager.addAccount(acc1)
        accountManager.addAccount(acc2)

        scraperManager.emailsByAccount["acc1"] = emails.filter { $0.accountId == "acc1" }
        scraperManager.emailsByAccount["acc2"] = emails.filter { $0.accountId == "acc2" }

        let acc1Inbox = mailbox.emails(for: .inbox, accountId: "acc1")
        XCTAssertEqual(acc1Inbox.count, 2, "Account 1 should have 2 inbox emails")

        let acc2Inbox = mailbox.emails(for: .inbox, accountId: "acc2")
        XCTAssertEqual(acc2Inbox.count, 1, "Account 2 should have 1 inbox email")
        XCTAssertEqual(acc2Inbox.first?.from, "sender3@test.com")
    }

    func testFilteredEmailsSortedByDateDescending() {
        let (accountManager, scraperManager, mailbox) = makeTestEnvironment()
        let (acc1, acc2, emails) = makeSampleEmails()
        accountManager.addAccount(acc1)
        accountManager.addAccount(acc2)

        scraperManager.emailsByAccount["acc1"] = emails.filter { $0.accountId == "acc1" }
        scraperManager.emailsByAccount["acc2"] = emails.filter { $0.accountId == "acc2" }

        let inboxEmails = mailbox.emails(for: .inbox)
        XCTAssertEqual(inboxEmails.count, 3)
        // Most recent first
        XCTAssertEqual(inboxEmails[0].msgId, "m3", "Most recent email should be first")
        XCTAssertEqual(inboxEmails[1].msgId, "m1")
        XCTAssertEqual(inboxEmails[2].msgId, "m2", "Oldest email should be last")
    }

    func testEmptyFolderReturnsNoEmails() {
        let (_, scraperManager, mailbox) = makeTestEnvironment()
        scraperManager.emailsByAccount["acc1"] = [
            Email(msgId: "m1", from: "x@x.com", subject: "s", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .inbox),
        ]

        let drafts = mailbox.emails(for: .drafts)
        XCTAssertTrue(drafts.isEmpty, "Drafts folder should be empty")
    }

    func testNilAccountIdShowsAllAccounts() {
        let (accountManager, scraperManager, mailbox) = makeTestEnvironment()
        let (acc1, acc2, _) = makeSampleEmails()
        accountManager.addAccount(acc1)
        accountManager.addAccount(acc2)

        scraperManager.emailsByAccount["acc1"] = [
            Email(msgId: "m1", from: "a@a.com", subject: "s1", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .inbox),
        ]
        scraperManager.emailsByAccount["acc2"] = [
            Email(msgId: "m2", from: "b@b.com", subject: "s2", date: Date(), snippet: "", isRead: false, accountId: "acc2", folder: .inbox),
        ]

        let allInbox = mailbox.emails(for: .inbox, accountId: nil)
        XCTAssertEqual(allInbox.count, 2, "nil accountId should show emails from all accounts")
    }

    // MARK: - Email display data tests

    func testEmailIdFormat() {
        let email = Email(msgId: "msg123", from: "test@test.com", subject: "Test", date: Date(), snippet: "sn", accountId: "acc1", folder: .inbox)
        XCTAssertEqual(email.id, "acc1_inbox_msg123", "Email id should be accountId_folder_msgId")
    }

    func testUnreadEmailProperties() {
        let email = Email(msgId: "m1", from: "test@test.com", subject: "Unread", date: Date(), snippet: "snip", isRead: false, accountId: "acc1", folder: .inbox)
        XCTAssertFalse(email.isRead)
    }

    func testReadEmailProperties() {
        let email = Email(msgId: "m1", from: "test@test.com", subject: "Read", date: Date(), snippet: "snip", isRead: true, accountId: "acc1", folder: .inbox)
        XCTAssertTrue(email.isRead)
    }

    // MARK: - Account indicator tests

    func testAccountColorLookup() {
        let accountManager = AccountManager(defaults: UserDefaults(suiteName: "MessageListTests-color-\(UUID().uuidString)")!)
        let acc = Account(id: "acc1", email: "a@gmail.com", displayName: "Alice", color: .red)
        accountManager.addAccount(acc)

        let found = accountManager.account(for: "acc1")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.color, .red, "Account color should be retrievable for indicator")
    }

    func testAccountLookupForUnknownIdReturnsNil() {
        let accountManager = AccountManager(defaults: UserDefaults(suiteName: "MessageListTests-nil-\(UUID().uuidString)")!)
        let found = accountManager.account(for: "nonexistent")
        XCTAssertNil(found, "Unknown account id should return nil")
    }
}
