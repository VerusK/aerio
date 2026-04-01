import XCTest
@testable import Aerio

@MainActor
final class GmailAPIManagerTests: XCTestCase {
    private var manager: GmailAPIManager!
    private var accountManager: AccountManager!
    private var oauthManager: OAuthManager!
    private var session: URLSession!
    private var mockKeychain: MockKeychainStore!
    private let testAccountId = "manager-test@gmail.com"

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        accountManager = AccountManager(defaults: UserDefaults(suiteName: "GmailAPIManagerTests")!)
        // Clear any leftover accounts
        for account in accountManager.accounts {
            accountManager.removeAccount(id: account.id)
        }

        mockKeychain = MockKeychainStore()
        oauthManager = OAuthManager(keychainStore: mockKeychain)

        // Save test tokens so the client can authenticate
        let tokens = KeychainHelper.OAuthTokens(
            accessToken: "test_access_token",
            refreshToken: "test_refresh_token",
            expiresAt: Date().addingTimeInterval(3600),
            email: testAccountId
        )
        try mockKeychain.saveTokens(tokens, for: testAccountId)

        manager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        // Inject custom client factory that uses our mock session and mock keychain
        manager.clientFactory = { [session, mockKeychain] accountId, oauthManager in
            GmailAPIClient(accountId: accountId, oauthManager: oauthManager, session: session!, keychainStore: mockKeychain!)
        }
    }

    override func tearDown() {
        manager.stopPollingAll()
        MockURLProtocol.requestHandler = nil
        UserDefaults(suiteName: "GmailAPIManagerTests")?.removePersistentDomain(forName: "GmailAPIManagerTests")
    }

    // MARK: - Client Management

    func testAddClientCreatesClient() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        XCTAssertNotNil(manager.clients[testAccountId])
        XCTAssertEqual(manager.clientStates[testAccountId], .idle)
    }

    func testAddClientDuplicateIsIgnored() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)
        let firstClient = manager.clients[testAccountId]
        manager.addClient(for: account)

        XCTAssertTrue(manager.clients[testAccountId] === firstClient)
    }

    func testRemoveClientCleansUpState() throws {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)
        manager.emailsByAccount[testAccountId] = [makeEmail(msgId: "m1")]
        manager.unreadCountsByAccount[testAccountId] = 5

        manager.removeClient(for: testAccountId)

        XCTAssertNil(manager.clients[testAccountId])
        XCTAssertNil(manager.clientStates[testAccountId])
        XCTAssertNil(manager.emailsByAccount[testAccountId])
        XCTAssertNil(manager.unreadCountsByAccount[testAccountId])
        // Verify tokens were deleted from mock keychain
        XCTAssertNil(try mockKeychain.loadTokens(for: testAccountId))
    }

    // MARK: - Fetch Emails

    func testFetchEmailsUpdatesEmailsByAccount() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        setupMockForFetchEmails()

        await manager.fetchEmails(for: testAccountId)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        XCTAssertEqual(emails.count, 2)
        XCTAssertTrue(emails.contains(where: { $0.msgId == "msg1" }))
        XCTAssertTrue(emails.contains(where: { $0.msgId == "msg2" }))
    }

    func testFetchEmailsSetsClientStateToIdleOnSuccess() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        setupMockForFetchEmails()

        await manager.fetchEmails(for: testAccountId)

        XCTAssertEqual(manager.clientStates[testAccountId], .idle)
    }

    func testFetchEmailsSetsClientStateToErrorOnFailure() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, "forbidden".data(using: .utf8)!)
        }

        await manager.fetchEmails(for: testAccountId)

        if case .error = manager.clientStates[testAccountId] {
            // expected
        } else {
            XCTFail("Expected error state")
        }
    }

    // MARK: - Mark As Read

    func testMarkAsReadOptimisticUpdate() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let email = makeEmail(msgId: "m1", isRead: false)
        manager.emailsByAccount[testAccountId] = [email]
        manager.unreadCountsByAccount[testAccountId] = 1

        let apiCalled = expectation(description: "API call completed")

        // Mock the modify API call
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "m1", "threadId": "t1", "labelIds": ["INBOX"]}
            """
            apiCalled.fulfill()
            return (response, json.data(using: .utf8)!)
        }

        manager.markAsRead(emailId: email.id, accountId: testAccountId)

        let updated = manager.emailsByAccount[testAccountId]!.first!
        XCTAssertTrue(updated.isRead)
        XCTAssertEqual(manager.unreadCountsByAccount[testAccountId], 0)

        // Wait for the fire-and-forget API Task to finish before tearDown
        await fulfillment(of: [apiCalled], timeout: 2)
    }

    func testMarkAsReadSkipsAlreadyRead() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        // Set a safe default handler to avoid interference from parallel tests
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        let email = makeEmail(msgId: "m1", isRead: true)
        manager.emailsByAccount[testAccountId] = [email]
        manager.unreadCountsByAccount[testAccountId] = 0

        manager.markAsRead(emailId: email.id, accountId: testAccountId)

        // Should remain unchanged
        XCTAssertEqual(manager.unreadCountsByAccount[testAccountId], 0)
    }

    // MARK: - Remove Email

    func testRemoveEmailSingleFolder() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let email1 = makeEmail(msgId: "m1")
        let email2 = makeEmail(msgId: "m2")
        manager.emailsByAccount[testAccountId] = [email1, email2]

        manager.removeEmail(id: email1.id, accountId: testAccountId, msgId: "m1")

        XCTAssertEqual(manager.emailsByAccount[testAccountId]?.count, 1)
        XCTAssertEqual(manager.emailsByAccount[testAccountId]?.first?.msgId, "m2")
    }

    func testRemoveEmailAllFolders() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let inboxEmail = makeEmail(msgId: "m1", folder: .inbox)
        let archiveEmail = makeEmail(msgId: "m1", folder: .archive)
        manager.emailsByAccount[testAccountId] = [inboxEmail, archiveEmail]

        manager.removeEmail(id: inboxEmail.id, accountId: testAccountId, msgId: "m1", allFolders: true)

        XCTAssertEqual(manager.emailsByAccount[testAccountId]?.count, 0)
    }

    // MARK: - Polling

    func testStartStopPolling() {
        XCTAssertFalse(manager.isPolling)
        manager.startPollingAll(interval: 300) // Long interval so it doesn't actually poll
        XCTAssertTrue(manager.isPolling)
        manager.stopPollingAll()
        XCTAssertFalse(manager.isPolling)
    }

    // MARK: - Computed Properties

    func testHasLoadedAny() async {
        XCTAssertFalse(manager.hasLoadedAny)

        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)
        // Client added but no fetch completed yet
        XCTAssertFalse(manager.hasLoadedAny)

        // After a successful fetch, hasLoadedAny should be true
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"messages":[],"resultSizeEstimate":0}"#
            return (response, json.data(using: .utf8)!)
        }
        await manager.fetchEmails(for: testAccountId)
        XCTAssertTrue(manager.hasLoadedAny)
    }

    func testClientErrorsAfterFailedFetch() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, "test error".data(using: .utf8)!)
        }

        await manager.fetchEmails(for: testAccountId)

        XCTAssertEqual(manager.clientErrors.count, 1)
        XCTAssertTrue(manager.clientErrors.first?.contains("Forbidden") ?? false)
    }

    func testAllClientsErrored() async {
        XCTAssertFalse(manager.allClientsErrored) // No clients

        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)
        XCTAssertFalse(manager.allClientsErrored) // Client is idle

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, "fail".data(using: .utf8)!)
        }
        await manager.fetchEmails(for: testAccountId)
        XCTAssertTrue(manager.allClientsErrored)
    }

    func testAllEmails() {
        let email1 = makeEmail(msgId: "m1", date: Date(timeIntervalSince1970: 1000))
        let email2 = makeEmail(msgId: "m2", date: Date(timeIntervalSince1970: 2000))
        manager.emailsByAccount["a1"] = [email1]
        manager.emailsByAccount["a2"] = [email2]

        let all = manager.allEmails
        XCTAssertEqual(all.count, 2)
        // Should be sorted by date descending
        XCTAssertEqual(all.first?.msgId, "m2")
    }

    func testTotalUnreadCount() {
        manager.unreadCountsByAccount["a1"] = 3
        manager.unreadCountsByAccount["a2"] = 7

        XCTAssertEqual(manager.totalUnreadCount, 10)
    }

    // MARK: - Convert Gmail Message

    func testConvertGmailMessageToEmail() {
        let message = GmailMessage(
            id: "msg1",
            threadId: "t1",
            labelIds: ["INBOX", "UNREAD"],
            snippet: "Hello world",
            payload: GmailPayload(
                mimeType: "text/plain",
                headers: [
                    GmailHeader(name: "From", value: "sender@test.com"),
                    GmailHeader(name: "Subject", value: "Test Subject"),
                    GmailHeader(name: "Date", value: "Mon, 1 Jan 2024 00:00:00 +0000")
                ],
                body: nil,
                parts: nil,
                filename: nil
            ),
            internalDate: "1704067200000",
            historyId: nil,
            sizeEstimate: nil
        )

        let email = manager.convertGmailMessageToEmail(message, accountId: testAccountId, folder: .inbox)

        XCTAssertNotNil(email)
        XCTAssertEqual(email?.msgId, "msg1")
        XCTAssertEqual(email?.from, "sender@test.com")
        XCTAssertEqual(email?.subject, "Test Subject")
        XCTAssertFalse(email?.isRead ?? true) // UNREAD label present
        XCTAssertEqual(email?.snippet, "Hello world")
        XCTAssertEqual(email?.accountId, testAccountId)
        XCTAssertEqual(email?.folder, .inbox)
    }

    func testConvertGmailMessageReadStatus() {
        let message = GmailMessage(
            id: "msg2",
            threadId: "t1",
            labelIds: ["INBOX"], // No UNREAD
            snippet: "",
            payload: GmailPayload(mimeType: nil, headers: [], body: nil, parts: nil, filename: nil),
            internalDate: "1704067200000",
            historyId: nil,
            sizeEstimate: nil
        )

        let email = manager.convertGmailMessageToEmail(message, accountId: testAccountId, folder: .inbox)
        XCTAssertTrue(email?.isRead ?? false)
    }

    func testConvertGmailMessageIncludesToCc() {
        let message = GmailMessage(
            id: "msg1",
            threadId: "thread1",
            labelIds: ["INBOX", "UNREAD"],
            snippet: "Hello",
            payload: GmailPayload(
                mimeType: "text/plain",
                headers: [
                    GmailHeader(name: "From", value: "sender@test.com"),
                    GmailHeader(name: "To", value: "recipient@test.com"),
                    GmailHeader(name: "Cc", value: "cc1@test.com, cc2@test.com"),
                    GmailHeader(name: "Subject", value: "Test Subject"),
                    GmailHeader(name: "Date", value: "Mon, 31 Mar 2026 10:00:00 +0000"),
                ],
                body: nil,
                parts: nil,
                filename: nil
            ),
            internalDate: String(Int(Date().timeIntervalSince1970 * 1000)),
            historyId: nil,
            sizeEstimate: nil
        )
        let email = manager.convertGmailMessageToEmail(message, accountId: testAccountId, folder: .inbox)
        XCTAssertNotNil(email)
        XCTAssertEqual(email?.to, "recipient@test.com")
        XCTAssertEqual(email?.cc, "cc1@test.com, cc2@test.com")
    }

    // MARK: - Navigate to Folder

    // MARK: - Incremental Sync

    func testIncrementalSyncWithNoHistoryIdFallsBackToFullFetch() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        // No historyId set — should do a full fetch
        setupMockForFetchEmails()

        await manager.incrementalSync(for: testAccountId)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        XCTAssertEqual(emails.count, 2)
        // historyId should now be set from the fetched messages
        XCTAssertNotNil(manager.historyIds[testAccountId])
    }

    func testIncrementalSyncProcessesHistoryEvents() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        // Set up initial state with existing emails and a historyId
        manager.historyIds[testAccountId] = "12345"
        manager.emailsByAccount[testAccountId] = [
            makeEmail(msgId: "msg1"),
            makeEmail(msgId: "msg2")
        ]

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/history") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "history": [{
                        "id": "12346",
                        "messagesAdded": [{"message": {"id": "msg3", "threadId": "t3"}}],
                        "messagesDeleted": [{"message": {"id": "msg1", "threadId": "t1"}}]
                    }],
                    "historyId": "12347"
                }
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg3") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg3", "threadId": "t3", "labelIds": ["INBOX", "UNREAD"], "snippet": "New",
                 "payload": {"headers": [{"name": "From", "value": "new@test.com"}, {"name": "Subject", "value": "New Msg"}]},
                 "internalDate": "1711000002000", "historyId": "12347"}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/labels/INBOX") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "INBOX", "name": "INBOX", "messagesUnread": 1}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.incrementalSync(for: testAccountId)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        // msg1 deleted, msg3 added, msg2 remains
        XCTAssertEqual(emails.count, 2)
        XCTAssertFalse(emails.contains(where: { $0.msgId == "msg1" }))
        XCTAssertTrue(emails.contains(where: { $0.msgId == "msg2" }))
        XCTAssertTrue(emails.contains(where: { $0.msgId == "msg3" }))
        XCTAssertEqual(manager.historyIds[testAccountId], "12347")
    }

    func testIncrementalSyncNoChanges() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        manager.historyIds[testAccountId] = "12345"
        manager.emailsByAccount[testAccountId] = [makeEmail(msgId: "msg1")]

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/history") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"historyId": "12345"}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.incrementalSync(for: testAccountId)

        // Emails unchanged
        XCTAssertEqual(manager.emailsByAccount[testAccountId]?.count, 1)
        XCTAssertEqual(manager.clientStates[testAccountId], .idle)
    }

    func testIncrementalSync410FallsBackToFullFetch() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        manager.historyIds[testAccountId] = "old_expired_id"
        manager.emailsByAccount[testAccountId] = []

        let requestCount = RequestCounter()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            requestCount.increment()

            // First call to /history returns 410
            if url.contains("/history") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!
                return (response, "Gone".data(using: .utf8)!)
            }

            // After 410, it should fall back to full fetch
            if url.contains("/labels/INBOX") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "INBOX", "name": "INBOX", "messagesUnread": 0}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg1") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg1", "threadId": "t1", "labelIds": ["INBOX"], "snippet": "Refetched",
                 "payload": {"headers": [{"name": "From", "value": "a@b.com"}, {"name": "Subject", "value": "Hi"}]},
                 "internalDate": "1711000000000", "historyId": "99999"}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages") && !url.contains("/messages/") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"messages": [{"id": "msg1", "threadId": "t1"}], "resultSizeEstimate": 1}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.incrementalSync(for: testAccountId)

        // After 410 fallback, should have done a full fetch
        let emails = manager.emailsByAccount[testAccountId] ?? []
        XCTAssertEqual(emails.count, 1)
        XCTAssertEqual(emails.first?.msgId, "msg1")
        // historyId should be updated from fresh fetch
        XCTAssertEqual(manager.historyIds[testAccountId], "99999")
    }

    func testIncrementalSyncLabelChanges() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        manager.historyIds[testAccountId] = "12345"
        manager.emailsByAccount[testAccountId] = [makeEmail(msgId: "msg1", isRead: false)]

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/history") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {
                    "history": [{
                        "id": "12346",
                        "labelsRemoved": [{"message": {"id": "msg1", "threadId": "t1"}, "labelIds": ["UNREAD"]}]
                    }],
                    "historyId": "12347"
                }
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg1") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg1", "threadId": "t1", "labelIds": ["INBOX"], "snippet": "Hello",
                 "payload": {"headers": [{"name": "From", "value": "a@b.com"}, {"name": "Subject", "value": "Hi"}]},
                 "internalDate": "1711000000000", "historyId": "12347"}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/labels/INBOX") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "INBOX", "name": "INBOX", "messagesUnread": 0}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.incrementalSync(for: testAccountId)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        XCTAssertEqual(emails.count, 1)
        // msg1 should now be read (UNREAD label removed)
        XCTAssertTrue(emails.first?.isRead ?? false)
    }

    func testRemoveClientCleansUpHistoryId() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)
        manager.historyIds[testAccountId] = "12345"

        manager.removeClient(for: testAccountId)

        XCTAssertNil(manager.historyIds[testAccountId])
    }

    func testFetchEmailsSetsHistoryId() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        setupMockForFetchEmails()
        await manager.fetchEmails(for: testAccountId)

        // historyId should be set from the max of fetched messages (12346 > 12345)
        XCTAssertEqual(manager.historyIds[testAccountId], "12346")
    }

    // MARK: - Multi-Account Client Initialization

    func testMultiAccountAddClientsCreatesIndependentClients() throws {
        let account1 = Account(id: "user1@gmail.com", email: "user1@gmail.com", displayName: "User 1")
        let account2 = Account(id: "user2@gmail.com", email: "user2@gmail.com", displayName: "User 2")

        // Save tokens for both accounts
        let tokens1 = KeychainHelper.OAuthTokens(accessToken: "token1", refreshToken: "refresh1", expiresAt: Date().addingTimeInterval(3600), email: "user1@gmail.com")
        let tokens2 = KeychainHelper.OAuthTokens(accessToken: "token2", refreshToken: "refresh2", expiresAt: Date().addingTimeInterval(3600), email: "user2@gmail.com")
        try mockKeychain.saveTokens(tokens1, for: "user1@gmail.com")
        try mockKeychain.saveTokens(tokens2, for: "user2@gmail.com")

        manager.addClient(for: account1)
        manager.addClient(for: account2)

        XCTAssertEqual(manager.clients.count, 2)
        XCTAssertNotNil(manager.clients["user1@gmail.com"])
        XCTAssertNotNil(manager.clients["user2@gmail.com"])
        XCTAssertTrue(manager.clients["user1@gmail.com"] !== manager.clients["user2@gmail.com"])
        XCTAssertEqual(manager.clientStates["user1@gmail.com"], .idle)
        XCTAssertEqual(manager.clientStates["user2@gmail.com"], .idle)
    }

    func testAddClientWithNoTokensStillCreatesClient() {
        // Account with no tokens saved in keychain
        let account = Account(id: "notoken@gmail.com", email: "notoken@gmail.com", displayName: "No Token")

        manager.addClient(for: account)

        // Client should still be created (will fail on first API call)
        XCTAssertNotNil(manager.clients["notoken@gmail.com"])
        XCTAssertEqual(manager.clientStates["notoken@gmail.com"], .idle)
    }

    func testMultiAccountFetchEmailsIndependentErrors() async throws {
        let account1 = Account(id: "user1@gmail.com", email: "user1@gmail.com", displayName: "User 1")
        let account2 = Account(id: "user2@gmail.com", email: "user2@gmail.com", displayName: "User 2")

        let tokens1 = KeychainHelper.OAuthTokens(accessToken: "token1", refreshToken: "refresh1", expiresAt: Date().addingTimeInterval(3600), email: "user1@gmail.com")
        let tokens2 = KeychainHelper.OAuthTokens(accessToken: "token2", refreshToken: "refresh2", expiresAt: Date().addingTimeInterval(3600), email: "user2@gmail.com")
        try mockKeychain.saveTokens(tokens1, for: "user1@gmail.com")
        try mockKeychain.saveTokens(tokens2, for: "user2@gmail.com")

        manager.addClient(for: account1)
        manager.addClient(for: account2)

        // Account 1 succeeds, account 2 gets 403
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""

            if auth.contains("token2") {
                // Account 2 fails
                let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
                return (response, "forbidden".data(using: .utf8)!)
            }

            // Account 1 succeeds
            if url.contains("/labels/INBOX") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, #"{"id":"INBOX","name":"INBOX","messagesUnread":0}"#.data(using: .utf8)!)
            }
            if url.contains("/messages") && !url.contains("/messages/") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, #"{"messages":[{"id":"m1","threadId":"t1"}],"resultSizeEstimate":1}"#.data(using: .utf8)!)
            }
            if url.contains("/messages/m1") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = #"{"id":"m1","threadId":"t1","labelIds":["INBOX"],"snippet":"Hi","payload":{"headers":[{"name":"From","value":"a@b.com"},{"name":"Subject","value":"Test"}]},"internalDate":"1711000000000","historyId":"100"}"#
                return (response, json.data(using: .utf8)!)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.fetchAllAccounts()

        // Account 1 should have emails
        XCTAssertEqual(manager.emailsByAccount["user1@gmail.com"]?.count, 1)
        XCTAssertEqual(manager.clientStates["user1@gmail.com"], .idle)

        // Account 2 should be in error state
        if case .error = manager.clientStates["user2@gmail.com"] {
            // expected
        } else {
            XCTFail("Expected error state for account 2, got \(String(describing: manager.clientStates["user2@gmail.com"]))")
        }

        // allClientsErrored should be false (only one errored)
        XCTAssertFalse(manager.allClientsErrored)
    }

    func testMultiAccountAllErrored() async throws {
        let account1 = Account(id: "user1@gmail.com", email: "user1@gmail.com", displayName: "User 1")
        let account2 = Account(id: "user2@gmail.com", email: "user2@gmail.com", displayName: "User 2")

        let tokens1 = KeychainHelper.OAuthTokens(accessToken: "token1", refreshToken: "refresh1", expiresAt: Date().addingTimeInterval(3600), email: "user1@gmail.com")
        let tokens2 = KeychainHelper.OAuthTokens(accessToken: "token2", refreshToken: "refresh2", expiresAt: Date().addingTimeInterval(3600), email: "user2@gmail.com")
        try mockKeychain.saveTokens(tokens1, for: "user1@gmail.com")
        try mockKeychain.saveTokens(tokens2, for: "user2@gmail.com")

        manager.addClient(for: account1)
        manager.addClient(for: account2)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, "forbidden".data(using: .utf8)!)
        }

        await manager.fetchAllAccounts()

        XCTAssertTrue(manager.allClientsErrored)
        XCTAssertEqual(manager.clientErrors.count, 2)
    }

    func testFetchEmailsForNonexistentClientIsNoOp() async {
        // Fetching for an account that has no client should not crash
        await manager.fetchEmails(for: "nonexistent@gmail.com")
        XCTAssertNil(manager.emailsByAccount["nonexistent@gmail.com"])
    }

    func testMultiAccountRemoveOnePreservesOther() throws {
        let account1 = Account(id: "user1@gmail.com", email: "user1@gmail.com", displayName: "User 1")
        let account2 = Account(id: "user2@gmail.com", email: "user2@gmail.com", displayName: "User 2")

        let tokens1 = KeychainHelper.OAuthTokens(accessToken: "t1", refreshToken: "r1", expiresAt: Date().addingTimeInterval(3600), email: "user1@gmail.com")
        let tokens2 = KeychainHelper.OAuthTokens(accessToken: "t2", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600), email: "user2@gmail.com")
        try mockKeychain.saveTokens(tokens1, for: "user1@gmail.com")
        try mockKeychain.saveTokens(tokens2, for: "user2@gmail.com")

        manager.addClient(for: account1)
        manager.addClient(for: account2)
        manager.emailsByAccount["user1@gmail.com"] = [makeEmail(msgId: "m1")]
        manager.emailsByAccount["user2@gmail.com"] = [makeEmail(msgId: "m2")]

        manager.removeClient(for: "user1@gmail.com")

        XCTAssertNil(manager.clients["user1@gmail.com"])
        XCTAssertNotNil(manager.clients["user2@gmail.com"])
        XCTAssertNil(manager.emailsByAccount["user1@gmail.com"])
        XCTAssertEqual(manager.emailsByAccount["user2@gmail.com"]?.count, 1)
        // user2 tokens should still exist
        XCTAssertNotNil(try mockKeychain.loadTokens(for: "user2@gmail.com"))
    }

    func testMultiAccountPerAccountTokenUsage() async throws {
        let account1 = Account(id: "user1@gmail.com", email: "user1@gmail.com", displayName: "User 1")
        let account2 = Account(id: "user2@gmail.com", email: "user2@gmail.com", displayName: "User 2")

        let tokens1 = KeychainHelper.OAuthTokens(accessToken: "access_token_1", refreshToken: "r1", expiresAt: Date().addingTimeInterval(3600), email: "user1@gmail.com")
        let tokens2 = KeychainHelper.OAuthTokens(accessToken: "access_token_2", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600), email: "user2@gmail.com")
        try mockKeychain.saveTokens(tokens1, for: "user1@gmail.com")
        try mockKeychain.saveTokens(tokens2, for: "user2@gmail.com")

        manager.addClient(for: account1)
        manager.addClient(for: account2)

        var tokensByAccount: [String: String] = [:]
        let lock = NSLock()

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""

            // Track which token was used for the list messages call
            if url.contains("/messages") && !url.contains("/messages/") {
                let token = auth.replacingOccurrences(of: "Bearer ", with: "")
                lock.lock()
                if token == "access_token_1" {
                    tokensByAccount["user1@gmail.com"] = token
                } else if token == "access_token_2" {
                    tokensByAccount["user2@gmail.com"] = token
                }
                lock.unlock()
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.contains("/labels/INBOX") {
                return (response, #"{"id":"INBOX","name":"INBOX","messagesUnread":0}"#.data(using: .utf8)!)
            }
            return (response, #"{"messages":[],"resultSizeEstimate":0}"#.data(using: .utf8)!)
        }

        await manager.fetchAllAccounts()

        // Each account should have used its own token
        XCTAssertEqual(tokensByAccount["user1@gmail.com"], "access_token_1")
        XCTAssertEqual(tokensByAccount["user2@gmail.com"], "access_token_2")
    }

    // MARK: - Batched Fetch

    func testFetchEmailsBatchedMultiplePages() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let listCallCount = RequestCounter()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/labels/INBOX") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, #"{"id":"INBOX","name":"INBOX","messagesUnread":2}"#.data(using: .utf8)!)
            }

            // List messages endpoint — return page 1 then page 2
            if url.contains("/messages") && !url.contains("/messages/") {
                let count = listCallCount.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if count == 1 {
                    // First page with nextPageToken
                    let json = """
                    {"messages": [{"id": "msg1", "threadId": "t1"}], "nextPageToken": "page2token", "resultSizeEstimate": 2, "historyId": "100"}
                    """
                    return (response, json.data(using: .utf8)!)
                } else {
                    // Second page, no more pages
                    let json = """
                    {"messages": [{"id": "msg2", "threadId": "t2"}], "resultSizeEstimate": 1, "historyId": "101"}
                    """
                    return (response, json.data(using: .utf8)!)
                }
            }

            if url.contains("/messages/msg1") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "snippet": "First",
                 "payload": {"headers": [{"name": "From", "value": "a@b.com"}, {"name": "Subject", "value": "Msg1"}]},
                 "internalDate": "1711000000000", "historyId": "100"}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg2") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg2", "threadId": "t2", "labelIds": ["INBOX"], "snippet": "Second",
                 "payload": {"headers": [{"name": "From", "value": "c@d.com"}, {"name": "Subject", "value": "Msg2"}]},
                 "internalDate": "1711000001000", "historyId": "101"}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.fetchEmails(for: testAccountId)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        // fetchEmails now stops after first batch for infinite scroll
        XCTAssertEqual(emails.count, 1)
        XCTAssertTrue(emails.contains(where: { $0.msgId == "msg1" }))
        // Only one list call — first batch only
        XCTAssertEqual(listCallCount.value, 1)
        // historyId should be set
        XCTAssertNotNil(manager.historyIds[testAccountId])
        // pageToken should be stored for infinite scroll
        XCTAssertEqual(manager.pageTokens[testAccountId]?[.inbox], "page2token")
    }

    func testFetchEmailsPageTokenSavedForInfiniteScroll() async {
        // When first page has no nextPageToken, pageToken should be nil (all loaded)
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        setupMockForFetchEmails()

        await manager.fetchEmails(for: testAccountId)

        // No nextPageToken in mock -> pageToken should be nil
        XCTAssertNil(manager.pageTokens[testAccountId]?[.inbox])
    }

    func testFetchEmailsNoDuplicatesOnRefresh() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        // Pre-populate with some emails
        manager.emailsByAccount[testAccountId] = [makeEmail(msgId: "old1")]

        setupMockForFetchEmails()

        await manager.fetchEmails(for: testAccountId)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        // Should only have the newly fetched emails, not old ones for the same folder
        let inboxEmails = emails.filter { $0.folder == .inbox }
        XCTAssertEqual(inboxEmails.count, 2)
        XCTAssertFalse(inboxEmails.contains(where: { $0.msgId == "old1" }))
    }

    func testFetchEmailsPreservesOtherFolderEmails() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        // Pre-populate with emails from a different folder
        let trashEmail = makeEmail(msgId: "trash1", folder: .trash)
        manager.emailsByAccount[testAccountId] = [trashEmail]

        setupMockForFetchEmails()

        await manager.fetchEmails(for: testAccountId)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        // Should still have the trash email
        XCTAssertTrue(emails.contains(where: { $0.msgId == "trash1" && $0.folder == .trash }))
        // Plus the 2 new inbox emails
        let inboxEmails = emails.filter { $0.folder == .inbox }
        XCTAssertEqual(inboxEmails.count, 2)
    }

    func testRemoveClientClearsPageTokens() throws {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)
        manager.pageTokens[testAccountId] = [.inbox: "someToken"]

        manager.removeClient(for: testAccountId)

        XCTAssertNil(manager.pageTokens[testAccountId])
    }

    // MARK: - Infinite Scroll (fetchMoreEmails)

    func testFetchMoreEmailsAppendsResults() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        // Set up initial state: some emails already loaded, with a pageToken
        manager.emailsByAccount[testAccountId] = [makeEmail(msgId: "msg1"), makeEmail(msgId: "msg2")]
        manager.pageTokens[testAccountId] = [.inbox: "page2token"]

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/messages") && !url.contains("/messages/") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"messages": [{"id": "msg3", "threadId": "t3"}, {"id": "msg4", "threadId": "t4"}], "resultSizeEstimate": 2}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg3") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg3", "threadId": "t3", "labelIds": ["INBOX", "UNREAD"], "snippet": "More1",
                 "payload": {"headers": [{"name": "From", "value": "e@f.com"}, {"name": "Subject", "value": "More1"}]},
                 "internalDate": "1711000003000", "historyId": "12348"}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg4") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg4", "threadId": "t4", "labelIds": ["INBOX"], "snippet": "More2",
                 "payload": {"headers": [{"name": "From", "value": "g@h.com"}, {"name": "Subject", "value": "More2"}]},
                 "internalDate": "1711000004000", "historyId": "12349"}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.fetchMoreEmails(accountId: testAccountId, folder: .inbox)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        XCTAssertEqual(emails.count, 4, "Should have original 2 + 2 new emails")
        XCTAssertTrue(emails.contains(where: { $0.msgId == "msg1" }))
        XCTAssertTrue(emails.contains(where: { $0.msgId == "msg3" }))
        XCTAssertTrue(emails.contains(where: { $0.msgId == "msg4" }))
    }

    func testFetchMoreEmailsNoDuplicates() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        manager.emailsByAccount[testAccountId] = [makeEmail(msgId: "msg1")]
        manager.pageTokens[testAccountId] = [.inbox: "page2token"]

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/messages") && !url.contains("/messages/") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                // Returns msg1 again (duplicate)
                let json = """
                {"messages": [{"id": "msg1", "threadId": "t1"}], "resultSizeEstimate": 1}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg1") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg1", "threadId": "t1", "labelIds": ["INBOX"], "snippet": "Hello",
                 "payload": {"headers": [{"name": "From", "value": "a@b.com"}, {"name": "Subject", "value": "Hi"}]},
                 "internalDate": "1711000000000", "historyId": "12345"}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.fetchMoreEmails(accountId: testAccountId, folder: .inbox)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        XCTAssertEqual(emails.count, 1, "Duplicate should not be appended")
    }

    func testFetchMoreEmailsNoOpWithoutPageToken() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        manager.emailsByAccount[testAccountId] = [makeEmail(msgId: "msg1")]
        // No pageToken set

        await manager.fetchMoreEmails(accountId: testAccountId, folder: .inbox)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        XCTAssertEqual(emails.count, 1, "Should not change when no page token exists")
    }

    func testFetchMoreEmailsClearsPageTokenWhenNoMore() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        manager.pageTokens[testAccountId] = [.inbox: "lastPageToken"]

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/messages") && !url.contains("/messages/") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                // No nextPageToken = last page
                let json = """
                {"messages": [{"id": "msg5", "threadId": "t5"}], "resultSizeEstimate": 1}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg5") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg5", "threadId": "t5", "labelIds": ["INBOX"], "snippet": "Last",
                 "payload": {"headers": [{"name": "From", "value": "z@z.com"}, {"name": "Subject", "value": "Last"}]},
                 "internalDate": "1711000005000", "historyId": "12350"}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.fetchMoreEmails(accountId: testAccountId, folder: .inbox)

        // pageToken should be cleared (nil) since no nextPageToken was returned
        XCTAssertNil(manager.pageTokens[testAccountId]?[.inbox])
    }

    func testPageTokenStoredAfterFetchEmailsWithMorePages() async {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/labels/INBOX") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "INBOX", "name": "INBOX", "messagesUnread": 1}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages") && !url.contains("/messages/") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                // This response HAS a nextPageToken — simulating the last fetched page still having more
                // But fetchEmails loops until pageToken is nil, so we only return nextPageToken on first call
                let hasPageToken = !url.contains("pageToken")
                let json: String
                if hasPageToken {
                    json = """
                    {"messages": [{"id": "msg1", "threadId": "t1"}], "nextPageToken": "nextPage123", "resultSizeEstimate": 1}
                    """
                } else {
                    json = """
                    {"messages": [{"id": "msg2", "threadId": "t2"}], "resultSizeEstimate": 1}
                    """
                }
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg1") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "snippet": "Hello",
                 "payload": {"headers": [{"name": "From", "value": "a@b.com"}, {"name": "Subject", "value": "Hi"}]},
                 "internalDate": "1711000000000", "historyId": "12345"}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg2") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg2", "threadId": "t2", "labelIds": ["INBOX"], "snippet": "World",
                 "payload": {"headers": [{"name": "From", "value": "c@d.com"}, {"name": "Subject", "value": "Hey"}]},
                 "internalDate": "1711000001000", "historyId": "12346"}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        await manager.fetchEmails(for: testAccountId)

        // fetchEmails stops after first batch; pageToken is stored for infinite scroll
        XCTAssertEqual(manager.pageTokens[testAccountId]?[.inbox], "nextPage123")
    }

    func testNavigateAllToFolderClearsPageTokens() async {
        manager.pageTokens["acc1"] = [.inbox: "token1"]
        manager.pageTokens["acc2"] = [.inbox: "token2"]

        await manager.navigateAllToFolder(.trash)

        XCTAssertTrue(manager.pageTokens.isEmpty, "navigateAllToFolder should clear all page tokens")
    }

    // MARK: - Polling Timer

    func testPollingTimerFiresFetchAndSync() async throws {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let listCallCount = RequestCounter()
        let historyCallCount = RequestCounter()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/labels/INBOX") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, #"{"id":"INBOX","name":"INBOX","messagesUnread":0}"#.data(using: .utf8)!)
            }

            if url.contains("/history") {
                historyCallCount.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, #"{"historyId":"200"}"#.data(using: .utf8)!)
            }

            // Individual message fetch (GET /messages/{id})
            if url.contains("/messages/msg1") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let msg = #"{"id":"msg1","threadId":"t1","historyId":"100","labelIds":["INBOX"],"payload":{"headers":[{"name":"From","value":"test@example.com"},{"name":"Subject","value":"Test"},{"name":"Date","value":"Mon, 1 Jan 2024 00:00:00 +0000"}]},"snippet":"test","internalDate":"1704067200000"}"#
                return (response, msg.data(using: .utf8)!)
            }

            if url.contains("/messages") && !url.contains("/messages/") {
                listCallCount.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, #"{"messages":[{"id":"msg1","threadId":"t1"}],"resultSizeEstimate":1,"historyId":"100"}"#.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        let historyExpectation = expectation(description: "History API called at least once")
        historyCallCount.onFirstIncrement = { historyExpectation.fulfill() }

        // Start polling with a very short interval
        manager.startPollingAll(interval: 0.1)
        XCTAssertTrue(manager.isPolling)

        // Wait for the initial fetch + at least one timer-driven sync cycle
        await fulfillment(of: [historyExpectation], timeout: 5)

        manager.stopPollingAll()
        XCTAssertFalse(manager.isPolling)

        // The initial full fetch should have called listMessages
        XCTAssertGreaterThanOrEqual(listCallCount.value, 1, "Initial fetch should have called listMessages")
        // The timer-driven sync should have called the history endpoint at least once
        XCTAssertGreaterThanOrEqual(historyCallCount.value, 1, "Timer-driven sync should have called history API")
    }

    // MARK: - Cache Integration

    func testLoadCachedEmailsPopulatesAtStartup() {
        // Create a cache with pre-loaded emails
        let cache = EmailCache(inMemory: true)
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        accountManager.addAccount(account)

        // Save some emails to cache
        let email1 = Email(msgId: "cached1", from: "a@b.com", subject: "Cached 1", date: Date(), snippet: "snap1", isRead: false, accountId: testAccountId, folder: .inbox)
        let email2 = Email(msgId: "cached2", from: "c@d.com", subject: "Cached 2", date: Date(), snippet: "snap2", isRead: true, accountId: testAccountId, folder: .inbox)
        cache.saveEmails([email1, email2])

        // Create a new manager with this cache — loadCachedEmails runs in init
        let cachedManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, dataStore: cache, keychainStore: mockKeychain)

        let emails = cachedManager.emailsByAccount[testAccountId] ?? []
        XCTAssertEqual(emails.count, 2)
        XCTAssertTrue(emails.contains(where: { $0.msgId == "cached1" }))
        XCTAssertTrue(emails.contains(where: { $0.msgId == "cached2" }))
        cachedManager.stopPollingAll()
    }

    func testLoadCachedEmailsSkipsEmptyAccounts() {
        let cache = EmailCache(inMemory: true)
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        accountManager.addAccount(account)

        // No emails saved for this account
        let cachedManager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, dataStore: cache, keychainStore: mockKeychain)

        // Should not have any emails (empty cache doesn't create entry)
        XCTAssertNil(cachedManager.emailsByAccount[testAccountId])
        cachedManager.stopPollingAll()
    }

    // MARK: - Archive/Spam/Delete Folder Sync

    func testArchiveEmailRemovesFromInboxAndAddsToArchive() async throws {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let inboxEmail = makeEmail(msgId: "m1", folder: .inbox)
        manager.emailsByAccount[testAccountId] = [inboxEmail]

        setupMockForModifyMessage()

        try await manager.archiveEmail(msgId: "m1", accountId: testAccountId, folder: .inbox)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        // Should not be in inbox
        XCTAssertFalse(emails.contains(where: { $0.msgId == "m1" && $0.folder == .inbox }))
        // Should appear in archive
        XCTAssertTrue(emails.contains(where: { $0.msgId == "m1" && $0.folder == .archive }))
        XCTAssertEqual(emails.count, 1)
    }

    func testDeleteEmailRemovesFromInboxAndAddsToTrash() async throws {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let inboxEmail = makeEmail(msgId: "m1", folder: .inbox)
        manager.emailsByAccount[testAccountId] = [inboxEmail]

        setupMockForModifyMessage()

        try await manager.deleteEmail(msgId: "m1", accountId: testAccountId, folder: .inbox)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        XCTAssertFalse(emails.contains(where: { $0.msgId == "m1" && $0.folder == .inbox }))
        XCTAssertTrue(emails.contains(where: { $0.msgId == "m1" && $0.folder == .trash }))
        XCTAssertEqual(emails.count, 1)
    }

    func testSpamEmailRemovesFromInboxAndAddsToSpam() async throws {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let inboxEmail = makeEmail(msgId: "m1", folder: .inbox)
        manager.emailsByAccount[testAccountId] = [inboxEmail]

        setupMockForModifyMessage()

        try await manager.spamEmail(msgId: "m1", accountId: testAccountId, folder: .inbox)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        XCTAssertFalse(emails.contains(where: { $0.msgId == "m1" && $0.folder == .inbox }))
        XCTAssertTrue(emails.contains(where: { $0.msgId == "m1" && $0.folder == .spam }))
        XCTAssertEqual(emails.count, 1)
    }

    func testArchiveEmailPreservesOtherEmails() async throws {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let email1 = makeEmail(msgId: "m1", folder: .inbox)
        let email2 = makeEmail(msgId: "m2", folder: .inbox)
        manager.emailsByAccount[testAccountId] = [email1, email2]

        setupMockForModifyMessage()

        try await manager.archiveEmail(msgId: "m1", accountId: testAccountId, folder: .inbox)

        let emails = manager.emailsByAccount[testAccountId] ?? []
        // m2 should remain in inbox
        XCTAssertTrue(emails.contains(where: { $0.msgId == "m2" && $0.folder == .inbox }))
        // m1 should be in archive
        XCTAssertTrue(emails.contains(where: { $0.msgId == "m1" && $0.folder == .archive }))
        XCTAssertEqual(emails.count, 2)
    }

    func testMovedEmailPreservesMetadata() async throws {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let originalDate = Date(timeIntervalSince1970: 1711000000)
        let email = Email(
            msgId: "m1",
            from: "sender@test.com",
            subject: "Important Subject",
            date: originalDate,
            snippet: "Preview text",
            isRead: true,
            accountId: testAccountId,
            folder: .inbox,
            messageId: "<msg-id@test.com>"
        )
        manager.emailsByAccount[testAccountId] = [email]

        setupMockForModifyMessage()

        try await manager.archiveEmail(msgId: "m1", accountId: testAccountId, folder: .inbox)

        let movedEmail = manager.emailsByAccount[testAccountId]?.first(where: { $0.folder == .archive })
        XCTAssertNotNil(movedEmail)
        XCTAssertEqual(movedEmail?.from, "sender@test.com")
        XCTAssertEqual(movedEmail?.subject, "Important Subject")
        XCTAssertEqual(movedEmail?.date, originalDate)
        XCTAssertEqual(movedEmail?.snippet, "Preview text")
        XCTAssertEqual(movedEmail?.isRead, true)
        XCTAssertEqual(movedEmail?.messageId, "<msg-id@test.com>")
        XCTAssertEqual(movedEmail?.accountId, testAccountId)
        // id should reflect new folder
        XCTAssertEqual(movedEmail?.id, "\(testAccountId)_archive_m1")
    }

    // MARK: - Thread / threadId

    func testConvertGmailMessageIncludesThreadId() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let message = GmailMessage(
            id: "msg1",
            threadId: "thread_abc",
            labelIds: ["INBOX", "UNREAD"],
            snippet: "Hello",
            payload: GmailPayload(
                mimeType: "text/plain",
                headers: [
                    GmailHeader(name: "From", value: "sender@test.com"),
                    GmailHeader(name: "Subject", value: "Test"),
                ],
                body: nil,
                parts: nil,
                filename: nil
            ),
            internalDate: String(Int(Date().timeIntervalSince1970 * 1000)),
            historyId: nil,
            sizeEstimate: nil
        )
        let email = manager.convertGmailMessageToEmail(message, accountId: testAccountId, folder: .inbox)
        XCTAssertNotNil(email)
        XCTAssertEqual(email?.threadId, "thread_abc")
    }

    // MARK: - Helpers

    private func setupMockForModifyMessage() {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"id": "m1", "threadId": "t1", "labelIds": []}"#
            return (response, json.data(using: .utf8)!)
        }
    }


    private func makeEmail(msgId: String, isRead: Bool = false, folder: Folder = .inbox, date: Date = Date()) -> Email {
        Email(
            msgId: msgId,
            from: "test@test.com",
            subject: "Test",
            date: date,
            snippet: "snippet",
            isRead: isRead,
            accountId: testAccountId,
            folder: folder
        )
    }

    private func setupMockForFetchEmails() {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("/labels/INBOX") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "INBOX", "name": "INBOX", "messagesUnread": 1}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg1") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "snippet": "Hello",
                 "payload": {"headers": [{"name": "From", "value": "a@b.com"}, {"name": "Subject", "value": "Hi"}]},
                 "internalDate": "1711000000000", "historyId": "12345"}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/msg2") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"id": "msg2", "threadId": "t2", "labelIds": ["INBOX"], "snippet": "World",
                 "payload": {"headers": [{"name": "From", "value": "c@d.com"}, {"name": "Subject", "value": "Hey"}]},
                 "internalDate": "1711000001000", "historyId": "12346"}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages") && !url.contains("/messages/") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"messages": [{"id": "msg1", "threadId": "t1"}, {"id": "msg2", "threadId": "t2"}], "resultSizeEstimate": 2}
                """
                return (response, json.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }
    }
}
