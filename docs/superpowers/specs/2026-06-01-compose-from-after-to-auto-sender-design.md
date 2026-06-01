# Compose: From under To + auto-select last-used sender

**Date:** 2026-06-01
**Status:** Approved + eng-reviewed + outside-voice (locked, rev 2)
**Scope:** `ComposeView` layout + new-message sender auto-selection via a durable
recipient→account map, with network fallback.

## Problem

When composing a **new** email, the From account defaults to the first account
(or `preselectedAccountId`). If you regularly write to a given recipient from a
specific account, you must fix From by hand every time.

Two changes:
1. Move **From** to sit directly under **To** (To → From → Cc → Subject).
2. In a new message, auto-select From to **exactly the account you last sent
   mail to that recipient from**.

## Approach (rev 2 — after Codex outside voice)

The first design reconstructed the answer from the Sent folder on every lookup
(cache scan + network + a startup warm-up). Codex flagged that as over-built for
the payoff. **Chosen approach (hybrid):**

- **Primary — durable map.** Persist a `recipientEmail → accountId` map. **Write
  it at send time** for every To/Cc recipient. Lookup is an O(1), synchronous,
  local, race-free read. This captures the real action ("I wrote to X from Y"),
  including when the user manually overrode From.
- **Fallback — network.** On a cold miss (recipient not yet in the map), search
  Gmail `in:sent {to:r cc:r}` per account and take the newest match. Async.
- **Dropped:** startup Sent warm-up, per-lookup Sent-cache scan,
  `LastSenderResolver`, `EmailCache.lastSentAccountId`.

## Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Which compose modes? | **New message only.** Reply / Reply All / Forward / Draft unchanged. |
| 2 | Trigger timing | On recipient **commit** — autocomplete pick, comma typed, Enter, or To loses focus. |
| 3 | Multiple recipients | Decide by the **first** recipient in To. |
| 4 | Data source | **Durable map first; network search fallback** on a cold miss. |
| 5 | Manual From change | **Manual wins.** Manual pick disables auto-fill for that window (and is recorded on send). |
| Q1 | Async apply guard | Apply network result only if token unchanged AND first recipient still == searched AND not disabled AND **account still exists**. |
| Q2 | Address match | **lowercase + trim, exact** email compare. No gmail dot/plus normalization. |
| #2 | Parser | Use the **quote-aware** splitter (extracted from ComposeView.swift:676), NOT the naive comma split. |
| #5 | Network query | `in:sent {to:r cc:r}` — honors the to-OR-cc matching rule. |
| Cross-model #9 | Architecture | **Hybrid (option C):** durable send-time map + network fallback; drop warm-up + cache scan. |

## Layout change
Move the From `HStack` (currently first row, ~lines 95–108 in `ComposeView.swift`,
incl. its trailing `Divider()`) to sit immediately after the To row. Order:
To → From → Cc → Subject → toolbar → body. From-row styling unchanged.

## Data flow

```
RECORD (on every send) ─ sendMessage() at ComposeView.swift:782
──────────────────────────────────────────────────────────────
 build OutboxItem (selectedAccountId, toField, ccField)
        │
        ▼
 for each addr in split(toField) + split(ccField):     [quote-aware splitter]
     email = ContactsCache.parseFromHeader(addr).email.lowercased().trimmed
     SentAccountMap.record(email, accountId: selectedAccountId)
   (learns from manual From overrides too)

RESOLVE (new compose, on 1st-recipient commit)
──────────────────────────────────────────────
 commit event (autocomplete pick / "," / Enter / blur To)
        │
        ▼
 resolveFrom()                         [only when composeType == .new]
        │  fromAutoFillDisabled? ──yes──► return (manual wins)
        ▼
   r = split(toField).first → parseFromHeader → email.lowercased().trimmed
        │  invalid/empty ──► lastResolvedRecipient = nil; return
        │  == lastResolvedRecipient ──► return (dedup)
        ▼
   PRIMARY (sync): SentAccountMap.accountId(forRecipient: r)
        │   hit AND account still exists ──► selectedAccountId = acct ; return
        │ miss
        ▼
   resolveToken += 1 ; lastResolvedRecipient = r
        ▼
   FALLBACK (async): apiManager.lastSenderAccountIdViaSearch(r)
        │   searchEmailsWithTokens("in:sent {to:r cc:r}") → newest .first
        ▼
   on result: token unchanged AND !disabled AND first recipient still == r
              AND account still exists?
        ├─ yes ──► selectedAccountId = acct
        └─ no  ──► discard
```

## Components

### `SentAccountMap` (new — Aerio/Services)
UserDefaults-backed (key `aerio_sent_account_map`), modeled on `ContactsCache`.
```
func record(recipient: String, accountId: String)         // normalizes, upserts (last wins)
func recordRecipients(to: String, cc: String, accountId: String)  // splits + records; testable
func accountId(forRecipient r: String) -> String?         // normalized exact lookup
```
- Normalization: lowercase + trim (Q2). Storage value carries a timestamp so the
  map can **cap** at ~2000 entries, evicting oldest. Last write wins (a newer
  send to the same recipient updates the account).
- `recordRecipients` uses the shared quote-aware splitter, so the send hook is
  unit-testable without the SwiftUI view.

### Shared address splitter (refactor — Beck "make the change easy first")
Extract the RFC-5322-aware comma splitter at `ComposeView.swift:676`
(`parseAddressList`) into a shared static (e.g. `ContactsCache.splitAddressList`)
and reuse it in: ComposeView trigger/first-recipient logic AND
`SentAccountMap.recordRecipients`. Removes duplication; fixes Codex #2.

### `GmailAPIManager` (extended)
```
func lastSenderAccountIdViaSearch(forRecipient r: String) async -> String?
```
`searchEmailsWithTokens(query: "in:sent {to:\(r) cc:\(r)}")`; results merged +
date-desc; return newest match's `accountId`. No local-cache method, no warm-up.

### `ComposeView` (wiring)
New `@State`: `fromAutoFillDisabled = false`, `lastResolvedRecipient: String?`,
`resolveToken = 0`. New `resolveFrom()`. Build commit triggers (none exist yet —
Codex #1): autocomplete pick (`insertContact` for `.to`), comma typed (detect via
splitter count delta), Return in To, focus leaves To. Record hook in
`sendMessage()`. `FromPickerView` passes `onUserSelect`.

### `FromPickerView` (extended)
Add `onUserSelect` callback fired **only** from `Coordinator.selectionChanged`
(the NSPopUpButton action, :1414). Programmatic `selectItem(at:)` in `updateItems`
(:1405) does NOT fire it. On callback → `fromAutoFillDisabled = true`.

## Manual override + race safety
- Manual override: `onUserSelect` → `fromAutoFillDisabled = true`; `resolveFrom`
  becomes a no-op for the window's life. With From under To, tabbing out of To
  runs the (synchronous) map lookup before focus lands on From, so From is
  already set when the user reaches it; an actual pick still overrides. (Codex #3
  acknowledged; accepted.)
- Race guard (network path only — map path is sync): each `resolveFrom` captures
  `resolveToken`. Apply the async result only if token unchanged AND
  `!fromAutoFillDisabled` AND current first recipient still == searched r AND the
  returned account still exists (Codex #4). Else discard. Auto-fill never reverts
  From when a recipient is removed.

## Test plan

```
CODE PATHS                                          USER FLOWS / REGRESSIONS
[+] SentAccountMap                                   [+] New compose [manual QA]
  ├── record→lookup round-trip       → unit           ├── known recipient → From switches
  ├── lowercase+trim normalize       → unit           ├── manual From pick → stays; recorded on send
  ├── last-write-wins (newer send)   → unit           └── no match → From = default
  ├── unknown recipient → nil        → unit
  └── cap/eviction at limit          → unit         [+] REGRESSION guard (CRITICAL) [manual QA]
[+] recordRecipients(to:cc:acct:)                      └── reply/replyAll/forward/draft:
  ├── records To + Cc                → unit               From NOT overridden (composeType == .new)
  └── quoted-comma name safe (#2)    → unit
[+] GmailAPIManager.lastSenderAccountIdViaSearch()   [+] Async race [manual QA]
  └── newest "in:sent {to cc}" + acct-exists → [→mock]   └── token + recipient + acct-exists (Q1/#4)
       URLProtocol harness (SearchOverlayTests-style)
[+] ComposeView.resolveFrom (glue)                   [+] Record-on-send [via recordRecipients unit]
  └── manual QA (triggers, dedup, guard)                 └── send → map has recipient→account
```
Test files: new `AerioTests/SentAccountMapTests.swift`; extend
`GmailAPIManagerTests.swift` (network method via URLProtocol mock); shared-splitter
unit covered via `recordRecipients` + any existing ContactsCache tests.

## Failure modes

| Codepath | Failure | Test | Handling | User sees |
|---|---|---|---|---|
| `resolveFrom` in reply/forward (regression) | guard slips, overrides inherited acct | manual-QA (CRITICAL) | `composeType == .new` guard | wrong From — catch in QA |
| record-on-send | record throws / map full | unit (cap) | best-effort, cap evicts | next compose uses network/default |
| network fallback | stale/wrong/removed acct, races recipient change | unit (method) + guard | token+recipient+acct-exists | benign discard |
| quoted-comma name | `"Doe, Jane" <j@x>` mis-split | unit (#2) | shared quote-aware splitter | correct recipient |
| offline cold miss | no map entry, no network | n/a | leave default From | default From (correct) |

**0 critical gaps** — regression guarded in code + flagged for QA.

## NOT in scope
- Seeding the map from Sent history / sync backfill (Codex optional) — deferred;
  network fallback covers cold misses. Revisit if cold-miss latency annoys.
- Startup Sent warm-up (dropped in favor of the map).
- Reverting From when recipients are cleared.
- Per-recipient resolution beyond the first address.
- Reply/Forward/Draft account behavior (unchanged).
- Gmail dot/plus normalization (Q2 = exact).

## What already exists (reused, not rebuilt)
- Quote-aware splitter `parseAddressList` (ComposeView.swift:676) — extract + share.
- `ContactsCache.parseFromHeader` — address → email (ComposeView.swift:285).
- `GmailAPIManager.searchEmailsWithTokens` — network search (:842).
- `FromPickerView` (:1374) — add `onUserSelect` only.
- `sendMessage()` (:782) — record hook site (has selectedAccountId + to/cc).
- ContactsCache UserDefaults pattern (`aerio_contacts_cache`) — model for the map.
- URLProtocol mock harness — `GmailAPIManagerTests` / `SearchOverlayTests`.

## Parallelization
- Lane R (do first): extract shared quote-aware splitter (refactor before behavior).
- Lane A: `SentAccountMap` + tests (depends on R for the splitter).
- Lane B: `GmailAPIManager.lastSenderAccountIdViaSearch` + URLProtocol test (independent).
- Lane C: `ComposeView` layout + resolveFrom + record hook + `FromPickerView.onUserSelect`
  (depends on R, A, B).
Single module (Aerio); recommend sequential R → (A ∥ B) → C.

## Implementation Tasks
- [ ] **T1 (P1, human ~20m / CC ~5m)** — extract quote-aware splitter to a shared static; reuse in ComposeView (refactor first, Codex #2).
- [ ] **T2 (P1, human ~30m / CC ~5m)** — ComposeView — move From row under To (To→From→Cc→Subject).
- [ ] **T3 (P1, human ~2h / CC ~15m)** — SentAccountMap (new) — record / recordRecipients / accountId / normalize / cap + full unit tests.
- [ ] **T4 (P1, human ~45m / CC ~10m)** — ComposeView — record-on-send hook in `sendMessage()` (To+Cc → SentAccountMap via recordRecipients).
- [ ] **T5 (P1, human ~2h / CC ~15m)** — GmailAPIManager — `lastSenderAccountIdViaSearch` (`in:sent {to cc}`) + URLProtocol-mock test + account-existence (#4, #5).
- [ ] **T6 (P1, human ~3h / CC ~20m)** — ComposeView — `resolveFrom` + commit triggers (build them, Codex #1) + `@State` + race guard; `.new`-only regression guard.
- [ ] **T7 (P1, human ~1h / CC ~10m)** — FromPickerView — `onUserSelect` from popup action only → `fromAutoFillDisabled`.
- [ ] **T8 (P2, human ~30m / CC ~5m)** — Manual QA: known-recipient switch, manual override stays + records, reply/forward/draft unchanged, cold miss → default.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 9 findings; 4 actioned, 4 noted, 1 architecture pivot |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | clean | 10 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CODEX:** raised 9 findings. Adopted: #9 (architecture → durable map + fallback, dropping warm-up/cache-scan), #2 (quote-aware parser), #4 (account-existence at apply), #5 (`to`+`cc` in network query). Noted/accepted: #1 (triggers must be built — folded into T6), #3 (blur-before-From override — accepted), #6 (warm-up "covers 1st compose" — moot, warm-up dropped), #7 (warm-cache drift — moot, warm-up dropped).
- **CROSS-MODEL:** one tension (architecture). Review locked Sent-folder reconstruction; Codex argued it was over-built. Resolved by user → **option C (hybrid)**: send-time durable map primary, network fallback for cold misses.
- **UNRESOLVED:** 0.
- **VERDICT:** ENG CLEARED — ready to implement.
