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

- Persisted Outbox queue lives in the existing SwiftData store (`default.store`).
- Send is fire-and-forget from the compose window: the window closes immediately after enqueue.
- Inline `sendError` UI in ComposeView is removed; all post-enqueue feedback is delivered via the Outbox panel and `UNUserNotificationCenter`.
- Idempotency is enforced via a locally-generated `Message-ID:` header that we control and can search for before retrying.
- Sidebar shows an Outbox row only when the queue is non-empty.
- No `NWPathMonitor` integration; backoff retry is sufficient for the reported scenarios.

## Architecture

### Data Model

`OutboxItem` is a SwiftData `@Model` stored alongside the existing email cache.

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
2. If none, finds the earliest `nextAttemptAt` in the future and sleeps until then (cancellable).
3. For each ready item: sets `.sending`, runs idempotency probe if needed, calls `client.sendMessage`, handles result.
4. On success: deletes the item, fires success notification, kicks off `apiManager.refreshAll()`, performs side-effects (delete consumed draft, archive replied-to inbox message).
5. On failure: classifies (transient vs permanent), updates `attemptCount` / `nextAttemptAt` / `status`, fires failure notification on permanent or after final retry.

The loop starts in `init` (after loading items) and is signalled to wake up when `enqueue` or `retry` is called. Implementation: a lightweight `AsyncStream<Void>` continuation that the loop awaits; `enqueue`/`retry` `yield()` to it, and the loop's `Task.sleep` for backoff races against this signal so a new item shortcuts any pending sleep.

Only one item is sent at a time (sequential processing). Concurrency is not a goal; ordering matches user intent.

### ComposeView Changes

`sendMessage()` becomes synchronous-feeling:

```swift
private func sendMessage() {
    guard !toField.isEmpty,
          let fromEmail = accountManager.accounts.first(where: { $0.id == selectedAccountId })?.email
    else { return }

    let messageId = "<\(UUID().uuidString)@aerio.local>"
    let raw = RFC2822Builder.build(..., messageId: messageId)

    let archiveOnSuccess = (composeType == .reply || composeType == .replyAll)
        && replyToEmail?.folder == .inbox
        && UserDefaults.standard.bool(forKey: AppState.archiveOnReplyKey)

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

    hasSent = true
    Task { await outboxService.enqueue(item) }
    onDismiss?()
}
```

The Send button is already disabled when `toField.isEmpty` (existing logic). The `selectedAccountId` is always populated from the account picker (which defaults to the first account on init), so the `fromEmail` guard is a defensive no-op rather than a user-visible error.

`saveDraftIfNeeded` keeps its existing `guard !hasSent` check; setting `hasSent = true` synchronously before `onDismiss` ensures `onDisappear` sees the right value.

The inline `sendError` `@State` and its UI block (`ComposeView.swift:163-174`) are removed; the `isSending` state is also no longer needed since the window closes immediately on Send.

### Sidebar Changes

`UnifiedSidebar` adds an Outbox row directly above the per-account folders, conditionally rendered when `outboxService.items.isEmpty == false`.

- Title: `Outbox`
- Badge: total item count
- Color: red if any item is `.failed`, default otherwise
- Selecting it sets a new sidebar selection mode that, in `MessageList`, shows the `OutboxList` view instead of the email list.

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

## Open Questions

None at write time. Implementation plan to clarify any that surface.

## Out of Scope (Recorded For Later)

- Undo Send (5–10s window before actual send).
- Multiple concurrent sends per account.
- Resumable upload for very large attachments.
- Bandwidth-aware send scheduling.
