# Thread/Conversation View — Design Spec

**Date:** 2026-04-01
**Status:** Approved

## Problem Statement

The detail panel shows a single email. For conversations (reply chains), the user sees only the selected message with quoted text nested inline. This makes it hard to follow multi-message conversations. The user wants a Gmail-like conversation view where each message in the thread is displayed as a separate block with its own headers, body, and action buttons.

## Decisions

- All messages in a thread are displayed expanded (no collapse/expand)
- Message list (left panel) stays unchanged — no thread grouping
- Thread data loaded via Gmail Threads API (`threads.get`) — one request per thread
- Reply/ReplyAll/Forward buttons on each message; Delete/Archive/Spam/MoveToInbox shared for whole thread
- Single messages (thread with 1 message) displayed as before via `NativeMessageDetail`

---

## Design

### 1. Data Model Changes

#### Email struct — add `threadId`

Add `threadId: String` to `Email` with default `""` so existing callers compile:

```swift
struct Email {
    // ... existing fields ...
    let threadId: String  // Gmail thread ID
}
```

#### CachedEmail — add `threadId`

Add `threadId: String?` to `CachedEmail` (SwiftData lightweight migration).

#### GmailThread — new model

```swift
struct GmailThread: Codable {
    let id: String
    let messages: [GmailMessage]?
    let historyId: String?
}
```

Add to `GmailAPIModels.swift`.

### 2. API Layer

#### GmailAPIClient — `getThread` method

New method wrapping `GET /gmail/v1/users/me/threads/{threadId}?format=full`:

```swift
func getThread(id: String, format: String = "full") async throws -> GmailThread
```

Returns all messages in the thread with full payload (headers, body, attachments).

#### GmailAPIManager — `fetchThread` method

```swift
func fetchThread(threadId: String, accountId: String) async throws -> [ThreadMessage]
```

Calls `getThread`, parses each `GmailMessage` into `ThreadMessage`:

```swift
struct ThreadMessage: Identifiable {
    let id: String           // message ID
    let from: String
    let to: String
    let cc: String
    let date: Date
    let subject: String
    let bodyHTML: String
    let attachments: [MessageContentData.AttachmentInfo]
    let inlineImages: [(cid: String, attachmentId: String, mimeType: String)]
}
```

#### convertGmailMessageToEmail — add threadId

Parse `message.threadId` and pass to `Email` init. Already available in `GmailMessage.threadId`.

#### Metadata headers

No change needed — `threadId` comes from the message object, not headers.

### 3. UI — ThreadDetailView (new file)

**File:** `Aerio/Views/ThreadDetailView.swift`

Replaces `NativeMessageDetail` when the thread has >1 messages.

**Structure:**
- Thread subject header at top
- Shared action bar: Archive, Delete, Spam, Move to Inbox
- `ScrollViewReader` containing `ForEach(threadMessages)` → `ThreadMessageView`
- Thick divider (4px) between messages for clear visual separation
- Auto-scroll to last message on appear
- "N messages in thread" counter

**Loading state:**
- Shows loading indicator while `fetchThread` is in progress
- On error: falls back to `NativeMessageDetail` for the selected single message

### 4. UI — ThreadMessageView (new file)

**File:** `Aerio/Views/ThreadMessageView.swift`

One message block within the thread:

- **Avatar:** Circle with first letter of sender name, color derived from email address
- **Header row:** From (bold), date (right-aligned)
- **Subheader:** "To: ..." line
- **Body:** WKWebView rendering the message HTML (same `wrapEmailHTML` as current)
- **Attachments:** Same attachment chips as current `NativeMessageDetail`
- **Action buttons:** Reply, Reply All, Forward — per message, below the body
- **Divider:** 4px solid separator below each message

**Body rendering:**
- Each message gets its own `BodyWebViewStore` instance
- HTML extracted from message payload (text/html preferred, text/plain fallback via `extractBodyFromPayload`)
- Inline CID images resolved via attachment download (same as current `loadContent`)
- Only the message's own body — no quoted previous messages (Gmail API returns each message body separately in `threads.get`)

### 5. Caching

**In-memory thread cache:**
- `static var threadCache: [String: [ThreadMessage]]` on `GmailAPIManager` or a dedicated `ThreadCache` class
- Keyed by `threadId`
- LRU eviction at ~20 threads
- Cleared on app restart (session-only)

**No SwiftData caching** for thread content in v1. The in-memory cache is sufficient since thread loading is fast (single API call) and the detail panel already has content caching per message.

### 6. Integration — MainView

**Detail panel switching logic:**

```
if selectedEmail exists:
    if threadId is not empty AND thread has >1 messages:
        show ThreadDetailView(threadId, accountId, apiManager, ...)
    else:
        show NativeMessageDetail(email, ...) // existing behavior
```

**Thread message count detection:**
- Quick check: count emails in `emailsByAccount` with same `threadId`
- If >1: load thread view
- If 1: show single message as before
- Edge case: if only 1 email loaded but thread actually has more (older messages not fetched yet), `threads.get` will reveal them

**Callbacks:**
- Reply/ReplyAll/Forward receive the specific `ThreadMessage` from the thread (converted to `Email` for `ComposeView`)
- Delete/Archive/Spam/MoveToInbox operate on the thread's primary message (or all messages — same behavior as current)

### 7. Fallback Behavior

- `getThread` API failure → show `NativeMessageDetail` for selected email
- Email without `threadId` → show `NativeMessageDetail`
- Thread with 1 message → show `NativeMessageDetail`

---

## Files Affected

| File | Action | Changes |
|------|--------|---------|
| `Aerio/Models/Email.swift` | Modify | Add `threadId: String` |
| `Aerio/Persistence/DataStore.swift` | Modify | Add `threadId` to CachedEmail |
| `Aerio/Models/GmailAPIModels.swift` | Modify | Add `GmailThread` struct |
| `Aerio/Services/GmailAPIClient.swift` | Modify | Add `getThread()` method |
| `Aerio/Services/GmailAPIManager.swift` | Modify | Add `fetchThread()`, `ThreadMessage`, threadId in `convertGmailMessageToEmail`, thread cache |
| `Aerio/Views/MainView.swift` | Modify | Switch between ThreadDetailView and NativeMessageDetail |
| `Aerio/Views/ThreadDetailView.swift` | **Create** | Thread conversation view |
| `Aerio/Views/ThreadMessageView.swift` | **Create** | Single message in thread |

## Out of Scope

- Thread grouping in message list
- Collapse/expand individual messages in thread
- SwiftData caching for threads
- Thread-level read/unread tracking
- Real-time thread updates (new message appears in open thread)
