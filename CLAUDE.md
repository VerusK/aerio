# AgMail — Development Guide

## Build & Test Commands

```bash
# Build
xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Debug build

# Run all tests
xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS'

# Run specific test class
xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS' -only-testing:AgMailTests/EmailTests
```

## Project Structure

- `AgMail/Models/` — Data models: Account, Email, Folder (enum)
- `AgMail/Services/` — Business logic: GmailScraper (JS injection + parsing), GmailScraperManager (per-account orchestration), AccountManager (add/remove accounts), WebViewPool (isolated WKWebView per account), UnifiedMailbox (merge all accounts), ComposeService (Gmail compose URLs)
- `AgMail/Views/` — SwiftUI views: 4-panel MainView (HSplitView), AccountSidebar, FolderList, MessageList, MessageWebView, ComposeWebView, AccountSetupView
- `AgMail/Scripts/` — JS files bundled as resources: gmail_parser.js (parse Basic HTML), gmail_actions.js (archive/delete/spam actions)
- `AgMail/Persistence/` — SwiftData cache (DataStore) for instant launch display
- `AgMail/Utilities/` — KeyboardShortcuts handler
- `AgMailTests/` — Unit tests (140+ tests)

## Key Patterns

- Each Gmail account uses an isolated `WKWebsiteDataStore` for cookie/session separation
- Gmail Basic HTML mode (`?ui=html`) is used for scraping — simpler DOM than standard Gmail
- Hidden WKWebView per account polls Gmail every 30-60 sec; visible WKWebView shows full Gmail for reading
- JS scripts are injected via `WKUserScript` / `evaluateJavaScript`
- `UnifiedMailbox` merges emails from all scrapers, sorted by date
- SwiftData caches parsed emails for instant display before first poll completes; `GmailScraperManager` calls `EmailCache.replaceEmails()` after each poll and `EmailCache.loadEmails()` at startup
- `GmailScraper` detects session expiration by checking navigation URLs for `accounts.google.com` redirect in `WKNavigationDelegate`
- No external dependencies — only macOS SDK (WKWebView, SwiftUI, SwiftData)
