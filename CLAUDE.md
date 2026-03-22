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
- `AgMail/Services/` — Business logic: GmailAPIClient (REST HTTP client with auth/retry), GmailAPIManager (per-account orchestration via API with batched fetch and infinite scroll), OAuthManager (OAuth 2.0 PKCE via ASWebAuthenticationSession), OAuthConfig (OAuth constants/endpoints), KeychainHelper (secure token storage via KeychainStore protocol), AccountManager (add/remove/update accounts), UnifiedMailbox (merge all accounts), RFC2822Builder (email composition), ContactsCache (address autocomplete from synced contacts), NotificationManager (desktop notifications via UNUserNotificationCenter)
- `AgMail/Views/` — SwiftUI views: 3-panel MainView (UnifiedSidebar + MessageList + Detail), UnifiedSidebar (merged folder/account tree), SearchOverlay (Spotlight-style global search), MessageList (with infinite scroll), MessageWebView (includes NativeMessageDetail with action buttons), ComposeView (with address autocomplete and draft-on-close), AccountSetupView, SettingsView
- `AgMail/Persistence/` — SwiftData cache (DataStore) for instant launch display
- `AgMail/Utilities/` — KeyboardShortcuts handler, KeyEventInterceptor (NSViewRepresentable for layout-independent hotkeys)
- `AgMailTests/` — Unit tests (140+ tests)

## Key Patterns

- OAuth 2.0 PKCE authentication via `ASWebAuthenticationSession`; tokens stored in macOS Keychain via `KeychainHelper`
- Gmail REST API via `GmailAPIClient` (URLSession): list/get/modify/trash/send messages, label queries, history sync
- `GmailAPIManager` orchestrates per-account API clients; polls via incremental sync (History API) after initial full fetch, with 410 Gone fallback to full re-fetch; batched email loading (50 per page) with real-time UI updates; page token management for infinite scroll
- `UnifiedMailbox` merges emails from all API clients, sorted by date; supports `hasMoreEmails()` for infinite scroll sentinel
- SwiftData caches parsed emails for instant display before first poll completes; `GmailAPIManager` calls `EmailCache.replaceEmails()` after each poll and `EmailCache.loadEmails()` at startup
- Email composition via `RFC2822Builder` (RFC 2047 Q-encoding for non-ASCII) sent through Gmail API; draft auto-save on compose window close via Gmail Drafts API
- Message content extracted from Gmail API MIME payload (text/html preferred, text/plain fallback); rendered natively via WKWebView in `MessageWebView` (forced light theme)
- `KeychainStore` protocol abstracts Keychain access; `MockKeychainStore` used in tests to avoid system Keychain prompts
- `ContactsCache` extracts sender addresses during sync for address autocomplete in ComposeView
- `NotificationManager` sends desktop notifications for new INBOX+UNREAD emails; click-to-navigate via userInfo
- `SearchOverlay` provides Spotlight-style global search across all accounts in parallel with 300ms debounce
- `UnifiedSidebar` replaces separate AccountSidebar + FolderList with a 3-panel layout: folder tree with per-account sub-items
- `KeyEventInterceptor` (NSViewRepresentable) intercepts key events before system menu processing for layout-independent hotkeys (EN/RU)
- Folder enum includes: inbox, sent, archive, trash, spam, drafts
- Debug logging via `os.log` (subsystem: "AgMail", categories: GmailAPIClient, GmailAPIManager, etc.) — view in Console.app or `log stream --predicate 'process == "AgMail"' --debug`
- No external dependencies — only macOS SDK (AuthenticationServices, Security, CryptoKit, SwiftUI, SwiftData, UserNotifications)

## Data Storage

- **Accounts**: `UserDefaults` (key `agmail_accounts`)
- **Email cache**: SwiftData `~/Library/Application Support/default.store`
- **Window frame**: `UserDefaults` (key `mainWindowFrame`)
- **Split positions**: `UserDefaults` (autosave key `AgMailMainSplit`)
- **Dock badge toggle**: `UserDefaults` (key `showDockBadge`)
- **Contacts cache**: `UserDefaults` (key `agmail_contacts_cache`)
- **OAuth tokens**: macOS Keychain (per-account access/refresh tokens via KeychainHelper)
