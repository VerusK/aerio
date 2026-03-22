---
name: os.log messages invisible in Release builds
description: os.log at .debug/.info level produces no output in Release builds — use NSLog for runtime debugging
type: project
---

`os.log` (Logger) messages at `.debug` and `.info` levels do not appear in Release builds, even with `log stream --level debug`. They also don't appear when redirecting stdout/stderr from the binary.

**Why:** Discovered while debugging the badge issue — spent time wondering why no logs appeared. `print()` also produces no visible output when running a macOS GUI app binary from terminal with stdout redirect.
**How to apply:** For quick runtime debugging, use `NSLog()` which always appears in `log show`/`log stream` and in redirected output. Remember to remove after debugging. For persistent logging, use `.error` or `.fault` level.
