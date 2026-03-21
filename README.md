# AgMail — Gmail Multi-Account Client for macOS

Native macOS application (Swift/SwiftUI) for managing multiple Gmail accounts through Gmail Basic HTML mode. Uses WKWebView with JS injections for parsing and managing email — no Google API, no IMAP, no SMTP.

## Features

- Multiple Gmail accounts with isolated cookie storage per account
- Unified inbox — merged emails from all accounts sorted by date
- 4-panel interface: Account sidebar | Folders | Message list | Message content (Gmail WebView)
- Gmail actions via JS injection: archive, delete, mark as spam
- Compose: new email, reply, reply all, forward — opens Gmail compose in WebView
- Keyboard shortcuts (Gmail-style): j/k navigation, e/archive, #/delete, r/reply, c/compose
- SwiftData cache for instant display on launch
- Periodic polling (30-60 sec) for new emails

## Architecture

```
AgMail/
├── AgMailApp.swift              # Entry point
├── Models/                      # Account, Email, Folder
├── Services/                    # GmailScraper, AccountManager, WebViewPool, UnifiedMailbox, ComposeService
├── Views/                       # MainView, AccountSidebar, FolderList, MessageList, MessageWebView, ComposeWebView, AccountSetupView
├── Scripts/                     # gmail_parser.js, gmail_actions.js
├── Persistence/                 # SwiftData cache (DataStore)
└── Utilities/                   # KeyboardShortcuts
```

## Tech Stack

- Swift 6.2+ / SwiftUI
- WKWebView with isolated WKWebsiteDataStore per account
- Gmail Basic HTML mode (`mail.google.com/mail/?ui=html`)
- JavaScript injection (WKUserScript / evaluateJavaScript)
- SwiftData for local cache
- async/await + Structured Concurrency

## Build & Run

Requirements: macOS 15+, Xcode 16+

```bash
# Build
xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Debug build

# Run tests
xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS'
```

Or open `AgMail.xcodeproj` in Xcode and press Cmd+R to run, Cmd+U to test.

## Usage

1. Launch AgMail
2. Click "+" to add a Gmail account — log in via the WebView (supports 2FA)
3. Repeat for additional accounts
4. Use the sidebar to switch between accounts or view the unified inbox
5. Click an email to read it in full Gmail WebView
6. Use keyboard shortcuts for quick actions

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `j` / `k` | Next / previous email |
| `e` | Archive |
| `#` | Trash |
| `!` | Mark as spam |
| `r` | Reply |
| `Shift+R` | Reply all |
| `f` | Forward |
| `c` | Compose new |
| `Cmd+1-9` | Switch account |
| `Cmd+0` | Unified view |
| `/` | Search |
| `Cmd+Enter` | Send |
