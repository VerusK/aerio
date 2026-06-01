# Compose: From under To + auto-select last-used sender

**Date:** 2026-06-01
**Status:** Approved (design)
**Scope:** `ComposeView` layout + new-message sender auto-selection

## Problem

When composing a **new** email, the From account defaults to the first
account (or `preselectedAccountId`). If you regularly write to a given
recipient from a specific account, you have to fix From by hand every time.

Two changes:

1. Move the **From** field to sit directly under **To** (current order is
   From → To → Cc → Subject; new order is To → From → Cc → Subject).
2. When composing a new message, auto-select the From account to **exactly the
   account you last sent mail to that recipient from**.

## Decisions (from brainstorming)

| # | Question | Decision |
|---|----------|----------|
| 1 | Which compose modes? | **New message only.** Reply / Reply All / Forward / Draft keep current behavior (account inherited from source email). |
| 2 | Trigger timing | On recipient **commit** — autocomplete pick, comma typed, Enter, or To loses focus. No live re-eval while mid-typing. |
| 3 | Multiple recipients | Decide by the **first** recipient in To. |
| 4 | Data source | **Local cache first; network search fallback** when no local match. |
| 5 | Manual From change | **Manual wins.** Once the user picks From by hand, auto-fill is disabled for that window. |

Self-decided defaults (open to change at review):

- From sits **between To and Cc** (because "after To").
- Recipient is matched against both **To and Cc** of sent messages ("I wrote to
  this person, even if they were CC'd").

## Layout change

In `ComposeView.composeForm` move the From `HStack` (currently the first row,
~lines 95–108, including its trailing `Divider()`) to sit immediately after the
To row. Resulting order:

```
To:      [autocomplete field]
From:    [FromPickerView]
Cc:      [autocomplete field]
Subject: [field]
[toolbar]
[body]
```

Styling of the From row is unchanged (label width 50, `FromPickerView`,
`.fixedSize`, same paddings).

## Sender resolution

### Matching rule

- Take the **first** parsed address from To (via `ContactsCache.parseAddressList`).
  If there is no syntactically valid first address, do nothing.
- A sent message **matches** the recipient if the normalized recipient email
  (lowercased, trimmed) appears among the parsed addresses of the message's
  `to` **or** `cc`.
- Among matching **Sent** messages, the **most recent by date** wins; its
  `accountId` is the answer — **only if that account still exists**.
- No match anywhere → leave From untouched (current default stays).

### Local lookup (primary)

Query `EmailCache` for messages in the **Sent** folder across all accounts,
sorted by date descending, and return the first match's `accountId`.

### Network fallback (secondary, decision #4 = B)

If the local lookup returns nil, run a per-account Gmail search
`in:sent to:<recipient>` via `apiManager.searchEmailsWithTokens`. Results come
back merged and sorted by date descending; the newest matching result's
`accountId` is the answer. This is asynchronous and may apply a beat later.

## Trigger model (decision #2 = A)

`resolveFrom` is invoked on these "address committed" events for the To field:

- a contact is inserted via autocomplete (`insertContact` for `.to`),
- a comma is typed in To (comma count increased in `onChange`),
- Enter is pressed in To,
- focus leaves To (focused field changes away from `.to`).

`resolveFrom` logic:

1. If `fromAutoFillDisabled` → return.
2. Parse the first recipient email. If empty/invalid → set
   `lastResolvedRecipient = nil` and return (so re-typing the same address later
   re-resolves).
3. If recipient `== lastResolvedRecipient` → return (no redundant work / network).
4. Bump `resolveToken`; set `lastResolvedRecipient = recipient`.
5. Local: `apiManager.lastSenderAccountId(forRecipient:)`. If non-nil → set
   `selectedAccountId` and return.
6. Else fire the async network fallback (see race guard below).

## Manual override + async race safety (decisions #5, #4)

**Manual override.** `FromPickerView` gains an `onUserSelect` callback that fires
**only** from the NSPopUpButton target action (i.e. real user interaction).
Programmatic updates to the `selectedAccountId` binding (and the
`updateNSView` sync) do **not** fire it. On `onUserSelect`, set
`fromAutoFillDisabled = true`. After that, `resolveFrom` is a no-op for the
window's lifetime.

**Race guard.** The network fallback is async. Each `resolveFrom` call captures
the current `resolveToken`. When the network result returns, apply it **only if**
(a) `resolveToken` is unchanged (the recipient hasn't changed since) **and**
(b) `fromAutoFillDisabled` is still false. Otherwise discard the result.

Auto-fill never *reverts* From when a recipient is removed; it only sets it
forward on a valid first recipient.

## Architecture

### `LastSenderResolver` (new — pure, testable)

```
static func match(
    recipient: String,
    sentEmails: [Email],         // assumed sorted date desc
    existingAccountIds: Set<String>
) -> String?
```

Normalizes the recipient, walks `sentEmails`, returns the first message's
`accountId` whose `to`/`cc` contains the recipient and whose account still
exists. Holds no I/O — trivially unit-testable.

### `EmailCache` (extended)

```
func lastSentAccountId(toRecipient recipient: String,
                       existingAccountIds: Set<String>) -> String?
```

Fetches Sent-folder `CachedEmail`s (sorted date desc, bounded fetch limit),
maps to `Email`, delegates to `LastSenderResolver.match`. Testable on an
in-memory store (existing project pattern).

### `GmailAPIManager` (extended)

```
func lastSenderAccountId(forRecipient: String) -> String?            // local, via dataStore
func lastSenderAccountIdViaSearch(forRecipient: String) async -> String?  // network
```

The network variant calls `searchEmailsWithTokens(query: "in:sent to:<r>")`,
filters to Sent + recipient match, returns the newest match's `accountId`.

### `ComposeView` (wiring — kept thin)

New `@State`: `fromAutoFillDisabled = false`, `lastResolvedRecipient: String?`,
`resolveToken = 0`. New private `resolveFrom(...)`. Trigger hooks added to the To
field / `insertContact` / focus change. `FromPickerView` call site passes
`onUserSelect`.

## Testing

Unit tests:

- `LastSenderResolver.match`:
  - picks most-recent sent account among several,
  - matches recipient in `to`,
  - matches recipient in `cc`,
  - case-insensitive match,
  - ignores non-Sent messages,
  - returns nil when no match,
  - skips messages whose `accountId` is not in `existingAccountIds`.
- `EmailCache.lastSentAccountId`: seed two accounts' Sent folders with different
  dates → returns the newer account's id; returns nil when recipient unknown.

UI behavior (triggers, race guard, manual override) is exercised by **manual
QA** — the SwiftUI `@State` glue is deliberately thin so the logic under test
lives in the resolver/cache.

## Out of scope

- Reverting From when recipients are cleared.
- Per-recipient resolution beyond the first address.
- Reply/Forward/Draft account behavior (unchanged).
- Any persisted "preferred account per contact" store (we derive from Sent
  history, not a separate mapping).
