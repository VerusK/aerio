# AgMail — Gmail Multi-Account Client for macOS

Native macOS application (Swift/SwiftUI) for managing multiple Gmail accounts. Uses the Gmail REST API with OAuth 2.0 PKCE authentication — no IMAP, no SMTP, no web scraping. Designed for keyboard-first workflow.

## Features

- Multiple Gmail accounts with OAuth 2.0 PKCE authentication (tokens in macOS Keychain)
- Unified inbox — merged emails from all accounts sorted by date
- 3-panel interface: Unified sidebar (folders + accounts) | Message list | Message detail
- Full keyboard-only navigation: panel focus (←/→), in-panel nav (↑/↓/J/K), Go-To folders (G+key), sidebar expand (Space)
- Gmail actions via REST API: archive, delete, mark as spam, move to inbox, mark as read
- Compose: new email, reply, reply all, forward — with address autocomplete from synced contacts
- Draft auto-save on compose window close via Gmail Drafts API
- Spotlight-style global search across all accounts (Cmd+Shift+F) with 300ms debounce
- Incremental sync via Gmail History API with 410 Gone fallback to full re-fetch
- Desktop notifications for new emails with click-to-navigate
- Dock badge showing total unread count across all accounts
- SwiftData cache for instant display on launch
- Periodic polling (every 45 sec) for new emails
- No external dependencies — only macOS SDK

## Architecture

```
AgMail/
├── AgMailApp.swift              # Entry point, AppState
├── Models/                      # Account, Email, Folder, GmailAPIModels
├── Services/                    # GmailAPIClient, GmailAPIManager, OAuthManager,
│                                # OAuthConfig, KeychainHelper, AccountManager,
│                                # UnifiedMailbox, RFC2822Builder, ContactsCache,
│                                # NotificationManager
├── Views/                       # MainView (3-panel HSplitView), UnifiedSidebar,
│                                # MessageList, MessageWebView (NativeMessageDetail),
│                                # ComposeView, SearchOverlay, AccountSetupView,
│                                # SettingsView
├── Persistence/                 # SwiftData cache (DataStore)
└── Utilities/                   # KeyboardShortcuts, KeyEventMonitor
```

## Tech Stack

- Swift 6.2+ / SwiftUI
- Gmail REST API (URLSession, no external dependencies)
- OAuth 2.0 PKCE via ASWebAuthenticationSession
- macOS Keychain (Security.framework) for token storage
- SwiftData for local email cache
- WKWebView for HTML email rendering (forced light theme)
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
# Build & Run (Release)
xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Release -derivedDataPath build build && open build/Build/Products/Release/AgMail.app

# Debug build
xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Debug build

# Run tests
xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS'
```

Or open `AgMail.xcodeproj` in Xcode and press Cmd+R to run, Cmd+U to test.

## Usage

1. Launch AgMail
2. Click "+" to add a Gmail account — authenticate via the system browser OAuth sheet (supports 2FA and passkeys)
3. Repeat for additional accounts
4. Navigate with keyboard: arrows to move between panels and items, G+I to jump to Inbox, etc.
5. Use sidebar to browse folders; Space to expand/collapse account list within a folder

## Keyboard Shortcuts

### Navigation

| Key | Action |
|-----|--------|
| `←` / `→` | Switch focus between panels (Sidebar / List / Detail) |
| `↑` / `↓` or `J` / `K` | Navigate within focused panel |
| `Escape` | Move focus back (panel left) |
| `Space` | Expand/collapse folder accounts in sidebar |
| `Opt+↑` / `Opt+↓` | Next/previous email (always, regardless of panel) |

### Go-To Folders

Press `G` then one of:

| Key | Folder |
|-----|--------|
| `I` | Inbox |
| `S` | Sent |
| `A` | Archive |
| `T` | Trash |
| `D` | Drafts |
| `P` | Spam |

### Actions

| Key | Action |
|-----|--------|
| `Cmd+E` | Archive |
| `Cmd+D` | Delete |
| `Cmd+Shift+1` | Mark as spam |
| `Cmd+I` | Move to Inbox |
| `Cmd+N` | Compose new |
| `Cmd+R` | Reply All |
| `Cmd+Shift+R` | Reply |
| `Cmd+T` | Forward |
| `Cmd+Enter` | Send |
| `Cmd+Shift+F` | Search |
| `Cmd+Shift+E` | Refresh |
| `Cmd+,` | Settings |

## Data Storage

| Data | Location |
|------|----------|
| Accounts | UserDefaults (key `agmail_accounts`) |
| Email cache | SwiftData `~/Library/Application Support/default.store` |
| Window frame | UserDefaults (key `mainWindowFrame`) |
| Split positions | UserDefaults (autosave key `AgMailMainSplit`) |
| Dock badge toggle | UserDefaults (key `showDockBadge`) |
| Contacts cache | UserDefaults (key `agmail_contacts_cache`) |
| OAuth tokens | macOS Keychain (per-account access/refresh tokens) |

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
