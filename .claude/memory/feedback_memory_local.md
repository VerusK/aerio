---
name: Keep memory local to project
description: User prefers memory files stored in the project's .claude/memory/ directory, not in the global ~/.claude/projects/ path
type: feedback
---

Keep memory files in the project's local `.claude/memory/` directory, not in the global `~/.claude/projects/` path.

**Why:** User explicitly requested local project memory — easier to manage and version alongside the project.
**How to apply:** Always use `/Users/sleepwalker/Projects/agapp/.claude/memory/` for this project's memory files.
