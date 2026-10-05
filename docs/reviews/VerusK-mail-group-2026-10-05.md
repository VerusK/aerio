# Review: VerusK/mail-group vs 56c33d3c3f620f8ad3aaae5ac4fe410fea3131e3
## Verdict
NOT READY — moving a conversation out of Trash can leave failed members in the wrong local folder, and the required GUI checks remain outstanding.
## Findings (confidence 7+)
[P1] (confidence: 10/10) Aerio/Services/GmailAPIManager.swift:857 — Move to Inbox makes two server changes for each Trash member; if `untrashMessage` succeeds and the subsequent `modifyMessage` fails, line 873 restores the local Trash copy although the server already removed TRASH, so that member appears in the wrong folder and retry can fail — compensate by trashing it again or fetch its server state before reverting, and test failure of the second request.
## Appendix (confidence below 7)
[P2] (confidence: 6/10) Aerio/Views/MainView.swift:256 — A search or notification jump to another folder changes `selectedEmailId` before the `sidebarSelection` observer updates `UnifiedMailbox.selectedFolder`; if the selection observer runs first, it falls back to marking only the target email read, and no later selection change marks the other unread members — resolve the target conversation against the email's folder during navigation, and verify an older-member jump across folders marks the whole row read.
## Plan alignment notes
The grouping, action routing, and detail wiring largely follow the plan. The Trash failure above is a plan-level defect in the specified per-member revert behavior. `./scripts/test.sh` compiled the changed sources with temporary DerivedData but Xcode aborted before tests ran because sandboxing blocked distributed notifications; the required `run.sh` and manual GUI checklist are also still pending.
## Ledger triage
- T3 self test count and `okResponse`: OK — the implementation uses a top-level action and nonisolated pure response helper.
- T4 self test count: OK — the fifth test is the manager force-refresh case.
- Ruling 1, `okResponse` isolation: OK — declared `nonisolated`.
- Ruling 2, expected test total: OK — counting error has no runtime effect.
- Ruling, ignored plan/review files: OK — local plan remains available for this review.
- Ruling, Debug app cleanup: OK — no repository source is affected.
- Task 1, absolute tie-order assertion: OK — comparator defines the order; test is weaker than it could be.
- Task 1, internal empty `Conversation` initializer: OK — production grouping constructs nonempty buckets.
- Task 1, lone ID/thread key collision: OK — Gmail message IDs are hexadecimal.
- Task 2, slow-path grouping test: OK — it delegates to the tested grouping helper.
- Task 2, incremental member-removal test: OK — rebuild derives groups from the final email array.
- Task 2, two published writes: OK — list and selection consume `conversations`.
- Ruling, replacement concurrency test: OK — the session-level observer checks the cap.
- Ruling, log-only action errors: OK — matches the recorded spec behavior.
- Task 3, revert after account removal: OK — limited to account deletion during an active action.
- Task 3, missing no-client/404/unread-revert tests: OK — edge coverage gap; the Trash second-request failure is the blocking case reported above.
- Task 3, unreachable Spam switch branch: OK — `moveToInbox` returns before the switch.
- Task 3, stale gauge comment: OK — test-only documentation.
- Task 3, uncapped mark-read requests: OK — explicit plan choice.
- Task 4, identical HTML reload resets scroll: OK — visual disruption on member changes, not data loss.
- Task 4, anchor/focus ID normalization: OK — Gmail message IDs are hexadecimal.
- Task 4, cache and load-sequence test gaps: OK — source paths are wired, but integration coverage is limited.
- Task 4, first-open focus timing: BLOCKS MERGE — manual first-open jump check must verify the core older-member focus path.
- Ruling, Task 5 GUI checklist deferred: BLOCKS MERGE — execute it before merging, including each action entry point.
- Ruling, final test total: OK — arithmetic correction does not change the tests.
- Task 5, repeated conversation/email lookups: OK — bounded view computation.
- Task 5, row interaction tests: OK — manual selection/reselect/scroll checks are in the pending GUI checklist.
- Task 5, edge navigation resets older-member focus: OK — documented edge behavior.
- Task 5, focus after a new reply: OK — matches the spec; confirm in the pending GUI check.
<!-- end of review -->
