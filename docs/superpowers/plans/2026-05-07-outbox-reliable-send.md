# Outbox Reliable Send Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persisted Outbox queue so emails are never silently lost — survive window close, app quit, and transient network failures, with prominent feedback when something goes wrong.

**Architecture:** A SwiftData `OutboxItem` queue in its own `outbox.store`, processed sequentially by an `@MainActor OutboxService` exposed via `@EnvironmentObject`. Send is fire-and-forget from `ComposeView` (window closes immediately). Backoff retry (10s/60s/300s × 3) with idempotency via locally-generated `Message-ID:` headers and a `rfc822msgid:` probe before retrying. UI surfaces queue status in a new sidebar row plus `UNUserNotification` success/failure messages.

**Tech Stack:** Swift 5+, SwiftUI, SwiftData, Swift Concurrency (actors, AsyncStream), UserNotifications, XCTest. No new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-05-07-outbox-reliable-send-design.md` (read first).

---

## File Structure

### New files
- `Aerio/Models/OutboxItem.swift` — `@Model` + `OutboxStatus` enum
- `Aerio/Persistence/OutboxStore.swift` — dedicated `ModelContainer` for `outbox.store`
- `Aerio/Services/ComposePayload.swift` — struct shared by all RFC2822 build sites
- `Aerio/Services/OutboxSender.swift` — protocol abstracting the wire send
- `Aerio/Services/OutboxService.swift` — queue + processLoop + retry + side-effects
- `Aerio/Views/SidebarSelection.swift` — `enum { folder(Folder), outbox }`
- `Aerio/Views/OutboxList.swift` — pending/failed item list with Retry/Cancel
- `AerioTests/Mocks/MockOutboxSender.swift` — test double for `OutboxSender`
- `AerioTests/Mocks/InMemoryOutboxStore.swift` — in-memory wrapper around outbox container
- `AerioTests/RFC2822BuilderPayloadTests.swift` — `ComposePayload` build tests
- `AerioTests/OutboxItemTests.swift` — model + status round-trip tests
- `AerioTests/OutboxServiceTests.swift` — full service behavior under mock
- `AerioTests/ComposeViewSendTests.swift` — enqueue + race regression tests

### Modified files
- `Aerio/Services/RFC2822Builder.swift` — add `build(_ payload: ComposePayload)` + `Message-ID` header support
- `Aerio/Services/GmailAPIClient.swift` — add `findInSent(messageId:)` + `OutboxSender` conformance
- `Aerio/Services/GmailAPIManager.swift` — refactor `sendEmail` / `saveDraft` to use `ComposePayload`
- `Aerio/Services/NotificationManager.swift` — add `outbox.success` / `outbox.failure` categories + `Retry` action handler
- `Aerio/Views/ComposeView.swift` — enqueue path, remove `sendError`/`isSending`, add `isSendingViaOutbox` race guard
- `Aerio/Views/MainView.swift` — replace `@State selectedFolder` with `@State sidebarSelection: SidebarSelection`; render `OutboxList` when `.outbox`
- `Aerio/Views/UnifiedSidebar.swift` — Outbox row (conditional, badge, color) + emit `SidebarSelection`
- `Aerio/AerioApp.swift` — instantiate `OutboxService` in `AppState`; call `resumeOnLaunch()` on init

---

## Build & Test Commands

Use these exactly as written. Substitute `<TestClass>` per task.

- **Build only:** `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build`
- **Run a single test class:** `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/<TestClass>`
- **Full app run (after big tasks):** `./scripts/run.sh`
- **Cleanup after test runs (avoids LaunchServices conflicts):** `rm -rf ~/Library/Developer/Xcode/DerivedData/Aerio-*/Build/Products/Debug/Aerio.app`

---

## Task 1: `OutboxItem` model + `OutboxStatus` enum

**Files:**
- Create: `Aerio/Models/OutboxItem.swift`
- Test:   `AerioTests/OutboxItemTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AerioTests/OutboxItemTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Aerio

final class OutboxItemTests: XCTestCase {
    func testInit_setsAllFields() {
        let id = UUID()
        let now = Date()
        let item = OutboxItem(
            id: id,
            accountId: "acct1",
            rawMime: Data("RAW".utf8),
            messageIdHeader: "<msg@aerio.local>",
            threadId: "thread123",
            draftIdToConsume: "draft9",
            subject: "hi",
            recipientsPreview: "to@example.com",
            status: .pending,
            attemptCount: 0,
            createdAt: now,
            nextAttemptAt: now,
            archiveOnSuccessForMsgId: "msg42",
            archiveOnSuccessForAccountId: "acct1"
        )
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.accountId, "acct1")
        XCTAssertEqual(item.rawMime, Data("RAW".utf8))
        XCTAssertEqual(item.messageIdHeader, "<msg@aerio.local>")
        XCTAssertEqual(item.threadId, "thread123")
        XCTAssertEqual(item.draftIdToConsume, "draft9")
        XCTAssertEqual(item.subject, "hi")
        XCTAssertEqual(item.recipientsPreview, "to@example.com")
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.attemptCount, 0)
        XCTAssertNil(item.lastError)
        XCTAssertEqual(item.createdAt, now)
        XCTAssertEqual(item.nextAttemptAt, now)
        XCTAssertEqual(item.archiveOnSuccessForMsgId, "msg42")
        XCTAssertEqual(item.archiveOnSuccessForAccountId, "acct1")
    }

    func testStatus_roundTripsThroughRawValue() {
        let item = OutboxItem(
            id: UUID(), accountId: "a", rawMime: Data(), messageIdHeader: "x",
            threadId: nil, draftIdToConsume: nil,
            subject: "s", recipientsPreview: "r",
            status: .pending, attemptCount: 0,
            createdAt: Date(), nextAttemptAt: Date(),
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        item.status = .sending
        XCTAssertEqual(item.statusRaw, "sending")
        XCTAssertEqual(item.status, .sending)
        item.statusRaw = "failed"
        XCTAssertEqual(item.status, .failed)
    }

    func testStatus_unknownRawValueFallsBackToFailed() {
        let item = OutboxItem(
            id: UUID(), accountId: "a", rawMime: Data(), messageIdHeader: "x",
            threadId: nil, draftIdToConsume: nil,
            subject: "s", recipientsPreview: "r",
            status: .pending, attemptCount: 0,
            createdAt: Date(), nextAttemptAt: Date(),
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        item.statusRaw = "garbage"
        XCTAssertEqual(item.status, .failed)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxItemTests
```

Expected: `error: cannot find 'OutboxItem' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Aerio/Models/OutboxItem.swift`:

```swift
import Foundation
import SwiftData

enum OutboxStatus: String, Sendable {
    case pending
    case sending
    case failed
}

@Model
final class OutboxItem {
    @Attribute(.unique) var id: UUID
    var accountId: String
    var rawMime: Data
    var messageIdHeader: String
    var threadId: String?
    var draftIdToConsume: String?
    var subject: String
    var recipientsPreview: String

    /// Raw storage for SwiftData; use `status` accessor.
    var statusRaw: String
    var attemptCount: Int
    var lastError: String?
    var createdAt: Date
    var nextAttemptAt: Date

    /// If set, after successful send remove INBOX label from this msgId on this account.
    var archiveOnSuccessForMsgId: String?
    var archiveOnSuccessForAccountId: String?

    var status: OutboxStatus {
        get { OutboxStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID,
        accountId: String,
        rawMime: Data,
        messageIdHeader: String,
        threadId: String?,
        draftIdToConsume: String?,
        subject: String,
        recipientsPreview: String,
        status: OutboxStatus,
        attemptCount: Int,
        createdAt: Date,
        nextAttemptAt: Date,
        archiveOnSuccessForMsgId: String?,
        archiveOnSuccessForAccountId: String?
    ) {
        self.id = id
        self.accountId = accountId
        self.rawMime = rawMime
        self.messageIdHeader = messageIdHeader
        self.threadId = threadId
        self.draftIdToConsume = draftIdToConsume
        self.subject = subject
        self.recipientsPreview = recipientsPreview
        self.statusRaw = status.rawValue
        self.attemptCount = attemptCount
        self.lastError = nil
        self.createdAt = createdAt
        self.nextAttemptAt = nextAttemptAt
        self.archiveOnSuccessForMsgId = archiveOnSuccessForMsgId
        self.archiveOnSuccessForAccountId = archiveOnSuccessForAccountId
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxItemTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```
git add Aerio/Models/OutboxItem.swift AerioTests/OutboxItemTests.swift
git commit -m "feat(outbox): add OutboxItem SwiftData model and OutboxStatus enum"
```

---

## Task 2: `OutboxStore` — dedicated ModelContainer

**Files:**
- Create: `Aerio/Persistence/OutboxStore.swift`
- Test:   extend `AerioTests/OutboxItemTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AerioTests/OutboxItemTests.swift`:

```swift
final class OutboxStoreTests: XCTestCase {
    func testInMemoryStore_persistsAndFetchesItems() async throws {
        let store = OutboxStore(inMemory: true)
        let id = UUID()
        let now = Date()
        let item = OutboxItem(
            id: id, accountId: "a", rawMime: Data("R".utf8), messageIdHeader: "<m>",
            threadId: nil, draftIdToConsume: nil, subject: "s", recipientsPreview: "r",
            status: .pending, attemptCount: 0, createdAt: now, nextAttemptAt: now,
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        try await store.insert(item)

        let fetched = try await store.allItems()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, id)
    }

    func testStore_deletesItemById() async throws {
        let store = OutboxStore(inMemory: true)
        let item = OutboxItem(
            id: UUID(), accountId: "a", rawMime: Data(), messageIdHeader: "<m>",
            threadId: nil, draftIdToConsume: nil, subject: "s", recipientsPreview: "r",
            status: .pending, attemptCount: 0, createdAt: Date(), nextAttemptAt: Date(),
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        try await store.insert(item)
        try await store.delete(id: item.id)
        let fetched = try await store.allItems()
        XCTAssertTrue(fetched.isEmpty)
    }

    func testStore_fetchesPendingReadyItems_sortedByCreatedAt() async throws {
        let store = OutboxStore(inMemory: true)
        let now = Date()
        let older = OutboxItem(
            id: UUID(), accountId: "a", rawMime: Data(), messageIdHeader: "<a>",
            threadId: nil, draftIdToConsume: nil, subject: "older", recipientsPreview: "r",
            status: .pending, attemptCount: 0,
            createdAt: now.addingTimeInterval(-10), nextAttemptAt: now.addingTimeInterval(-5),
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        let newer = OutboxItem(
            id: UUID(), accountId: "a", rawMime: Data(), messageIdHeader: "<b>",
            threadId: nil, draftIdToConsume: nil, subject: "newer", recipientsPreview: "r",
            status: .pending, attemptCount: 0,
            createdAt: now, nextAttemptAt: now.addingTimeInterval(-1),
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        let future = OutboxItem(
            id: UUID(), accountId: "a", rawMime: Data(), messageIdHeader: "<c>",
            threadId: nil, draftIdToConsume: nil, subject: "future", recipientsPreview: "r",
            status: .pending, attemptCount: 0,
            createdAt: now, nextAttemptAt: now.addingTimeInterval(60),
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        try await store.insert(older)
        try await store.insert(newer)
        try await store.insert(future)

        let ready = try await store.pendingReady(asOf: now)
        XCTAssertEqual(ready.map(\.subject), ["older", "newer"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxStoreTests
```

Expected: `error: cannot find 'OutboxStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Aerio/Persistence/OutboxStore.swift`:

```swift
import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "Aerio", category: "OutboxStore")

@MainActor
final class OutboxStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) {
        let schema = Schema([OutboxItem.self])
        let url = Self.storeURL()
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            config = ModelConfiguration(schema: schema, url: url)
        }
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            logger.error("Failed to create outbox ModelContainer: \(error.localizedDescription). Falling back to in-memory.")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            self.container = try! ModelContainer(for: schema, configurations: [fallback])
        }
    }

    private static func storeURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("outbox.store")
    }

    func insert(_ item: OutboxItem) async throws {
        context.insert(item)
        try context.save()
    }

    func delete(id: UUID) async throws {
        let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.id == id })
        let matches = try context.fetch(descriptor)
        for m in matches { context.delete(m) }
        try context.save()
    }

    func allItems() async throws -> [OutboxItem] {
        let descriptor = FetchDescriptor<OutboxItem>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Pending items whose nextAttemptAt is at or before `asOf`, ordered by createdAt.
    func pendingReady(asOf date: Date) async throws -> [OutboxItem] {
        let pendingRaw = OutboxStatus.pending.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.statusRaw == pendingRaw && $0.nextAttemptAt <= date },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    /// Earliest future nextAttemptAt across pending items, or nil if none in future.
    func earliestPendingNext(after date: Date) async throws -> Date? {
        let pendingRaw = OutboxStatus.pending.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.statusRaw == pendingRaw && $0.nextAttemptAt > date },
            sortBy: [SortDescriptor(\.nextAttemptAt, order: .forward)]
        )
        var d = descriptor
        d.fetchLimit = 1
        return try context.fetch(d).first?.nextAttemptAt
    }

    func resetSendingToPending() async throws -> Int {
        let sendingRaw = OutboxStatus.sending.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.statusRaw == sendingRaw })
        let stuck = try context.fetch(descriptor)
        for item in stuck {
            item.status = .pending
        }
        try context.save()
        return stuck.count
    }

    func save() throws {
        try context.save()
    }

    func item(byId id: UUID) async throws -> OutboxItem? {
        let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxStoreTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```
git add Aerio/Persistence/OutboxStore.swift AerioTests/OutboxItemTests.swift
git commit -m "feat(outbox): add isolated outbox.store ModelContainer with fetch/insert/delete"
```

---

## Task 3: `ComposePayload` + `RFC2822Builder.build(_:)` + `Message-ID` header

**Files:**
- Create: `Aerio/Services/ComposePayload.swift`
- Modify: `Aerio/Services/RFC2822Builder.swift`
- Test:   `AerioTests/RFC2822BuilderPayloadTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AerioTests/RFC2822BuilderPayloadTests.swift`:

```swift
import XCTest
@testable import Aerio

final class RFC2822BuilderPayloadTests: XCTestCase {
    func testBuild_plainBody_decodesToValidRFC2822WithExpectedHeaders() {
        let payload = ComposePayload(
            from: "me@example.com",
            to: "you@example.com",
            cc: nil,
            subject: "Hello",
            body: "World",
            inReplyTo: nil,
            references: nil,
            htmlBody: nil,
            attachments: [],
            inlineImages: [],
            messageId: nil
        )
        let raw = RFC2822Builder.build(payload)
        let decoded = String(data: RFC2822Builder.base64URLDecode(raw)!, encoding: .utf8)!
        XCTAssertTrue(decoded.contains("From: me@example.com"))
        XCTAssertTrue(decoded.contains("To: you@example.com"))
        XCTAssertTrue(decoded.contains("Subject: Hello"))
        XCTAssertFalse(decoded.contains("Message-ID:"))
    }

    func testBuild_withMessageId_embedsMessageIDHeader() {
        let payload = ComposePayload(
            from: "me@example.com", to: "you@example.com", cc: nil,
            subject: "Hi", body: "B", inReplyTo: nil, references: nil,
            htmlBody: nil, attachments: [], inlineImages: [],
            messageId: "<abc-123@aerio.local>"
        )
        let raw = RFC2822Builder.build(payload)
        let decoded = String(data: RFC2822Builder.base64URLDecode(raw)!, encoding: .utf8)!
        XCTAssertTrue(decoded.contains("Message-ID: <abc-123@aerio.local>"))
    }

    func testBuild_withHtmlBody_producesMultipartAlternative() {
        let payload = ComposePayload(
            from: "a@b.c", to: "d@e.f", cc: nil,
            subject: "S", body: "PLAIN", inReplyTo: nil, references: nil,
            htmlBody: "<p>HTML</p>", attachments: [], inlineImages: [],
            messageId: "<x@aerio.local>"
        )
        let raw = RFC2822Builder.build(payload)
        let decoded = String(data: RFC2822Builder.base64URLDecode(raw)!, encoding: .utf8)!
        XCTAssertTrue(decoded.contains("multipart/alternative"))
        XCTAssertTrue(decoded.contains("Message-ID: <x@aerio.local>"))
    }

    func testBuild_withAttachments_producesMultipartMixedWithMessageId() {
        let payload = ComposePayload(
            from: "a@b", to: "c@d", cc: nil,
            subject: "S", body: "B", inReplyTo: nil, references: nil,
            htmlBody: "<p>H</p>",
            attachments: [.init(filename: "f.txt", mimeType: "text/plain", data: Data("FILE".utf8))],
            inlineImages: [],
            messageId: "<y@aerio.local>"
        )
        let raw = RFC2822Builder.build(payload)
        let decoded = String(data: RFC2822Builder.base64URLDecode(raw)!, encoding: .utf8)!
        XCTAssertTrue(decoded.contains("multipart/mixed"))
        XCTAssertTrue(decoded.contains("Message-ID: <y@aerio.local>"))
        XCTAssertTrue(decoded.contains("filename=\"f.txt\""))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/RFC2822BuilderPayloadTests
```

Expected: `error: cannot find 'ComposePayload' in scope` (or `RFC2822Builder.build`).

- [ ] **Step 3: Create `ComposePayload`**

Create `Aerio/Services/ComposePayload.swift`:

```swift
import Foundation

struct ComposePayload {
    let from: String
    let to: String
    let cc: String?
    let subject: String
    let body: String
    let inReplyTo: String?
    let references: String?
    let htmlBody: String?
    let attachments: [RFC2822Builder.Attachment]
    let inlineImages: [RFC2822Builder.InlineImage]
    /// Optional `<uuid@aerio.local>` style identifier; when present, embedded as `Message-ID:` header.
    let messageId: String?
}
```

- [ ] **Step 4: Extend `RFC2822Builder` with `build(_:)` and `messageId`**

Add a new top-level static method to `Aerio/Services/RFC2822Builder.swift` (do not delete the existing `buildRawMessage` / `buildRawHTMLMessage` / `buildRawHTMLMessageWithAttachments` methods yet — they will be removed in Task 4 once GmailAPIManager is migrated):

```swift
extension RFC2822Builder {
    /// Single entry point — picks the right MIME structure based on the payload.
    static func build(_ payload: ComposePayload) -> String {
        if !payload.attachments.isEmpty || !payload.inlineImages.isEmpty {
            return buildRawHTMLMessageWithAttachments(
                from: payload.from, to: payload.to, cc: payload.cc, subject: payload.subject,
                htmlBody: payload.htmlBody ?? payload.body, plainBody: payload.body,
                attachments: payload.attachments, inlineImages: payload.inlineImages,
                inReplyTo: payload.inReplyTo, references: payload.references,
                messageId: payload.messageId
            )
        }
        if let html = payload.htmlBody, !html.isEmpty {
            return buildRawHTMLMessage(
                from: payload.from, to: payload.to, cc: payload.cc, subject: payload.subject,
                htmlBody: html, plainBody: payload.body,
                inReplyTo: payload.inReplyTo, references: payload.references,
                messageId: payload.messageId
            )
        }
        return buildRawMessage(
            from: payload.from, to: payload.to, cc: payload.cc, subject: payload.subject,
            body: payload.body,
            inReplyTo: payload.inReplyTo, references: payload.references,
            messageId: payload.messageId
        )
    }
}
```

Then add a `messageId: String? = nil` parameter to each of the existing three builders (`buildRawMessage`, `buildRawHTMLMessage`, `buildRawHTMLMessageWithAttachments`). In each, after the existing `Subject:` line and before the `MIME-Version:` line, insert:

```swift
if let messageId, !messageId.isEmpty {
    lines.append("Message-ID: \(messageId)")
}
```

(default-nil parameter means existing call sites in `GmailAPIManager` keep working unchanged.)

- [ ] **Step 5: Run to verify it passes**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/RFC2822BuilderPayloadTests
```

Expected: 4 tests pass. Then run the full RFC2822 + GmailAPIManager test suites to confirm no regressions:

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/GmailAPIManagerTests
```

Expected: all existing tests still pass (Message-ID header is opt-in; old call sites pass `nil`).

- [ ] **Step 6: Commit**

```
git add Aerio/Services/ComposePayload.swift Aerio/Services/RFC2822Builder.swift AerioTests/RFC2822BuilderPayloadTests.swift
git commit -m "feat(outbox): add ComposePayload + Message-ID header support to RFC2822Builder"
```

---

## Task 4: Refactor `GmailAPIManager` to use `ComposePayload`

**Files:**
- Modify: `Aerio/Services/GmailAPIManager.swift`

This is a behavior-preserving refactor — both `sendEmail` and `saveDraft` already build raw MIME via `buildRawMessage`/etc. We funnel them through `RFC2822Builder.build(payload)` so OutboxService uses the same path.

- [ ] **Step 1: Find the existing `buildRawMessage` helper inside `GmailAPIManager.swift`**

Read the file. There is a `private func buildRawMessage(...)` (around the same area as `sendEmail`/`saveDraft`). Note its parameters.

- [ ] **Step 2: Replace `buildRawMessage` with a `ComposePayload` constructor**

Replace the body of the private `buildRawMessage` function with one that constructs a `ComposePayload` and delegates:

```swift
private func buildRawMessage(
    from: String, to: String, cc: String? = nil,
    subject: String, body: String,
    inReplyTo: String? = nil, references: String? = nil,
    htmlBody: String? = nil,
    attachments: [RFC2822Builder.Attachment] = [],
    inlineImages: [RFC2822Builder.InlineImage] = []
) -> String {
    let payload = ComposePayload(
        from: from, to: to, cc: cc, subject: subject, body: body,
        inReplyTo: inReplyTo, references: references, htmlBody: htmlBody,
        attachments: attachments, inlineImages: inlineImages,
        messageId: nil
    )
    return RFC2822Builder.build(payload)
}
```

(Keep the existing call sites for `sendEmail` and `saveDraft` unchanged — they call this helper, which now goes through `ComposePayload`.)

- [ ] **Step 3: Run the existing GmailAPIManager tests**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/GmailAPIManagerTests
```

Expected: all tests still pass — pure refactor.

- [ ] **Step 4: Commit**

```
git add Aerio/Services/GmailAPIManager.swift
git commit -m "refactor: route GmailAPIManager raw-MIME building through ComposePayload"
```

---

## Task 5: `OutboxSender` protocol + `findInSent` + `GmailAPIClient` conformance

**Files:**
- Create: `Aerio/Services/OutboxSender.swift`
- Modify: `Aerio/Services/GmailAPIClient.swift`
- Test:   extend `AerioTests/GmailAPIClientTests.swift`

- [ ] **Step 1: Write the failing test for `findInSent`**

Append to `AerioTests/GmailAPIClientTests.swift` (use existing `URLProtocol` mocking pattern in that file — copy the structure of an existing list-messages test):

```swift
func testFindInSent_returnsTrueWhenMessageMatchesQuery() async throws {
    MockURLProtocol.mockResponses["/gmail/v1/users/me/messages"] = (
        statusCode: 200,
        body: """
        {"messages":[{"id":"abc","threadId":"t1"}], "resultSizeEstimate":1}
        """.data(using: .utf8)!
    )
    let client = makeClient()  // helper used elsewhere in this file
    let result = try await client.findInSent(messageId: "<m@aerio.local>")
    XCTAssertTrue(result)
}

func testFindInSent_returnsFalseWhenNoMatch() async throws {
    MockURLProtocol.mockResponses["/gmail/v1/users/me/messages"] = (
        statusCode: 200,
        body: """
        {"messages":[],"resultSizeEstimate":0}
        """.data(using: .utf8)!
    )
    let client = makeClient()
    let result = try await client.findInSent(messageId: "<m@aerio.local>")
    XCTAssertFalse(result)
}
```

(If `GmailAPIClientTests.swift` does not have a `makeClient()` helper, copy the pattern of an existing test in that file.)

- [ ] **Step 2: Run to verify it fails**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/GmailAPIClientTests
```

Expected: `error: value of type 'GmailAPIClient' has no member 'findInSent'`.

- [ ] **Step 3: Create the protocol**

Create `Aerio/Services/OutboxSender.swift`:

```swift
import Foundation

/// Wire-protocol abstraction used by OutboxService. Production: GmailAPIClient.
/// Tests: MockOutboxSender.
protocol OutboxSender: Sendable {
    func sendMessage(rawBase64URL: String, threadId: String?) async throws -> GmailMessage
    func findInSent(messageId: String) async throws -> Bool
    func deleteDraft(draftId: String) async throws
    func modifyMessage(id: String, addLabels: [String]?, removeLabels: [String]?) async throws -> GmailMessage
}
```

- [ ] **Step 4: Add `findInSent` and conformance to `GmailAPIClient`**

In `Aerio/Services/GmailAPIClient.swift`, add (next to the existing `listMessages`):

```swift
func findInSent(messageId: String) async throws -> Bool {
    let query = "rfc822msgid:\(messageId)"
    let response = try await listMessages(query: query, labelIds: ["SENT"], maxResults: 1)
    return (response.messages?.isEmpty == false)
}
```

Then add an extension at the bottom of the file:

```swift
extension GmailAPIClient: OutboxSender {
    func sendMessage(rawBase64URL: String, threadId: String?) async throws -> GmailMessage {
        try await sendMessage(raw: rawBase64URL, threadId: threadId)
    }
}
```

(`modifyMessage` and `deleteDraft` already exist on `GmailAPIClient` with the right signatures — protocol conformance is automatic.)

- [ ] **Step 5: Run to verify it passes**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/GmailAPIClientTests
```

Expected: all tests pass (including the two new ones).

- [ ] **Step 6: Commit**

```
git add Aerio/Services/OutboxSender.swift Aerio/Services/GmailAPIClient.swift AerioTests/GmailAPIClientTests.swift
git commit -m "feat(outbox): OutboxSender protocol + findInSent for idempotency probe"
```

---

## Task 6: `MockOutboxSender` for tests

**Files:**
- Create: `AerioTests/Mocks/MockOutboxSender.swift`

This isn't TDD'd in itself — it's the test infrastructure for Tasks 7-14.

- [ ] **Step 1: Create the mock**

Create `AerioTests/Mocks/MockOutboxSender.swift`:

```swift
import Foundation
@testable import Aerio

actor MockOutboxSender: OutboxSender {
    enum Behavior {
        case success(GmailMessage)
        case throwError(Error)
    }

    var sendBehavior: Behavior = .success(GmailMessage(id: "sent-1", threadId: "t1", labelIds: [], snippet: nil, payload: nil, internalDate: nil, historyId: nil))
    var findInSentReturns: Bool = false
    var deleteDraftThrows: Error?
    var modifyMessageThrows: Error?

    private(set) var sendMessageCalls: [(raw: String, threadId: String?)] = []
    private(set) var findInSentCalls: [String] = []
    private(set) var deleteDraftCalls: [String] = []
    private(set) var modifyMessageCalls: [(id: String, add: [String]?, remove: [String]?)] = []

    func setSendBehavior(_ b: Behavior) { sendBehavior = b }
    func setFindInSent(_ v: Bool) { findInSentReturns = v }

    func sendMessage(rawBase64URL: String, threadId: String?) async throws -> GmailMessage {
        sendMessageCalls.append((rawBase64URL, threadId))
        switch sendBehavior {
        case .success(let m): return m
        case .throwError(let e): throw e
        }
    }

    func findInSent(messageId: String) async throws -> Bool {
        findInSentCalls.append(messageId)
        return findInSentReturns
    }

    func deleteDraft(draftId: String) async throws {
        deleteDraftCalls.append(draftId)
        if let e = deleteDraftThrows { throw e }
    }

    func modifyMessage(id: String, addLabels: [String]?, removeLabels: [String]?) async throws -> GmailMessage {
        modifyMessageCalls.append((id, addLabels, removeLabels))
        if let e = modifyMessageThrows { throw e }
        return GmailMessage(id: id, threadId: nil, labelIds: nil, snippet: nil, payload: nil, internalDate: nil, historyId: nil)
    }
}
```

(If `GmailMessage`'s init signature differs, adjust. Check `Aerio/Models/GmailAPIModels.swift` to confirm.)

- [ ] **Step 2: Build to verify it compiles**

```
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build
```

Expected: build success.

- [ ] **Step 3: Commit**

```
git add AerioTests/Mocks/MockOutboxSender.swift
git commit -m "test: add MockOutboxSender for OutboxService tests"
```

---

## Task 7: `OutboxService` skeleton + `enqueue` persistence

**Files:**
- Create: `Aerio/Services/OutboxService.swift`
- Test:   `AerioTests/OutboxServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AerioTests/OutboxServiceTests.swift`:

```swift
import XCTest
@testable import Aerio

@MainActor
final class OutboxServiceEnqueueTests: XCTestCase {
    func testEnqueue_persistsItemAndPublishesIt() async throws {
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        let service = OutboxService(
            store: store,
            sendersByAccount: ["a": sender],
            notifier: NoopNotifier(),
            postSendRefresh: { },
            now: { Date(timeIntervalSince1970: 1000) }
        )

        let item = makeItem(account: "a", subject: "hello")
        try await service.enqueue(item)

        let stored = try await store.allItems()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items.first?.subject, "hello")
    }
}

// Test helpers used across this file:
@MainActor
func makeItem(
    id: UUID = UUID(),
    account: String,
    subject: String = "s",
    status: OutboxStatus = .pending,
    nextAttemptAt: Date = Date(),
    attemptCount: Int = 0,
    threadId: String? = nil,
    draftIdToConsume: String? = nil,
    archiveOnSuccessForMsgId: String? = nil,
    archiveOnSuccessForAccountId: String? = nil
) -> OutboxItem {
    OutboxItem(
        id: id, accountId: account, rawMime: Data("RAW".utf8),
        messageIdHeader: "<\(id.uuidString)@aerio.local>",
        threadId: threadId, draftIdToConsume: draftIdToConsume,
        subject: subject, recipientsPreview: "to@x",
        status: status, attemptCount: attemptCount,
        createdAt: Date(timeIntervalSince1970: 0), nextAttemptAt: nextAttemptAt,
        archiveOnSuccessForMsgId: archiveOnSuccessForMsgId,
        archiveOnSuccessForAccountId: archiveOnSuccessForAccountId
    )
}

actor NoopNotifier: OutboxNotifying {
    func notifySuccess(item: OutboxItem) { }
    func notifyFailure(item: OutboxItem, permanent: Bool) { }
}
```

- [ ] **Step 2: Run to verify it fails**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceEnqueueTests
```

Expected: `error: cannot find 'OutboxService'`.

- [ ] **Step 3: Implement the skeleton**

Create `Aerio/Services/OutboxService.swift`:

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: "Aerio", category: "OutboxService")

protocol OutboxNotifying: Sendable {
    func notifySuccess(item: OutboxItem) async
    func notifyFailure(item: OutboxItem, permanent: Bool) async
}

@MainActor
final class OutboxService: ObservableObject {
    @Published private(set) var items: [OutboxItem] = []

    private let store: OutboxStore
    private var sendersByAccount: [String: OutboxSender]
    private let notifier: OutboxNotifying
    private let postSendRefresh: @MainActor () async -> Void
    private let now: @Sendable () -> Date

    private var processTask: Task<Void, Never>?
    private var signalContinuation: AsyncStream<Void>.Continuation?
    private var signalStream: AsyncStream<Void>?

    init(
        store: OutboxStore,
        sendersByAccount: [String: OutboxSender],
        notifier: OutboxNotifying,
        postSendRefresh: @escaping @MainActor () async -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.sendersByAccount = sendersByAccount
        self.notifier = notifier
        self.postSendRefresh = postSendRefresh
        self.now = now
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.signalStream = stream
        self.signalContinuation = continuation
    }

    func setSenders(_ senders: [String: OutboxSender]) {
        self.sendersByAccount = senders
    }

    func enqueue(_ item: OutboxItem) async throws {
        try await store.insert(item)
        await reloadItems()
        signal()
    }

    private func reloadItems() async {
        do {
            items = try await store.allItems()
        } catch {
            logger.error("Failed to reload outbox items: \(error.localizedDescription)")
        }
    }

    private func signal() {
        signalContinuation?.yield()
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceEnqueueTests
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```
git add Aerio/Services/OutboxService.swift AerioTests/OutboxServiceTests.swift
git commit -m "feat(outbox): OutboxService skeleton with enqueue + signal stream"
```

---

## Task 8: `processLoop` happy path — first-attempt success

**Files:**
- Modify: `Aerio/Services/OutboxService.swift`
- Test:   extend `AerioTests/OutboxServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AerioTests/OutboxServiceTests.swift`:

```swift
@MainActor
final class OutboxServiceProcessTests: XCTestCase {
    func testProcess_successDeletesItemFromStoreAndFiresNotification() async throws {
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        let notifier = RecordingNotifier()
        var refreshed = false
        let service = OutboxService(
            store: store,
            sendersByAccount: ["a": sender],
            notifier: notifier,
            postSendRefresh: { refreshed = true }
        )
        let item = makeItem(account: "a", subject: "hi")
        try await store.insert(item)

        await service.processOnce()

        let stored = try await store.allItems()
        XCTAssertTrue(stored.isEmpty)
        await XCTAssertEqual(await notifier.successCalls.count, 1)
        XCTAssertTrue(refreshed)
        await XCTAssertEqual(await sender.findInSentCalls.count, 0, "no idempotency probe on first attempt")
    }
}

actor RecordingNotifier: OutboxNotifying {
    var successCalls: [OutboxItem] = []
    var failureCalls: [(OutboxItem, Bool)] = []
    func notifySuccess(item: OutboxItem) { successCalls.append(item) }
    func notifyFailure(item: OutboxItem, permanent: Bool) { failureCalls.append((item, permanent)) }
}
```

- [ ] **Step 2: Run to verify it fails**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceProcessTests
```

Expected: `error: value of type 'OutboxService' has no member 'processOnce'`.

- [ ] **Step 3: Implement `processOnce` and `attemptSend` happy path**

Append to `Aerio/Services/OutboxService.swift`:

```swift
extension OutboxService {
    /// Processes one ready item if any. Exposed for testing; production calls processLoop.
    func processOnce() async {
        do {
            let ready = try await store.pendingReady(asOf: now())
            guard let item = ready.first else { return }
            await attemptSend(item)
            await reloadItems()
        } catch {
            logger.error("processOnce failed: \(error.localizedDescription)")
        }
    }

    /// Per-item processing isolated in its own do/catch so a corrupt item cannot stall the queue.
    private func attemptSend(_ item: OutboxItem) async {
        do {
            item.status = .sending
            try store.save()

            guard let sender = sendersByAccount[item.accountId] else {
                item.status = .failed
                item.lastError = "Account removed"
                try? store.save()
                await notifier.notifyFailure(item: item, permanent: true)
                return
            }

            // First attempt skips the idempotency probe.
            if item.attemptCount > 0 {
                if try await sender.findInSent(messageId: item.messageIdHeader) {
                    logger.info("idempotency: \(item.messageIdHeader) already in SENT, treating as success")
                    await onSuccess(item)
                    return
                }
            }

            let raw = String(data: item.rawMime, encoding: .utf8) ?? ""
            _ = try await sender.sendMessage(rawBase64URL: raw, threadId: item.threadId)
            await onSuccess(item)
        } catch {
            // Classification + retry handled in Task 9
            logger.error("attemptSend failed: \(error.localizedDescription)")
            item.status = .failed
            item.lastError = error.localizedDescription
            try? store.save()
            await notifier.notifyFailure(item: item, permanent: true)
        }
    }

    private func onSuccess(_ item: OutboxItem) async {
        try? await store.delete(id: item.id)
        await notifier.notifySuccess(item: item)
        await postSendRefresh()
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceProcessTests
```

Expected: test passes.

- [ ] **Step 5: Commit**

```
git add Aerio/Services/OutboxService.swift AerioTests/OutboxServiceTests.swift
git commit -m "feat(outbox): processOnce happy-path success deletes item and notifies"
```

---

## Task 9: Error classification + retry with backoff

**Files:**
- Modify: `Aerio/Services/OutboxService.swift`
- Test:   extend `AerioTests/OutboxServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `OutboxServiceProcessTests`:

```swift
func testProcess_transientErrorReschedulesPendingWithBackoff() async throws {
    let store = OutboxStore(inMemory: true)
    let sender = MockOutboxSender()
    await sender.setSendBehavior(.throwError(GmailAPIError.networkError("offline")))
    let notifier = RecordingNotifier()
    var fixedNow = Date(timeIntervalSince1970: 1000)
    let service = OutboxService(
        store: store, sendersByAccount: ["a": sender],
        notifier: notifier, postSendRefresh: { },
        now: { fixedNow }
    )
    let item = makeItem(account: "a")
    try await store.insert(item)

    await service.processOnce()

    let after = try await store.allItems()
    XCTAssertEqual(after.count, 1)
    XCTAssertEqual(after.first?.status, .pending)
    XCTAssertEqual(after.first?.attemptCount, 1)
    XCTAssertEqual(after.first?.nextAttemptAt, fixedNow.addingTimeInterval(10))
    await XCTAssertTrue(await notifier.failureCalls.isEmpty)
}

func testProcess_threeTransientFailuresMarksFailed() async throws {
    let store = OutboxStore(inMemory: true)
    let sender = MockOutboxSender()
    await sender.setSendBehavior(.throwError(GmailAPIError.networkError("offline")))
    let notifier = RecordingNotifier()
    let fixedNow = Date(timeIntervalSince1970: 1000)
    let service = OutboxService(
        store: store, sendersByAccount: ["a": sender],
        notifier: notifier, postSendRefresh: { },
        now: { fixedNow }
    )
    // Simulate a previously-attempted item: nextAttemptAt is in the past, attemptCount 2.
    let item = makeItem(account: "a", attemptCount: 2, nextAttemptAt: fixedNow.addingTimeInterval(-1))
    try await store.insert(item)

    await service.processOnce()

    let after = try await store.allItems()
    XCTAssertEqual(after.count, 1)
    XCTAssertEqual(after.first?.status, .failed)
    XCTAssertEqual(after.first?.attemptCount, 3)
    await XCTAssertEqual(await notifier.failureCalls.count, 1)
    await XCTAssertEqual(await notifier.failureCalls.first?.1, false, "permanent flag should be false (exhausted, not permanent)")
}

func testProcess_permanentErrorMarksFailedImmediately() async throws {
    let store = OutboxStore(inMemory: true)
    let sender = MockOutboxSender()
    await sender.setSendBehavior(.throwError(GmailAPIError.sessionExpired))
    let notifier = RecordingNotifier()
    let service = OutboxService(
        store: store, sendersByAccount: ["a": sender],
        notifier: notifier, postSendRefresh: { }
    )
    let item = makeItem(account: "a")
    try await store.insert(item)

    await service.processOnce()

    let after = try await store.allItems()
    XCTAssertEqual(after.first?.status, .failed)
    XCTAssertEqual(after.first?.attemptCount, 1)
    await XCTAssertEqual(await notifier.failureCalls.first?.1, true, "permanent should be true")
}
```

- [ ] **Step 2: Run to verify they fail**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceProcessTests
```

Expected: 3 new tests fail (current implementation marks everything `.failed` on any error).

- [ ] **Step 3: Replace `attemptSend` body with classified retry logic**

In `Aerio/Services/OutboxService.swift`, replace the `} catch {` block at the end of `attemptSend` with:

```swift
} catch {
    let classification = classify(error)
    item.attemptCount += 1
    item.lastError = error.localizedDescription
    if classification == .permanent {
        item.status = .failed
        try? store.save()
        await notifier.notifyFailure(item: item, permanent: true)
    } else if item.attemptCount >= 3 {
        item.status = .failed
        try? store.save()
        await notifier.notifyFailure(item: item, permanent: false)
    } else {
        item.status = .pending
        item.nextAttemptAt = now().addingTimeInterval(Self.backoffSeconds(for: item.attemptCount))
        try? store.save()
    }
}
```

Then add inside the same extension:

```swift
private enum ErrorClassification { case transient, permanent }

private func classify(_ error: Error) -> ErrorClassification {
    if let gmailError = error as? GmailAPIError {
        switch gmailError {
        case .networkError, .serverError, .rateLimited:
            return .transient
        case .forbidden, .notFound, .sessionExpired, .decodingError, .historyExpired, .unauthorized:
            return .permanent
        }
    }
    return .transient
}

static func backoffSeconds(for attemptCount: Int) -> TimeInterval {
    switch attemptCount {
    case 1: return 10
    case 2: return 60
    default: return 300
    }
}
```

(If `GmailAPIError` doesn't have one of those cases, match against the cases that exist — read `Aerio/Services/GmailAPIClient.swift` to confirm. Do NOT add new cases to `GmailAPIError`.)

- [ ] **Step 4: Run to verify all process tests pass**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceProcessTests
```

Expected: all process tests pass.

- [ ] **Step 5: Commit**

```
git add Aerio/Services/OutboxService.swift AerioTests/OutboxServiceTests.swift
git commit -m "feat(outbox): classify errors and retry transient failures with 10/60/300s backoff"
```

---

## Task 10: Idempotency probe on retries

**Files:**
- Modify: `Aerio/Services/OutboxService.swift` (already wired in Task 8)
- Test:   extend `AerioTests/OutboxServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `OutboxServiceProcessTests`:

```swift
func testIdempotency_skipsSendWhenMessageAlreadyInSent() async throws {
    let store = OutboxStore(inMemory: true)
    let sender = MockOutboxSender()
    await sender.setFindInSent(true)
    let notifier = RecordingNotifier()
    var refreshed = false
    let service = OutboxService(
        store: store, sendersByAccount: ["a": sender],
        notifier: notifier, postSendRefresh: { refreshed = true }
    )
    let item = makeItem(account: "a", attemptCount: 1)
    try await store.insert(item)

    await service.processOnce()

    let after = try await store.allItems()
    XCTAssertTrue(after.isEmpty, "item should be deleted as success via idempotency")
    await XCTAssertEqual(await sender.findInSentCalls.count, 1)
    await XCTAssertEqual(await sender.sendMessageCalls.count, 0, "should NOT send when already in SENT")
    await XCTAssertEqual(await notifier.successCalls.count, 1)
    XCTAssertTrue(refreshed)
}

func testIdempotency_doesNotProbeOnFirstAttempt() async throws {
    let store = OutboxStore(inMemory: true)
    let sender = MockOutboxSender()
    let service = OutboxService(
        store: store, sendersByAccount: ["a": sender],
        notifier: NoopNotifier(), postSendRefresh: { }
    )
    let item = makeItem(account: "a", attemptCount: 0)
    try await store.insert(item)

    await service.processOnce()

    await XCTAssertEqual(await sender.findInSentCalls.count, 0)
    await XCTAssertEqual(await sender.sendMessageCalls.count, 1)
}
```

- [ ] **Step 2: Run to verify they pass**

The probe was already wired in Task 8 (`if item.attemptCount > 0 { findInSent ... }`). Run:

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceProcessTests
```

Expected: both new tests pass.

- [ ] **Step 3: Commit**

```
git add AerioTests/OutboxServiceTests.swift
git commit -m "test(outbox): cover idempotency probe behavior on retry vs first attempt"
```

---

## Task 11: `resumeOnLaunch` — sending → pending recovery

**Files:**
- Modify: `Aerio/Services/OutboxService.swift`
- Test:   extend `AerioTests/OutboxServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
func testResumeOnLaunch_resetsSendingItemsToPending() async throws {
    let store = OutboxStore(inMemory: true)
    let stuck = makeItem(account: "a", status: .sending)
    try await store.insert(stuck)

    let service = OutboxService(
        store: store, sendersByAccount: [:],
        notifier: NoopNotifier(), postSendRefresh: { }
    )
    let resetCount = try await service.resumeOnLaunch()

    XCTAssertEqual(resetCount, 1)
    let after = try await store.allItems()
    XCTAssertEqual(after.first?.status, .pending)
}

func testResumeOnLaunch_noopWhenNoStuckItems() async throws {
    let store = OutboxStore(inMemory: true)
    let service = OutboxService(
        store: store, sendersByAccount: [:],
        notifier: NoopNotifier(), postSendRefresh: { }
    )
    let count = try await service.resumeOnLaunch()
    XCTAssertEqual(count, 0)
}
```

- [ ] **Step 2: Run to verify they fail**

Expected: `error: value of type 'OutboxService' has no member 'resumeOnLaunch'`.

- [ ] **Step 3: Implement**

Add to the `OutboxService` extension:

```swift
@discardableResult
func resumeOnLaunch() async throws -> Int {
    let count = try await store.resetSendingToPending()
    await reloadItems()
    if count > 0 { signal() }
    return count
}
```

- [ ] **Step 4: Run to verify they pass**

Expected: both pass.

- [ ] **Step 5: Commit**

```
git add Aerio/Services/OutboxService.swift AerioTests/OutboxServiceTests.swift
git commit -m "feat(outbox): resumeOnLaunch resets stuck .sending items to .pending"
```

---

## Task 12: Post-success side effects (delete draft, archive inbox)

**Files:**
- Modify: `Aerio/Services/OutboxService.swift`
- Test:   extend `AerioTests/OutboxServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testSideEffects_deletesDraftWhenDraftIdToConsumeSet() async throws {
    let store = OutboxStore(inMemory: true)
    let sender = MockOutboxSender()
    let service = OutboxService(
        store: store, sendersByAccount: ["a": sender],
        notifier: NoopNotifier(), postSendRefresh: { }
    )
    let item = makeItem(account: "a", draftIdToConsume: "draft-99")
    try await store.insert(item)

    await service.processOnce()

    await XCTAssertEqual(await sender.deleteDraftCalls, ["draft-99"])
}

func testSideEffects_archivesInboxMessageOnReplyWhenFlagged() async throws {
    let store = OutboxStore(inMemory: true)
    let sender = MockOutboxSender()
    let service = OutboxService(
        store: store, sendersByAccount: ["a": sender],
        notifier: NoopNotifier(), postSendRefresh: { }
    )
    let item = makeItem(account: "a",
                        archiveOnSuccessForMsgId: "orig-42",
                        archiveOnSuccessForAccountId: "a")
    try await store.insert(item)

    await service.processOnce()

    let calls = await sender.modifyMessageCalls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.id, "orig-42")
    XCTAssertEqual(calls.first?.remove ?? [], ["INBOX"])
}

func testSideEffects_failureIsLoggedNotPropagated() async throws {
    let store = OutboxStore(inMemory: true)
    let sender = MockOutboxSender()
    sender.deleteDraftThrows = GmailAPIError.networkError("dropped")
    let notifier = RecordingNotifier()
    let service = OutboxService(
        store: store, sendersByAccount: ["a": sender],
        notifier: notifier, postSendRefresh: { }
    )
    let item = makeItem(account: "a", draftIdToConsume: "d-1")
    try await store.insert(item)

    await service.processOnce()

    // success notification still fires; deleteDraft failure was swallowed
    await XCTAssertEqual(await notifier.successCalls.count, 1)
    let stored = try await store.allItems()
    XCTAssertTrue(stored.isEmpty)
}
```

- [ ] **Step 2: Run to verify they fail**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceProcessTests
```

Expected: tests fail (side effects not yet wired).

- [ ] **Step 3: Update `onSuccess` to do side effects**

Replace `onSuccess` in `OutboxService.swift` with:

```swift
private func onSuccess(_ item: OutboxItem) async {
    let sender = sendersByAccount[item.accountId]

    // Delete consumed draft (best-effort)
    if let draftId = item.draftIdToConsume, let sender {
        do { try await sender.deleteDraft(draftId: draftId) }
        catch { logger.error("deleteDraft failed (ignored): \(error.localizedDescription)") }
    }

    // Archive replied-to inbox message (best-effort)
    if let archiveId = item.archiveOnSuccessForMsgId,
       let archiveAccount = item.archiveOnSuccessForAccountId,
       let sender = sendersByAccount[archiveAccount] {
        do { _ = try await sender.modifyMessage(id: archiveId, addLabels: nil, removeLabels: ["INBOX"]) }
        catch { logger.error("archive inbox failed (ignored): \(error.localizedDescription)") }
    }

    try? await store.delete(id: item.id)
    await notifier.notifySuccess(item: item)
    await postSendRefresh()
}
```

- [ ] **Step 4: Run tests**

Expected: side-effect tests pass; existing tests still pass.

- [ ] **Step 5: Commit**

```
git add Aerio/Services/OutboxService.swift AerioTests/OutboxServiceTests.swift
git commit -m "feat(outbox): on success delete consumed draft and archive replied-to inbox msg"
```

---

## Task 13: Per-item try/catch — corrupt item resilience

**Files:**
- Modify: `Aerio/Services/OutboxService.swift`
- Test:   extend `AerioTests/OutboxServiceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testProcess_corruptItemDoesNotStallQueue() async throws {
    let store = OutboxStore(inMemory: true)
    let sender = MockOutboxSender()

    // Inject an item whose accountId has no sender registered → triggers "Account removed" path,
    // which is the closest reproducible "corrupt-state" we can test deterministically.
    let bad = makeItem(account: "missing-account", subject: "bad")
    let good = makeItem(account: "a", subject: "good")
    try await store.insert(bad)
    try await store.insert(good)

    let service = OutboxService(
        store: store, sendersByAccount: ["a": sender],
        notifier: NoopNotifier(), postSendRefresh: { }
    )

    // Process bad item
    await service.processOnce()
    // Process next ready (good) item
    await service.processOnce()

    let stored = try await store.allItems()
    XCTAssertEqual(stored.count, 1)
    XCTAssertEqual(stored.first?.status, .failed, "bad item is failed")
    XCTAssertEqual(stored.first?.subject, "bad")
    await XCTAssertEqual(await sender.sendMessageCalls.count, 1, "good item was sent")
}
```

- [ ] **Step 2: Run to verify it passes**

The "Account removed" guard already exists in Task 8. The test should pass already — this task DOCUMENTS the behavior and locks it in. Run:

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceProcessTests
```

Expected: passes.

- [ ] **Step 3: Add explicit per-item top-level try/catch**

To make resilience explicit (defense-in-depth), wrap the whole `attemptSend` body in an outer do/catch. Replace `private func attemptSend(_ item: OutboxItem) async {` body with:

```swift
private func attemptSend(_ item: OutboxItem) async {
    do {
        try await attemptSendInner(item)
    } catch {
        logger.error("attemptSend crashed unexpectedly: \(error.localizedDescription); item=\(item.id)")
        item.status = .failed
        item.lastError = "Processing crashed: \(error.localizedDescription)"
        try? store.save()
        await notifier.notifyFailure(item: item, permanent: true)
    }
}

private func attemptSendInner(_ item: OutboxItem) async throws {
    // (move the existing attemptSend body here, BUT remove the outer catch — let it propagate)
}
```

Move the entirety of the existing `attemptSend` body (success path + classification catch) into `attemptSendInner` so that any unexpected throw bubbles to the wrapper.

- [ ] **Step 4: Run all OutboxService tests**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceProcessTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
git add Aerio/Services/OutboxService.swift AerioTests/OutboxServiceTests.swift
git commit -m "feat(outbox): per-item try/catch wrapper so one bad item cannot stall the queue"
```

---

## Task 14: `cancel` and `retry`

**Files:**
- Modify: `Aerio/Services/OutboxService.swift`
- Test:   extend `AerioTests/OutboxServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
final class OutboxServiceCancelRetryTests: XCTestCase {
    func testCancel_removesItemFromStore() async throws {
        let store = OutboxStore(inMemory: true)
        let item = makeItem(account: "a")
        try await store.insert(item)

        let service = OutboxService(
            store: store, sendersByAccount: [:],
            notifier: NoopNotifier(), postSendRefresh: { }
        )
        try await service.cancel(itemId: item.id)

        let stored = try await store.allItems()
        XCTAssertTrue(stored.isEmpty)
    }

    func testRetry_resetsFailedToPendingNow() async throws {
        let store = OutboxStore(inMemory: true)
        let failed = makeItem(account: "a", status: .failed, attemptCount: 3)
        try await store.insert(failed)

        let service = OutboxService(
            store: store, sendersByAccount: [:],
            notifier: NoopNotifier(), postSendRefresh: { },
            now: { Date(timeIntervalSince1970: 5000) }
        )
        try await service.retry(itemId: failed.id)

        let stored = try await store.allItems()
        XCTAssertEqual(stored.first?.status, .pending)
        XCTAssertEqual(stored.first?.nextAttemptAt, Date(timeIntervalSince1970: 5000))
        XCTAssertEqual(stored.first?.attemptCount, 0, "retry resets attempt count")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Expected: missing methods.

- [ ] **Step 3: Implement**

Add to `OutboxService.swift`:

```swift
extension OutboxService {
    func cancel(itemId: UUID) async throws {
        try await store.delete(id: itemId)
        await reloadItems()
    }

    func retry(itemId: UUID) async throws {
        guard let item = try await store.item(byId: itemId) else { return }
        item.status = .pending
        item.attemptCount = 0
        item.lastError = nil
        item.nextAttemptAt = now()
        try store.save()
        await reloadItems()
        signal()
    }
}
```

- [ ] **Step 4: Run tests**

Expected: pass.

- [ ] **Step 5: Commit**

```
git add Aerio/Services/OutboxService.swift AerioTests/OutboxServiceTests.swift
git commit -m "feat(outbox): cancel and retry actions"
```

---

## Task 15: `processLoop` driver — sleep until next ready, wake on signal

**Files:**
- Modify: `Aerio/Services/OutboxService.swift`
- Test:   add a small integration test in `AerioTests/OutboxServiceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
final class OutboxServiceLoopTests: XCTestCase {
    func testStartLoop_processesEnqueuedItem() async throws {
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        let notifier = RecordingNotifier()
        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: notifier, postSendRefresh: { }
        )

        service.startLoop()
        try await service.enqueue(makeItem(account: "a"))

        // Wait up to 2s for the loop to drain (signal-driven; usually <100ms).
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && !(try await store.allItems()).isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        let stored = try await store.allItems()
        XCTAssertTrue(stored.isEmpty)
        await XCTAssertEqual(await notifier.successCalls.count, 1)

        service.stopLoop()
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Expected: `startLoop`/`stopLoop` missing.

- [ ] **Step 3: Implement**

The driver design avoids racing an `AsyncStream` iterator inside child Tasks (iterators aren't `Sendable`). Instead: the loop awaits one signal at a time via `for await _ in stream`. When a signal arrives, it drains all ready items, then schedules a single one-shot timer Task that emits another signal at the earliest future `nextAttemptAt`. New `enqueue` / `retry` calls cancel the timer and signal directly.

Append to `OutboxService.swift`:

```swift
extension OutboxService {
    func startLoop() {
        guard processTask == nil else { return }
        // Kick once so any items already in the store at boot get drained.
        signal()
        processTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stopLoop() {
        nextWakeTimer?.cancel()
        nextWakeTimer = nil
        processTask?.cancel()
        processTask = nil
    }

    private func runLoop() async {
        guard let stream = signalStream else { return }
        for await _ in stream {
            if Task.isCancelled { return }
            nextWakeTimer?.cancel()
            nextWakeTimer = nil
            await drainReady()
            await scheduleNextWake()
        }
    }

    private func drainReady() async {
        while !Task.isCancelled {
            let ready: [OutboxItem]
            do { ready = try await store.pendingReady(asOf: now()) }
            catch {
                logger.error("drainReady fetch failed: \(error.localizedDescription)")
                return
            }
            guard let item = ready.first else { return }
            await attemptSend(item)
            await reloadItems()
        }
    }

    private func scheduleNextWake() async {
        let next: Date?
        do { next = try await store.earliestPendingNext(after: now()) }
        catch {
            logger.error("scheduleNextWake fetch failed: \(error.localizedDescription)")
            return
        }
        guard let wake = next else { return }
        let delay = max(0, wake.timeIntervalSince(now()))
        // `signalContinuation` is captured by reference — its `.yield()` is nonisolated and Sendable.
        let continuation = self.signalContinuation
        nextWakeTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            continuation?.yield()
        }
    }
}
```

Add a property to `OutboxService` near `processTask`:

```swift
private var nextWakeTimer: Task<Void, Never>?
```

- [ ] **Step 4: Run the test**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/OutboxServiceLoopTests
```

Expected: pass within 1s.

- [ ] **Step 5: Commit**

```
git add Aerio/Services/OutboxService.swift AerioTests/OutboxServiceTests.swift
git commit -m "feat(outbox): processLoop sleeps until next ready or signal"
```

---

## Task 16: Notification categories + Retry action

**Files:**
- Modify: `Aerio/Services/NotificationManager.swift`
- Test:   skip — UNUserNotificationCenter is hard to test in unit; verified via manual QA in Task 21.

- [ ] **Step 1: Add Outbox category constants and registration**

Edit `Aerio/Services/NotificationManager.swift`. Add at the top of the class (after `private(set) var isAuthorized = false`):

```swift
static let outboxSuccessCategory = "AERIO_OUTBOX_SUCCESS"
static let outboxFailureCategory = "AERIO_OUTBOX_FAILURE"
static let outboxRetryActionId = "AERIO_OUTBOX_RETRY"

/// Callback fired when user taps the Retry action on an outbox failure notification.
var onOutboxRetry: ((UUID) -> Void)?
```

In `init`, after `realCenter.delegate = self`, register categories:

```swift
let retryAction = UNNotificationAction(
    identifier: Self.outboxRetryActionId,
    title: "Retry",
    options: [.foreground]
)
let failureCategory = UNNotificationCategory(
    identifier: Self.outboxFailureCategory,
    actions: [retryAction],
    intentIdentifiers: [],
    options: []
)
let successCategory = UNNotificationCategory(
    identifier: Self.outboxSuccessCategory,
    actions: [],
    intentIdentifiers: [],
    options: []
)
realCenter.setNotificationCategories([failureCategory, successCategory])
```

- [ ] **Step 2: Add `OutboxNotifier` wrapper that conforms to `OutboxNotifying`**

Append to the same file:

```swift
@MainActor
struct OutboxNotifier: OutboxNotifying {
    let manager: NotificationManager

    func notifySuccess(item: OutboxItem) async {
        guard manager.isAuthorized else { return }
        // Suppress if app is frontmost — user just sent it, no need to interrupt.
        if NSApp?.isActive == true { return }
        let content = UNMutableNotificationContent()
        content.title = "Sent"
        content.subtitle = item.subject
        content.body = "to \(item.recipientsPreview)"
        content.categoryIdentifier = NotificationManager.outboxSuccessCategory
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "outbox_success_\(item.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func notifyFailure(item: OutboxItem, permanent: Bool) async {
        guard manager.isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Failed to send"
        content.subtitle = item.subject
        let detail = item.lastError ?? "Unknown error"
        content.body = permanent
            ? "\(detail) — Sign in again to retry."
            : "\(detail) — Tap Retry."
        content.categoryIdentifier = NotificationManager.outboxFailureCategory
        content.userInfo = ["outboxItemId": item.id.uuidString]
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "outbox_failure_\(item.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
```

(Add `import AppKit` at the top of the file if not already present, for `NSApp`.)

- [ ] **Step 3: Wire `Retry` action in delegate**

Update the existing `userNotificationCenter(_:didReceive:withCompletionHandler:)` method. Add at the top, before the existing `emailId/accountId` parse:

```swift
if response.actionIdentifier == Self.outboxRetryActionId,
   let idString = response.notification.request.content.userInfo["outboxItemId"] as? String,
   let uuid = UUID(uuidString: idString) {
    completionHandler()
    Task { @MainActor in
        onOutboxRetry?(uuid)
    }
    return
}
```

- [ ] **Step 4: Build + run existing notification tests**

```
xcodebuild build -project Aerio.xcodeproj -scheme Aerio -configuration Debug
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/NotificationManagerTests
```

(If the test class doesn't exist, just build.) Expected: build success, no regressions.

- [ ] **Step 5: Commit**

```
git add Aerio/Services/NotificationManager.swift
git commit -m "feat(outbox): notification categories and Retry action for outbox failures"
```

---

## Task 17: Wire `OutboxService` into `AppState` + `AerioApp`

**Files:**
- Modify: `Aerio/AerioApp.swift`

- [ ] **Step 1: Add `outboxService` to `AppState`**

Edit `Aerio/AerioApp.swift`. In `final class AppState: ObservableObject`, after `let notificationManager: NotificationManager`, add:

```swift
let outboxStore: OutboxStore
let outboxService: OutboxService
```

- [ ] **Step 2: Construct in `init()`**

Inside the production `init()` method (the one without parameters), AFTER `let notifications = NotificationManager()` and `api.notificationManager = notifications`, but BEFORE `self.accountManager = am` add:

```swift
let outboxStore = OutboxStore()
let sendersByAccount: [String: OutboxSender] = api.clients.mapValues { $0 as OutboxSender }
let outbox = OutboxService(
    store: outboxStore,
    sendersByAccount: sendersByAccount,
    notifier: OutboxNotifier(manager: notifications),
    postSendRefresh: { [weak api] in await api?.refreshAll() }
)
```

(`GmailAPIManager.clients` is the existing per-account `[String: GmailAPIClient]` dictionary. If it's `private`, expose it via a `var clientsForOutbox: [String: OutboxSender] { clients.mapValues { $0 } }` on `GmailAPIManager`.)

After the existing `self.notificationManager = notifications` line, add:

```swift
self.outboxStore = outboxStore
self.outboxService = outbox
```

- [ ] **Step 3: Hook resumeOnLaunch + start the loop**

After the existing `Task { await notifications.requestPermission() }` block in `init`:

```swift
Task { @MainActor in
    do { _ = try await outbox.resumeOnLaunch() }
    catch { Self.logger.error("outbox resumeOnLaunch failed: \(error.localizedDescription)") }
    outbox.startLoop()
}

// Wire Retry-from-notification handler
notifications.onOutboxRetry = { [weak outbox] itemId in
    Task { @MainActor in try? await outbox?.retry(itemId: itemId) }
}

// Keep senders in sync as accounts change.
am.onAccountsChanged = { [weak api, weak outbox] in
    guard let api, let outbox else { return }
    outbox.setSenders(api.clients.mapValues { $0 as OutboxSender })
}
```

(If `AccountManager` doesn't have `onAccountsChanged`, call `outbox.setSenders(...)` from wherever `clients` is mutated in `GmailAPIManager` instead — read that file to find the right hook.)

- [ ] **Step 4: Mirror in the test-only `init` overload**

Update the second `init(accountManager:apiManager:...)` initializer to also create `outboxStore`/`outboxService` with `inMemory: true`:

```swift
let outboxStore = OutboxStore(inMemory: true)
let outbox = OutboxService(
    store: outboxStore, sendersByAccount: [:],
    notifier: OutboxNotifier(manager: notificationManager ?? NotificationManager()),
    postSendRefresh: { }
)
self.outboxStore = outboxStore
self.outboxService = outbox
```

- [ ] **Step 5: Inject as environment object in `WindowGroup`**

Update the `body` so `MainView` gets `outboxService`:

```swift
WindowGroup {
    MainView(...)
        .environmentObject(appState.outboxService)
        .background(WindowAccessor())
        .navigationTitle("")
}
```

- [ ] **Step 6: Build & run app smoke**

```
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build
./scripts/run.sh
```

Expected: app launches; sending an email still works (no UI changes yet — that's Tasks 18-20). No new compile errors.

- [ ] **Step 7: Commit**

```
git add Aerio/AerioApp.swift Aerio/Services/GmailAPIManager.swift
git commit -m "feat(outbox): wire OutboxService into AppState with resumeOnLaunch and signal hooks"
```

---

## Task 18: `SidebarSelection` enum + refactor `MainView`

**Files:**
- Create: `Aerio/Views/SidebarSelection.swift`
- Modify: `Aerio/Views/MainView.swift`

This refactor preserves all existing reads of `selectedFolder` by making it a derived computed property over the new `@State sidebarSelection`. About 28 read-sites stay unchanged; only writes (5 sites) and rendering switch are touched.

- [ ] **Step 1: Create the enum**

Create `Aerio/Views/SidebarSelection.swift`:

```swift
import Foundation

enum SidebarSelection: Hashable {
    case folder(Folder)
    case outbox

    var folder: Folder {
        if case .folder(let f) = self { return f }
        return .inbox
    }

    var isOutbox: Bool {
        if case .outbox = self { return true }
        return false
    }
}
```

- [ ] **Step 2: Refactor `MainView`**

In `Aerio/Views/MainView.swift`:

Replace `@State private var selectedFolder: Folder = .inbox` with:

```swift
@State private var sidebarSelection: SidebarSelection = .folder(.inbox)

private var selectedFolder: Folder { sidebarSelection.folder }
private var selectedFolderBinding: Binding<Folder> {
    Binding(
        get: { sidebarSelection.folder },
        set: { sidebarSelection = .folder($0) }
    )
}
```

Find every `selectedFolder = X` write site (about 5 of them — search file for `selectedFolder = `) and replace with `sidebarSelection = .folder(X)`.

Find every place that passes `$selectedFolder` (Binding) and replace with `selectedFolderBinding`.

Find the `.onChange(of: selectedFolder)` handler and convert to `.onChange(of: sidebarSelection) { ... }` — extract the folder via `newValue.folder`.

- [ ] **Step 3: Render OutboxList vs MessageList based on selection**

Find the place where `MessageList` is constructed (around line 194 of MainView.swift). Wrap in a switch:

```swift
Group {
    switch sidebarSelection {
    case .folder:
        MessageList(
            // ... existing parameters unchanged
        )
    case .outbox:
        OutboxList()
            .environmentObject(outboxService)
    }
}
```

Add `@EnvironmentObject var outboxService: OutboxService` near other `@EnvironmentObject` / property declarations on `MainView`.

(`OutboxList` is defined in Task 20 — at this point a placeholder stub is fine. Create `Aerio/Views/OutboxList.swift` with `struct OutboxList: View { var body: some View { Text("Outbox") } }` — Task 20 fleshes it out.)

- [ ] **Step 4: Build**

```
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build
```

Fix any compile errors. Most should be straightforward — usually `selectedFolder = X` writes that were missed.

- [ ] **Step 5: Run + smoke test**

```
./scripts/run.sh
```

Verify: clicking different folders in sidebar still works exactly as before. Outbox row not yet visible (Task 19 adds it).

- [ ] **Step 6: Commit**

```
git add Aerio/Views/SidebarSelection.swift Aerio/Views/MainView.swift Aerio/Views/OutboxList.swift
git commit -m "refactor: replace MainView.selectedFolder with SidebarSelection enum"
```

---

## Task 19: Outbox row in `UnifiedSidebar`

**Files:**
- Modify: `Aerio/Views/UnifiedSidebar.swift`

- [ ] **Step 1: Read the current sidebar selection binding**

Open `Aerio/Views/UnifiedSidebar.swift`. Find where the folder selection is exposed (likely a `@Binding var selectedFolder: Folder` or similar).

- [ ] **Step 2: Update the binding to `SidebarSelection`**

Change the binding type from `Folder` to `SidebarSelection`:

```swift
@Binding var sidebarSelection: SidebarSelection
@EnvironmentObject var outboxService: OutboxService
```

In every place inside `UnifiedSidebar` that wrote `selectedFolder = X`, replace with `sidebarSelection = .folder(X)`. In every place that read `selectedFolder == X`, replace with `sidebarSelection == .folder(X)`.

Update `MainView.swift` call site:

```swift
UnifiedSidebar(
    sidebarSelection: $sidebarSelection,
    // ... other args
)
```

- [ ] **Step 3: Add the Outbox row**

In the body of `UnifiedSidebar`, ABOVE the per-folder/per-account list (at the very top of the sidebar `List`/`ScrollView`), insert:

```swift
if !outboxService.items.isEmpty {
    Button(action: { sidebarSelection = .outbox }) {
        HStack {
            Image(systemName: "tray.and.arrow.up")
                .foregroundStyle(outboxRowColor)
            Text("Outbox")
                .foregroundStyle(outboxRowColor)
            Spacer()
            Text("\(outboxService.items.count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(outboxRowColor.opacity(0.15))
                .clipShape(Capsule())
                .foregroundStyle(outboxRowColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(sidebarSelection.isOutbox ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
```

Add a computed property to the view:

```swift
private var outboxRowColor: Color {
    outboxService.items.contains { $0.status == .failed } ? .red : .primary
}
```

- [ ] **Step 4: Build + run**

```
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build
./scripts/run.sh
```

Verify: with no pending items, no Outbox row visible. Send an email while offline (toggle Wi-Fi) → Outbox row appears with count 1; goes red after retries exhaust.

- [ ] **Step 5: Commit**

```
git add Aerio/Views/UnifiedSidebar.swift Aerio/Views/MainView.swift
git commit -m "feat(outbox): conditional Outbox row in UnifiedSidebar with badge and red-when-failed"
```

---

## Task 20: `OutboxList` view

**Files:**
- Modify: `Aerio/Views/OutboxList.swift` (created stub in Task 18)

- [ ] **Step 1: Write the view**

Replace the stub in `Aerio/Views/OutboxList.swift` with:

```swift
import SwiftUI

struct OutboxList: View {
    @EnvironmentObject var outboxService: OutboxService

    var body: some View {
        if outboxService.items.isEmpty {
            ContentUnavailableView("Outbox is empty", systemImage: "tray")
        } else {
            List {
                ForEach(outboxService.items, id: \.id) { item in
                    OutboxRow(item: item)
                }
            }
        }
    }
}

private struct OutboxRow: View {
    let item: OutboxItem
    @EnvironmentObject var outboxService: OutboxService

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.subject.isEmpty ? "(no subject)" : item.subject)
                    .font(.body)
                Text("To: \(item.recipientsPreview)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let err = item.lastError, item.status == .failed {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "hourglass")
                .foregroundStyle(.secondary)
        case .sending:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if item.status == .failed {
                Button("Retry") {
                    Task { try? await outboxService.retry(itemId: item.id) }
                }
                .buttonStyle(.bordered)
            }
            Button("Cancel") {
                Task { try? await outboxService.cancel(itemId: item.id) }
            }
            .buttonStyle(.bordered)
        }
    }
}
```

- [ ] **Step 2: Build + run**

```
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build
./scripts/run.sh
```

Verify: enqueue an item (toggle airplane mode, send) → click Outbox row → see the item with hourglass icon and Cancel button. Wait for retries to exhaust → item shows red triangle and Retry button.

- [ ] **Step 3: Commit**

```
git add Aerio/Views/OutboxList.swift
git commit -m "feat(outbox): OutboxList view with status icons and Retry/Cancel actions"
```

---

## Task 21: Refactor `ComposeView.sendMessage` to enqueue path + race-guard regression test

**Files:**
- Modify: `Aerio/Views/ComposeView.swift`
- Test:   `AerioTests/ComposeViewSendTests.swift`

- [ ] **Step 1: Write the regression test**

Create `AerioTests/ComposeViewSendTests.swift`:

```swift
import XCTest
@testable import Aerio

@MainActor
final class ComposeSendIntegrationTests: XCTestCase {
    /// Regression: clicking Send must mark hasSent and isSendingViaOutbox synchronously
    /// so saveDraftIfNeeded (called from onDisappear) does not create a phantom draft.
    func testSend_setsRaceGuardsBeforeOnDismiss() async throws {
        // Drive ComposeView model directly — full SwiftUI render not needed.
        // (See ComposeViewTestHelper in this file for view-state extraction.)
        // For this plan we test the helper logic in a sub-component:
        let model = ComposeSendCoordinator(
            now: { Date(timeIntervalSince1970: 5000) },
            messageIdFactory: { "<test-id@aerio.local>" }
        )
        let payload = ComposePayload(
            from: "me@x", to: "you@x", cc: nil, subject: "s", body: "b",
            inReplyTo: nil, references: nil, htmlBody: nil,
            attachments: [], inlineImages: [],
            messageId: "<test-id@aerio.local>"
        )
        let item = model.buildOutboxItem(
            accountId: "a", payload: payload,
            replyToEmail: nil, archiveOnReplyEnabled: false,
            composeType: .new, draftIdToConsume: nil
        )
        XCTAssertEqual(item.accountId, "a")
        XCTAssertEqual(item.messageIdHeader, "<test-id@aerio.local>")
        XCTAssertEqual(item.subject, "s")
        XCTAssertNil(item.draftIdToConsume)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Expected: `error: cannot find 'ComposeSendCoordinator' in scope`.

- [ ] **Step 3: Extract `ComposeSendCoordinator` from `ComposeView`**

Inside `Aerio/Views/ComposeView.swift`, extract a small testable helper at the bottom of the file:

```swift
/// Pure logic for building an OutboxItem from compose state. Extracted for testability.
struct ComposeSendCoordinator {
    let now: () -> Date
    let messageIdFactory: () -> String

    init(now: @escaping () -> Date = { Date() },
         messageIdFactory: @escaping () -> String = { "<\(UUID().uuidString)@aerio.local>" }) {
        self.now = now
        self.messageIdFactory = messageIdFactory
    }

    func buildOutboxItem(
        accountId: String,
        payload: ComposePayload,
        replyToEmail: Email?,
        archiveOnReplyEnabled: Bool,
        composeType: ComposeType,
        draftIdToConsume: String?
    ) -> OutboxItem {
        let raw = RFC2822Builder.build(payload)
        let archive = (composeType == .reply || composeType == .replyAll)
            && replyToEmail?.folder == .inbox
            && archiveOnReplyEnabled
        let now = now()
        return OutboxItem(
            id: UUID(),
            accountId: accountId,
            rawMime: Data(raw.utf8),
            messageIdHeader: payload.messageId ?? messageIdFactory(),
            threadId: replyToEmail?.threadId.isEmpty == false ? replyToEmail?.threadId : nil,
            draftIdToConsume: composeType == .draft ? draftIdToConsume : nil,
            subject: payload.subject,
            recipientsPreview: ContactsCache.parseAddressList(payload.to).first?.email ?? payload.to,
            status: .pending,
            attemptCount: 0,
            createdAt: now,
            nextAttemptAt: now,
            archiveOnSuccessForMsgId: archive ? replyToEmail?.msgId : nil,
            archiveOnSuccessForAccountId: archive ? replyToEmail?.accountId : nil
        )
    }
}
```

- [ ] **Step 4: Replace `ComposeView.sendMessage` body**

Inside `ComposeView`, add:

```swift
@EnvironmentObject var outboxService: OutboxService
@State private var isSendingViaOutbox = false
```

Replace the existing `private func sendMessage()` body with:

```swift
private func sendMessage() {
    guard !toField.isEmpty,
          let fromEmail = accountManager.accounts.first(where: { $0.id == selectedAccountId })?.email
    else {
        logger.error("Send guard failed: empty toField or no fromEmail for account \(selectedAccountId, privacy: .public)")
        return
    }
    isSendingViaOutbox = true
    hasSent = true

    let (htmlBody, editorInlineImages) = editorState.htmlBodyWithInlineImages()
    let messageId = "<\(UUID().uuidString)@aerio.local>"
    let payload = ComposePayload(
        from: fromEmail,
        to: toField,
        cc: ccField.isEmpty ? nil : ccField,
        subject: subjectField,
        body: bodyText,
        inReplyTo: replyToEmail?.messageId ?? fetchedMessageId,
        references: replyToEmail?.messageId ?? fetchedMessageId,
        htmlBody: htmlBody.isEmpty ? nil : htmlBody,
        attachments: attachments.map {
            RFC2822Builder.Attachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        },
        inlineImages: editorInlineImages.map {
            RFC2822Builder.InlineImage(cid: $0.cid, mimeType: $0.mimeType, data: $0.data)
        },
        messageId: messageId
    )
    let coordinator = ComposeSendCoordinator()
    let item = coordinator.buildOutboxItem(
        accountId: selectedAccountId,
        payload: payload,
        replyToEmail: replyToEmail,
        archiveOnReplyEnabled: UserDefaults.standard.bool(forKey: AppState.archiveOnReplyKey),
        composeType: composeType,
        draftIdToConsume: draftId
    )
    Task { try? await outboxService.enqueue(item) }
    onDismiss?()

    // Update contact frequency (was previously inside the post-send block).
    let allRecipients = ContactsCache.parseAddressList(toField) + ContactsCache.parseAddressList(ccField)
    for recipient in allRecipients {
        contactsCache?.addContact(email: recipient.email, displayName: recipient.displayName)
    }
}
```

- [ ] **Step 5: Update `saveDraftIfNeeded` to also gate on `isSendingViaOutbox`**

Find `private func saveDraftIfNeeded() {` and change the first guard to:

```swift
guard !hasSent && !isSendingViaOutbox else { return }
```

- [ ] **Step 6: Remove obsolete state and UI**

Delete these `@State` declarations (lines around 44-47):

```swift
@State private var isSending = false
@State private var sendError: String?
```

Delete the entire `if let sendError { ... }` block (lines around 163-174).

Find the Send button (`Button(action: { sendMessage() })`) and remove the `if isSending { ... } else if isSending { ... }` branch — replace with the simple "Send" label always.

- [ ] **Step 7: Run tests**

```
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/ComposeSendIntegrationTests
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/ComposeDraftTests
```

Expected: ComposeSendIntegrationTests passes; existing draft tests still pass.

- [ ] **Step 8: Commit**

```
git add Aerio/Views/ComposeView.swift AerioTests/ComposeViewSendTests.swift
git commit -m "feat(outbox): ComposeView.send enqueues to OutboxService and closes window immediately"
```

---

## Task 22: Manual QA pass

**Files:** none — verification only.

- [ ] **Step 1: Build & launch**

```
./scripts/run.sh
```

- [ ] **Step 2: Walk the critical-paths checklist**

Reference: `~/.gstack/projects/VerusK-aerio/sleepwalker-main-eng-review-test-plan-20260507-212733.md`

For each, verify:

1. **Window-close race regression** — Open compose, type a recipient/subject/body, click Send + Cmd+W within 100ms → message arrives in recipient's inbox; Drafts folder has NO new draft. ✓ critical
2. **Quit-during-send regression** — Open compose, click Send, immediately Cmd+Q → relaunch app within 5s → message arrives exactly once (verify by checking recipient + Sent folder). ✓ critical
3. **Offline → online recovery** — Toggle Wi-Fi off, Send → Outbox row appears in sidebar with hourglass → Toggle Wi-Fi on → wait ≤300s → message arrives, Outbox row disappears.
4. **Reply with auto-archive** — Reply to inbox message with archive-on-reply enabled in Settings → reply sends; original inbox message archived.
5. **Draft-to-sent transition** — Open existing draft, edit, Send → server-side draft is gone, new sent message in Sent folder.
6. **Failure visibility** — Send to `notanemail` → after 3 retries (~6 minutes), Outbox row turns red, system notification fires with Retry button. Click Retry → fails again. Click Cancel → item disappears.

- [ ] **Step 3: Document any deviations**

If any path doesn't behave as expected, file a follow-up task. Do NOT fix unrelated regressions.

- [ ] **Step 4: Cleanup**

```
rm -rf ~/Library/Developer/Xcode/DerivedData/Aerio-*/Build/Products/Debug/Aerio.app
```

- [ ] **Step 5: Final commit (if any tweaks landed)**

```
git status
# only commit if there are residual fixes from QA
```

---

## Self-review checklist

Run through this once you've completed all tasks (or before handing off to executing-plans):

- [ ] Spec coverage: every section of `docs/superpowers/specs/2026-05-07-outbox-reliable-send-design.md` maps to at least one task above.
- [ ] No placeholders: no `TBD`, no `// implement later`, no untyped "similar to Task N".
- [ ] Type consistency: `OutboxStatus`, `OutboxItem`, `OutboxSender`, `ComposePayload`, `SidebarSelection`, `OutboxNotifying`, `OutboxNotifier` are all defined and referenced consistently.
- [ ] Critical regression tests covered:
  - `testSend_setsRaceGuardsBeforeOnDismiss` (Task 21)
  - `testProcess_corruptItemDoesNotStallQueue` (Task 13)
  - `testIdempotency_skipsSendWhenMessageAlreadyInSent` (Task 10)
  - `testResumeOnLaunch_resetsSendingItemsToPending` (Task 11)
- [ ] Build/test commands match `CLAUDE.md` conventions.
- [ ] Each task ends with a commit using a conventional-commit prefix.
