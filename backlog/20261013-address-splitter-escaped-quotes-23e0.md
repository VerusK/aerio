---
type: backlog
id: 20261013-address-splitter-escaped-quotes-23e0
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
updated: 2026-10-13T02:22:21Z
---
# Address splitter: escaped quotes

ContactsCache.splitAddressList toggles its quote state on every ", including an escaped quote (quoted-pair), so an address like "a\"b,c"@example.com is split at the comma. Found in review round 2 of the mailto branch (P2, docs/reviews/VerusK-mailto-links-2026-10-13-2.md). Rare in practice; affects mailto links and compose address parsing alike.

## Acceptance criteria

- splitAddressList treats \" inside a quoted string as a literal quote
- mailto:%22a%5C%22b%2Cc%22@example.com yields one To address
