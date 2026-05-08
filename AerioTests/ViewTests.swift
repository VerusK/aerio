import XCTest
@testable import Aerio

@MainActor
final class ViewTests: XCTestCase {

    // MARK: - UnifiedSidebar data tests

    func testUnifiedSidebarDisplaysAllAccounts() {
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

    // MARK: - Folder data tests (used by UnifiedSidebar)

    func testFolderListShowsAllFolders() {
        let folders = Folder.allCases
        XCTAssertEqual(folders.count, 6)
        XCTAssertEqual(folders.map(\.displayName), ["Inbox", "Sent", "Archive", "Trash", "Spam", "Drafts"])
    }

    func testFolderIconNames() {
        XCTAssertEqual(Folder.inbox.iconName, "tray.fill")
        XCTAssertEqual(Folder.sent.iconName, "paperplane.fill")
        XCTAssertEqual(Folder.archive.iconName, "archivebox.fill")
        XCTAssertEqual(Folder.trash.iconName, "trash.fill")
        XCTAssertEqual(Folder.spam.iconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(Folder.drafts.iconName, "doc.fill")
    }

    // MARK: - UnifiedSidebar folder-account filtering tests

    func testFilterEmailsByFolderAllAccounts() {
        let defaults = UserDefaults(suiteName: "ViewTests-filter-all-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let mailbox = UnifiedMailbox(apiManager: apiManager)

        apiManager.emailsByAccount["acc1"] = [
            Email(msgId: "1", from: "a@a.com", subject: "s1", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .inbox),
            Email(msgId: "2", from: "a@a.com", subject: "s2", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .sent),
        ]
        apiManager.emailsByAccount["acc2"] = [
            Email(msgId: "3", from: "b@b.com", subject: "s3", date: Date(), snippet: "", isRead: false, accountId: "acc2", folder: .inbox),
        ]

        // All accounts, inbox folder
        let inboxEmails = mailbox.emails(for: .inbox)
        XCTAssertEqual(inboxEmails.count, 2)

        // All accounts, sent folder
        let sentEmails = mailbox.emails(for: .sent)
        XCTAssertEqual(sentEmails.count, 1)
    }

    func testFilterEmailsByFolderSpecificAccount() {
        let defaults = UserDefaults(suiteName: "ViewTests-filter-acct-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let mailbox = UnifiedMailbox(apiManager: apiManager)

        apiManager.emailsByAccount["acc1"] = [
            Email(msgId: "1", from: "a@a.com", subject: "s1", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .inbox),
        ]
        apiManager.emailsByAccount["acc2"] = [
            Email(msgId: "2", from: "b@b.com", subject: "s2", date: Date(), snippet: "", isRead: false, accountId: "acc2", folder: .inbox),
        ]

        // Filter to acc1 only
        let acc1Emails = mailbox.emails(for: .inbox, accountId: "acc1")
        XCTAssertEqual(acc1Emails.count, 1)
        XCTAssertEqual(acc1Emails[0].accountId, "acc1")

        // Filter to acc2 only
        let acc2Emails = mailbox.emails(for: .inbox, accountId: "acc2")
        XCTAssertEqual(acc2Emails.count, 1)
        XCTAssertEqual(acc2Emails[0].accountId, "acc2")
    }

    func testUnreadCountPerFolderPerAccount() {
        let defaults = UserDefaults(suiteName: "ViewTests-unread-per-acct-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let mailbox = UnifiedMailbox(apiManager: apiManager)

        apiManager.emailsByAccount["acc1"] = [
            Email(msgId: "1", from: "a@a.com", subject: "s1", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .inbox),
            Email(msgId: "2", from: "a@a.com", subject: "s2", date: Date(), snippet: "", isRead: true, accountId: "acc1", folder: .inbox),
        ]
        apiManager.emailsByAccount["acc2"] = [
            Email(msgId: "3", from: "b@b.com", subject: "s3", date: Date(), snippet: "", isRead: false, accountId: "acc2", folder: .inbox),
            Email(msgId: "4", from: "b@b.com", subject: "s4", date: Date(), snippet: "", isRead: false, accountId: "acc2", folder: .inbox),
        ]

        // Per-account unread counts
        XCTAssertEqual(mailbox.unreadCount(for: .inbox, accountId: "acc1"), 1)
        XCTAssertEqual(mailbox.unreadCount(for: .inbox, accountId: "acc2"), 2)

        // Total unread across all accounts
        XCTAssertEqual(mailbox.unreadCount(for: .inbox), 3)
    }

    func testFilterEmptyFolder() {
        let defaults = UserDefaults(suiteName: "ViewTests-empty-folder-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let mailbox = UnifiedMailbox(apiManager: apiManager)

        apiManager.emailsByAccount["acc1"] = [
            Email(msgId: "1", from: "a@a.com", subject: "s1", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .inbox),
        ]

        // Empty folder should return no emails
        XCTAssertEqual(mailbox.emails(for: .spam).count, 0)
        XCTAssertEqual(mailbox.unreadCount(for: .spam), 0)
    }

    func testFilterNonexistentAccount() {
        let defaults = UserDefaults(suiteName: "ViewTests-noexist-acct-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let mailbox = UnifiedMailbox(apiManager: apiManager)

        apiManager.emailsByAccount["acc1"] = [
            Email(msgId: "1", from: "a@a.com", subject: "s1", date: Date(), snippet: "", isRead: false, accountId: "acc1", folder: .inbox),
        ]

        // Non-existent account should return empty
        XCTAssertEqual(mailbox.emails(for: .inbox, accountId: "nonexistent").count, 0)
        XCTAssertEqual(mailbox.unreadCount(for: .inbox, accountId: "nonexistent"), 0)
    }

    func testUnreadCountsPerFolder() {
        let defaults = UserDefaults(suiteName: "ViewTests-counts-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
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
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
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
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let mailbox = UnifiedMailbox(apiManager: apiManager)

        XCTAssertEqual(mailbox.selectedFolder, .inbox, "Default folder should be inbox")
        XCTAssertNil(mailbox.selectedAccountId, "Default account selection should be nil (all accounts)")
    }

    // MARK: - SplitViewConfigurator tests

    func testSplitViewConfiguratorConstants() {
        XCTAssertEqual(SplitViewConfigurator.maxRetries, 20, "Should retry up to 20 times")
        XCTAssertEqual(SplitViewConfigurator.retryInterval, 0.1, accuracy: 0.001, "Retry interval should be 0.1s")
    }

    func testSplitViewConfiguratorFindSplitViewReturnsNilForPlainView() {
        let plainView = NSView()
        XCTAssertNil(SplitViewConfigurator.findSplitViewUp(from: plainView), "Should return nil when no NSSplitView in hierarchy")
    }

    func testSplitViewConfiguratorFindSplitViewFindsParentSplitView() {
        let splitView = NSSplitView()
        let child = NSView()
        splitView.addSubview(child)
        let grandchild = NSView()
        child.addSubview(grandchild)

        let found = SplitViewConfigurator.findSplitViewUp(from: grandchild)
        XCTAssertNotNil(found, "Should find NSSplitView in ancestor hierarchy")
        XCTAssertEqual(found, splitView, "Should return the correct NSSplitView")
    }

    func testSplitViewConfiguratorFindSplitViewReturnsSplitViewItself() {
        let splitView = NSSplitView()
        let found = SplitViewConfigurator.findSplitViewUp(from: splitView)
        XCTAssertEqual(found, splitView, "Should return the NSSplitView itself when starting from it")
    }

    // MARK: - Dock badge tests

    func testDockBadgeShowsUnreadCount() {
        let defaults = UserDefaults(suiteName: "ViewTests-badge-\(UUID().uuidString)")!
        defaults.set(true, forKey: AppState.showDockBadgeKey)
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let appState = AppState(accountManager: accountManager, apiManager: apiManager, defaults: defaults)

        var capturedBadgeCount: Int?
        appState.badgeCountHandler = { capturedBadgeCount = $0 }

        let counts = ["acc1": 3, "acc2": 5]
        appState.updateDockBadge(counts: counts)
        XCTAssertEqual(capturedBadgeCount, 8, "Badge should show sum of unread counts across accounts")
    }

    func testDockBadgeClearsWhenZeroUnread() {
        let defaults = UserDefaults(suiteName: "ViewTests-badge0-\(UUID().uuidString)")!
        defaults.set(true, forKey: AppState.showDockBadgeKey)
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let appState = AppState(accountManager: accountManager, apiManager: apiManager, defaults: defaults)

        var capturedBadgeCount: Int?
        appState.badgeCountHandler = { capturedBadgeCount = $0 }

        appState.updateDockBadge(counts: [:])
        XCTAssertEqual(capturedBadgeCount, 0, "Badge should be zero when there are no unread emails")
    }

    func testDockBadgeDisabledClearsBadge() {
        let defaults = UserDefaults(suiteName: "ViewTests-badgeOff-\(UUID().uuidString)")!
        defaults.set(false, forKey: AppState.showDockBadgeKey)
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let appState = AppState(accountManager: accountManager, apiManager: apiManager, defaults: defaults)

        var capturedBadgeCount: Int?
        appState.badgeCountHandler = { capturedBadgeCount = $0 }

        appState.updateDockBadge(counts: ["acc1": 10])
        XCTAssertEqual(capturedBadgeCount, 0, "Badge should be cleared (0) when dock badge is disabled")
    }

    func testDockBadgeDefaultIsEnabled() {
        let defaults = UserDefaults(suiteName: "ViewTests-badgeDefault-\(UUID().uuidString)")!
        defaults.register(defaults: [AppState.showDockBadgeKey: true])
        XCTAssertTrue(defaults.bool(forKey: AppState.showDockBadgeKey))
    }

    // MARK: - ComposeView tests

    func testComposeTypeEnum() {
        // Verify all compose types exist and are distinct
        let types: [ComposeType] = [.new, .reply, .replyAll, .forward, .draft]
        XCTAssertEqual(types.count, 5)
    }

    @MainActor
    private func makeStubOutbox() -> OutboxService {
        let store = OutboxStore(inMemory: true)
        return OutboxService(
            store: store,
            sendersByAccount: [:],
            notifier: NoopNotifier(),
            postSendRefresh: { }
        )
    }

    @MainActor
    func testComposeViewInitializesWithDefaults() {
        let defaults = UserDefaults(suiteName: "ViewTests-compose-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)

        let view = ComposeView(accountManager: accountManager, apiManager: apiManager, outboxService: makeStubOutbox())
        XCTAssertEqual(view.composeType, .new)
        XCTAssertNil(view.replyToEmail)
        XCTAssertNil(view.preselectedAccountId)
    }

    @MainActor
    func testComposeViewInitializesWithReplyType() {
        let defaults = UserDefaults(suiteName: "ViewTests-compose-reply-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)

        let email = Email(msgId: "msg1", from: "sender@test.com", subject: "Test", date: Date(), snippet: "Hello", isRead: false, accountId: "acc1", folder: .inbox)
        let view = ComposeView(accountManager: accountManager, apiManager: apiManager, outboxService: makeStubOutbox(), composeType: .reply, replyToEmail: email)
        XCTAssertEqual(view.composeType, .reply)
        XCTAssertNotNil(view.replyToEmail)
        XCTAssertEqual(view.replyToEmail?.from, "sender@test.com")
    }

    @MainActor
    func testComposeViewInitializesWithPreselectedAccount() {
        let defaults = UserDefaults(suiteName: "ViewTests-compose-acct-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)

        let view = ComposeView(accountManager: accountManager, apiManager: apiManager, outboxService: makeStubOutbox(), preselectedAccountId: "acc-123")
        XCTAssertEqual(view.preselectedAccountId, "acc-123")
    }

    // MARK: - MessageWebView light theme tests

    func testWrapEmailHTMLContainsNoDarkModeCSS() {
        let html = wrapEmailHTML("<p>Hello</p>", subject: "Test")
        XCTAssertFalse(html.contains("prefers-color-scheme: dark"), "HTML wrapper should not contain dark mode media queries")
        XCTAssertFalse(html.contains("prefers-color-scheme:dark"), "HTML wrapper should not contain dark mode media queries (no space variant)")
    }

    func testWrapEmailHTMLUsesLightColors() {
        let html = wrapEmailHTML("<p>Test</p>", subject: "Subject")
        XCTAssertTrue(html.contains("color: #1d1d1f"), "Body text should use dark color for light theme")
        XCTAssertFalse(html.contains("background-color: #1e1e1e"), "Should not have dark background")
    }

    func testWrapEmailHTMLIncludesBody() {
        let body = "<div>Email content here</div>"
        let html = wrapEmailHTML(body, subject: "My Subject")
        XCTAssertTrue(html.contains(body), "Wrapped HTML should contain the original body")
    }

    // MARK: - NativeMessageDetail action button tests

    func testNativeMessageDetailAcceptsActionClosures() {
        let defaults = UserDefaults(suiteName: "ViewTests-actions-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let email = Email(msgId: "msg1", from: "a@test.com", subject: "Test", date: Date(), snippet: "Hello", isRead: false, accountId: "acc1", folder: .inbox)

        var replyCalled = false
        var replyAllCalled = false
        var forwardCalled = false
        var archiveCalled = false
        var deleteCalled = false
        var spamCalled = false

        let view = NativeMessageDetail(
            email: email,
            apiManager: apiManager,
            folder: .inbox,
            onReply: { replyCalled = true },
            onReplyAll: { replyAllCalled = true },
            onForward: { forwardCalled = true },
            onArchive: { archiveCalled = true },
            onDelete: { deleteCalled = true },
            onSpam: { spamCalled = true }
        )

        // Verify closures are set (non-nil)
        XCTAssertNotNil(view.onReply)
        XCTAssertNotNil(view.onReplyAll)
        XCTAssertNotNil(view.onForward)
        XCTAssertNotNil(view.onArchive)
        XCTAssertNotNil(view.onDelete)
        XCTAssertNotNil(view.onSpam)

        // Verify closures execute correctly
        view.onReply?()
        view.onReplyAll?()
        view.onForward?()
        view.onArchive?()
        view.onDelete?()
        view.onSpam?()

        XCTAssertTrue(replyCalled)
        XCTAssertTrue(replyAllCalled)
        XCTAssertTrue(forwardCalled)
        XCTAssertTrue(archiveCalled)
        XCTAssertTrue(deleteCalled)
        XCTAssertTrue(spamCalled)
    }

    func testNativeMessageDetailDefaultClosuresAreNil() {
        let defaults = UserDefaults(suiteName: "ViewTests-noactions-\(UUID().uuidString)")!
        let accountManager = AccountManager(defaults: defaults)
        let mockKeychain = MockKeychainStore()
        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        let apiManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        let email = Email(msgId: "msg2", from: "b@test.com", subject: "Test2", date: Date(), snippet: "World", isRead: true, accountId: "acc1", folder: .inbox)

        let view = NativeMessageDetail(
            email: email,
            apiManager: apiManager,
            folder: .inbox
        )

        XCTAssertNil(view.onReply)
        XCTAssertNil(view.onReplyAll)
        XCTAssertNil(view.onForward)
        XCTAssertNil(view.onArchive)
        XCTAssertNil(view.onDelete)
        XCTAssertNil(view.onSpam)
    }

    func testActionButtonTooltipsContainShortcutLabels() {
        // Verify that ShortcutAction labels are non-empty for all action button actions
        let actions: [ShortcutAction] = [.reply, .replyAll, .forward, .archiveMessage, .deleteMessage, .spamMessage]
        for action in actions {
            XCTAssertFalse(action.shortcutLabel.isEmpty, "\(action.displayName) should have a non-empty shortcut label")
        }

        // Verify specific tooltip content matches expected format
        XCTAssertTrue(ShortcutAction.reply.shortcutLabel.contains("⌘"), "Reply shortcut should contain Cmd symbol")
        XCTAssertTrue(ShortcutAction.replyAll.shortcutLabel.contains("⌘"), "Reply All shortcut should contain Cmd symbol")
        XCTAssertTrue(ShortcutAction.forward.shortcutLabel.contains("⌘"), "Forward shortcut should contain Cmd symbol")
        XCTAssertTrue(ShortcutAction.archiveMessage.shortcutLabel.contains("⌘"), "Archive shortcut should contain Cmd symbol")
        XCTAssertTrue(ShortcutAction.deleteMessage.shortcutLabel.contains("⌘"), "Delete shortcut should contain Cmd symbol")
        XCTAssertTrue(ShortcutAction.spamMessage.shortcutLabel.contains("⌘"), "Spam shortcut should contain Cmd symbol")
    }
}
