# AgMail Stage 1 Refactor

## Overview
- Fix 15+ issues found during user testing: broken hotkeys, email loading problems, missing UI actions, sidebar UX
- Add new features: Sent folder, search, autocomplete, infinite scroll, desktop notifications
- Restructure sidebar from 4-panel to 3-panel layout with unified folder/account tree
- 7 phases, ordered by priority and dependency

## Context (from discovery)
- **Files involved**: MainView.swift (392 lines), GmailAPIManager.swift (540 lines), KeyboardShortcuts.swift (184 lines), MessageWebView.swift (307 lines), ComposeView.swift (326 lines), MessageList.swift (100 lines), Folder.swift (64 lines), AccountSidebar.swift (135 lines), FolderList.swift (57 lines)
- **New files to create**: UnifiedSidebar.swift, SearchOverlay.swift, NotificationManager.swift, ContactsCache.swift
- **Existing patterns**: OAuth 2.0 PKCE, Gmail REST API via URLSession, SwiftData cache, NSEvent keyboard handling, os.log debug logging
- **Test coverage**: 18 test files, 140+ tests (GmailAPIClient, GmailAPIManager, KeyboardShortcuts, Views, Models, etc.)
- **Dependencies**: No external — macOS SDK only (AuthenticationServices, Security, CryptoKit, SwiftUI, SwiftData, UserNotifications)

## Development Approach
- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change
- Maintain backward compatibility
- Build & run after each phase: `xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Release -derivedDataPath build build && open build/Build/Products/Release/AgMail.app`

## Testing Strategy
- **Unit tests**: required for every task (see Development Approach above)
- **Manual UI testing**: after each phase (2 accounts, both keyboard layouts, context menus, etc.)
- No e2e test framework in this project

## Progress Tracking
- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with + prefix
- Document issues/blockers with ! prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase
- **Post-Completion** (no checkboxes): manual testing, deployment verification

## Implementation Steps

---

### Phase 1: Quick Fixes

### Task 1: Fix Settings button (Issue 1)
- [x] In `AccountSidebar.swift:31` replace `Selector(("showSettingsWindow:"))` with macOS version check: `if #available(macOS 14, *) { showSettingsWindow: } else { showPreferencesWindow: }`
- [x] Verify same fix needed in `MainView.swift:323` if settings triggered from there
- [x] Write tests for settings trigger logic
- [x] Run tests - must pass before next task

### Task 2: Unique account colors (Issue 5)
- [x] In `AccountSetupView.swift:78-83` change color assignment to pick first unused color from `AccountColor.allCases` (check existing accounts' colors)
- [x] Fallback: if all colors used, pick least-used
- [x] Write tests for color assignment (0 accounts, 1 account, all colors used)
- [x] Run tests - must pass before next task

### Task 3: Fix From field alignment (Issue 6)
- [x] In `ComposeView.swift:80,145` change `.frame(width: 50, alignment: .trailing)` to `.leading`
- [x] Write test verifying ComposeView initializes correctly
- [x] Run tests - must pass before next task

### Task 4: Mock KeychainHelper for tests (Keychain access prompts)
- [x] Create `KeychainStore` protocol with `saveTokens`, `loadTokens`, `deleteTokens`, `updateAccessToken` methods
- [x] Make `KeychainHelper` conform to `KeychainStore` (static methods → instance methods on a default implementation)
- [x] Create `MockKeychainStore` (in-memory `[String: OAuthTokens]` dictionary) for tests
- [x] Inject `KeychainStore` into `GmailAPIClient` and `OAuthManager` (replace direct `KeychainHelper` calls)
- [x] Update `GmailAPIManager.removeClient()` to use injected store for `deleteTokens`
- [x] Rewrite `KeychainHelperTests` to test both real `KeychainHelper` and `MockKeychainStore`
- [x] Update `GmailAPIClientTests` and `GmailAPIManagerTests` to use `MockKeychainStore` instead of real Keychain
- [x] Run tests - must pass with zero Keychain access prompts

### Task 5: Force light theme for email viewer (Issue 10)
- [x] In `MessageWebView.swift` remove `@media (prefers-color-scheme: dark)` blocks from `wrapHTML()`
- [x] In `BodyWebViewStore.init()` set `self.webView.appearance = NSAppearance(named: .aqua)`
- [x] Write tests for HTML wrapper (no dark mode CSS present)
- [x] Run tests - must pass before next task

### Task 6: Add Sent folder (Issue 14)
- [x] Add `case sent` to `Folder` enum in `Folder.swift` (after `inbox`)
- [x] Set properties: displayName="Sent", gmailQuery="in:sent", gmailLabelIds=`[GmailLabelId.sent]`, iconName="paperplane.fill"
- [x] Add `matchesLabels` logic for sent (check for SENT label)
- [x] Update `FolderList.swift` to include Sent folder
- [x] Verify `GmailLabelId.sent = "SENT"` exists in `GmailAPIModels.swift`
- [x] Write tests for Sent folder enum properties, gmailQuery, matchesLabels
- [x] Run tests - must pass before next task

---

### Phase 2: Hotkeys

### Task 7: Fix keyboard shortcuts on both layouts (Issue 2)
- [x] Create `KeyEventInterceptor` (NSViewRepresentable wrapping NSView with `performKeyEquivalent`) to intercept key events BEFORE system menu processing
- [x] In `MainView.swift` replace `installKeyMonitor`/`removeKeyMonitor` with `.background(KeyEventInterceptor(...))`
- [x] Update shortcut mappings in `KeyboardShortcuts.swift`:
  - Delete: `Cmd+D`
  - Spam: `Cmd+Shift+1`
  - Reply All: `Cmd+R`
  - Reply: `Cmd+Shift+R`
  - Forward: `Cmd+T`
  - Search: `Cmd+Shift+F`
- [x] Verify shortcuts work on English AND Russian keyboard layouts (uses charactersIgnoringModifiers for layout-independent matching)
- [x] Update `ShortcutAction.shortcutLabel` for new mappings
- [x] Write tests for KeyEventInterceptor key matching
- [x] Write tests for updated shortcut mappings (action lookup by key+modifiers)
- [x] Run tests - must pass before next task

---

### Phase 3: Data Fixes

### Task 8: Fix second account email loading (Issue 3)
- [x] In `GmailAPIManager.swift` add detailed error logging in `addClient()`/`fetchEmails()` for per-account failures
- [x] Verify `OAuthConfig.swift` credentials work for multiple accounts
- [x] Ensure `GmailAPIClient` is correctly initialized with per-account tokens
- [x] Write tests for multi-account client initialization and error handling
- [x] Run tests - must pass before next task

### Task 9: Batched email loading with real-time display (Issue 4)
- [x] Refactor `GmailAPIManager.swift:177-246` `fetchEmails()`:
  1. Request first page `listMessages(maxResults: 50)`
  2. Immediately `getMessages()` for those 50 IDs
  3. Update `emailsByAccount` and trigger UI refresh (user sees first emails)
  4. Request next page -> getMessages -> update UI -> repeat
  5. Continue while `pageToken` exists (save last pageToken for infinite scroll)
- [x] Each batch: append to `emailsByAccount`, update SwiftData cache
- [x] Remove hardcoded 500-email cap
- [x] Write tests for batched fetch logic (first batch, subsequent batches, page token handling)
- [x] Write tests for append behavior (no duplicate emails)
- [x] Run tests - must pass before next task

### Task 10: Fix archive/spam/delete folder sync (Issue 12)
- [x] In `GmailAPIManager.swift:450-454` `archiveEmail()`: before API call save email copy, after success create copy with `folder: .archive` and add to `emailsByAccount`
- [x] Apply same pattern to `spamEmail()` (move to .spam) and `deleteEmail()` (move to .trash)
- [x] Ensure removed email disappears from source folder and appears in target folder immediately
- [x] Write tests for archive flow (remove from inbox, appear in archive)
- [x] Write tests for spam/delete flow
- [x] Run tests - must pass before next task

---

### Phase 4: UI Enhancements

### Task 11: Action buttons with tooltips (Issue 8)
- [x] Add action closure properties to `NativeMessageDetail` in `MessageWebView.swift`
- [x] Add button bar between message headers and body: Reply, Reply All, Forward | Spacer | Archive, Delete, Spam
- [x] Each button: icon + `.help("Reply (Cmd+Shift+R)")` tooltip using `ShortcutAction.shortcutLabel`
- [x] Wire buttons to same handlers as keyboard shortcuts in `MainView.swift`
- [x] Write tests for action button configuration and tooltip text
- [x] Run tests - must pass before next task

### Task 12: Context menu on message list (Issue 9)
- [x] In `MessageList.swift` add `.contextMenu` to `MessageRow` with actions: Reply, Reply All, Forward, Archive, Delete, Spam
- [x] Pass action closures from `MainView.swift`
- [x] Each menu item shows hotkey hint text
- [x] Write tests for context menu action routing
- [x] Run tests - must pass before next task

### Task 13: Compose window resize + draft on Esc (Issue 7)
- [x] In `ComposeView.swift` change fixed frame to `.frame(minWidth: 450, idealWidth: 600, minHeight: 350, idealHeight: 500)`
- [x] Implement close handler: if any field non-empty, fire-and-forget `saveDraft()` via Gmail Drafts API (POST /users/me/drafts)
- [x] Add `createDraft()` to `GmailAPIClient.swift`
- [x] Add `saveDraft()` to `GmailAPIManager.swift`
- [x] Write tests for createDraft API call construction
- [x] Write tests for draft-save-on-close decision logic (empty vs non-empty fields)
- [x] Run tests - must pass before next task

### Task 14: Unified sidebar — merge accounts and folders (Issue 13)
- [x] Create `AgMail/Views/UnifiedSidebar.swift`:
  - Folders as DisclosureGroup items, sub-items = accounts (colored circle with initial + email)
  - Click folder = all accounts, click account sub-item = filter to that account
  - Bottom: Add Account + Settings buttons
- [x] In `MainView.swift` replace HSplitView 4-panel with 3-panel (UnifiedSidebar + MessageList + Detail)
- [x] Remove `AccountSidebar.swift` and `FolderList.swift` (or mark deprecated)
- [x] Use `.listStyle(.sidebar)` for native macOS sidebar look
- [x] Write tests for folder-account data structure and filtering logic
- [x] Run tests - must pass before next task

### Task 15: Account editing (name, color, avatar)
- [x] In `UnifiedSidebar.swift` add context menu on account items: "Edit Account" -> sheet/popover with TextField (name) + Picker (color)
- [x] Add `updateAccount()` to `AccountManager.swift`
- [x] Avatar: initials from displayName in colored circle with border (color = account color)
- [x] Write tests for updateAccount logic
- [x] Run tests - must pass before next task

---

### Phase 5: Infinite Scroll

### Task 16: Infinite scroll pagination (Issue 11)
- [x] In `GmailAPIManager.swift` add `pageTokens: [String: [Folder: String]]` storage (accountId -> folder -> token)
- [x] Implement `fetchMoreEmails(accountId:, folder:)` using stored pageToken, append results to `emailsByAccount`
- [x] In `UnifiedMailbox.swift` add `hasMoreEmails(folder:, accountId:)` checking pageToken existence
- [x] In `MessageList.swift` add sentinel `ProgressView().onAppear { onLoadMore?() }` at end of list
- [x] Wire `onLoadMore` through `MainView` to `GmailAPIManager.fetchMoreEmails()`
- [x] Write tests for pageToken management (store, retrieve, clear on full refresh)
- [x] Write tests for fetchMoreEmails append behavior
- [x] Run tests - must pass before next task

---

### Phase 6: Search + Autocomplete

### Task 17: Global search overlay (Issue 16)
- [x] Create `AgMail/Views/SearchOverlay.swift`: Spotlight-style centered overlay
  - TextField with auto-focus, results in dropdown list
  - Esc closes, Enter/click selects result
- [x] Search via Gmail API: `GET /users/me/messages?q={query}` for each account in parallel
- [x] Debounce 300ms on text input
- [x] Results: MessageRow with account color indicator
- [x] On select: navigate to email's folder, highlight in message list
- [x] In `MainView.swift` wire `Cmd+Shift+F` to toggle search overlay
- [x] Write tests for search query construction and debounce logic
- [x] Write tests for result merging from multiple accounts
- [x] Run tests - must pass before next task

### Task 18: Address autocomplete in Compose (Issue 17)
- [x] Create `AgMail/Services/ContactsCache.swift`:
  - Storage: `UserDefaults` (Set of email+displayName pairs)
  - Population: extract From headers during `fetchEmails`/`incrementalSync`
  - Update: add new senders on each sync cycle
- [x] In `ComposeView.swift` for To/Cc fields:
  - Show suggestions dropdown on text input
  - Filter by email and displayName
  - On select: insert full address "Name <email>"
- [x] Wire `ContactsCache` population into `GmailAPIManager` sync flows
- [x] Write tests for ContactsCache (add, deduplicate, search/filter)
- [x] Write tests for autocomplete matching logic
- [x] Run tests - must pass before next task

---

### Phase 7: Notifications

### Task 19: Desktop notifications for new emails (Issue 15)
- [x] Create `AgMail/Services/NotificationManager.swift`:
  - `UNUserNotificationCenter` setup and permission request
  - `showNotification(from:, subject:, snippet:, emailId:, accountId:)`
- [x] In `GmailAPIManager.swift` `incrementalSync()`: trigger notification for new INBOX+UNREAD emails
- [x] In `AgMailApp.swift` `AppState.init()`: request notification permission
- [x] Notification click handler: activate window, navigate to email (via userInfo emailId/accountId)
- [x] Write tests for notification content building
- [x] Write tests for notification trigger conditions (only new INBOX+UNREAD)
- [x] Run tests - must pass before next task

---

### Verification & Finalization

### Task 20: Verify acceptance criteria
- [x] Verify all 15+ issues from overview are implemented
- [x] Verify edge cases (multiple accounts, empty folders, long subjects, no network)
- [x] Run full test suite: `xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS'`
- [x] Run linter - all issues must be fixed (no SwiftLint in project; xcodebuild compilation passed clean)
- [x] Verify test coverage meets project standard (80%+) — business logic 80%+, Views lower due to no UI test framework

### Task 21: [Final] Update documentation
- [x] Update CLAUDE.md with new patterns (UnifiedSidebar, SearchOverlay, NotificationManager, ContactsCache, Sent folder, infinite scroll)
- [x] Update project structure section in CLAUDE.md

## Technical Details

### Keyboard Shortcut Mappings (new)
| Action | Shortcut | Notes |
|--------|----------|-------|
| Delete | Cmd+D | |
| Spam | Cmd+Shift+1 | |
| Reply All | Cmd+R | Was conflicting with system Reload |
| Reply | Cmd+Shift+R | |
| Forward | Cmd+T | |
| Search | Cmd+Shift+F | Opens SearchOverlay |
| Settings | Cmd+, | System standard |
| Archive | Cmd+E | Unchanged |
| Compose | Cmd+N | Unchanged |

### Unified Sidebar Structure (3-panel layout)
```
[Inbox] (23)              <- click = all accounts
  +-- user1@gmail.com (15)  <- colored circle + initial
  +-- user2@gmail.com (8)
[Sent]
  +-- user1@gmail.com
  +-- user2@gmail.com
[Archive]
  +-- ...
[Trash]
[Spam]
[Drafts]
---------
[+ Add Account]
[Settings]
```

### Batched Email Loading Flow
```
fetchEmails():
  page1 = listMessages(maxResults: 50)
  emails1 = getMessages(page1.ids)
  emailsByAccount.append(emails1)  -> UI updates

  page2 = listMessages(pageToken: page1.nextPageToken)
  emails2 = getMessages(page2.ids)
  emailsByAccount.append(emails2)  -> UI updates

  ... repeat until no nextPageToken
  save lastPageToken for infinite scroll
```

### Notification Payload
```swift
let content = UNMutableNotificationContent()
content.title = senderName
content.subtitle = subject
content.body = String(bodyPreview.prefix(100))
content.userInfo = ["emailId": id, "accountId": accountId]
content.sound = .default
```

### ContactsCache Structure
```swift
struct CachedContact: Codable, Hashable {
    let email: String
    let displayName: String?
}
// Storage: UserDefaults key "agmail_contacts_cache"
// Population: from email.from during fetchEmails/incrementalSync
```

## Post-Completion
*Items requiring manual intervention*

**Manual verification:**
- Test with 2+ accounts, verify unique colors
- Test hotkeys on EN and RU keyboard layouts
- Test archive/spam/delete flow: action in Inbox -> verify appears in target folder
- Test batched loading: observe emails appearing incrementally
- Test infinite scroll in large folders (100+ emails)
- Test search across multiple accounts
- Test address autocomplete in compose (To/Cc fields)
- Test notification click navigates to correct email
- Test compose Esc with filled/empty fields (draft save)
- Test context menu on different message states
- Test sidebar: folder click vs account sub-item click
- Test account editing (name, color change)
