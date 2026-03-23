import Foundation

enum OAuthConfig {
    static let clientId: String = {
        guard let id = Bundle.main.infoDictionary?["OAuthClientID"] as? String,
              id != "REPLACE_ME" else {
            fatalError("OAuth Client ID not configured. See AgMail/Config/OAuth.local.xcconfig.example")
        }
        return id
    }()

    static let redirectURI: String = {
        guard let scheme = Bundle.main.infoDictionary?["OAuthCallbackScheme"] as? String else {
            fatalError("OAuth Callback Scheme not configured.")
        }
        return "\(scheme):/oauth/callback"
    }()

    static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let userinfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"
    static let scopes = "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/userinfo.email"
}
