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
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    @discardableResult func increment() -> Int {
        lock.lock(); defer { lock.unlock() }; _value += 1; return _value
    }
}

// MARK: - Tests

@MainActor
final class GmailAPIClientTests: XCTestCase {
    private var client: GmailAPIClient!
    private var session: URLSession!
    private let testAccountId = "api-client-test@gmail.com"

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        let tokens = KeychainHelper.OAuthTokens(
            accessToken: "test_access_token",
            refreshToken: "test_refresh_token",
            expiresAt: Date().addingTimeInterval(3600),
            email: testAccountId
        )
        try KeychainHelper.saveTokens(tokens, for: testAccountId)

        let oauthManager = OAuthManager()
        client = GmailAPIClient(accountId: testAccountId, oauthManager: oauthManager, session: session)
    }

    override func tearDown() {
        try? KeychainHelper.deleteTokens(for: testAccountId)
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
