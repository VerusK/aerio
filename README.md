# AgMail — Gmail Multi-Account Client for macOS

Native macOS application (Swift/SwiftUI) for managing multiple Gmail accounts. Uses the Gmail REST API with OAuth 2.0 PKCE authentication — no IMAP, no SMTP, no web scraping.

## Features

- Multiple Gmail accounts with OAuth 2.0 PKCE token-based authentication (tokens stored in macOS Keychain)
- Unified inbox — merged emails from all accounts sorted by date
- 4-panel interface: Account sidebar | Folders | Message list | Native message reader
- Gmail actions via REST API: archive, delete, mark as spam, mark as read
- Compose: new email, reply, reply all, forward — native SwiftUI form sent via Gmail API
- Incremental sync via Gmail History API for efficient polling
- Keyboard shortcuts (Gmail-style): j/k navigation, e/archive, #/delete, r/reply, c/compose
- Alt+Up/Down alternative message navigation
- Settings view (Cmd+,) with hotkey reference and dock badge toggle
- Dock badge showing total unread email count across all accounts
- SwiftData cache for instant display on launch
- Periodic polling (every 45 sec) for new emails

## Architecture

```
AgMail/
├── AgMailApp.swift              # Entry point, AppState
├── Models/                      # Account, Email, Folder, GmailAPIModels
├── Services/                    # GmailAPIClient, GmailAPIManager, OAuthManager, OAuthConfig, KeychainHelper, AccountManager, UnifiedMailbox, RFC2822Builder
├── Views/                       # MainView, AccountSidebar, FolderList, MessageList, MessageWebView, ComposeView, AccountSetupView, SettingsView
├── Persistence/                 # SwiftData cache (DataStore)
└── Utilities/                   # KeyboardShortcuts
```

## Tech Stack

- Swift 6.2+ / SwiftUI
- Gmail REST API (URLSession, no external dependencies)
- OAuth 2.0 PKCE via ASWebAuthenticationSession
- macOS Keychain (Security.framework) for token storage
- SwiftData for local cache
- async/await + Structured Concurrency

## Setup

Requirements: macOS 15+, Xcode 16+

1. Create a Google Cloud Console project with Gmail API enabled
2. Create an OAuth 2.0 Client ID (Desktop app type)
3. Replace the placeholder in `AgMail/Services/OAuthConfig.swift`:
   ```swift
   static let clientId = "YOUR_CLIENT_ID.apps.googleusercontent.com"
   ```

## Build & Run

```bash
# Debug build
xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Debug -derivedDataPath build build

# Release build
xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Release -derivedDataPath build build

# Run the app
open build/Build/Products/Release/AgMail.app

# Run tests
xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS'
```

Or open `AgMail.xcodeproj` in Xcode and press Cmd+R to run, Cmd+U to test.

## Usage

1. Launch AgMail
2. Click "+" to add a Gmail account — authenticate via the system browser OAuth sheet (supports 2FA and passkeys)
3. Repeat for additional accounts
4. Use the sidebar to switch between accounts or view the unified inbox
5. Click an email to read it with native headers and rendered HTML body
6. Use keyboard shortcuts for quick actions

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Cmd+J` / `Cmd+K` | Next / previous email |
| `Cmd+E` | Archive |
| `Cmd+Shift+3` | Trash |
| `Cmd+Shift+1` | Mark as spam |
| `Cmd+R` | Reply |
| `Cmd+Shift+R` | Reply all |
| `Cmd+F` | Forward |
| `Cmd+N` | Compose new |
| `Alt+Up` / `Alt+Down` | Next / previous email (alt) |
| `Cmd+1-9` | Switch account |
| `Cmd+0` | Unified view |
| `Cmd+,` | Open settings |
| `Cmd+Shift+E` | Refresh |
| `Cmd+/` | Search |
| `Cmd+Enter` | Send |

## Data Storage

| Data | Location |
|------|----------|
| Accounts | `~/Library/Preferences/` (UserDefaults, key `agmail_accounts`) |
| Email cache | `~/Library/Application Support/default.store` (SwiftData) |
| Window frame | `~/Library/Preferences/` (UserDefaults, key `mainWindowFrame`) |
| Split positions | `~/Library/Preferences/` (UserDefaults, key `NSSplitView Subview Frames AgMailMainSplit`) |
| Dock badge toggle | `~/Library/Preferences/` (UserDefaults, key `showDockBadge`) |
| OAuth tokens | macOS Keychain (per-account access/refresh tokens via KeychainHelper) |

## Uninstall

To completely remove AgMail and all its data:

```bash
# Remove the app
rm -rf /path/to/AgMail.app

# Remove preferences
defaults delete AgMail 2>/dev/null

# Remove email cache (SwiftData)
rm -rf ~/Library/Application\ Support/default.store

# Remove OAuth tokens from Keychain
security delete-generic-password -s com.agmail.oauth 2>/dev/null

# Remove Containers (if sandboxed)
rm -rf ~/Library/Containers/AgMail
```
