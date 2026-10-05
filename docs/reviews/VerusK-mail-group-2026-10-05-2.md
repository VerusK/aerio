# Review: VerusK/mail-group vs 56c33d3c3f620f8ad3aaae5ac4fe410fea3131e3
## Verdict
NOT READY — a failed compensating re-trash can still leave a conversation member in the wrong local folder, and the required GUI checks remain outstanding.
## Findings (confidence 7+)
[P1] (confidence: 10/10) Aerio/Services/GmailAPIManager.swift:880 — After `untrashMessage` succeeds and the Inbox update fails, a failed compensating `trashMessage` is only logged; line 884 still restores the local Trash copy although the server no longer has TRASH. A 403 or network failure can affect both calls, and the new test only covers successful compensation — when compensation fails, keep the member out of Trash until its server labels are reconciled or retry compensation, and test that failure path.
## Appendix (confidence below 7)
[P2] (confidence: 6/10) Aerio/Views/MainView.swift:256 — A search or notification jump across folders sets `selectedEmailId` while the folder is updated by a separate `sidebarSelection` observer; if the selection observer runs first, it marks only the jumped-to email read and never revisits the other unread conversation members — resolve the target conversation from the email's destination folder during navigation, and verify an older-member jump across folders marks the whole row read.
## Plan alignment notes
The prior Trash finding is resolved when the compensating request succeeds; its failure path above remains unresolved. Grouping and action routing otherwise match the plan. `./scripts/test.sh` was attempted with temporary DerivedData but Xcode's Swift macro server was blocked by sandboxing before tests ran. The planned `run.sh` and manual GUI checklist, including first-open focus, remain pending.
## Ledger triage
- T3 self test count and `okResponse`: OK — top-level action and nonisolated helper are present.
- T4 self test count: OK — the manager force-refresh case is the fifth test.
- Ruling 1, `okResponse` isolation: OK — declared `nonisolated`.
- Ruling 2, expected test total: OK — counting error has no runtime effect.
- Ruling, ignored plan/review files: OK — local plan remains available.
- Ruling, Debug app cleanup: OK — no repository source is affected.
- Task 1, absolute tie-order assertion: OK — comparator defines the order despite a weaker test.
- Task 1, internal empty `Conversation` initializer: OK — production grouping constructs nonempty buckets.
- Task 1, lone ID/thread key collision: OK — Gmail message IDs are hexadecimal.
- Task 2, slow-path grouping test: OK — it delegates to the tested grouping helper.
- Task 2, incremental member-removal test: OK — rebuild derives groups from the final email array.
- Task 2, two published writes: OK — list and selection consume `conversations`.
- Ruling, replacement concurrency test: OK — the session-level observer checks the cap.
- Ruling, log-only action errors: OK — matches the recorded spec behavior.
- Task 3, revert after account removal: OK — limited to account deletion during an active action.
- Task 3, missing no-client/404/unread-revert tests: OK — edge coverage gap separate from the compensation failure above.
- Task 3, unreachable Spam switch branch: OK — `moveToInbox` returns before the switch.
- Task 3, stale gauge comment: OK — test-only documentation.
- Task 3, uncapped mark-read requests: OK — explicit plan choice.
- Task 4, identical HTML reload resets scroll: OK — visual disruption on member changes, without data loss.
- Task 4, anchor/focus ID normalization: OK — Gmail message IDs are hexadecimal.
- Task 4, cache and load-sequence test gaps: OK — source paths are wired, though integration coverage is limited.
- Task 4, first-open focus timing: BLOCKS MERGE — verify the core older-member jump in the manual GUI check.
- Ruling, Task 5 GUI checklist deferred: BLOCKS MERGE — run it before merging, including each action entry point.
- Ruling, final test total: OK — arithmetic correction does not change the tests.
- Task 5, repeated conversation/email lookups: OK — bounded view computation.
- Task 5, row interaction tests: OK — selection, reselect and scroll remain in the pending GUI checklist.
- Task 5, edge navigation resets older-member focus: OK — documented edge behavior.
- Task 5, focus after a new reply: OK — matches the spec; confirm in the pending GUI check.
<!-- end of review -->
