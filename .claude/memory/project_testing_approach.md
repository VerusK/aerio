---
name: Testing approach and requirements
description: Every code change must include tests, all tests must pass before next task, KeychainStore is mocked via protocol
type: project
---

Strict testing discipline established across all plans:

- **Every task MUST include new/updated tests** — tests are not optional
- **All tests must pass before starting next task** — no exceptions
- **140+ tests** across 18+ test files
- **KeychainStore protocol** with `MockKeychainStore` (in-memory) — eliminates system Keychain access prompts during tests
- **URLProtocol mock** for GmailAPIClient tests — no real network calls
- **No UI test framework** — manual UI testing after each phase (2 accounts, both keyboard layouts, context menus)
- **No external test dependencies** — everything uses XCTest

**Why:** Prior to KeychainStore protocol, tests triggered macOS Keychain access prompts which blocked CI and annoyed developers.
**How to apply:** Always use MockKeychainStore and InMemoryKeychainStore in tests. Never skip writing tests for new code. Run full suite before moving on.
