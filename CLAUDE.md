# AgMail — Development Guide

## Build & Test Commands

```bash
# Build & Run (always run after changes so the user sees results immediately)
xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Release -derivedDataPath build build && open build/Build/Products/Release/AgMail.app

# Build only (debug)
xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Debug build

# Run all tests
xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS'

# Run specific test class
xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS' -only-testing:AgMailTests/GmailAPIClientTests
```

## Project Structure

- `AgMail/Models/` — Data models: Account, Email, Folder (enum)
- `AgMail/Services/` — Business logic: GmailAPIClient (REST HTTP client with auth/retry), GmailAPIManager (per-account orchestration via API), OAuthManager (OAuth 2.0 PKCE via ASWebAuthenticationSession), OAuthConfig (OAuth constants/endpoints), KeychainHelper (secure token storage), AccountManager (add/remove accounts), UnifiedMailbox (merge all accounts), RFC2822Builder (email composition)
- `AgMail/Views/` — SwiftUI views: 4-panel MainView (HSplitView), AccountSidebar, FolderList, MessageList, MessageWebView (includes NativeMessageDetail), ComposeView, AccountSetupView, SettingsView
- `AgMail/Persistence/` — SwiftData cache (DataStore) for instant launch display
- `AgMail/Utilities/` — KeyboardShortcuts handler
- `AgMailTests/` — Unit tests (140+ tests)

## Key Patterns

- OAuth 2.0 PKCE authentication via `ASWebAuthenticationSession`; tokens stored in macOS Keychain via `KeychainHelper`
- Gmail REST API via `GmailAPIClient` (URLSession): list/get/modify/trash/send messages, label queries, history sync
- `GmailAPIManager` orchestrates per-account API clients; polls via incremental sync (History API) after initial full fetch, with 410 Gone fallback to full re-fetch
- `UnifiedMailbox` merges emails from all API clients, sorted by date
- SwiftData caches parsed emails for instant display before first poll completes; `GmailAPIManager` calls `EmailCache.replaceEmails()` after each poll and `EmailCache.loadEmails()` at startup
- Email composition via `RFC2822Builder` (RFC 2047 Q-encoding for non-ASCII) sent through Gmail API
- Message content extracted from Gmail API MIME payload (text/html preferred, text/plain fallback); rendered natively via WKWebView in `MessageWebView`
- Debug logging via `os.log` (subsystem: "AgMail", categories: GmailAPIClient, GmailAPIManager, etc.) — view in Console.app or `log stream --predicate 'process == "AgMail"' --debug`
- No external dependencies — only macOS SDK (AuthenticationServices, Security, CryptoKit, SwiftUI, SwiftData)

## Data Storage

- **Accounts**: `UserDefaults` (key `agmail_accounts`)
- **Email cache**: SwiftData `~/Library/Application Support/default.store`
- **Window frame**: `UserDefaults` (key `mainWindowFrame`)
- **Split positions**: `UserDefaults` (autosave key `AgMailMainSplit`)
- **Dock badge toggle**: `UserDefaults` (key `showDockBadge`)
- **OAuth tokens**: macOS Keychain (per-account access/refresh tokens via KeychainHelper)
