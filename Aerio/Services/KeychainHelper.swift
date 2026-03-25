import Foundation
import Security

protocol KeychainStore {
    func saveTokens(_ tokens: KeychainHelper.OAuthTokens, for accountId: String) throws
    func loadTokens(for accountId: String) throws -> KeychainHelper.OAuthTokens?
    func deleteTokens(for accountId: String) throws
    func updateAccessToken(_ accessToken: String, expiresIn: Int, for accountId: String) throws
}

final class KeychainHelper: KeychainStore {
    private static let service = "com.aerio.oauth"
    static let shared = KeychainHelper()

    /// In-memory cache: avoids repeated Keychain prompts on unsigned builds.
    /// Populated on first read, updated on save/delete — Keychain is hit at most once per account per app session.
    private var cache: [String: OAuthTokens] = [:]
    private var cacheLoaded: Set<String> = []

    struct OAuthTokens: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var email: String

        var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
    }

    enum KeychainError: Error {
        case encodingFailed
        case decodingFailed
        case unexpectedStatus(OSStatus)
    }

    func saveTokens(_ tokens: OAuthTokens, for accountId: String) throws {
        let data = try JSONEncoder().encode(tokens)

        // Delete existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountId
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        cache[accountId] = tokens
        cacheLoaded.insert(accountId)
    }

    func loadTokens(for accountId: String) throws -> OAuthTokens? {
        if cacheLoaded.contains(accountId) {
            return cache[accountId]
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountId,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            cacheLoaded.insert(accountId)
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.decodingFailed
        }
        let tokens = try JSONDecoder().decode(OAuthTokens.self, from: data)
        cache[accountId] = tokens
        cacheLoaded.insert(accountId)
        return tokens
    }

    func deleteTokens(for accountId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountId
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        cache.removeValue(forKey: accountId)
        cacheLoaded.insert(accountId)
    }

    func updateAccessToken(_ accessToken: String, expiresIn: Int, for accountId: String) throws {
        guard var tokens = try loadTokens(for: accountId) else { return }
        tokens.accessToken = accessToken
        tokens.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        try saveTokens(tokens, for: accountId)
    }
}

/// In-memory KeychainStore for use when real Keychain is unavailable (e.g. test host).
final class InMemoryKeychainStore: KeychainStore {
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
