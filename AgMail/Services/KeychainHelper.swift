import Foundation
import Security

struct KeychainHelper {
    private static let service = "com.agmail.oauth"

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

    static func saveTokens(_ tokens: OAuthTokens, for accountId: String) throws {
        let data = try JSONEncoder().encode(tokens)

        // Delete existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func loadTokens(for accountId: String) throws -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.decodingFailed
        }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    static func deleteTokens(for accountId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func updateAccessToken(_ accessToken: String, expiresIn: Int, for accountId: String) throws {
        guard var tokens = try loadTokens(for: accountId) else { return }
        tokens.accessToken = accessToken
        tokens.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        try saveTokens(tokens, for: accountId)
    }
}
