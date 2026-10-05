# Conversation grouping in the message list — design

## Goal

Messages of one Gmail thread that sit in the same folder are shown as a single
row in `MessageList`, like Gmail's conversation view. Triggering case: Inbox
showed `Fw: [EXTERNAL] Dispute` and `Re: [EXTERNAL] Dispute` as two rows
although both carry `threadId 1a10c368e4e08eab` (the same thread as the user's
own `Dispute` in Sent).

## Non-goals

- Changing how mail is fetched: no `threads.list`, no `threads.get` per row, no
  change to `fetchEmails`, `fetchMoreEmails`, `incrementalSync` or the
  SwiftData cache schema.
- Per-conversation unread counts. Sidebar counts and the dock badge keep
  counting messages; switching them is a separate task.
- Grouping in Drafts, the Outbox or `SearchOverlay` results.
- Batch Gmail API calls (`messages.batchModify`, `threads.modify`).
- Marking a message read when it arrives in a conversation that is already
  selected. It stays unread (row turns bold) until the conversation is
  selected again, the same as a new row today.
- A mark-unread action (none exists today).

## Design

### Model: `Conversation` (`Aerio/Models/Conversation.swift`)

`Aerio.xcodeproj/project.pbxproj` lists every file explicitly, so the new
`Aerio/Models/Conversation.swift` (Aerio target) and
`AerioTests/ConversationTests.swift` (AerioTests target) each get a file
reference, a group entry and a Sources build-phase entry.

```swift
struct Conversation: Identifiable, Equatable {
    let id: String          // "\(accountId)_\(folder.rawValue)_t_\(threadId)", or the member's Email.id when ungrouped
    let messages: [Email]   // non-empty, newest first
    var newest: Email { messages[0] }
    var count: Int { messages.count }
    var isUnread: Bool { messages.contains { !$0.isRead } }
    func contains(emailId: String) -> Bool

    static func group(_ emails: [Email]) -> [Conversation]
}
```

`group` is a pure function:

- Grouping key is `(accountId, folder, threadId)`. The same threadId in two
  accounts never merges.
- An email with an empty `threadId`, or in `.drafts`, forms its own
  conversation whose `id` is the email's `id`.
- Messages inside a conversation are sorted by date, newest first; equal dates
  are ordered by `msgId`.
- Conversations are sorted by `newest.date`, newest first; equal dates are
  ordered by conversation `id`. The output does not depend on input order
  (the unified input comes from unordered dictionary values).
- The input is the already filtered folder view (one folder, one account or
  all accounts); `group` does not filter.

### `UnifiedMailbox`

- New `@Published private(set) var conversations: [Conversation]`.
- `rebuildEmails` builds the final email array in a local variable on both
  paths (the full-sort branch that currently assigns and returns early, and the
  incremental merge), then assigns `emails` and
  `conversations = Conversation.group(final)` once, together. The "nothing
  changed" early return assigns neither.
- Grouping costs O(n log n) for n = messages in the current folder view (a few
  hundred), once per change of that view.
- New `conversations(for:accountId:)` mirroring `emails(for:accountId:)`
  (fast path returns the published array).
- `emails`, `unreadCounts`, `unreadCount`, `totalCount`, `hasMoreEmails` are
  unchanged.

### `MessageList` / `MessageRow`

- `ForEach(unifiedMailbox.conversations)`; row `.id(conversation.id)`.
- A row is selected when `conversation.contains(emailId: selectedEmailId)`.
- Tap selects `conversation.newest.id`. Tapping the row that is already
  selected does not change `selectedEmailId`, so the tap handler also calls
  `onReselect(conversation)`; `MainView` marks that conversation's unread
  members read (same helper as below). This covers an unread message that
  joined the selected conversation.
- `MessageRow` takes a `Conversation`: sender, subject, snippet and date of
  `newest`; sender/subject bold when `isUnread`; a small secondary-coloured
  count capsule after the sender when `count > 1`.
- Scrolling on selection change maps `selectedEmailId` to the id of the
  conversation containing it before `proxy.scrollTo`. Folder/account change
  scrolls to `conversations.first?.id`.
- Context menu items receive `conversation.newest` (the actions below expand
  it to the whole conversation).

### Selection state (`MainView`)

`selectedEmailId: String?` stays an `Email.id` (any member of the selected
conversation). Notification click, search jump and `pinnedEmailId` keep
selecting a specific message; the row containing it is highlighted and the
thread view scrolls to that message (see Detail panel).

New pure helpers, unit-tested, in `Conversation.swift` (extension on
`[Conversation]`):

- `conversation(containing emailId:) -> Conversation?`
- `adjacentSelection(from emailId: String?, offset: Int) -> String?` — returns
  the `newest.id` of the conversation `offset` rows away, clamped to the list;
  with no current selection (or one not in the list) returns `first?.newest.id`.
- `selectionAfterRemoving(conversationId:) -> String?` — `newest.id` of the next
  row, else the previous row, else nil.

`MainView` uses them:

- `currentConversations` = `unifiedMailbox.conversations(for: selectedFolder, accountId: selectedAccountId)`.
- `selectAdjacentEmail(offset:)` → `adjacentSelection`.
- `findEmail(by:)` stays over `currentEmails` (members are still emails).
- New `selectedConversation` = `currentConversations.conversation(containing: selectedEmailId)`.

### Actions on a conversation

`executeActionOnEmail(_ email:, action:)` resolves the conversation containing
`email` (falling back to a one-message conversation if not found), computes
`selectionAfterRemoving`, sets the selection, then in the existing `Task` calls
`apiManager.apply(action, to: conversation.messages)`.

`EmailAction` moves from `MainView` to `GmailAPIManager.swift` (same cases).
New `GmailAPIManager.apply(_ action: EmailAction, to emails: [Email]) async`
calls the existing per-message method (`archiveEmail`, `deleteEmail`,
`spamEmail`, `moveToInbox`) once per email, sequentially, continuing after a
failure and logging each error as `MainView` does today. Each call keeps its
own optimistic update and failure handling:

- a non-404 failure reverts that member alone; it reappears as a smaller row;
- an HTTP 404 from archive/delete/spam is treated as already gone (existing
  `performMove` behaviour): the member is dropped, not reverted, and no error
  surfaces.

All entry points (context menu, keyboard shortcuts, detail-panel buttons) go
through this path, so they all act on the whole conversation in the current
folder. Messages of the thread in other folders (e.g. the user's reply in Sent)
are not touched.

Reply / Reply All / Forward from the list, the context menu or the keyboard
target `selectedConversation.newest` (keyboard: `selectedEmailMsgId` becomes
`selectedConversation?.newest.msgId`) or the row's `newest` (context menu). Per-message reply buttons inside `ThreadDetailView`
are unchanged.

### Mark as read

A `MainView` helper `markConversationRead(_:)` calls the existing
`apiManager.markAsRead(emailId:accountId:)` for every unread member. It runs
from `onChange(of: selectedEmailId)` (for the conversation containing the new
id) and from `onReselect` (tap on the already-selected row). An already-read
conversation makes no calls.

### Detail panel

Replace the condition at `MainView.swift:382`:

```swift
!email.threadId.isEmpty && selectedFolder != .drafts &&
    (conversation.count > 1 || apiManager.threadHasMultipleMessages(email.threadId, accountId: email.accountId))
```

- The `subject.hasPrefix("Re:")` check is removed, so `Fw:`, `RE:`, `AW:` and
  unprefixed multi-message threads open in `ThreadDetailView`.
- "Thread has more than one message" means more than one message **loaded in
  memory** for that account (any folder). A reply whose earlier messages are
  not loaded (beyond the fetched pages, or trimmed from a closed folder) opens
  in `NativeMessageDetail`. No extra API call is made to find out.
- `email` passed to the detail views is `selectedConversation.newest` (falling
  back to `findEmail(by: selectedEmailId)`).
- Thread identity is account-qualified: `ThreadDetailView` is keyed
  `.id("\(email.accountId)_\(email.threadId)")`, its reload `onChange` watches
  the same key, and `threadHTMLCache` keys include `accountId`, so two accounts
  with the same threadId never share a mounted view or cached HTML.
- New `ThreadDetailView` parameter `focusMessageId: String?`: the selected
  email's `msgId` when it is not the newest member, else nil.
  `buildThreadHTML` gives every message section an `id="msg-<msgId>"` anchor;
  after the page loads, `ThreadDetailView` runs JS `scrollIntoView` on the
  focused anchor. A notification click or search jump to an older member opens
  the thread scrolled to that message.
- `threadHasMultipleMessages` gains an `accountId` parameter and counts
  **distinct `msgId`s** of that account with that threadId, so one message
  present in two folders no longer counts as two.

### `moveEmailInMemory` fix

`GmailAPIManager.moveEmailInMemory` rebuilds the moved `Email` without
`threadId`, `to` and `cc`, so an optimistically archived/moved message lands in
the target folder with `threadId == ""` and would not group there. It now
passes all three through.

## Error handling

- Per-member action failures: non-404 errors revert that member, which
  reappears as a smaller conversation; 404s drop the member (see Actions).
- A `selectedEmailId` whose email has disappeared (e.g. removed by sync):
  `selectedConversation` is nil and the detail panel shows its empty state, as
  today.
- Conversations with an empty `threadId` (old cache rows) degrade to one row
  per message.

## Testing

Unit tests (XCTest, run with `./scripts/test.sh`):

- `ConversationTests` (new, `AerioTests/ConversationTests.swift`):
  grouping of same-thread messages in one folder; same threadId in two
  accounts stays separate; empty threadId stays separate; Drafts never group;
  messages newest-first inside a conversation; conversations sorted by newest
  member; `isUnread` true when any member unread; `id` format;
  equal dates across accounts give the same order regardless of input order;
  `adjacentSelection` (down, up, clamp at both ends, no selection, moving down
  and up from a selected older member); `selectionAfterRemoving` (middle, last,
  only row); `conversation(containing:)` on an older member returns the
  conversation whose `newest` is the reply/forward target.
- `UnifiedMailboxTests`: `conversations` reflects the folder view, updates when
  a new message joins an existing thread (incremental path), when `isRead`
  changes, and after a folder switch that takes the full-sort path (no rows
  from the previous folder remain).
- `GmailAPIManagerTests`: archived message keeps `threadId` in Archive
  (`moveEmailInMemory`); `threadHasMultipleMessages` counts distinct msgIds per
  account; `apply(.archive, to:)` on a two-member Inbox conversation with the
  mock client archiving the first and failing the second with a non-404 error
  leaves the first in Archive and the second back in Inbox; the same with a
  404 on the second drops it from Inbox without revert.
- `ThreadHTMLTests`: `buildThreadHTML` emits one `msg-<msgId>` anchor per
  message.
- `MessageListTests`: existing ordering/filtering tests adapted to
  conversations; a row with two messages renders one row.

Manual check with `./scripts/run.sh`: the Dispute thread in Inbox shows one
row with count 2, opens in `ThreadDetailView` with the user's Sent original,
selecting it marks both read, archiving it removes the row and leaves the Sent
message in Sent. A search jump to the older `Fw:` message opens the thread
scrolled to it. With two accounts, switching between their conversations
always shows the selected account's thread content.

## Decisions

```
Решение (Jev): In which folders should the message list group messages into one row per Gmail thread (threadId)?
  A. All folders except Drafts     100%
  B. Inbox only                    0%
  C. All folders including Drafts  0%
  Рекомендация Claude: A
  Данных достаточно: 76%
  Выбрано: A, confidence 1.00, данных 0.76, порог 0.7 → принято автоматически
```
Mode: `auto`.

```
Решение (Jev): What does a grouped conversation row display in the message list?
  A. Newest message + count badge  99%
  B. Participants list + count     0%
  C. Oldest message + count badge  1%
  Рекомендация Claude: A
  Данных достаточно: 52%
  Выбрано: A, confidence 0.98, данных 0.52, порог 0.7 → принято автоматически
```
Mode: `auto`.

```
Решение (Jev): Which messages form a conversation row: only the current folder's loaded messages of a thread, or the whole Gmail thread fetched from the API?
  A. Folder-local grouping                96%
  B. Whole thread via threads.get         3%
  C. Switch folder fetch to threads.list  1%
  Рекомендация Claude: A
  Данных достаточно: 33%
  Выбрано: A, confidence 0.94, данных 0.33, порог 0.7 → принято автоматически
```
Mode: `auto`.

```
Решение (Jev): When should the detail panel show ThreadDetailView (all thread messages) instead of the single-message view?
  A. Whenever the thread has >1 message   100%
  B. Keep current 'Re:' heuristic         0%
  C. Only when the row's group count > 1  0%
  Рекомендация Claude: A
  Данных достаточно: 41%
  Выбрано: A, confidence 0.99, данных 0.41, порог 0.7 → принято автоматически
```
Mode: `auto`.

```
Решение (Jev): What do Archive / Delete / Spam / Move-to-Inbox act on when invoked on a grouped conversation row?
  A. All its messages in this folder  62%
  B. Only the newest message          37%
  C. Entire Gmail thread              1%
  Рекомендация Claude: A
  Данных достаточно: 78%
  Выбрано: A, confidence 0.42, данных 0.78, порог 0.7 → спросить пользователя
```
Mode: `user` — A.

```
Решение (Jev): When a grouped conversation row is selected, which messages get marked as read?
  A. All unread messages of the group  6%
  B. Only the newest message           94%
  Рекомендация Claude: A
  Данных достаточно: 79%
  Выбрано: B, confidence 0.87, данных 0.79, порог 0.7 → спросить пользователя (Jev ≠ рекомендация)
```
Mode: `user` — A.

```
Решение (Jev): How is the selected conversation row identified in state?
  A. Keep selectedEmailId, match any member  99%
  B. New conversation key                    1%
  Рекомендация Claude: A
  Данных достаточно: 64%
  Выбрано: A, confidence 0.97, данных 0.64, порог 0.7 → принято автоматически
```
Mode: `auto`.

```
Решение (Jev): How are actions and mark-read applied to the several messages of a conversation row at the API level?
  A. Loop existing per-message calls  67%
  B. Add messages.batchModify         33%
  Рекомендация Claude: A
  Данных достаточно: 46%
  Выбрано: A, confidence 0.34, данных 0.46, порог 0.7 → спросить пользователя
```
Mode: `user` — A (user delegated: "реши все уже за меня"; Claude's recommendation taken).

```
Решение (Jev): Should sidebar unread counts and the dock badge count unread messages (as now) or unread conversations?
  A. Keep counting messages  4%
  B. Count conversations     96%
  Рекомендация Claude: A
  Данных достаточно: 33%
  Выбрано: B, confidence 0.91, данных 0.33, порог 0.7 → спросить пользователя (Jev ≠ рекомендация)
```
Mode: `user` — A (user delegated; Claude's recommendation taken; per-conversation counts deferred to a separate task).

Approach (not judged; user delegated): a pure `Conversation.group` model
published by `UnifiedMailbox`, over grouping inside the view (would duplicate
the logic in `MainView` navigation) or storing conversations in
`GmailAPIManager` (would rework sync and cache).

## Spec review decisions (round 1)

Reviewer: codex-exec. Report: `docs/specs/2026-10-05-conversation-grouping-design.review.md`.

accepted without the judge: [P0] new files are not compiled unless registered — `Aerio.xcodeproj/project.pbxproj` lists every file explicitly (4 references to `UnifiedMailbox.swift`, no synchronized groups); Model section now requires pbxproj entries for both files.

```
Решение (Jev): How should the detail-panel predicate that only sees locally loaded thread members be fixed?
  A. Always ThreadDetailView for threaded mail        39%
  B. Fetch thread on selection when local count is 1  27%
  C. Define it as locally loaded messages             34%
  Рекомендация Claude: C
  Данных достаточно: 51%
  Выбрано: A, confidence 0.08, данных 0.51, порог 0.7 → спросить пользователя (Jev ≠ рекомендация)
```
Mode: `user` — C (user delegated all decisions: "реши все уже за меня"; Claude's recommendation taken). Supersedes the wording of the auto decision on thread view: "more than one message" means loaded in memory.

accepted without the judge: [P1] ThreadDetailView identity ignores accountId — `ThreadDetailView.swift:178` reloads on threadId only, `:253` cache key omits accountId, while the model separates accounts; view id, reload trigger and HTML cache key now include accountId.

```
Решение (Jev): How should a notification/search jump to an older member of a conversation be handled in the detail panel?
  A. Scroll thread view to the selected member  98%
  B. Show the thread from the top               2%
  Рекомендация Claude: A
  Данных достаточно: 46%
  Выбрано: A, confidence 0.97, данных 0.46, порог 0.7 → принято автоматически
```

accepted without the judge: [P1] tap on an already-selected row never fires `onChange(of: selectedEmailId)` (`MainView.swift:240-249`), so a newly joined unread member could not be marked read — added `onReselect` from the tap handler calling `markConversationRead`.

accepted without the judge: [P1] full-sort branch of `rebuildEmails` assigns and returns early (`UnifiedMailbox.swift:69-75`) — both paths now finish by assigning `emails` and `conversations` once from one final array; test for a folder switch on the full-sort path added.

accepted without the judge: [P1] no test proves whole-conversation action routing or partial failure — the loop moves into testable `GmailAPIManager.apply(_:to:)` (with `EmailAction` moved there), tested with the mock client for non-404 and 404 failures.

accepted without the judge: [P2] per-member revert claim ignores the 404 path (`GmailAPIManager.swift:750-765` drops on 404 without throwing) — Actions and Error handling now state the 404 exception; covered by the `apply` test.

accepted without the judge: [P2] tie order not deterministic (unordered dictionary input at `UnifiedMailbox.swift:42-46`) — secondary keys `msgId` (members) and conversation `id` (rows) added, with a test.

accepted without the judge: [P2] O(n) claim wrong with sorting — cost restated as O(n log n) over the current folder view.

```
Решение (Jev): How should the reviewer's scope concern (new files, separate published projection, detail-eligibility change) be resolved?
  A. Keep scope, register new files        35%
  B. Fold into existing files              39%
  C. Fold in and split detail eligibility  26%
  Рекомендация Claude: A
  Данных достаточно: 55%
  Выбрано: B, confidence 0.10, данных 0.55, порог 0.7 → спросить пользователя (Jev ≠ рекомендация)
```
Mode: `user` — A (user delegated; Claude's recommendation taken). Left as is: one published grouping shared by `MessageList` and `MainView` instead of regrouping per render in both, and the Re:-prefix removal stays because a grouped row with an `Fw:`/`RE:` newest member would otherwise open one message out of several.

accepted without the judge: [P2] tests miss reply target, navigation from an older member and account-qualified detail — added `conversation(containing:)` / `adjacentSelection` cases from an older member and a manual two-account check.
