import Foundation

enum OAuthConfig {
    static let clientId = "451766587137-5chs7l3rup98dkpavmijkq1gm8mj365h.apps.googleusercontent.com"
    static let redirectURI = "com.googleusercontent.apps.451766587137-5chs7l3rup98dkpavmijkq1gm8mj365h:/oauth/callback"
    static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let userinfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"
    static let scopes = "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/userinfo.email"
}
