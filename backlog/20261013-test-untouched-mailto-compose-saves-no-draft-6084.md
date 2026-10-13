---
type: backlog
id: 20261013-test-untouched-mailto-compose-saves-no-draft-6084
department: development
status: proposed
take: owner
priority: normal
author: Roman Dubina (@VerusK) · MacBook-Pro · Claude app, team member
date: 2026-10-13
task: 
after: 
goal: 
epic: mailto / default email app
rank: 
found_in: 
updated: 2026-10-13T02:22:26Z
---
# Test: untouched mailto compose saves no draft

The no-draft guarantee for mailto compose is only tested via ComposeSeed.marksDirty; the real path (ComposeView setup, deferred onChange from the rich-text editor, onDisappear → saveDraftIfNeeded) is untested, so a deferred state update could mark an untouched compose dirty unnoticed. Mount a seeded ComposeView with a fake draft API, close it, assert no saveDraft call. Review round 2 appendix.

## Acceptance criteria

- A test mounts ComposeView with a mailto seed, closes it untouched and asserts saveDraft was not called
- The same test with one edit asserts saveDraft was called
