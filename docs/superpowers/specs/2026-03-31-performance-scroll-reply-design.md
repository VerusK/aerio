# Performance, Scroll Stability & Reply-to-Sent — Design Spec

**Date:** 2026-03-31
**Status:** Approved

## Problem Statement

Three interrelated issues affecting Aerio usability:

1. **Performance degradation** — app lags on any interaction (switching emails, focusing window). Root causes: DataStore loads all cached emails without limit, UnifiedMailbox rebuilds/re-sorts the entire array on every change, MessageWebView reloads content on every selection.
2. **Scroll position loss** — new emails arriving in background cause the message list to jump to top and sidebar folder focus to disappear. Root cause: GmailAPIManager replaces the email array wholesale on every sync, breaking SwiftUI's stable-ID tracking.
3. **Reply to sent email replies to self** — replying to a sent email puts your own address in To: instead of the original recipient. Root cause: `setupInitialValues()` always uses `email.from`; Email model lacks `to`/`cc` fields.

---

## Design

### 1. Performance — Lazy Loading & Content Cache

#### 1.1 DataStore: Scoped Fetches with Limits

**Current:** `loadEmails()` fetches ALL emails from SwiftData without filtering or limit.

**Change:**
- `loadEmails(for folder: Folder, accountId: String)` adds a `fetchLimit: 200` and filters by folder + account
- New `purgeOldEmails(keepLast: 1000)` method — called after each sync, deletes CachedEmail entries beyond the 1000 most recent (by date), preventing unbounded cache growth
- Startup path: load only the current folder's emails for display, not the entire database

#### 1.2 UnifiedMailbox: Incremental Merge

**Current:** `emailsByAccount` observer rebuilds the entire `allEmails` array and re-sorts on every change.

**Change:**
- New `mergeEmails(accountId: String, newEmails: [Email])` method that:
  - Computes diff by email `id` (new, removed, updated)
  - Inserts new emails at correct position via binary search on date (no full re-sort)
  - Removes only deleted emails
  - Updates changed emails in-place
- `@Published var allEmails` mutates incrementally — SwiftUI sees minimal diffs
- Remove the wholesale `rebuildEmails()` call from the `emailsByAccount` observer

#### 1.3 MessageWebView: In-Memory Content Cache

**Current:** Every email selection triggers `loadContent()` which fetches from API/cache, inlines images, and loads HTML into a new WKWebView.

**Change:**
- `contentCache: [String: String]` — in-memory dictionary keyed by `email.id`, stores fully-rendered HTML (with inlined images)
- On email selection: check cache first, skip `loadContent()` pipeline if hit
- LRU eviction at ~50 entries to bound memory usage
- Cache is per-session (cleared on app restart, which is fine since SwiftData has the raw content)

---

### 2. Scroll Stability & Sidebar Focus

#### 2.1 GmailAPIManager: No Wholesale Array Replacement

**Current:** Both `fetchEmails()` and `incrementalSync()` end with `emailsByAccount[accountId] = newArray`, replacing the entire array reference.

**Change:**
- Both methods call `UnifiedMailbox.mergeEmails()` instead of replacing the array
- This is the same merge mechanism from section 1.2 — single implementation, two benefits
- The array mutates in-place with stable element identities

#### 2.2 MessageList: Scroll Anchored to Selection

**Current:** `onChange(of: filteredEmails.count)` tries to detect new emails and scroll, using `knownEmailIds` tracking. This is fragile.

**Change:**
- Remove `onChange(of: filteredEmails.count)` scroll logic
- Remove `knownEmailIds` state
- Scroll position is inherently stable because the underlying array has stable IDs (from 2.1)
- New emails appear at top of list without moving the viewport
- `ScrollViewReader.scrollTo(selectedEmailId)` only called on explicit user navigation (keyboard shortcuts, click)

#### 2.3 UnifiedSidebar: Guard Against Duplicate Selection Events

**Current:** `onChange(of: selectedFolder)` calls `navigateAllToFolder()` which resets historyIds and forces full re-fetch. This can fire even when folder hasn't actually changed.

**Change:**
- Add guard in `onChange(of: selectedFolder)`: skip if new value equals previous value
- `selectedFolder` and `selectedAccountId` bindings are not affected by email array mutations (they live in MainView state, which is independent)
- This prevents phantom folder-change events from triggering unnecessary re-fetches

---

### 3. Reply to Sent Email

#### 3.1 Email Model: Add `to` and `cc` Fields

**Current:** `Email` struct has `from` but no `to` or `cc`.

**Change:**
- Add `to: String` and `cc: String` to `Email` struct (default empty string)
- Parse from Gmail API message headers (`To`, `Cc`) during Email construction — these headers already arrive in the API response, just aren't being stored
- Store in existing header-parsing logic alongside `from`, `subject`, etc.

#### 3.2 CachedEmail: Persist `to` and `cc`

**Current:** `CachedEmail` SwiftData model mirrors Email but without `to`/`cc`.

**Change:**
- Add optional `to: String?` and `cc: String?` properties to `CachedEmail`
- SwiftData handles lightweight migration automatically for new optional fields
- Update `toEmail()` and `fromEmail()` converters

#### 3.3 ComposeView: Sent-Aware Reply Logic

**Current:** `setupInitialValues()` always sets `toField = email.from` for reply/replyAll.

**Change in `setupInitialValues()`:**
- If `email.folder == .sent`:
  - **Reply:** `toField = email.to`
  - **ReplyAll:** `toField = email.to`, `ccField = email.cc`, with own address removed from both fields
- If `email.folder != .sent`:
  - Behavior unchanged: `toField = email.from` (or Reply-To if present)

**Change in `fetchReplyHeaders()`:**
- Same sent-folder logic: if email is from sent, extract `To` and `Cc` from headers instead of `From`
- Reply-To header still takes priority for non-sent emails

---

## Files Affected

| File | Changes |
|------|---------|
| `Aerio/Persistence/DataStore.swift` | Scoped fetch with limit, purge method |
| `Aerio/Services/UnifiedMailbox.swift` | `mergeEmails()` with incremental diff/insert |
| `Aerio/Services/GmailAPIManager.swift` | Call mergeEmails() instead of array replacement |
| `Aerio/Views/MessageWebView.swift` | In-memory content cache with LRU |
| `Aerio/Views/MessageList.swift` | Remove count-based scroll logic, remove knownEmailIds |
| `Aerio/Views/UnifiedSidebar.swift` | Guard duplicate folder selection |
| `Aerio/Views/MainView.swift` | Guard duplicate folder onChange |
| `Aerio/Models/Email.swift` | Add `to`, `cc` fields |
| `Aerio/Persistence/DataStore.swift` | Add `to`, `cc` to CachedEmail |
| `Aerio/Views/ComposeView.swift` | Sent-aware reply logic in setupInitialValues() and fetchReplyHeaders() |

## Out of Scope

- Full pagination/virtualization of message list (SwiftUI List already virtualizes rendering)
- Offline mode / full offline cache strategy
- Threading / conversation view
- Refactoring unrelated code
