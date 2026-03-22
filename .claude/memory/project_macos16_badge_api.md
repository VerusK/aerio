---
name: macOS 16 badge API change
description: NSApp.dockTile.badgeLabel is silently ignored on macOS 16 (Darwin 25.x) — must use UNUserNotificationCenter.setBadgeCount() instead
type: project
---

On macOS 16 (Darwin 25.3.0), `NSApp.dockTile.badgeLabel` is silently ignored — the value is set but the dock badge never appears visually.

**Why:** Apple deprecated `badgeLabel` in favor of the UNUserNotificationCenter API. On macOS 16 it no longer renders.
**How to apply:** Use `UNUserNotificationCenter.current().setBadgeCount(_:)` for dock badge. This requires notification permission (`.badge` option in `requestAuthorization`), which the app already requests. The fix is in `AppState.updateDockBadge()` in `AgMailApp.swift`.
