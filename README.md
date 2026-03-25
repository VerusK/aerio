# Aerio — Gmail Multi-Account Client for macOS

Native macOS application (Swift/SwiftUI) for managing multiple Gmail accounts. Uses the Gmail REST API with OAuth 2.0 PKCE authentication — no IMAP, no SMTP, no web scraping. Designed for keyboard-first workflow.

## Features

- Multiple Gmail accounts with OAuth 2.0 PKCE authentication (tokens in macOS Keychain)
- Unified inbox — merged emails from all accounts sorted by date
- 3-panel interface: Unified sidebar (folders + accounts) | Message list | Message detail
- Full keyboard-only navigation: panel focus (←/→), in-panel nav (↑/↓/J/K), Go-To folders (G+key), sidebar expand (Space)
- Gmail actions via REST API: archive, delete, mark as spam, move to inbox, mark as read
- Compose: new email, reply, reply all, forward — with address autocomplete from synced contacts
- Attachments: drag & drop files, paste images from clipboard (⌘V), file picker (⇧⌘A)
- Inline images: pasted/dropped images embed in email body via multipart/related
- Attachment viewer: download to configurable directory, open in default app, or save-only
- Inline image display in received emails (CID + image attachment embedding)
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
Aerio/
├── AerioApp.swift               # Entry point, AppState
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

## Install

### Homebrew (recommended)

```bash
brew tap VerusK/aerio
brew install --cask aerio
```

On first launch macOS may block the app because it's not signed. To fix:

```bash
xattr -cr /Applications/Aerio.app
```

Or: right-click Aerio.app → Open → Open.

### Build from source

Requirements: macOS 15+, Xcode 16+

1. Create a Google Cloud Console project with Gmail API enabled
2. Create an OAuth 2.0 Client ID (Desktop app type)
3. Copy `Aerio/Config/OAuth.local.xcconfig.example` to `Aerio/Config/OAuth.local.xcconfig` and fill in your Client ID

## Build & Run

```bash
# Build & Run (Release)
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Release -derivedDataPath build build && open build/Build/Products/Release/Aerio.app

# Debug build
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build

# Run tests
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS'
```

Or open `Aerio.xcodeproj` in Xcode and press Cmd+R to run, Cmd+U to test.

## Usage

1. Launch Aerio
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
| `Cmd+Shift+A` | Attach files |
| `Cmd+Shift+F` | Search |
| `Cmd+Shift+E` | Refresh |
| `Cmd+,` | Settings |

## Data Storage

| Data | Location |
|------|----------|
| Accounts | UserDefaults (key `aerio_accounts`) |
| Email cache | SwiftData `~/Library/Application Support/default.store` |
| Window frame | UserDefaults (key `mainWindowFrame`) |
| Split positions | UserDefaults (autosave key `AerioMainSplit`) |
| Dock badge toggle | UserDefaults (key `showDockBadge`) |
| Downloads directory | UserDefaults (key `downloadsDirectory`) |
| Contacts cache | UserDefaults (key `aerio_contacts_cache`) |
| OAuth tokens | macOS Keychain (per-account access/refresh tokens) |

## Uninstall

To completely remove Aerio and all its data:

```bash
# Remove the app
rm -rf /path/to/Aerio.app

# Remove preferences
defaults delete Aerio 2>/dev/null

# Remove email cache (SwiftData)
rm -rf ~/Library/Application\ Support/default.store

# Remove OAuth tokens from Keychain
security delete-generic-password -s com.aerio.oauth 2>/dev/null

# Remove Containers (if sandboxed)
rm -rf ~/Library/Containers/Aerio
```
