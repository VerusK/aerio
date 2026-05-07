# Outbox — Reliable Send Design Spec

**Date:** 2026-05-07
**Status:** Approved

## Problem Statement

Users report that emails sometimes appear to be sent but are not actually delivered. Investigation of the current send path (`ComposeView.sendMessage` → `GmailAPIManager.sendEmail` → `GmailAPIClient.sendMessage`) revealed several silent-failure modes:

1. **Window closed during send** — `Task { ... }` is created inside the SwiftUI view and is not cancelled when the window closes. State updates (`sendError`, `isSending`) go to a dead view, and `onDisappear` triggers `saveDraftIfNeeded()` while the send may still be in flight, producing both a draft and (sometimes) a sent message.
2. **Network/transient error** — error is shown as a thin orange line at the bottom of compose, easy to miss; the Send button returns to its idle state and looks ready to retry, but the user has already mentally closed the task.
3. **App quit / sleep during send** — the in-flight `Task` dies with the process and there is no record of the attempt.
4. **Send succeeds, post-send refresh fails** — the email is on the server but does not yet appear in the local Sent folder, prompting the user to send again.
5. **Token refresh failure** — `sessionExpired` surfaces only as the same easy-to-miss inline error.

The unifying root cause: **send is tied to the lifetime of the compose view and has no durable representation**. We need a queue that survives view lifecycle, app quits, and transient failures, with prominent feedback when something goes wrong.

## Goals

- A user who clicks Send can rely on the email being delivered or being told it failed.
- Closing the compose window, quitting the app, or losing connectivity must not silently lose a message.
- Errors must surface visibly (not as inline orange text) and stay surfaced until acknowledged or resolved.
- Retries are automatic for transient failures; users can manually retry permanent failures.

## Non-Goals

- Undo Send (timed delay before actually sending). Out of scope.
- Smart retry policies based on network quality / battery / push notifications.
- Server-side scheduled send. Out of scope.
- Replacing Gmail's own server-side draft storage.

## Decisions

- Persisted Outbox queue lives in its own SwiftData store (`outbox.store`) under Application Support, isolated from the email cache. Avoids coupling between `EmailCache` and `OutboxService` save/migration paths.
- `OutboxService` is owned by `AppState` and injected into views via `@EnvironmentObject` (mirrors `AccountManager`, `GmailAPIManager`). Not a `.shared` singleton.
- Send is fire-and-forget from the compose window: the window closes immediately after enqueue.
- Inline `sendError` UI in ComposeView is removed; all post-enqueue feedback is delivered via the Outbox panel and `UNUserNotificationCenter`.
- Idempotency is enforced via a locally-generated `Message-ID:` header that we control and can search for before retrying.
- Sidebar shows an Outbox row only when the queue is non-empty. A new `enum SidebarSelection { case folder(Folder), outbox }` replaces the implicit "selected folder" state so Outbox is not modeled as a Gmail folder.
- The wire-protocol for sending is abstracted via an `OutboxSender` protocol that `GmailAPIClient` conforms to. Tests inject `MockOutboxSender`; production uses the real client.
- `RFC2822Builder` accepts a `ComposePayload` struct so all three call sites (current `sendEmail`, current `saveDraft`, new Outbox path) build raw MIME via one entry point.
- No `NWPathMonitor` integration; backoff retry is sufficient for the reported scenarios.

## Architecture

### End-to-end data flow

```
[Send click in ComposeView]
        │
        ▼
  build ComposePayload
        │
        ▼
  RFC2822Builder.build(payload, messageId: <UUID@aerio.local>)
        │
        ▼
  OutboxItem(rawMime, messageIdHeader, accountId, ...)
        │
        ▼
  outboxService.enqueue(item)  ──┐  (returns immediately)
                                 │
        ┌────────────────────────┘
        │
        ▼
  ComposeView: hasSent=true → onDismiss() → window closes
                                 │
                                 │  (parallel)
                                 ▼
  OutboxService.processLoop wakes via AsyncStream signal
        │
        ▼
  fetch pending where nextAttemptAt<=now, sorted by createdAt
        │
        ▼
  per-item, sequential:
        │
        ▼
  status=.sending; (if attemptCount>0) probe rfc822msgid in SENT
        │                                  │
        │                                  └─→ found: skip send, treat as success
        │
        ▼
  sender.sendMessage(raw, threadId)
        │
   ┌────┴────┐
   │         │
success   failure
   │         │
   │         └─→ classify (transient | permanent)
   │                 │
   │                 ├─ transient & attempts<3 → status=.pending,
   │                 │                          nextAttemptAt=now+backoff
   │                 │
   │                 └─ permanent or attempts>=3 → status=.failed,
   │                                              UNUserNotification(failure)
   │
   ├─ delete OutboxItem
   ├─ if draftIdToConsume → client.deleteDraft
   ├─ if archiveOnSuccess → client.modifyMessage(removeLabels: [INBOX])
   ├─ apiManager.refreshAll()
   └─ UNUserNotification(success) [suppressed if app frontmost]
```

### Data Model

`OutboxItem` is a SwiftData `@Model` stored in a dedicated `outbox.store` container.

```swift
@Model
final class OutboxItem {
    @Attribute(.unique) var id: UUID
    var accountId: String
    var rawMime: Data            // RFC2822 built at Send time
    var messageIdHeader: String  // value of the Message-ID header inside rawMime
    var threadId: String?        // for replies
    var draftIdToConsume: String? // delete this draft on success
    var subject: String           // for UI / notifications
    var recipientsPreview: String // first To address for UI
    var statusRaw: String         // OutboxStatus.rawValue
    var attemptCount: Int
    var lastError: String?
    var createdAt: Date
    var nextAttemptAt: Date
    var archiveOnSuccessForMsgId: String? // inbox auto-archive on reply
    var archiveOnSuccessForAccountId: String?
}

enum OutboxStatus: String { case pending, sending, failed }
```

`statusRaw` is a `String` (not the enum directly) for SwiftData compatibility; `var status: OutboxStatus` is a computed accessor.

### Lifecycle

```
[Send clicked]
      │
      ▼
   pending  ──(picker)──▶  sending
                              │
                ┌─────────────┼─────────────┐
                │             │             │
             success      transient      permanent
                │           failure        failure
                ▼             │             │
            [delete]          ▼             ▼
                          attempt < 3   marked failed
                              │       (manual retry)
                              ▼
                        nextAttemptAt =
                        now + backoff
                              │
                              ▼
                          pending
```

- Backoff schedule: 10s, 60s, 300s. After three failed attempts the item is `failed` and waits for manual retry.
- `permanent failure` = HTTP 400 (malformed) or `sessionExpired` (token revoked). Anything else is treated as transient.
- On app start, items with `status == .sending` are reset to `.pending`. The idempotency check (next section) protects against duplicates.

### Idempotency

`RFC2822Builder` is extended to accept (or generate) a `Message-ID` header of the form `<UUID@aerio.local>`. This UUID is stored as `messageIdHeader` on the `OutboxItem`.

Before sending an item that has `attemptCount > 0` OR was recovered from `.sending` on launch, `OutboxService` first runs:

```
client.listMessages(query: "rfc822msgid:<our-message-id>", labelIds: ["SENT"])
```

If a match exists, the previous attempt actually reached Gmail; we mark the item delivered and remove it without sending again. If not, we send.

First-attempt sends skip the idempotency probe (one extra API call per send is unnecessary cost in the common case).

### OutboxService

`@MainActor final class OutboxService: ObservableObject` exposed via `@EnvironmentObject` similar to `AccountManager`.

```swift
@MainActor
final class OutboxService: ObservableObject {
    @Published private(set) var items: [OutboxItem] = []

    init(modelContext: ModelContext, apiManager: GmailAPIManager) { ... }

    func enqueue(_ item: OutboxItem) async
    func retry(itemId: UUID) async
    func cancel(itemId: UUID) async
    func resumeOnLaunch() async   // resets .sending → .pending, kicks loop
}
```

A single `processLoop` task is owned by the service. It:

1. Loads pending items where `nextAttemptAt <= now`, sorted by `createdAt`.
2. If none, finds the earliest `nextAttemptAt` in the future and sleeps **exactly until** that timestamp (not a fixed poll interval) — `Task.sleep(until:)`-equivalent — to avoid busy-loop. If the queue is fully empty, the loop awaits the wake-up signal indefinitely.
3. For each ready item: sets `.sending`, runs idempotency probe if needed, calls `sender.sendMessage`, handles result.
4. **Each item is processed inside its own `do/catch` boundary.** A corrupt or unprocessable item is logged, marked `.failed` with `lastError = "Processing crashed: <reason>"`, and the loop continues to the next item — one bad item must never block the queue forever.
5. On success: deletes the item, fires success notification, kicks off `apiManager.refreshAll()`, performs side-effects (delete consumed draft, archive replied-to inbox message). Side-effect failures are logged but do not bubble — the email is sent; the side-effect is best-effort.
6. On failure: classifies (transient vs permanent), updates `attemptCount` / `nextAttemptAt` / `status`, fires failure notification on permanent or after final retry.

The loop starts in `init` (after loading items) and is signalled to wake up when `enqueue` or `retry` is called. Implementation: a lightweight `AsyncStream<Void>` continuation that the loop awaits; `enqueue`/`retry` `yield()` to it, and the loop's `Task.sleep` for backoff races against this signal so a new item shortcuts any pending sleep.

Only one item is sent at a time (sequential processing). Concurrency is not a goal; ordering matches user intent.

### Sender Abstraction

```swift
protocol OutboxSender {
    func sendMessage(raw: Data, threadId: String?) async throws -> GmailMessage
    func findInSent(messageId: String) async throws -> Bool
}
```

`GmailAPIClient` is extended with `findInSent(messageId:)` (thin wrapper around `listMessages(query: "rfc822msgid:\(messageId)", labelIds: ["SENT"])`) and conforms to `OutboxSender`. Tests inject a `MockOutboxSender` that records calls and returns scripted results — no network, no auth, no Keychain.

`OutboxService` is constructed with `@MainActor` per-account `[String: OutboxSender]` (mirrors how `GmailAPIManager` keeps `[accountId: GmailAPIClient]`). On account add/remove, `AppState` updates this map.

### ComposePayload (DRY)

```swift
struct ComposePayload {
    let from: String
    let to: String
    let cc: String?
    let subject: String
    let body: String
    let inReplyTo: String?
    let references: String?
    let htmlBody: String?
    let attachments: [RFC2822Builder.Attachment]
    let inlineImages: [RFC2822Builder.InlineImage]
    let messageId: String?  // optional; when set, embedded as Message-ID header
}

extension RFC2822Builder {
    static func build(_ payload: ComposePayload) -> String { ... }
}
```

`GmailAPIManager.sendEmail` and `GmailAPIManager.saveDraft` are refactored to construct `ComposePayload` and call the new builder. `OutboxService.enqueue` does the same. One source of truth for raw MIME assembly.

### ComposeView Changes

`sendMessage()` becomes synchronous-feeling:

```swift
@State private var isSendingViaOutbox = false  // race guard for saveDraftIfNeeded

private func sendMessage() {
    guard !toField.isEmpty,
          let fromEmail = accountManager.accounts.first(where: { $0.id == selectedAccountId })?.email
    else {
        logger.error("Send guard failed: empty toField or no fromEmail for account \(selectedAccountId, privacy: .public)")
        return
    }

    isSendingViaOutbox = true
    hasSent = true

    let messageId = "<\(UUID().uuidString)@aerio.local>"
    let (htmlBody, editorInlineImages) = editorState.htmlBodyWithInlineImages()
    let archiveOnSuccess = (composeType == .reply || composeType == .replyAll)
        && replyToEmail?.folder == .inbox
        && UserDefaults.standard.bool(forKey: AppState.archiveOnReplyKey)

    let payload = ComposePayload(
        from: fromEmail,
        to: toField,
        cc: ccField.isEmpty ? nil : ccField,
        subject: subjectField,
        body: bodyText,
        inReplyTo: replyToEmail?.messageId ?? fetchedMessageId,
        references: replyToEmail?.messageId ?? fetchedMessageId,
        htmlBody: htmlBody.isEmpty ? nil : htmlBody,
        attachments: attachments.map { ... },
        inlineImages: editorInlineImages.map { ... },
        messageId: messageId
    )
    let raw = RFC2822Builder.build(payload)

    let item = OutboxItem(
        id: UUID(),
        accountId: selectedAccountId,
        rawMime: Data(raw.utf8),
        messageIdHeader: messageId,
        threadId: replyToEmail?.threadId.isEmpty == false ? replyToEmail?.threadId : nil,
        draftIdToConsume: composeType == .draft ? draftId : nil,
        subject: subjectField,
        recipientsPreview: ContactsCache.parseAddressList(toField).first?.email ?? toField,
        status: .pending,
        attemptCount: 0,
        createdAt: Date(),
        nextAttemptAt: Date(),
        archiveOnSuccessForMsgId: archiveOnSuccess ? replyToEmail?.msgId : nil,
        archiveOnSuccessForAccountId: archiveOnSuccess ? replyToEmail?.accountId : nil
    )

    Task { await outboxService.enqueue(item) }
    onDismiss?()
}
```

The Send button is already disabled when `toField.isEmpty` (existing logic). The `selectedAccountId` is always populated from the account picker (which defaults to the first account on init), so the `fromEmail` guard is a defensive no-op for production paths but logs if hit.

`saveDraftIfNeeded` is updated to also bail when `isSendingViaOutbox` is true:

```swift
private func saveDraftIfNeeded() {
    guard !hasSent && !isSendingViaOutbox else { return }
    // ... existing logic
}
```

This double-guard protects against any SwiftUI state-flush ordering issue between `hasSent` and `onDisappear`. It is explicit and cheap.

The inline `sendError` `@State` and its UI block (`ComposeView.swift:163-174`) are removed; the `isSending` state is also no longer needed since the window closes immediately on Send.

### Sidebar Changes

`UnifiedSidebar` adds an Outbox row directly above the per-account folders, conditionally rendered when `outboxService.items.isEmpty == false`.

- Title: `Outbox`
- Badge: total item count
- Color: red if any item is `.failed`, default otherwise

A new selection model replaces the implicit "current folder" state:

```swift
enum SidebarSelection: Hashable {
    case folder(Folder)
    case outbox
}
```

`UnifiedSidebar` and the message-list area both switch on `SidebarSelection`. When `.outbox` is active, the message-list area renders `OutboxList`; when `.folder(...)` is active, the existing `MessageList` flow runs unchanged. `Folder` keeps its current Gmail-domain meaning — Outbox is not a Gmail folder.

### OutboxList View

A new `OutboxList` view, rendered in the message list panel when the Outbox row is selected.

For each item:
- Status icon (pending: hourglass, sending: spinner, failed: warning triangle)
- Subject and first recipient
- Account label
- Action buttons: Retry (failed only), Cancel (any state)

No "Edit" action in v1 — the rawMime is opaque and reconstructing the full compose state is non-trivial. Out of scope for this spec.

### Notifications

`UNUserNotificationCenter` is already wired up via `NotificationManager`. We add two notification categories:

- `outbox.success` — title "Sent", body "<subject> — to <recipient>". Auto-dismisses.
- `outbox.failure` — title "Failed to send", body "<subject>: <error>". Persistent, includes `Retry` action that, when tapped, calls `OutboxService.retry(itemId:)`.

Successful notifications are suppressed if the app is frontmost (the Outbox row simply disappears).

### Side-Effects on Success

Two side-effects currently live in `ComposeView.sendMessage` and must move into `OutboxService`:

1. Delete the source draft (when `draftIdToConsume` is set).
2. Archive the replied-to inbox email when `archiveOnReplyKey` is enabled (gated by `archiveOnSuccessForMsgId`).

`apiManager.refreshAll()` continues to be called after each successful send.

### Account Removal

When `AccountManager` removes an account, all `OutboxItem`s with that `accountId` are marked `.failed` with `lastError = "Account removed"` so the user can see what was lost. They are not auto-deleted.

## Error Classification

| Error from `GmailAPIClient` | Classification | Behavior |
|---|---|---|
| `networkError` | transient | retry with backoff |
| `serverError(5xx)` | transient | retry with backoff |
| `rateLimited` | transient | retry with backoff (already retried inside client) |
| `forbidden` | permanent | mark `.failed` |
| `notFound` | permanent | mark `.failed` |
| `sessionExpired` | permanent | mark `.failed`, notification suggests re-auth |
| `decodingError` | permanent | mark `.failed` (likely a bug) |
| `historyExpired` | n/a | not applicable to send path |
| HTTP 400 (malformed body) | permanent | mark `.failed` |

## Testing

### Unit (using `MockGmailAPIClient`, similar to existing test patterns)

- `OutboxServiceTests.testEnqueue_persistsAndStartsProcessing`
- `OutboxServiceTests.testProcess_successDeletesItemAndFiresNotification`
- `OutboxServiceTests.testProcess_transientErrorRetriesWithBackoff`
- `OutboxServiceTests.testProcess_threeTransientFailuresMarksFailed`
- `OutboxServiceTests.testProcess_permanentErrorSkipsRetry`
- `OutboxServiceTests.testIdempotency_skipsSendWhenAlreadyInSent`
- `OutboxServiceTests.testIdempotency_doesNotProbeOnFirstAttempt`
- `OutboxServiceTests.testResumeOnLaunch_resetsSendingToPending`
- `OutboxServiceTests.testCancel_removesItem`
- `OutboxServiceTests.testRetry_resetsFailedToPendingAndImmediatelyAttempts`
- `OutboxServiceTests.testAccountRemoval_marksItemsFailed`
- `OutboxServiceTests.testSideEffects_archivesRepliedToInboxOnSuccess`
- `OutboxServiceTests.testSideEffects_deletesConsumedDraftOnSuccess`

### Integration

- `ComposeViewTests.testSend_enqueuesAndDoesNotCreateDraft`
- `ComposeViewTests.testSend_setsHasSentBeforeOnDismiss`

### Manual QA

- Send and immediately Cmd+W the window — message arrives, no draft created
- Send, then quit the app within 200ms — message arrives on next launch
- Send while offline → reconnect — message eventually sends
- Send to invalid address (e.g. `notanemail`) — Outbox shows failed, notification appears
- Send three pending messages — they go out one at a time, in order
- Retry a failed message manually — sends successfully

## Implementation Order (worktree lanes)

After eng review, suggested execution lanes:

| Lane | Step | Modules | Depends on |
|---|---|---|---|
| A | 1. `OutboxItem` model + dedicated `outbox.store` container | `Models/`, `Persistence/` | — |
| A | 2. `RFC2822Builder.build(ComposePayload)` + `messageId` header support + tests | `Services/` (RFC2822Builder.swift) | — |
| A | 3. NotificationManager `outbox.success`/`outbox.failure` categories + Retry action | `Services/` (NotificationManager.swift) | — |
| B | 4. `OutboxSender` protocol + `GmailAPIClient.findInSent` + conformance | `Services/` (GmailAPIClient.swift) | 2 |
| B | 5. `OutboxService` + `processLoop` + tests via `MockOutboxSender` | `Services/` | 1, 4 |
| C | 6. `ComposeView` refactor (enqueue path, isSendingViaOutbox flag) | `Views/` | 5 |
| C | 7. `SidebarSelection` enum + `UnifiedSidebar` Outbox row + `OutboxList` view | `Views/` | 5 |
| D | 8. `AppState`/`AerioApp` wiring (env-injected service, resumeOnLaunch) | root + `Views/MainView.swift` | 5, 6, 7 |

Lane A items (1, 2, 3) parallelize cleanly across worktrees — separate files, no coupling. Lane C items (6, 7) both edit `Views/` so run sequentially or coordinate carefully.

## Open Questions

None at write time. Implementation plan to clarify any that surface.

## Out of Scope (Recorded For Later)

- Undo Send (5–10s window before actual send).
- Multiple concurrent sends per account.
- Resumable upload for very large attachments.
- Bandwidth-aware send scheduling.
