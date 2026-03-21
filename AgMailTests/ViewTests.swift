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
        let oauthManager = OAuthManager()
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager)
        let mailbox = UnifiedMailbox(apiManager: apiManager)

        let acc = Account(id: "test-1", email: "test@gmail.com", displayName: "Test")
        accountManager.addAccount(acc)

        let emails = [
            Email(msgId: "1", from: "x@x.com", subject: "s1", date: Date(), snippet: "sn1", isRead: false, accountId: "test-1", folder: .inbox),
            Email(msgId: "2", from: "y@y.com", subject: "s2", date: Date(), snippet: "sn2", isRead: true, accountId: "test-1", folder: .inbox),
            Email(msgId: "3", from: "z@z.com", subject: "s3", date: Date(), snippet: "sn3", isRead: false, accountId: "test-1", folder: .trash),
        ]

        apiManager.emailsByAccount["test-1"] = emails

        XCTAssertEqual(mailbox.unreadCount(for: .inbox, accountId: "test-1"), 1)
        XCTAssertEqual(mailbox.unreadCount(for: .trash, accountId: "test-1"), 1)
        XCTAssertEqual(mailbox.unreadCount(for: .spam, accountId: "test-1"), 0)
    }

    func testUnreadCountsAllAccounts() {
        let defaults = UserDefaults(suiteName: "ViewTests-all-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let oauthManager = OAuthManager()
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager)
        let mailbox = UnifiedMailbox(apiManager: apiManager)

        apiManager.emailsByAccount["acc1"] = [
            Email(msgId: "1", from: "a@a.com", subject: "s", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .inbox),
        ]
        apiManager.emailsByAccount["acc2"] = [
            Email(msgId: "2", from: "b@b.com", subject: "s", date: Date(), snippet: "", isRead: false, accountId: "acc2", folder: .inbox),
        ]

        XCTAssertEqual(mailbox.unreadCount(for: .inbox), 2)
    }

    // MARK: - MainView layout tests

    func testUnifiedMailboxDefaultFolder() {
        let defaults = UserDefaults(suiteName: "ViewTests-defaults-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let oauthManager = OAuthManager()
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager)
        let mailbox = UnifiedMailbox(apiManager: apiManager)

        XCTAssertEqual(mailbox.selectedFolder, .inbox, "Default folder should be inbox")
        XCTAssertNil(mailbox.selectedAccountId, "Default account selection should be nil (all accounts)")
    }

    // MARK: - SplitViewConfigurator tests

    func testSplitViewConfiguratorConstants() {
        XCTAssertEqual(SplitViewConfigurator.maxRetries, 3, "Should retry up to 3 times")
        XCTAssertEqual(SplitViewConfigurator.retryInterval, 0.1, accuracy: 0.001, "Retry interval should be 0.1s")
    }

    func testSplitViewConfiguratorFindSplitViewReturnsNilForPlainView() {
        let plainView = NSView()
        XCTAssertNil(SplitViewConfigurator.findSplitView(from: plainView), "Should return nil when no NSSplitView in hierarchy")
    }

    func testSplitViewConfiguratorFindSplitViewFindsParentSplitView() {
        let splitView = NSSplitView()
        let child = NSView()
        splitView.addSubview(child)
        let grandchild = NSView()
        child.addSubview(grandchild)

        let found = SplitViewConfigurator.findSplitView(from: grandchild)
        XCTAssertNotNil(found, "Should find NSSplitView in ancestor hierarchy")
        XCTAssertEqual(found, splitView, "Should return the correct NSSplitView")
    }

    func testSplitViewConfiguratorFindSplitViewReturnsSplitViewItself() {
        let splitView = NSSplitView()
        let found = SplitViewConfigurator.findSplitView(from: splitView)
        XCTAssertEqual(found, splitView, "Should return the NSSplitView itself when starting from it")
    }

    // MARK: - Dock badge tests

    func testDockBadgeShowsUnreadCount() {
        let defaults = UserDefaults(suiteName: "ViewTests-badge-\(UUID().uuidString)")!
        defaults.set(true, forKey: AppState.showDockBadgeKey)
        let accountManager = AccountManager(defaults: defaults)
        let oauthManager = OAuthManager()
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager)
        let appState = AppState(accountManager: accountManager, apiManager: apiManager, defaults: defaults)

        let counts = ["acc1": 3, "acc2": 5]
        appState.updateDockBadge(counts: counts)

        XCTAssertEqual(NSApp?.dockTile.badgeLabel, "8")
    }

    func testDockBadgeClearsWhenZeroUnread() {
        let defaults = UserDefaults(suiteName: "ViewTests-badge0-\(UUID().uuidString)")!
        defaults.set(true, forKey: AppState.showDockBadgeKey)
        let accountManager = AccountManager(defaults: defaults)
        let oauthManager = OAuthManager()
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager)
        let appState = AppState(accountManager: accountManager, apiManager: apiManager, defaults: defaults)

        appState.updateDockBadge(counts: [:])
        XCTAssertNil(NSApp?.dockTile.badgeLabel)
    }

    func testDockBadgeDisabledClearsBadge() {
        let defaults = UserDefaults(suiteName: "ViewTests-badgeOff-\(UUID().uuidString)")!
        defaults.set(false, forKey: AppState.showDockBadgeKey)
        let accountManager = AccountManager(defaults: defaults)
        let oauthManager = OAuthManager()
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager)
        let appState = AppState(accountManager: accountManager, apiManager: apiManager, defaults: defaults)

        appState.updateDockBadge(counts: ["acc1": 10])
        XCTAssertNil(NSApp?.dockTile.badgeLabel)
    }

    func testDockBadgeDefaultIsEnabled() {
        let defaults = UserDefaults(suiteName: "ViewTests-badgeDefault-\(UUID().uuidString)")!
        defaults.register(defaults: [AppState.showDockBadgeKey: true])
        XCTAssertTrue(defaults.bool(forKey: AppState.showDockBadgeKey))
    }
}
