import Foundation
@testable import AgMail

final class MockKeychainStore: KeychainStore {
    private var storage: [String: KeychainHelper.OAuthTokens] = [:]

    func saveTokens(_ tokens: KeychainHelper.OAuthTokens, for accountId: String) throws {
        storage[accountId] = tokens
    }

    func loadTokens(for accountId: String) throws -> KeychainHelper.OAuthTokens? {
        storage[accountId]
    }

    func deleteTokens(for accountId: String) throws {
        storage.removeValue(forKey: accountId)
    }

    func updateAccessToken(_ accessToken: String, expiresIn: Int, for accountId: String) throws {
        guard var tokens = storage[accountId] else { return }
        tokens.accessToken = accessToken
        tokens.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        storage[accountId] = tokens
    }
}
