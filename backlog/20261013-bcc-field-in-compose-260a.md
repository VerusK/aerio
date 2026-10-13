---
type: backlog
id: 20261013-bcc-field-in-compose-260a
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
updated: 2026-10-13T02:22:17Z
---
# Bcc field in compose

Compose has no Bcc field anywhere (ComposeView, RFC2822Builder, OutboxItem, saveDraft). Because of that, mailto: links currently drop their bcc= addresses (MailtoURL logs and ignores them; decision from the v1.9.0 mailto work). Add a Bcc field end to end, then let MailtoURL fill it from bcc=.

## Acceptance criteria

- Compose shows a Bcc field; Bcc recipients receive the message and are absent from the sent headers seen by To/Cc
- Outbox and Gmail drafts keep Bcc
- mailto:?bcc=x@y.com fills the Bcc field
