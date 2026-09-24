# Review: VerusK/freezing vs 1725850366b6473ed232a6b834c20e4f685837bb
## Verdict
NOT READY — cache clearing can delete another app's database, and the memory cap misses folder transitions; the local test run was blocked by the sandbox.
## Findings (confidence 7+)
[P1] (confidence: 10/10) Aerio/Views/SettingsView.swift:240 — Clear Cache still deletes `Application Support/default.store*`, which this change identifies as a shared store that another app may now own; it leaves Aerio's new `EmailCache.store` untouched — remove the shared-store deletion and clear only Aerio's cache through its own store or context.
[P1] (confidence: 9/10) Aerio/Services/GmailAPIManager.swift:288 — Switching from a paginated folder to one whose fetched first page equals its cached rows skips `boundedEmails`, leaving the previously open folder's full history in memory indefinitely when history has no changes; an empty fetch also returns before bounding — apply the cap when `currentFolder` changes even if the fetched rows are unchanged or empty.
[P2] (confidence: 8/10) Aerio/Services/GmailAPIManager.swift:546 — A `fetchMoreEmails` request started in one folder can finish after navigation and append another page to that now-closed folder without bounding it; later no-change syncs never trim it — bound at this publication point using the current open folder.
## Appendix (confidence below 7)
None
## Plan alignment notes
No plan given
## Ledger triage
None
<!-- end of review -->
