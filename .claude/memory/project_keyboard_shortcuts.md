---
name: Keyboard shortcut design decisions
description: Hotkey mappings were carefully chosen to avoid system conflicts and work on both EN/RU layouts
type: project
---

Keyboard shortcuts were redesigned in Stage 1 to avoid conflicts with system menu bindings and work on both EN and RU keyboard layouts.

**Key decisions:**
- Reply All = Cmd+R (took over from system Reload which isn't needed)
- Reply = Cmd+Shift+R
- Forward = Cmd+T
- Delete = Cmd+D
- Spam = Cmd+Shift+1
- Search = Cmd+Shift+F (opens Spotlight-style SearchOverlay)
- Archive = Cmd+E (unchanged)
- Compose = Cmd+N (unchanged)

**Layout independence:** `KeyEventInterceptor` (NSViewRepresentable) intercepts key events BEFORE system menu processing using `performKeyEquivalent`. Uses `charactersIgnoringModifiers` so shortcuts work regardless of active keyboard layout (EN/RU).

**Why these specific keys:** Chosen to avoid clashing with standard macOS menu shortcuts (Cmd+R=Refresh, Cmd+F=Find, etc.) while remaining ergonomic.
**How to apply:** When adding new shortcuts, always check against macOS system shortcuts and test on both EN and RU layouts.
