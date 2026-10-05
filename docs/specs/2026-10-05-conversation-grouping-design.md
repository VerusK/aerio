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
- Messages inside a conversation are sorted by date, newest first.
- Conversations are sorted by `newest.date`, newest first; ties keep the input
  order (stable), so the output is deterministic.
- The input is the already filtered folder view (one folder, one account or
  all accounts); `group` does not filter.

### `UnifiedMailbox`

- New `@Published private(set) var conversations: [Conversation]`, recomputed
  from `emails` at the end of every `rebuildEmails` that changes `emails`.
  The existing incremental merge of `emails` stays as is; grouping is O(n) over
  a folder view of a few hundred messages.
- New `conversations(for:accountId:)` mirroring `emails(for:accountId:)`
  (fast path returns the published array).
- `emails`, `unreadCounts`, `unreadCount`, `totalCount`, `hasMoreEmails` are
  unchanged.

### `MessageList` / `MessageRow`

- `ForEach(unifiedMailbox.conversations)`; row `.id(conversation.id)`.
- A row is selected when `conversation.contains(emailId: selectedEmailId)`.
- Tap selects `conversation.newest.id`.
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
working unchanged: they select a specific message, and the row containing it is
highlighted.

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
the existing per-message manager method (`archiveEmail`, `deleteEmail`,
`spamEmail`, `moveToInbox`) once per member, sequentially. Each call keeps its
own optimistic update, revert and 404 handling; a member whose call fails is
reverted alone and reappears as a smaller row. Errors are logged per member as
today.

All entry points (context menu, keyboard shortcuts, detail-panel buttons) go
through this path, so they all act on the whole conversation in the current
folder. Messages of the thread in other folders (e.g. the user's reply in Sent)
are not touched.

Reply / Reply All / Forward from the list, the context menu or the keyboard
target `selectedConversation.newest` (for the keyboard path) or the row's
`newest` (context menu). Per-message reply buttons inside `ThreadDetailView`
are unchanged.

### Mark as read

`onChange(of: selectedEmailId)`: for the conversation containing the new id,
call the existing `apiManager.markAsRead(emailId:accountId:)` for every unread
member. Selecting an already-read conversation makes no calls.

### Detail panel

Replace the condition at `MainView.swift:382`:

```swift
!email.threadId.isEmpty && selectedFolder != .drafts &&
    (conversation.count > 1 || apiManager.threadHasMultipleMessages(email.threadId, accountId: email.accountId))
```

- The `subject.hasPrefix("Re:")` check is removed, so `Fw:`, `RE:`, `AW:` and
  unprefixed multi-message threads open in `ThreadDetailView`.
- `email` passed to the detail views is `selectedConversation.newest` (falling
  back to `findEmail(by: selectedEmailId)`), so `ThreadDetailView`'s
  `.id(email.threadId)` stays stable across members.
- `threadHasMultipleMessages` gains an `accountId` parameter and counts
  **distinct `msgId`s** of that account with that threadId, so one message
  present in two folders no longer counts as two.

### `moveEmailInMemory` fix

`GmailAPIManager.moveEmailInMemory` rebuilds the moved `Email` without
`threadId`, `to` and `cc`, so an optimistically archived/moved message lands in
the target folder with `threadId == ""` and would not group there. It now
passes all three through.

## Error handling

- Per-member action failures: existing per-message revert; the conversation
  reappears with the members that failed.
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
  `adjacentSelection` (down, up, clamp at both ends, no selection, selection on
  an older member); `selectionAfterRemoving` (middle, last, only row).
- `UnifiedMailboxTests`: `conversations` reflects the folder view, updates when
  a new message joins an existing thread, and when `isRead` changes.
- `GmailAPIManagerTests`: archived message keeps `threadId` in Archive
  (`moveEmailInMemory`); `threadHasMultipleMessages` counts distinct msgIds per
  account.
- `MessageListTests`: existing ordering/filtering tests adapted to
  conversations; a row with two messages renders one row.

Manual check with `./scripts/run.sh`: the Dispute thread in Inbox shows one
row with count 2, opens in `ThreadDetailView` with the user's Sent original,
selecting it marks both read, archiving it removes the row and leaves the Sent
message in Sent.

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
