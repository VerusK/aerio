import XCTest
@testable import AgMail

@MainActor
final class ViewTests: XCTestCase {

    // MARK: - AccountSidebar data tests

    func testAccountSidebarDisplaysAllAccounts() {
        let defaults = UserDefaults(suiteName: "ViewTests-\(UUID().uuidString)")!
        let manager = AccountManager(defaults: defaults)
        let acc1 = Account(email: "a@gmail.com", displayName: "Alice", color: .blue)
        let acc2 = Account(email: "b@gmail.com", displayName: "Bob", color: .red)
        manager.addAccount(acc1)
        manager.addAccount(acc2)

        XCTAssertEqual(manager.accounts.count, 2)
        XCTAssertEqual(manager.accounts[0].avatarLetter, "A")
        XCTAssertEqual(manager.accounts[1].avatarLetter, "B")
        XCTAssertEqual(manager.accounts[0].color, .blue)
        XCTAssertEqual(manager.accounts[1].color, .red)
    }

    // MARK: - FolderList data tests

    func testFolderListShowsAllFolders() {
        let folders = Folder.allCases
        XCTAssertEqual(folders.count, 5)
        XCTAssertEqual(folders.map(\.displayName), ["Inbox", "Archive", "Trash", "Spam", "Drafts"])
    }

    func testFolderIconNames() {
        XCTAssertEqual(Folder.inbox.iconName, "tray.fill")
        XCTAssertEqual(Folder.archive.iconName, "archivebox.fill")
        XCTAssertEqual(Folder.trash.iconName, "trash.fill")
        XCTAssertEqual(Folder.spam.iconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(Folder.drafts.iconName, "doc.fill")
    }

    func testUnreadCountsPerFolder() {
        let defaults = UserDefaults(suiteName: "ViewTests-counts-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let scraperManager = GmailScraperManager(accountManager: accountManager)
        let mailbox = UnifiedMailbox(scraperManager: scraperManager)

        let acc = Account(id: "test-1", email: "test@gmail.com", displayName: "Test")
        accountManager.addAccount(acc)

        let emails = [
            Email(msgId: "1", from: "x@x.com", subject: "s1", date: Date(), snippet: "sn1", isRead: false, accountId: "test-1", folder: .inbox),
            Email(msgId: "2", from: "y@y.com", subject: "s2", date: Date(), snippet: "sn2", isRead: true, accountId: "test-1", folder: .inbox),
            Email(msgId: "3", from: "z@z.com", subject: "s3", date: Date(), snippet: "sn3", isRead: false, accountId: "test-1", folder: .trash),
        ]

        scraperManager.emailsByAccount["test-1"] = emails

        XCTAssertEqual(mailbox.unreadCount(for: .inbox, accountId: "test-1"), 1)
        XCTAssertEqual(mailbox.unreadCount(for: .trash, accountId: "test-1"), 1)
        XCTAssertEqual(mailbox.unreadCount(for: .spam, accountId: "test-1"), 0)
    }

    func testUnreadCountsAllAccounts() {
        let defaults = UserDefaults(suiteName: "ViewTests-all-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let scraperManager = GmailScraperManager(accountManager: accountManager)
        let mailbox = UnifiedMailbox(scraperManager: scraperManager)

        scraperManager.emailsByAccount["acc1"] = [
            Email(msgId: "1", from: "a@a.com", subject: "s", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .inbox),
        ]
        scraperManager.emailsByAccount["acc2"] = [
            Email(msgId: "2", from: "b@b.com", subject: "s", date: Date(), snippet: "", isRead: false, accountId: "acc2", folder: .inbox),
        ]

        XCTAssertEqual(mailbox.unreadCount(for: .inbox), 2)
    }

    // MARK: - MainView layout tests

    func testUnifiedMailboxDefaultFolder() {
        let defaults = UserDefaults(suiteName: "ViewTests-defaults-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let scraperManager = GmailScraperManager(accountManager: accountManager)
        let mailbox = UnifiedMailbox(scraperManager: scraperManager)

        XCTAssertEqual(mailbox.selectedFolder, .inbox, "Default folder should be inbox")
        XCTAssertNil(mailbox.selectedAccountId, "Default account selection should be nil (all accounts)")
    }
}
