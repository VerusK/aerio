import XCTest
@testable import AgMail

final class KeychainHelperTests: XCTestCase {
    private var store: MockKeychainStore!
    private let testAccountId = "keychain-test-account1"
    private let testAccountId2 = "keychain-test-account2"

    private func makeTokens(
        accessToken: String = "access_123",
        refreshToken: String = "refresh_456",
        expiresAt: Date = Date().addingTimeInterval(3600),
        email: String = "test@gmail.com"
    ) -> KeychainHelper.OAuthTokens {
        KeychainHelper.OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            email: email
        )
    }

    override func setUp() {
        store = MockKeychainStore()
    }

    // MARK: - KeychainStore protocol tests (via MockKeychainStore)

    func testSaveAndLoadTokens() throws {
        let tokens = makeTokens()
        try store.saveTokens(tokens, for: testAccountId)

        let loaded = try store.loadTokens(for: testAccountId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.accessToken, "access_123")
        XCTAssertEqual(loaded?.refreshToken, "refresh_456")
        XCTAssertEqual(loaded?.email, "test@gmail.com")
    }

    func testLoadNonexistentReturnsNil() throws {
        let loaded = try store.loadTokens(for: "nonexistent-account-id")
        XCTAssertNil(loaded)
    }

    func testDeleteTokens() throws {
        let tokens = makeTokens()
        try store.saveTokens(tokens, for: testAccountId)
        try store.deleteTokens(for: testAccountId)

        let loaded = try store.loadTokens(for: testAccountId)
        XCTAssertNil(loaded)
    }

    func testDeleteNonexistentDoesNotThrow() throws {
        XCTAssertNoThrow(try store.deleteTokens(for: "nonexistent-account"))
    }

    func testUpdateAccessToken() throws {
        let tokens = makeTokens()
        try store.saveTokens(tokens, for: testAccountId)

        try store.updateAccessToken("new_access_token", expiresIn: 7200, for: testAccountId)

        let loaded = try store.loadTokens(for: testAccountId)
        XCTAssertEqual(loaded?.accessToken, "new_access_token")
        XCTAssertEqual(loaded?.refreshToken, "refresh_456")
        XCTAssertEqual(loaded?.email, "test@gmail.com")
    }

    func testSaveOverwritesExisting() throws {
        let tokens1 = makeTokens(accessToken: "first")
        try store.saveTokens(tokens1, for: testAccountId)

        let tokens2 = makeTokens(accessToken: "second")
        try store.saveTokens(tokens2, for: testAccountId)

        let loaded = try store.loadTokens(for: testAccountId)
        XCTAssertEqual(loaded?.accessToken, "second")
    }

    // MARK: - OAuthTokens model tests

    func testIsExpired() {
        let expired = makeTokens(expiresAt: Date().addingTimeInterval(-10))
        XCTAssertTrue(expired.isExpired)

        let notExpired = makeTokens(expiresAt: Date().addingTimeInterval(3600))
        XCTAssertFalse(notExpired.isExpired)
    }

    func testIsExpiredWithBuffer() {
        let almostExpired = makeTokens(expiresAt: Date().addingTimeInterval(30))
        XCTAssertTrue(almostExpired.isExpired)
    }

    func testMultipleAccountsIndependent() throws {
        let tokens1 = makeTokens(accessToken: "token_1", email: "user1@gmail.com")
        let tokens2 = makeTokens(accessToken: "token_2", email: "user2@gmail.com")

        try store.saveTokens(tokens1, for: testAccountId)
        try store.saveTokens(tokens2, for: testAccountId2)

        let loaded1 = try store.loadTokens(for: testAccountId)
        let loaded2 = try store.loadTokens(for: testAccountId2)

        XCTAssertEqual(loaded1?.accessToken, "token_1")
        XCTAssertEqual(loaded2?.accessToken, "token_2")

        try store.deleteTokens(for: testAccountId)

        XCTAssertNil(try store.loadTokens(for: testAccountId))
        XCTAssertNotNil(try store.loadTokens(for: testAccountId2))
    }
}
