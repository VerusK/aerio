---
name: project_messagelist_lazyvstack
description: MessageList migrated from List to ScrollView+LazyVStack (2026-08-06) — macOS List dropped inserted rows in long sessions; .id() hacks all failed
type: project
---

MessageList (Aerio/Views/MessageList.swift) uses `ScrollView` + `LazyVStack`, NOT `List`.

**Why:** macOS `List` (NSTableView bridge) intermittently failed to display newly
inserted rows in long-running sessions — new mail was in `unifiedMailbox.emails`
(counters correct) but invisible until the user forced a relayout (expand/collapse
a sidebar folder). Three `.id()`-keyed List-recreation workarounds all failed:
count-keyed froze every poll/archive; `first?.id`-keyed missed non-top inserts
(2bd1eca); count+first.id was reverted (74b08e2, scroll reset on every
archive/delete and infinite-scroll page load).

**Key evidence (2026-08-06):** the bug does NOT reproduce in a freshly launched
app — synthetic-mail injection into `apiManager.emailsByAccount` (env-gated
driver, isolated HOME) showed the full pipeline correct: rebuildEmails inserts at
right indices, MessageList body re-evaluates, NSTableView row count/docHeight
track data, even occluded/scrolled/mid-list. The trigger is accumulated
long-session state in the AppKit bridge (sleep/wake, App Nap, repeated List
recreation). LazyVStack removes the AppKit row cache entirely, so the bug class
is gone; it also removed the scroll-reset-on-new-mail wart from the `.id()` hack.

**How to apply:** don't reintroduce `List` for the message list; if another
AppKit-bridge staleness bug appears, prefer replacing the bridge with
SwiftUI-native layout over `.id()` identity hacks. Repro/diagnosis technique:
temporary `AERIO_SYNTH=1` driver appended to AerioApp.swift injecting fake mail
into `emailsByAccount` + NSLog dumps comparing data count vs NSTableView rows,
run with `HOME=/tmp/... AERIO_SYNTH=1` from a local DerivedData build.
Related: [[feedback_list_selection]], [[feedback_list_scroll]].
