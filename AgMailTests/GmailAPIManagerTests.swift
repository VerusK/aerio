import XCTest
@testable import AgMail

@MainActor
final class GmailAPIManagerTests: XCTestCase {
    private var manager: GmailAPIManager!
    private var accountManager: AccountManager!
    private var oauthManager: OAuthManager!
    private var session: URLSession!
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

        oauthManager = OAuthManager()

        // Save test tokens so the client can authenticate
        let tokens = KeychainHelper.OAuthTokens(
            accessToken: "test_access_token",
            refreshToken: "test_refresh_token",
            expiresAt: Date().addingTimeInterval(3600),
            email: testAccountId
        )
        try KeychainHelper.saveTokens(tokens, for: testAccountId)

        manager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager)
        // Inject custom client factory that uses our mock session
        manager.clientFactory = { [session] accountId, oauthManager in
            GmailAPIClient(accountId: accountId, oauthManager: oauthManager, session: session!)
        }
    }

    override func tearDown() {
        manager.stopPollingAll()
        try? KeychainHelper.deleteTokens(for: testAccountId)
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

    func testRemoveClientCleansUpState() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)
        manager.emailsByAccount[testAccountId] = [makeEmail(msgId: "m1")]
        manager.unreadCountsByAccount[testAccountId] = 5

        manager.removeClient(for: testAccountId)

        XCTAssertNil(manager.clients[testAccountId])
        XCTAssertNil(manager.clientStates[testAccountId])
        XCTAssertNil(manager.emailsByAccount[testAccountId])
        XCTAssertNil(manager.unreadCountsByAccount[testAccountId])
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

    func testMarkAsReadOptimisticUpdate() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

        let email = makeEmail(msgId: "m1", isRead: false)
        manager.emailsByAccount[testAccountId] = [email]
        manager.unreadCountsByAccount[testAccountId] = 1

        // Mock the modify API call
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "m1", "threadId": "t1", "labelIds": ["INBOX"]}
            """
            return (response, json.data(using: .utf8)!)
        }

        manager.markAsRead(emailId: email.id, accountId: testAccountId)

        let updated = manager.emailsByAccount[testAccountId]!.first!
        XCTAssertTrue(updated.isRead)
        XCTAssertEqual(manager.unreadCountsByAccount[testAccountId], 0)
    }

    func testMarkAsReadSkipsAlreadyRead() {
        let account = Account(id: testAccountId, email: testAccountId, displayName: "Test")
        manager.addClient(for: account)

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

    // MARK: - Navigate to Folder

    func testNavigateAllToFolder() async {
        // Just verify it doesn't crash and the folder is stored
        await manager.navigateAllToFolder(.trash)
        // Next fetch should use the new folder - we can verify indirectly
    }

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

        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            requestCount += 1

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

    // MARK: - Helpers

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
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            callCount += 1

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
