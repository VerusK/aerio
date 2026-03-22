import XCTest
@testable import AgMail

// MARK: - Mock URL Protocol

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            var mutableRequest = request
            if mutableRequest.httpBody == nil, let stream = mutableRequest.httpBodyStream {
                stream.open()
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: 1024)
                    if read > 0 { data.append(buffer, count: read) }
                    else { break }
                }
                stream.close()
                mutableRequest.httpBody = data
            }
            let (response, data) = try handler(mutableRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Thread-safe Counter

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var onFirstIncrement: (() -> Void)?
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    @discardableResult func increment() -> Int {
        lock.lock()
        _value += 1
        let current = _value
        let callback = onFirstIncrement
        lock.unlock()
        if current == 1 { callback?() }
        return current
    }
}

// MARK: - Tests

@MainActor
final class GmailAPIClientTests: XCTestCase {
    private var client: GmailAPIClient!
    private var session: URLSession!
    private var mockKeychain: MockKeychainStore!
    private let testAccountId = "api-client-test@gmail.com"

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        mockKeychain = MockKeychainStore()

        let tokens = KeychainHelper.OAuthTokens(
            accessToken: "test_access_token",
            refreshToken: "test_refresh_token",
            expiresAt: Date().addingTimeInterval(3600),
            email: testAccountId
        )
        try mockKeychain.saveTokens(tokens, for: testAccountId)

        let oauthManager = OAuthManager(keychainStore: mockKeychain)
        client = GmailAPIClient(accountId: testAccountId, oauthManager: oauthManager, session: session, keychainStore: mockKeychain)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
    }

    // MARK: - Request Construction

    func testListMessagesRequestConstruction() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url!.absoluteString.contains("/messages"))
            XCTAssertTrue(request.url!.absoluteString.contains("maxResults=20"))
            XCTAssertTrue(request.url!.absoluteString.contains("q=in%3Ainbox") || request.url!.absoluteString.contains("q=in:inbox"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test_access_token")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"messages": [{"id": "msg1", "threadId": "t1"}], "resultSizeEstimate": 1}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.listMessages(query: "in:inbox", maxResults: 20)
        XCTAssertEqual(result.messages?.count, 1)
        XCTAssertEqual(result.messages?.first?.id, "msg1")
    }

    func testGetMessageRequestConstruction() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("/messages/msg123"))
            XCTAssertTrue(request.url!.absoluteString.contains("format=full"))

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "msg123", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "snippet": "Hello", "internalDate": "1711000000000"}
            """
            return (response, json.data(using: .utf8)!)
        }

        let message = try await client.getMessage(id: "msg123")
        XCTAssertEqual(message.id, "msg123")
        XCTAssertEqual(message.labelIds, ["INBOX", "UNREAD"])
        XCTAssertEqual(message.snippet, "Hello")
    }

    func testModifyMessageSendsCorrectBody() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.absoluteString.contains("/messages/msg1/modify"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try! JSONDecoder().decode(GmailModifyRequest.self, from: request.httpBody!)
            XCTAssertEqual(body.removeLabelIds, ["UNREAD"])

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "msg1", "threadId": "t1", "labelIds": ["INBOX"]}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.modifyMessage(id: "msg1", removeLabels: ["UNREAD"])
        XCTAssertEqual(result.id, "msg1")
        XCTAssertFalse(result.labelIds?.contains("UNREAD") ?? false)
    }

    func testSendMessageConstruction() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.absoluteString.contains("/messages/send"))

            let body = try! JSONDecoder().decode(GmailSendRequest.self, from: request.httpBody!)
            XCTAssertEqual(body.raw, "dGVzdA")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "sent1", "threadId": "t1", "labelIds": ["SENT"]}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.sendMessage(raw: "dGVzdA")
        XCTAssertEqual(result.id, "sent1")
    }

    // MARK: - Draft

    func testCreateDraftConstruction() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.absoluteString.contains("/drafts"))

            let body = try! JSONDecoder().decode(GmailDraftRequest.self, from: request.httpBody!)
            XCTAssertEqual(body.message.raw, "dGVzdA")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "draft1", "message": {"id": "m1", "threadId": "t1"}}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.createDraft(raw: "dGVzdA")
        XCTAssertEqual(result.id, "draft1")
    }

    // MARK: - Error Handling

    func testServerErrorRetries() async throws {
        let counter = RequestCounter()

        MockURLProtocol.requestHandler = { request in
            let count = counter.increment()
            if count <= 2 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"resultSizeEstimate": 0}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.listMessages()
        XCTAssertEqual(counter.value, 3)
        XCTAssertNil(result.messages)
    }

    func testServerErrorExhaustsRetries() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await client.listMessages()
            XCTFail("Should have thrown")
        } catch let error as GmailAPIError {
            if case .serverError(503) = error {
                // expected
            } else {
                XCTFail("Expected serverError(503), got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testForbiddenError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, "quota exceeded".data(using: .utf8)!)
        }

        do {
            _ = try await client.listMessages()
            XCTFail("Should have thrown")
        } catch let error as GmailAPIError {
            if case .forbidden(let msg) = error {
                XCTAssertTrue(msg.contains("quota"))
            } else {
                XCTFail("Expected forbidden, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNotFoundError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await client.getMessage(id: "nonexistent")
            XCTFail("Should have thrown")
        } catch let error as GmailAPIError {
            if case .notFound = error {
                // expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSuccessfulDecoding() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "id": "msg1",
                "threadId": "t1",
                "labelIds": ["INBOX", "UNREAD"],
                "snippet": "Test snippet",
                "payload": {
                    "mimeType": "text/plain",
                    "headers": [{"name": "From", "value": "sender@test.com"}, {"name": "Subject", "value": "Test"}],
                    "body": {"size": 10, "data": "SGVsbG8"}
                },
                "internalDate": "1711000000000",
                "historyId": "12345"
            }
            """
            return (response, json.data(using: .utf8)!)
        }

        let message = try await client.getMessage(id: "msg1")
        XCTAssertEqual(message.id, "msg1")
        XCTAssertEqual(message.payload?.mimeType, "text/plain")
        XCTAssertEqual(message.payload?.headers?.count, 2)
        XCTAssertEqual(message.payload?.headers?.first?.name, "From")
        XCTAssertEqual(message.payload?.body?.data, "SGVsbG8")
        XCTAssertEqual(message.historyId, "12345")
    }

    // MARK: - Labels

    func testListLabels() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("/labels"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"labels": [{"id": "INBOX", "name": "INBOX", "messagesUnread": 5}, {"id": "SENT", "name": "SENT"}]}
            """
            return (response, json.data(using: .utf8)!)
        }

        let labels = try await client.listLabels()
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels.first?.messagesUnread, 5)
    }

    func testGetLabel() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("/labels/INBOX"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "INBOX", "name": "INBOX", "messagesUnread": 3, "messagesTotal": 100}
            """
            return (response, json.data(using: .utf8)!)
        }

        let label = try await client.getLabel(id: "INBOX")
        XCTAssertEqual(label.messagesUnread, 3)
        XCTAssertEqual(label.messagesTotal, 100)
    }

    // MARK: - 401 Token Refresh

    func testUnauthorizedTriggersRefreshAndRetry() async throws {
        // Register globally to intercept OAuthManager's URLSession.shared calls
        URLProtocol.registerClass(MockURLProtocol.self)
        defer { URLProtocol.unregisterClass(MockURLProtocol.self) }

        let apiCounter = RequestCounter()

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            // Token refresh endpoint (OAuthManager -> URLSession.shared)
            if url.contains("oauth2.googleapis.com/token") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"access_token": "refreshed_token", "expires_in": 3600, "token_type": "Bearer"}
                """
                return (response, json.data(using: .utf8)!)
            }

            // Gmail API calls
            let count = apiCounter.increment()
            if count == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            // Retry after refresh should use new token
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed_token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"messages": [{"id": "msg1", "threadId": "t1"}], "resultSizeEstimate": 1}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.listMessages()
        XCTAssertEqual(result.messages?.count, 1)
        XCTAssertEqual(apiCounter.value, 2)
    }

    func testUnauthorizedWithFailedRefreshPropagatesError() async {
        // Register globally for OAuthManager's URLSession.shared
        URLProtocol.registerClass(MockURLProtocol.self)
        defer { URLProtocol.unregisterClass(MockURLProtocol.self) }

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("oauth2.googleapis.com/token") {
                // Refresh fails
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (response, "invalid_grant".data(using: .utf8)!)
            }

            // API call returns 401
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await client.listMessages()
            XCTFail("Should have thrown")
        } catch {
            // Should propagate refresh error, not loop infinitely
            XCTAssertTrue(error is OAuthManager.OAuthError, "Expected OAuthError, got \(error)")
        }
    }

    func testConcurrent401sCoalesceIntoSingleRefresh() async throws {
        // Register globally for OAuthManager's URLSession.shared
        URLProtocol.registerClass(MockURLProtocol.self)
        defer { URLProtocol.unregisterClass(MockURLProtocol.self) }

        let refreshCounter = RequestCounter()
        let apiCounter = RequestCounter()

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString

            if url.contains("oauth2.googleapis.com/token") {
                refreshCounter.increment()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                {"access_token": "refreshed_token", "expires_in": 3600, "token_type": "Bearer"}
                """
                return (response, json.data(using: .utf8)!)
            }

            let count = apiCounter.increment()
            if count <= 2 {
                // First two calls (concurrent) return 401
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            // Retries succeed
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "msg1", "threadId": "t1", "labelIds": ["INBOX"]}
            """
            return (response, json.data(using: .utf8)!)
        }

        // Fire two requests concurrently
        async let r1: GmailMessage = client.getMessage(id: "m1")
        async let r2: GmailMessage = client.getMessage(id: "m2")

        let (msg1, msg2) = try await (r1, r2)
        // Both requests should succeed after refresh
        XCTAssertNotNil(msg1.id)
        XCTAssertNotNil(msg2.id)
        // Both 401s should coalesce — at most 1 refresh call
        XCTAssertEqual(refreshCounter.value, 1, "Concurrent 401s should coalesce into single refresh")
    }

    // MARK: - Endpoint Tests

    func testTrashMessageRequestShape() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "msg1", "threadId": "t1", "labelIds": ["TRASH"]}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.trashMessage(id: "msg1")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertTrue(capturedRequest!.url!.absoluteString.contains("/messages/msg1/trash"))
        XCTAssertEqual(result.labelIds, ["TRASH"])
    }

    func testGetAttachmentRequestAndResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("/messages/msg1/attachments/att1"))
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"attachmentId": "att1", "size": 1024, "data": "SGVsbG8gV29ybGQ"}
            """
            return (response, json.data(using: .utf8)!)
        }

        let attachment = try await client.getAttachment(messageId: "msg1", attachmentId: "att1")
        XCTAssertEqual(attachment.attachmentId, "att1")
        XCTAssertEqual(attachment.size, 1024)
        XCTAssertEqual(attachment.data, "SGVsbG8gV29ybGQ")
    }

    func testListHistoryRequestAndResponse() async throws {
        var capturedURL: String?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "history": [
                    {
                        "id": "12345",
                        "messagesAdded": [{"message": {"id": "new1", "threadId": "t1"}}]
                    }
                ],
                "historyId": "12346"
            }
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.listHistory(startHistoryId: "12340", labelId: "INBOX")
        XCTAssertTrue(capturedURL!.contains("startHistoryId=12340"))
        XCTAssertTrue(capturedURL!.contains("labelId=INBOX"))
        XCTAssertEqual(result.history?.count, 1)
        XCTAssertEqual(result.historyId, "12346")
        XCTAssertEqual(result.history?.first?.messagesAdded?.count, 1)
    }

    func testListDraftsRequestAndResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("/drafts"))
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"drafts": [{"id": "d1", "message": {"id": "m1", "threadId": "t1"}}, {"id": "d2", "message": {"id": "m2", "threadId": "t2"}}]}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.listDrafts()
        XCTAssertEqual(result.drafts?.count, 2)
        XCTAssertEqual(result.drafts?.first?.id, "d1")
    }

    func testGetDraftRequestAndResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("/drafts/d1"))
            XCTAssertTrue(request.url!.absoluteString.contains("format=full"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "d1", "message": {"id": "m1", "threadId": "t1", "snippet": "Draft content"}}
            """
            return (response, json.data(using: .utf8)!)
        }

        let draft = try await client.getDraft(draftId: "d1")
        XCTAssertEqual(draft.id, "d1")
        XCTAssertEqual(draft.message?.snippet, "Draft content")
    }

    func testSendDraftRequestShape() async throws {
        var capturedBody: [String: String]?
        MockURLProtocol.requestHandler = { request in
            capturedBody = try? JSONDecoder().decode([String: String].self, from: request.httpBody!)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "sent1", "threadId": "t1", "labelIds": ["SENT"]}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.sendDraft(draftId: "d1")
        XCTAssertEqual(capturedBody?["id"], "d1")
        XCTAssertEqual(result.id, "sent1")
    }

    func testSearchWithQueryAndPageToken() async throws {
        var capturedURL: String?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"messages": [{"id": "s1", "threadId": "t1"}], "nextPageToken": "page2", "resultSizeEstimate": 20}
            """
            return (response, json.data(using: .utf8)!)
        }

        let result = try await client.listMessages(query: "from:user@test.com has:attachment", maxResults: 20, pageToken: "page1")
        XCTAssertTrue(capturedURL!.contains("q=from"))
        XCTAssertTrue(capturedURL!.contains("pageToken=page1"))
        XCTAssertTrue(capturedURL!.contains("maxResults=20"))
        XCTAssertEqual(result.nextPageToken, "page2")
        XCTAssertEqual(result.messages?.count, 1)
    }

    // MARK: - Rate Limiting

    func testRateLimitRetriesAndEventuallyThrows() async {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            guard url.contains("gmail.googleapis.com") else {
                // Shouldn't happen, but return error
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "0"])!
            return (response, Data())
        }

        do {
            _ = try await client.listMessages()
            XCTFail("Should have thrown rateLimited")
        } catch let error as GmailAPIError {
            if case .rateLimited = error {
                // expected — exhausted retries
            } else {
                XCTFail("Expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Batch Get

    func testGetMessagesUsesTaskGroup() async throws {
        var requestedIds: [String] = []
        let lock = NSLock()

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if let range = url.range(of: "/messages/") {
                let afterMessages = url[range.upperBound...]
                let id = String(afterMessages.prefix(while: { $0 != "?" }))
                lock.lock()
                requestedIds.append(id)
                lock.unlock()
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"id": "test", "threadId": "t1"}
            """
            return (response, json.data(using: .utf8)!)
        }

        let ids = ["m1", "m2", "m3"]
        let results = try await client.getMessages(ids: ids)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(Set(requestedIds), Set(ids))
    }
}
