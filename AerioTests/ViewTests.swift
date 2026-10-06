import XCTest
import WebKit
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

    // MARK: - Settings cache tests

    /// `default.store` belongs to whichever unsandboxed SwiftData app claimed it, and Outbox.store
    /// holds unsent mail — neither is Aerio's cache.
    func testEmailDatabaseSizeCountsOnlyTheEmailCacheStoreFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = [
            "EmailCache.store": 100, "EmailCache.store-wal": 20, "EmailCache.store-shm": 3,
            "default.store": 5000, "default.store-wal": 600,
            "Outbox.store": 70000, "Outbox.store-wal": 800000,
        ]
        for (name, size) in files {
            try Data(count: size).write(to: dir.appendingPathComponent(name))
        }

        let size = SettingsView.emailDatabaseSize(storeURL: dir.appendingPathComponent("EmailCache.store"))

        XCTAssertEqual(size, 123)
    }

    func testClearCachesEmptiesTheEmailCacheThroughItsContainer() throws {
        let cache = EmailCache(inMemory: true)
        cache.saveEmails([Email(msgId: "m1", from: "a@test.com", subject: "s", date: Date(), snippet: "",
                                isRead: true, accountId: "acc1", folder: .inbox)])
        cache.saveContent(accountId: "acc1", msgId: "m1", bodyHTML: "<p>hi</p>", headers: [:], attachments: [])
        let appCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appCacheDir, withIntermediateDirectories: true)

        SettingsView.clearCaches(emailCache: cache, appCacheDirectory: appCacheDir)

        XCTAssertTrue(cache.loadEmails().isEmpty)
        XCTAssertEqual(cache.contentCacheCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appCacheDir.path))
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

// MARK: - Thread page rendering

@MainActor
final class ThreadHTMLTests: XCTestCase {
    /// Records every request WebKit makes for the probe scheme and fails it.
    private final class ProbeSchemeHandler: NSObject, WKURLSchemeHandler {
        private(set) var requestedURLs: [URL] = []
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            if let url = urlSchemeTask.request.url { requestedURLs.append(url) }
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
    }

    /// Resumes once the page and its subresources (stylesheets, frames) have loaded.
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
        private func finish() { continuation?.resume(); continuation = nil }
    }

    private func message(body: String, attachments: [MessageContentData.AttachmentInfo] = []) -> ThreadMessage {
        ThreadMessage(
            id: "m1", from: "sender@example.com", to: "me@example.com", cc: "",
            date: Date(timeIntervalSince1970: 0), subject: "s", bodyHTML: body,
            attachments: attachments, inlineImages: [], accountId: "acc", msgId: "m1",
            messageId: nil, folder: .inbox, isRead: true
        )
    }

    private func message(id: String, body: String) -> ThreadMessage {
        ThreadMessage(
            id: id, from: "sender@example.com", to: "me@example.com", cc: "",
            date: Date(timeIntervalSince1970: 0), subject: "s", bodyHTML: body,
            attachments: [], inlineImages: [], accountId: "acc", msgId: id,
            messageId: nil, folder: .inbox, isRead: true
        )
    }

    private func number(_ script: String, in webView: WKWebView) async -> Double {
        let value = try? await webView.evaluateJavaScript(script)
        return (value as? Double) ?? (value as? Int).map(Double.init) ?? -1
    }

    /// Polls `condition` every 20 ms for up to `timeout` seconds. The ceiling is generous
    /// because a CI runner's first WebKit load spawns the web content process cold, which
    /// took over 3 s on macos-14 and failed the v1.8.0 release run.
    private func waitUntil(timeout: TimeInterval = 20, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func load(_ html: String, in webView: WKWebView) async {
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func testThreadPage_doesNotLoadExternalContentEmbeddedInAnEmail() async {
        // The single-message view blocks an email's external stylesheets and frames with
        // a CSP; a thread shows the same emails and must too. Those fetches reveal that
        // the mail was opened and can pull arbitrary pages into the reading pane.
        let body = """
        <html><head><link rel="stylesheet" href="aerio-probe://tracker/style.css"></head>
        <body><p>Hello</p><iframe src="aerio-probe://tracker/frame"></iframe></body></html>
        """
        let config = WKWebViewConfiguration()
        let probe = ProbeSchemeHandler()
        config.setURLSchemeHandler(probe, forURLScheme: "aerio-probe")
        let webView = WKWebView(frame: .zero, configuration: config)

        await load(ThreadDetailView.buildThreadHTML(messages: [message(body: body)]), in: webView)

        XCTAssertEqual(probe.requestedURLs, [], "the thread page fetched content the email embedded")
    }

    func testThreadPage_appScriptsStillRunUnderThePagePolicy() async throws {
        // Attachment chips are updated by the app via evaluateJavaScript. Locking the
        // page down must not stop that — checked in the real web view store the thread
        // uses, where content JavaScript is disabled.
        let attachment = MessageContentData.AttachmentInfo(
            name: "report.pdf", size: "1 KB", attachmentId: "att1", messageId: "m1", mimeType: "application/pdf")
        let store = BodyWebViewStore()

        await load(ThreadDetailView.buildThreadHTML(messages: [message(body: "<p>Hi</p>", attachments: [attachment])]),
                   in: store.webView)

        let chipCount = try await store.webView.evaluateJavaScript("document.querySelectorAll('#att-att1').length")
        XCTAssertEqual(chipCount as? Int, 1)
    }

    func testThreadPage_givesEveryMessageAnAnchor() async throws {
        let store = BodyWebViewStore()
        await load(ThreadDetailView.buildThreadHTML(messages: [message(id: "m2", body: "<p>b</p>"),
                                                               message(id: "m1", body: "<p>a</p>")]),
                   in: store.webView)

        let anchors = try await store.webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('[id^=\"msg-\"]')).map(e => e.id).join(',')")
        XCTAssertEqual(anchors as? String, "msg-m2,msg-m1")
    }

    // MARK: - Quoted text is collapsed, not removed

    private let outlookReply = """
    <div>Her reply</div><div dir="auto" id="mail-editor-reference-message-container"><br>\
    <hr style="display: inline-block; width: 98%;"><div id="divRplyFwdMsg"><b>From:</b> me<br></div>\
    <p>My original</p></div><hr>NOTICE footer
    """

    /// Offset of `needle` in `haystack`, or nil when absent.
    private func offset(of needle: String, in haystack: String, after start: Int = 0) -> Int? {
        let from = haystack.index(haystack.startIndex, offsetBy: start)
        guard let range = haystack.range(of: needle, range: from..<haystack.endIndex) else { return nil }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    }

    /// Asserts `needle` sits between the first `<details` and the `</details>` after it.
    private func assertInsideDetails(_ needle: String, in html: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard let open = offset(of: "<details", in: html),
              let at = offset(of: needle, in: html, after: open),
              let close = offset(of: "</details>", in: html, after: at) else {
            return XCTFail("\(needle) is not inside a details block: \(html)", file: file, line: line)
        }
        XCTAssertLessThan(open, at, file: file, line: line)
        XCTAssertLessThan(at, close, file: file, line: line)
    }

    func testCollapse_outlookContainerIsWrappedAndFooterStaysVisible() {
        let html = ThreadDetailView.collapseQuotedContent(outlookReply)

        XCTAssertTrue(html.hasPrefix("<div>Her reply</div>"), html)
        let details = offset(of: "<details class=\"aerio-quote\">", in: html)
        let container = offset(of: "mail-editor-reference-message-container", in: html)
        XCTAssertNotNil(details, html)
        XCTAssertNotNil(container, html)
        if let details, let container { XCTAssertLessThan(details, container) }
        assertInsideDetails("My original", in: html)
        let close = offset(of: "</details>", in: html)
        let footer = offset(of: "NOTICE footer", in: html)
        XCTAssertNotNil(close, html)
        if let close, let footer { XCTAssertGreaterThan(footer, close, "the footer must stay visible") }
    }

    func testCollapse_appendOnSendTailIsWrappedToEndOfBody() {
        let input = """
        <html><body><p>Reply</p><div id="appendonsend"></div><hr><div id="divRplyFwdMsg">From: me</div>\
        <div>Quoted</div></body></html>
        """
        let html = ThreadDetailView.collapseQuotedContent(input)

        XCTAssertTrue(html.hasPrefix("<html><body><p>Reply</p><details"), html)
        assertInsideDetails("<hr>", in: html)
        assertInsideDetails("Quoted", in: html)
        XCTAssertTrue(html.hasSuffix("</details></body></html>"), html)
    }

    func testCollapse_gmailQuoteIsCollapsedNotRemoved() {
        let input = """
        <div dir="ltr">Hi</div><div class="gmail_quote gmail_quote_container"><div>On Mon, X wrote:</div>\
        <blockquote>old</blockquote></div><div>sig</div>
        """
        let html = ThreadDetailView.collapseQuotedContent(input)

        assertInsideDetails("old", in: html)
        XCTAssertEqual(html.components(separatedBy: "<details").count - 1, 1,
                       "the blockquote inside the Gmail quote must not be wrapped twice: \(html)")
        let close = offset(of: "</details>", in: html)
        let sig = offset(of: "sig", in: html)
        XCTAssertNotNil(close, html)
        if let close, let sig { XCTAssertGreaterThan(sig, close) }
    }

    func testCollapse_blockquoteIsCollapsed() {
        let html = ThreadDetailView.collapseQuotedContent("<p>Reply</p><blockquote>old</blockquote>")

        XCTAssertTrue(html.hasPrefix("<p>Reply</p><details"), html)
        assertInsideDetails("old", in: html)
    }

    func testCollapse_plainTextSeparatorKeepsThePreBalanced() {
        let input = "<pre style=\"white-space: pre-wrap;\">Reply\n---\nOld</pre>"
        let html = ThreadDetailView.collapseQuotedContent(input)

        XCTAssertEqual(html, "<pre style=\"white-space: pre-wrap;\">Reply</pre>"
                       + "<details class=\"aerio-quote\"><summary>•••</summary>"
                       + "<pre style=\"white-space: pre-wrap;\">\n---\nOld</pre></details>")
    }

    func testCollapse_messageWithoutQuotesIsUnchanged() {
        XCTAssertEqual(ThreadDetailView.collapseQuotedContent("<p>Just text</p>"), "<p>Just text</p>")
    }

    func testThreadPage_quoteIsCollapsedByDefault() async throws {
        let store = BodyWebViewStore()
        await load(ThreadDetailView.buildThreadHTML(messages: [message(body: outlookReply)]), in: store.webView)

        let count = try await store.webView.evaluateJavaScript("document.querySelectorAll('details.aerio-quote').length")
        XCTAssertEqual(count as? Int, 1)
        let open = try await store.webView.evaluateJavaScript("document.querySelector('details.aerio-quote').open")
        XCTAssertEqual(open as? Bool, false)
    }

    func testLoadSequence_onlyTheLatestLoadMayApplyItsResult() {
        // A forced refresh (new member) can start while the first fetch is in flight;
        // whichever finishes last, only the newest load may write the view.
        let loads = LoadSequence()
        let initial = loads.begin()
        let refresh = loads.begin()

        XCTAssertFalse(loads.isLatest(initial), "the older fetch finishing last must be ignored")
        XCTAssertTrue(loads.isLatest(refresh))
    }

    func testFocusScript_withoutATargetScrollsToTheTop() {
        XCTAssertEqual(ThreadNavigationDelegate.focusScript(for: nil), "window.scrollTo(0, 0)")
        XCTAssertTrue(ThreadNavigationDelegate.focusScript(for: "ab'c").contains("getElementById('msg-abc')"),
                      "quotes are stripped from the id")
    }

    func testFocus_followsTheLatestTargetAcrossALoadAndBackToTheTop() async {
        let store = BodyWebViewStore()
        // Host the web view in a window so WebKit lays out and can scroll.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = store.webView
        defer { window.contentView = nil }

        let delegate = ThreadNavigationDelegate()
        delegate.webView = store.webView
        store.webView.navigationDelegate = delegate

        let tall = "<div style=\"height:2000px\">x</div>"
        let html = ThreadDetailView.buildThreadHTML(messages: [message(id: "m3", body: tall),
                                                               message(id: "m2", body: tall),
                                                               message(id: "m1", body: tall)])

        delegate.focusMessageId = "m1"
        delegate.pageWillLoad()
        store.webView.loadHTMLString(html, baseURL: nil)
        // A second jump arrives while the page is still loading: only it may win.
        delegate.focusMessageId = "m2"
        delegate.applyFocus()

        let loaded = await waitUntil { delegate.isPageLoaded }
        XCTAssertTrue(loaded, "page never finished loading")
        let m2Top = await number("document.getElementById('msg-m2').getBoundingClientRect().top + window.scrollY", in: store.webView)
        let reachedM2 = await waitUntil {
            abs(await self.number("window.scrollY", in: store.webView) - m2Top) < 2
        }
        XCTAssertTrue(reachedM2, "thread did not scroll to the latest focus target")

        delegate.focusMessageId = nil
        delegate.applyFocus()
        let reachedTop = await waitUntil { await self.number("window.scrollY", in: store.webView) == 0 }
        XCTAssertTrue(reachedTop, "nil focus did not return to the top")
    }
}
