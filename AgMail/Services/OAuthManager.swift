import Foundation
import AuthenticationServices
import CryptoKit
import os

@MainActor
final class OAuthManager: ObservableObject {
    private let logger = Logger(subsystem: "AgMail", category: "OAuthManager")
    private var activeSession: ASWebAuthenticationSession?
    private var contextProvider: PresentationContextProvider?
    let keychainStore: KeychainStore

    init(keychainStore: KeychainStore = KeychainHelper.shared) {
        self.keychainStore = keychainStore
    }

    enum OAuthError: LocalizedError {
        case authSessionFailed(Error?)
        case noAuthCode
        case tokenExchangeFailed(String)
        case refreshFailed(String)
        case userInfoFailed
        case noTokensFound
        case invalidConfiguration

        var errorDescription: String? {
            switch self {
            case .authSessionFailed(let error):
                return "Authentication failed: \(error?.localizedDescription ?? "unknown")"
            case .noAuthCode:
                return "No authorization code received"
            case .tokenExchangeFailed(let msg):
                return "Token exchange failed: \(msg)"
            case .refreshFailed(let msg):
                return "Token refresh failed: \(msg)"
            case .userInfoFailed:
                return "Failed to fetch user info"
            case .noTokensFound:
                return "No tokens found for account"
            case .invalidConfiguration:
                return "Invalid OAuth configuration"
            }
        }
    }

    struct PKCEPair {
        let verifier: String
        let challenge: String
    }

    func generatePKCE() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()
        let challengeData = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(challengeData).base64URLEncoded()
        return PKCEPair(verifier: verifier, challenge: challenge)
    }

    func authorize() async throws -> (tokens: KeychainHelper.OAuthTokens, accountId: String) {
        let pkce = generatePKCE()

        guard var components = URLComponents(string: OAuthConfig.authURL) else {
            throw OAuthError.invalidConfiguration
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfig.clientId),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: OAuthConfig.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = components.url else {
            throw OAuthError.invalidConfiguration
        }
        let callbackScheme = String(OAuthConfig.redirectURI.prefix(while: { $0 != ":" }))

        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                self?.activeSession = nil
                if let error = error {
                    continuation.resume(throwing: OAuthError.authSessionFailed(error))
                    return
                }
                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: OAuthError.noAuthCode)
                    return
                }
                continuation.resume(returning: code)
            }
            self.activeSession = session
            let window = NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.mainWindow ?? NSApp.windows.first
            self.contextProvider = window.map { PresentationContextProvider(window: $0) }
            session.presentationContextProvider = self.contextProvider
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        logger.debug("Got authorization code, exchanging for tokens")
        var tokens = try await exchangeCodeForTokens(code: code, pkceVerifier: pkce.verifier)
        let email = try await fetchUserEmail(accessToken: tokens.accessToken)
        tokens.email = email

        let accountId = email
        try keychainStore.saveTokens(tokens, for: accountId)
        logger.info("OAuth complete for \(email)")

        return (tokens, accountId)
    }

    func exchangeCodeForTokens(code: String, pkceVerifier: String) async throws -> KeychainHelper.OAuthTokens {
        guard let tokenURL = URL(string: OAuthConfig.tokenURL) else { throw OAuthError.invalidConfiguration }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfig.clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: pkceVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.redirectURI)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data.prefix(200), encoding: .utf8) ?? "unknown"
            throw OAuthError.tokenExchangeFailed(errorBody)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refreshToken = tokenResponse.refresh_token else {
            throw OAuthError.tokenExchangeFailed("no refresh_token in response")
        }
        return KeychainHelper.OAuthTokens(
            accessToken: tokenResponse.access_token,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in)),
            email: ""
        )
    }

    func refreshAccessToken(for accountId: String) async throws -> String {
        guard let tokens = try keychainStore.loadTokens(for: accountId) else {
            throw OAuthError.noTokensFound
        }

        guard let tokenURL = URL(string: OAuthConfig.tokenURL) else { throw OAuthError.invalidConfiguration }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfig.clientId),
            URLQueryItem(name: "refresh_token", value: tokens.refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data.prefix(200), encoding: .utf8) ?? "unknown"
            throw OAuthError.refreshFailed(errorBody)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        if let newRefreshToken = tokenResponse.refresh_token {
            // Server rotated the refresh token — save the new one to avoid permanent logout
            var tokens = try keychainStore.loadTokens(for: accountId) ?? KeychainHelper.OAuthTokens(accessToken: tokenResponse.access_token, refreshToken: newRefreshToken, expiresAt: Date(), email: accountId)
            tokens.accessToken = tokenResponse.access_token
            tokens.refreshToken = newRefreshToken
            tokens.expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in))
            try keychainStore.saveTokens(tokens, for: accountId)
        } else {
            try keychainStore.updateAccessToken(tokenResponse.access_token, expiresIn: tokenResponse.expires_in, for: accountId)
        }
        logger.debug("Refreshed access token for \(accountId)")
        return tokenResponse.access_token
    }

    func fetchUserEmail(accessToken: String) async throws -> String {
        guard let userinfoURL = URL(string: OAuthConfig.userinfoURL) else { throw OAuthError.invalidConfiguration }
        var request = URLRequest(url: userinfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OAuthError.userInfoFailed
        }

        let userInfo = try JSONDecoder().decode(UserInfoResponse.self, from: data)
        return userInfo.email
    }
}

private struct TokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
    let token_type: String?
}

private struct UserInfoResponse: Codable {
    let email: String
}

private class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
