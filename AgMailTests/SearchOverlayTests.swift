import XCTest
@testable import AgMail

@MainActor
final class SearchOverlayTests: XCTestCase {
    private var manager: GmailAPIManager!
    private var accountManager: AccountManager!
    private var oauthManager: OAuthManager!
    private var session: URLSession!
    private var mockKeychain: MockKeychainStore!
    private let testAccountId1 = "search-test1@gmail.com"
    private let testAccountId2 = "search-test2@gmail.com"

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        accountManager = AccountManager(defaults: UserDefaults(suiteName: "SearchOverlayTests")!)
        for account in accountManager.accounts {
            accountManager.removeAccount(id: account.id)
        }

        mockKeychain = MockKeychainStore()
        oauthManager = OAuthManager(keychainStore: mockKeychain)

        for id in [testAccountId1, testAccountId2] {
            let tokens = KeychainHelper.OAuthTokens(
                accessToken: "test_access_token",
                refreshToken: "test_refresh_token",
                expiresAt: Date().addingTimeInterval(3600),
                email: id
            )
            try mockKeychain.saveTokens(tokens, for: id)
        }

        manager = GmailAPIManager(accountManager: accountManager, oauthManager: oauthManager, keychainStore: mockKeychain)
        manager.clientFactory = { [session, mockKeychain] accountId, oauthManager in
            GmailAPIClient(accountId: accountId, oauthManager: oauthManager, session: session!, keychainStore: mockKeychain!)
        }
    }

    override func tearDown() {
        manager.stopPollingAll()
        MockURLProtocol.requestHandler = nil
        UserDefaults(suiteName: "SearchOverlayTests")?.removePersistentDomain(forName: "SearchOverlayTests")
    }

    // MARK: - SearchViewModel Tests

    func testSearchViewModelInitialState() {
        let vm = SearchViewModel(apiManager: manager)
        XCTAssertEqual(vm.query, "")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.isSearching)
    }

    func testSearchViewModelClear() {
        let vm = SearchViewModel(apiManager: manager)
        vm.query = "test query"
        vm.clear()
        XCTAssertEqual(vm.query, "")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.isSearching)
    }

    func testPerformSearchWithEmptyQuery() {
        let vm = SearchViewModel(apiManager: manager)
        vm.performSearch(query: "")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.isSearching)
    }

    func testPerformSearchWithWhitespaceQuery() {
        let vm = SearchViewModel(apiManager: manager)
        vm.performSearch(query: "   ")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.isSearching)
    }

    // MARK: - Search API Tests

    func testSearchEmailsSingleAccount() async {
        let account = Account(id: testAccountId1, email: testAccountId1, displayName: "Test1")
        manager.addClient(for: account)

        setupMockForSearch(messageIds: ["s1", "s2"], accountId: testAccountId1)

        let results = await manager.searchEmails(query: "hello")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.accountId == testAccountId1 })
    }

    func testSearchEmailsMultipleAccounts() async {
        let account1 = Account(id: testAccountId1, email: testAccountId1, displayName: "Test1")
        let account2 = Account(id: testAccountId2, email: testAccountId2, displayName: "Test2")
        manager.addClient(for: account1)
        manager.addClient(for: account2)

        setupMockForSearchMultiAccount()

        let results = await manager.searchEmails(query: "hello")
        XCTAssertEqual(results.count, 4)
        let account1Results = results.filter { $0.accountId == testAccountId1 }
        let account2Results = results.filter { $0.accountId == testAccountId2 }
        XCTAssertEqual(account1Results.count, 2)
        XCTAssertEqual(account2Results.count, 2)
    }

    func testSearchEmailsResultsSortedByDate() async {
        let account = Account(id: testAccountId1, email: testAccountId1, displayName: "Test1")
        manager.addClient(for: account)

        setupMockForSearch(messageIds: ["s1", "s2"], accountId: testAccountId1)

        let results = await manager.searchEmails(query: "test")
        // Results should be sorted by date descending (most recent first)
        if results.count >= 2 {
            XCTAssertGreaterThanOrEqual(results[0].date, results[1].date)
        }
    }

    func testSearchEmailsNoResults() async {
        let account = Account(id: testAccountId1, email: testAccountId1, displayName: "Test1")
        manager.addClient(for: account)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"resultSizeEstimate": 0}"#
            return (response, json.data(using: .utf8)!)
        }

        let results = await manager.searchEmails(query: "nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchEmailsHandlesAPIError() async {
        let account = Account(id: testAccountId1, email: testAccountId1, displayName: "Test1")
        manager.addClient(for: account)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, "Server Error".data(using: .utf8)!)
        }

        let results = await manager.searchEmails(query: "error")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchQueryPassedToAPI() async {
        let account = Account(id: testAccountId1, email: testAccountId1, displayName: "Test1")
        manager.addClient(for: account)

        var capturedQuery: String?
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/messages") && !url.contains("/messages/") {
                if let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false),
                   let qItem = components.queryItems?.first(where: { $0.name == "q" }) {
                    capturedQuery = qItem.value
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = #"{"resultSizeEstimate": 0}"#
                return (response, json.data(using: .utf8)!)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        _ = await manager.searchEmails(query: "from:test@example.com subject:important")
        XCTAssertEqual(capturedQuery, "from:test@example.com subject:important")
    }

    func testDebounceInterval() {
        XCTAssertEqual(SearchViewModel.debounceInterval, 0.3)
    }

    // MARK: - Helpers

    private func setupMockForSearch(messageIds: [String], accountId: String) {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            // List messages response
            if url.contains("/messages") && !url.contains("/messages/") {
                let refs = messageIds.map { #"{"id": "\#($0)", "threadId": "t\#($0)"}"# }.joined(separator: ", ")
                let json = #"{"messages": [\#(refs)], "resultSizeEstimate": \#(messageIds.count)}"#
                return (response, json.data(using: .utf8)!)
            }

            // Individual message responses
            for msgId in messageIds {
                if url.contains("/messages/\(msgId)") {
                    let json = """
                    {"id": "\(msgId)", "threadId": "t\(msgId)", "labelIds": ["INBOX", "UNREAD"], "snippet": "Search result",
                     "payload": {"headers": [{"name": "From", "value": "sender@test.com"}, {"name": "Subject", "value": "Search \(msgId)"}]},
                     "internalDate": "\(Int(Date().timeIntervalSince1970 * 1000) - messageIds.firstIndex(of: msgId)! * 60000)", "historyId": "99999"}
                    """
                    return (response, json.data(using: .utf8)!)
                }
            }

            return (response, "{}".data(using: .utf8)!)
        }
    }

    private func setupMockForSearchMultiAccount() {
        MockURLProtocol.requestHandler = { [testAccountId1] request in
            let url = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if url.contains("/messages") && !url.contains("/messages/") {
                // We don't know which account is calling, but we can return different results
                // based on call order. For simplicity, return same structure.
                let json = #"{"messages": [{"id": "sa1", "threadId": "ta1"}, {"id": "sa2", "threadId": "ta2"}], "resultSizeEstimate": 2}"#
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/sa1") {
                let json = """
                {"id": "sa1", "threadId": "ta1", "labelIds": ["INBOX"], "snippet": "Result A1",
                 "payload": {"headers": [{"name": "From", "value": "a@test.com"}, {"name": "Subject", "value": "Sub A1"}]},
                 "internalDate": "1711000000000", "historyId": "99998"}
                """
                return (response, json.data(using: .utf8)!)
            }

            if url.contains("/messages/sa2") {
                let json = """
                {"id": "sa2", "threadId": "ta2", "labelIds": ["INBOX", "UNREAD"], "snippet": "Result A2",
                 "payload": {"headers": [{"name": "From", "value": "b@test.com"}, {"name": "Subject", "value": "Sub A2"}]},
                 "internalDate": "1711000001000", "historyId": "99999"}
                """
                return (response, json.data(using: .utf8)!)
            }

            return (response, "{}".data(using: .utf8)!)
        }
    }
}
