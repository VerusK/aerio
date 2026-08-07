# Aerio — Development Guide

## Build & Test Commands

```bash
# Build & Run (always run after changes so the user sees results immediately)
./scripts/run.sh

# Build only (debug)
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build

# Run all tests (removes Debug .app after to avoid LaunchServices conflicts)
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS'; rm -rf ~/Library/Developer/Xcode/DerivedData/Aerio-*/Build/Products/Debug/Aerio.app

# Run specific test class
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/GmailAPIClientTests
```

## Project Structure

- `Aerio/Models/` — Data models: Account, Email, Folder (enum)
- `Aerio/Services/` — Business logic: GmailAPIClient (REST HTTP client with auth/retry, attachment download), GmailAPIManager (per-account orchestration via API with batched fetch and infinite scroll), OAuthManager (OAuth 2.0 PKCE via ASWebAuthenticationSession), OAuthConfig (OAuth constants/endpoints), KeychainHelper (secure token storage via KeychainStore protocol), AccountManager (add/remove/update accounts), UnifiedMailbox (merge all accounts), RFC2822Builder (email composition with multipart/related inline images), ContactsCache (address autocomplete from synced contacts), NotificationManager (desktop notifications via UNUserNotificationCenter)
- `Aerio/Views/` — SwiftUI views: 3-panel MainView (UnifiedSidebar + MessageList + Detail), UnifiedSidebar (merged folder/account tree), SearchOverlay (Spotlight-style global search with ↑/↓ nav, → preview panel, pagination, ? help link), MessageList (with infinite scroll), MessageWebView (includes NativeMessageDetail with attachment download/open and inline image display), ComposeView (with address autocomplete, draft editing, drag-drop/paste inline images, file attachments via ⇧⌘A), ComposeWindowManager (non-modal NSPanel windows for compose), AccountSetupView, SettingsView (General: dock badge, downloads directory, poll interval; Cache: size breakdown + clear; Keyboard Shortcuts; Esc to close via app-level NSEvent monitor)
- `Aerio/Persistence/` — SwiftData cache (DataStore) for instant launch display
- `Aerio/Utilities/` — KeyboardShortcuts (layout-independent hotkeys via keyCode + NSEvent local monitor), KeyEventMonitor (Go-To state machine with timer)
- `AerioTests/` — Unit tests (390+ tests)

## Key Patterns

- OAuth 2.0 PKCE authentication via `ASWebAuthenticationSession`; tokens stored in macOS Keychain via `KeychainHelper`
- Gmail REST API via `GmailAPIClient` (URLSession): list/get/modify/trash/send messages, label queries, history sync
- `GmailAPIManager` orchestrates per-account API clients; polls via incremental sync (History API) after initial full fetch, with 410 Gone fallback to full re-fetch; batched email loading (50 per page) with real-time UI updates; page token management for infinite scroll
- `UnifiedMailbox` merges emails from all API clients, sorted by date; supports `hasMoreEmails()` for infinite scroll sentinel
- SwiftData caches parsed emails for instant display before first poll completes; `GmailAPIManager` calls `EmailCache.replaceEmails()` after each poll and `EmailCache.loadEmails()` at startup
- Email composition via `RFC2822Builder` (RFC 2047 Q-encoding for non-ASCII) sent through Gmail API; supports multipart/alternative (plain + html), multipart/related (inline images via CID), and multipart/mixed (file attachments) — nesting: mixed > related > alternative; draft auto-save on compose window close via Gmail Drafts API with optimistic UI update (draft appears immediately, background sync follows); draft editing loads content via Drafts API and sends via `sendDraft`
- Attachment support: `GmailAPIClient.getAttachment()` downloads via Gmail API; `NativeMessageDetail` shows attachment chips with open/download buttons, resolves CID inline images and embeds image attachments in body; `ComposeView` supports drag-drop (images inline, files as attachments), clipboard paste (⌘V for screenshots), file picker (⇧⌘A); `TabAwareTextView` handles DnD via `performDragOperation` and paste via `keyDown` interception (not `paste:` — NSPanel doesn't reliably route it)
- `ComposeWindowManager` opens compose views in non-modal `NSPanel` windows (not `.sheet`); windows are resizable, persist size via `frameAutosaveName`, and don't block the main window; uses `NSHostingController` with `sizingOptions = []` to prevent SwiftUI from overriding window size
- `ComposeBodyEditor` (rich text NSTextView wrapper) with WYSIWYG formatting toolbar (bold/italic/underline, bullet/numbered lists); `ComposeEditorState` manages formatting state and HTML extraction; auto-list continuation on Enter (type "1. " or "- " to start lists); layout-independent ⌘B/⌘I/⌘U via keyCode; `FromPickerView` (NSPopUpButton wrapper) for keyboard-accessible account picker
- Message content extracted from Gmail API MIME payload (text/html preferred, text/plain fallback); rendered natively via WKWebView in `MessageWebView` (forced light theme)
- `KeychainStore` protocol abstracts Keychain access; `MockKeychainStore` used in tests to avoid system Keychain prompts
- `ContactsCache` extracts sender addresses during sync for address autocomplete in ComposeView
- `NotificationManager` sends desktop notifications for new INBOX+UNREAD emails; click-to-navigate via userInfo — navigation (and search jumps) keeps the unified view unless the current account filter already shows the email; silently switching the filter hid the account-indicator dots and read as a bug
- `SearchOverlay` provides Spotlight-style global search across all accounts in parallel with 300ms debounce; ↑/↓ navigate results, → opens inline preview panel (WKWebView, light theme, JS-driven scroll), ← closes preview; paginated results via `searchEmailsWithTokens`; ? button links to Gmail search operators docs
- `UnifiedSidebar` provides a 3-panel layout: folder tree with per-account sub-items
- Keyboard-only navigation: `FocusedPanel` enum tracks active panel (sidebar/messageList/detail); ←/→ switch panels, ↑/↓ and J/K navigate within panel, Enter opens draft for editing or focuses detail, Escape = back; `KeyEventMonitor` handles Go-To state machine (G+I/S/A/T/D/P for instant folder switch with 1s timeout); Space expands/collapses sidebar folder accounts; all bare keys suppressed when text field focused; **KeyEventMonitor is scoped to main window only** — compose windows receive native keyboard events
- Sidebar tree nav: `expandedFolders: Set<Folder>` controls DisclosureGroup expansion; ↑/↓ walks flat visible list of folders + expanded account rows; `SidebarItem` enum models cursor position
- `MessageList` uses `ScrollView` + `LazyVStack` (NOT `List`) — the NSTableView bridge under macOS List intermittently dropped newly inserted rows in long-running sessions (new mail invisible until relayout); three rounds of `.id()`-keyed List recreation each failed (count-keyed → froze every poll, first.id-keyed → missed non-top inserts). Manual `onTapGesture` + background for selection highlight; `ScrollViewReader` for scrollTo on selection/folder change; focus indicator bar lives in `MainView` above the overlay
- Folder enum includes: inbox, sent, archive, trash, spam, drafts
- Dock badge count via `UNUserNotificationCenter.setBadgeCount()` (not `NSApp.dockTile.badgeLabel` — silently ignored on macOS 16+)
- Debug logging via `os.log` (subsystem: "Aerio", categories: GmailAPIClient, GmailAPIManager, etc.) — view in Console.app or `log stream --predicate 'process == "Aerio"' --debug`; note: `.debug`/`.info` levels invisible in Release builds, use `NSLog` for quick debugging
- No external dependencies — only macOS SDK (AuthenticationServices, Security, CryptoKit, SwiftUI, SwiftData, UserNotifications)

## Data Storage

- **Accounts**: `UserDefaults` (key `aerio_accounts`)
- **Email cache**: SwiftData `~/Library/Application Support/default.store`
- **Window frame**: `UserDefaults` (key `mainWindowFrame`)
- **Split positions**: `UserDefaults` (autosave key `AerioMainSplit`)
- **Compose window size**: `NSWindow.frameAutosaveName` (key `AerioComposeWindow`)
- **Dock badge toggle**: `UserDefaults` (key `showDockBadge`)
- **Downloads directory**: `UserDefaults` (key `downloadsDirectory`, empty = ~/Downloads)
- **Poll interval**: `UserDefaults` (key `pollInterval`, default 45 seconds)
- **Contacts cache**: `UserDefaults` (key `aerio_contacts_cache`)
- **OAuth tokens**: macOS Keychain (per-account access/refresh tokens via KeychainHelper)

## Release Process

```bash
# 1. Commit changes
git add <files> && git commit -m "fix: description"

# 2. Tag (semver: patch for fixes, minor for features)
git tag v1.X.Y

# 3. Push branch + tag (tag push triggers CI release workflow → builds DMG)
git push origin main && git push origin v1.X.Y

# 4. Create GitHub release with human-readable notes
gh release create v1.X.Y --repo VerusK/aerio --title "Aerio 1.X.Y" --notes "..."
```

- CI builds DMG and attaches it to the GitHub release automatically on tag push
- Release notes should describe **what was broken and how it's fixed** in user-facing language, not commit messages
- Include Homebrew install/upgrade instructions in notes
- Homebrew tap: `VerusK/tap/aerio`
- **Never delete + re-push a tag after the release exists.** GitHub disassociates the existing release and marks it draft, breaking the canonical `releases/download/v.../...` URL. If a shipped tag needs a fix, bump to the next patch version (e.g., v1.5.0 → v1.5.1) instead of retagging.
- If CI's `Update Homebrew tap` step fails (typically expired `TAP_GITHUB_TOKEN` PAT), run `scripts/update-tap.sh <version>` locally as a recovery step. The DMG itself is independent and gets uploaded regardless.

## Memory & Knowledge Management

- Memory files stored in `.claude/memory/` — see `MEMORY.md` there for index
- When you discover something non-obvious (platform quirks, API gotchas, debugging tricks, architectural decisions), save it to memory immediately — don't wait for session end
- Update CLAUDE.md when a discovery affects how the project should be built or debugged (e.g., "don't use API X, use API Y instead")
- Memory is for cross-session context that can't be derived from code; CLAUDE.md is for durable project instructions
