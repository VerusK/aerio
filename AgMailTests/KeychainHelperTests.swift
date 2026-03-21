import XCTest
@testable import AgMail

final class KeychainHelperTests: XCTestCase {
    private let testAccountId = "keychain-test-\(UUID().uuidString)"
    private let testAccountId2 = "keychain-test2-\(UUID().uuidString)"

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

    override func tearDown() {
        try? KeychainHelper.deleteTokens(for: testAccountId)
        try? KeychainHelper.deleteTokens(for: testAccountId2)
        super.tearDown()
    }

    func testSaveAndLoadTokens() throws {
        let tokens = makeTokens()
        try KeychainHelper.saveTokens(tokens, for: testAccountId)

        let loaded = try KeychainHelper.loadTokens(for: testAccountId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.accessToken, "access_123")
        XCTAssertEqual(loaded?.refreshToken, "refresh_456")
        XCTAssertEqual(loaded?.email, "test@gmail.com")
    }

    func testLoadNonexistentReturnsNil() throws {
        let loaded = try KeychainHelper.loadTokens(for: "nonexistent-account-id")
        XCTAssertNil(loaded)
    }

    func testDeleteTokens() throws {
        let tokens = makeTokens()
        try KeychainHelper.saveTokens(tokens, for: testAccountId)
        try KeychainHelper.deleteTokens(for: testAccountId)

        let loaded = try KeychainHelper.loadTokens(for: testAccountId)
        XCTAssertNil(loaded)
    }

    func testDeleteNonexistentDoesNotThrow() throws {
        XCTAssertNoThrow(try KeychainHelper.deleteTokens(for: "nonexistent-account"))
    }

    func testUpdateAccessToken() throws {
        let tokens = makeTokens()
        try KeychainHelper.saveTokens(tokens, for: testAccountId)

        try KeychainHelper.updateAccessToken("new_access_token", expiresIn: 7200, for: testAccountId)

        let loaded = try KeychainHelper.loadTokens(for: testAccountId)
        XCTAssertEqual(loaded?.accessToken, "new_access_token")
        XCTAssertEqual(loaded?.refreshToken, "refresh_456")
        XCTAssertEqual(loaded?.email, "test@gmail.com")
    }

    func testSaveOverwritesExisting() throws {
        let tokens1 = makeTokens(accessToken: "first")
        try KeychainHelper.saveTokens(tokens1, for: testAccountId)

        let tokens2 = makeTokens(accessToken: "second")
        try KeychainHelper.saveTokens(tokens2, for: testAccountId)

        let loaded = try KeychainHelper.loadTokens(for: testAccountId)
        XCTAssertEqual(loaded?.accessToken, "second")
    }

    func testIsExpired() {
        let expired = makeTokens(expiresAt: Date().addingTimeInterval(-10))
        XCTAssertTrue(expired.isExpired)

        let notExpired = makeTokens(expiresAt: Date().addingTimeInterval(3600))
        XCTAssertFalse(notExpired.isExpired)
    }

    func testIsExpiredWithBuffer() {
        // Token expiring in 30 seconds should be considered expired (60s buffer)
        let almostExpired = makeTokens(expiresAt: Date().addingTimeInterval(30))
        XCTAssertTrue(almostExpired.isExpired)
    }

    func testMultipleAccountsIndependent() throws {
        let tokens1 = makeTokens(accessToken: "token_1", email: "user1@gmail.com")
        let tokens2 = makeTokens(accessToken: "token_2", email: "user2@gmail.com")

        try KeychainHelper.saveTokens(tokens1, for: testAccountId)
        try KeychainHelper.saveTokens(tokens2, for: testAccountId2)

        let loaded1 = try KeychainHelper.loadTokens(for: testAccountId)
        let loaded2 = try KeychainHelper.loadTokens(for: testAccountId2)

        XCTAssertEqual(loaded1?.accessToken, "token_1")
        XCTAssertEqual(loaded2?.accessToken, "token_2")

        try KeychainHelper.deleteTokens(for: testAccountId)

        XCTAssertNil(try KeychainHelper.loadTokens(for: testAccountId))
        XCTAssertNotNil(try KeychainHelper.loadTokens(for: testAccountId2))
    }
}
