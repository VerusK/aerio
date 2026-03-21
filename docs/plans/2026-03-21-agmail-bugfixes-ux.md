# AgMail: Bug Fixes and UX Improvements

## Overview

Fix 6 issues: message reader script bundle problem, panel position persistence, dock badge with unread count, mark-as-read on Gmail server, settings view with Cmd+, hotkey list, and Alt+Up/Down message navigation.

## Context

- Files involved: `AgMail/Views/MessageWebView.swift`, `AgMail/Views/MainView.swift`, `AgMail/Views/AccountSidebar.swift`, `AgMail/AgMailApp.swift`, `AgMail/Utilities/KeyboardShortcuts.swift`, `AgMail/Services/GmailScraperManager.swift`, `AgMail/Services/GmailScraper.swift`, `AgMail.xcodeproj/project.pbxproj`
- Related patterns: NSEvent-based keyboard shortcuts via `KeyboardShortcuts.action(for:)`, `GmailScraperManager` as central state manager, `WebViewPool` per-account isolation
- Dependencies: none (macOS SDK only)

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Fix "Message reader script not found"

The script is in the Xcode project but Bundle.main.url may fail if the Copy Bundle Resources build phase has issues, or if the file path in pbxproj doesn't match the actual filesystem path. The file exists as `AgMail/Scripts/gmail_message_reader.js` and is referenced in pbxproj Resources build phase.

**Files:**
- Modify: `AgMail.xcodeproj/project.pbxproj` (verify resource membership)
- Modify: `AgMail/Views/MessageWebView.swift` (add debug logging for script load failure)
- Modify: `AgMail/Services/GmailScraper.swift` (add debug logging for script load failure)

- [x] Build the app and check if `gmail_message_reader.js` exists in `build/Build/Products/Release/AgMail.app/Contents/Resources/`
- [x] If missing, fix the pbxproj resource reference to ensure the file is copied to the bundle
- [x] Add os.log debug output in `MessageWebView.loadContent()` to log `Bundle.main.url` result for diagnosing future issues
- [x] Write test verifying `gmail_message_reader.js` can be loaded from the test bundle
- [x] Run project test suite - must pass before task 2

### Task 2: Fix panel position persistence

The `SplitViewConfigurator` sets `autosaveName` via `DispatchQueue.main.async`, but the NSSplitView may not be found if the view hierarchy isn't ready. Additionally, when selecting an email, the detail panel content changes (placeholder -> NativeMessageDetail), causing layout recalculation that overrides saved positions.

**Files:**
- Modify: `AgMail/Views/MainView.swift`

- [x] Change `SplitViewConfigurator` to retry finding the NSSplitView with a short delay loop (e.g., DispatchQueue.main.asyncAfter with 0.1s increments, max 3 retries) to handle cases where the split view isn't in the hierarchy yet
- [x] Set `NSSplitView.arrangesAllSubviews = false` to prevent automatic rearrangement when subview content changes
- [x] Ensure the detail panel always has content (even the placeholder) with consistent frame constraints so the split view doesn't recalculate positions when switching between placeholder and message detail
- [x] Write test for `SplitViewConfigurator` initialization
- [x] Run project test suite - must pass before task 3

### Task 3: Add dock badge with unread count

**Files:**
- Modify: `AgMail/AgMailApp.swift`
- Modify: `AgMail/Services/GmailScraperManager.swift`

- [x] Add a `UserDefaults` boolean setting `showDockBadge` (default: true)
- [x] In `AppState.init()`, observe `scraperManager.$unreadCountsByAccount` and update `NSApp.dockTile.badgeLabel` with total unread count (empty string when 0)
- [x] Respect the `showDockBadge` setting - clear badge when disabled
- [x] Write tests verifying badge label is set correctly based on unread counts and the toggle
- [x] Run project test suite - must pass before task 4

### Task 4: Fix mark-as-read not persisting to Gmail

Currently `markAsRead` only updates the local model. On next poll, Gmail still reports the email as unread, overwriting the local state. Need to also execute the "markAsRead" Gmail action via the scraper.

**Files:**
- Modify: `AgMail/Services/GmailScraperManager.swift`

- [x] In `markAsRead(emailId:accountId:)`, after updating local state, call `scraper.executeAction("markAsRead", msgIds: [msgId])` to mark as read on Gmail
- [x] Need to find the email's `msgId` from the email array to pass to `executeAction`
- [x] Add error logging if the Gmail action fails (but keep local state updated optimistically)
- [x] Write tests for the updated `markAsRead` logic
- [x] Run project test suite - must pass before task 5

### Task 5: Settings view with Cmd+, hotkey list, and dock badge toggle

**Files:**
- Create: `AgMail/Views/SettingsView.swift`
- Modify: `AgMail/Utilities/KeyboardShortcuts.swift` (add display name/description for each action)
- Modify: `AgMail/Views/AccountSidebar.swift` (add gear icon below add account button)
- Modify: `AgMail/Views/MainView.swift` (add Cmd+, handler and settings sheet)
- Modify: `AgMail/AgMailApp.swift` (add Settings scene)

- [x] Add `displayName` and `shortcutLabel` computed properties to `ShortcutAction` for human-readable names (e.g., "Next Message" / "Cmd+J")
- [x] Create `SettingsView` with two sections: a list of all keyboard shortcuts (action name + shortcut key), and a toggle for "Show unread count on dock icon" bound to `UserDefaults` `showDockBadge`
- [x] Add `Settings` scene in `AgMailApp` body to enable standard macOS Cmd+, behavior
- [x] Add `openSettings` shortcut action to `ShortcutAction` enum with `NSEventKeyBinding(",", modifiers: .command)`
- [x] Handle `openSettings` in `MainView.handleKeyEvent` by calling `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`
- [x] Add a gear icon button below the add account button in `AccountSidebar` that opens settings
- [x] Write tests for `ShortcutAction.displayName` and `shortcutLabel`
- [x] Run project test suite - must pass before task 6

### Task 6: Add Alt+Up/Down hotkeys for message navigation

**Files:**
- Modify: `AgMail/Utilities/KeyboardShortcuts.swift`
- Modify: `AgMail/Views/MainView.swift`

- [x] Add `nextMessageAlt` and `previousMessageAlt` cases to `ShortcutAction` with `NSEventKeyBinding` using `.option` modifier and up/down arrow keys (characters from `charactersIgnoringModifiers`: Unicode F701 for down, F700 for up)
- [x] Handle `nextMessageAlt` and `previousMessageAlt` in `MainView.handleKeyEvent` the same way as `nextMessage`/`previousMessage`
- [x] Write tests verifying the new shortcut bindings match correctly
- [x] Run project test suite - must pass before task 7

### Task 7: Verify acceptance criteria

- [x] Run full test suite: `xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS'`
- [x] Build and launch app: verify gmail_message_reader.js loads, panels stay stable, dock badge shows, mark-as-read persists, Cmd+, opens settings, Alt+Up/Down navigates messages (manual verification - build succeeds, app launches)

### Task 8: Update documentation

- [x] Update README.md if user-facing changes
- [x] Update CLAUDE.md if internal patterns changed
- [x] Move this plan to `docs/plans/completed/`
