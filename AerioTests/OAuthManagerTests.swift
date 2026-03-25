import XCTest
import CryptoKit
@testable import Aerio

final class OAuthManagerTests: XCTestCase {

    @MainActor
    func testPKCEVerifierLength() {
        let manager = OAuthManager(keychainStore: MockKeychainStore())
        let pkce = manager.generatePKCE()
        // 32 random bytes -> base64url = 43 characters
        XCTAssertEqual(pkce.verifier.count, 43)
    }

    @MainActor
    func testPKCEChallengeIsSHA256OfVerifier() {
        let manager = OAuthManager(keychainStore: MockKeychainStore())
        let pkce = manager.generatePKCE()

        // Manually compute expected challenge
        let verifierData = Data(pkce.verifier.utf8)
        let hash = SHA256.hash(data: verifierData)
        let expectedChallenge = Data(hash).base64URLEncoded()

        XCTAssertEqual(pkce.challenge, expectedChallenge)
    }

    @MainActor
    func testPKCEGeneratesDifferentValues() {
        let manager = OAuthManager(keychainStore: MockKeychainStore())
        let pkce1 = manager.generatePKCE()
        let pkce2 = manager.generatePKCE()

        XCTAssertNotEqual(pkce1.verifier, pkce2.verifier)
        XCTAssertNotEqual(pkce1.challenge, pkce2.challenge)
    }

    @MainActor
    func testPKCEVerifierIsBase64URL() {
        let manager = OAuthManager(keychainStore: MockKeychainStore())
        let pkce = manager.generatePKCE()

        // base64url should not contain +, /, or =
        XCTAssertFalse(pkce.verifier.contains("+"))
        XCTAssertFalse(pkce.verifier.contains("/"))
        XCTAssertFalse(pkce.verifier.contains("="))
    }

    @MainActor
    func testPKCEChallengeIsBase64URL() {
        let manager = OAuthManager(keychainStore: MockKeychainStore())
        let pkce = manager.generatePKCE()

        XCTAssertFalse(pkce.challenge.contains("+"))
        XCTAssertFalse(pkce.challenge.contains("/"))
        XCTAssertFalse(pkce.challenge.contains("="))
    }

    func testBase64URLEncode() {
        let data = Data([0xFF, 0xFE, 0xFD])
        let encoded = data.base64URLEncoded()
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }

    func testBase64URLDecodeRoundtrip() {
        let original = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        let encoded = original.base64URLEncoded()
        let decoded = Data.fromBase64URL(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testBase64URLDecodeInvalidReturnsNil() {
        // Base64 decoding of completely invalid string should return empty or nil
        let decoded = Data.fromBase64URL("!!!invalid!!!")
        // Invalid base64 returns nil from Data(base64Encoded:)
        XCTAssertNil(decoded)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
