# Performance, Scroll Stability & Reply-to-Sent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three interrelated issues: app-wide performance degradation from unbounded cache loading, scroll/focus loss on new emails, and reply-to-sent replying to self instead of original recipient.

**Architecture:** Incremental merge replaces wholesale array replacement in UnifiedMailbox, scoped cache loading with limits in DataStore, in-memory HTML content cache in MessageWebView, and sent-aware reply logic with new `to`/`cc` fields on Email model.

**Tech Stack:** Swift, SwiftUI, SwiftData, WKWebView, Gmail REST API

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Aerio/Models/Email.swift` | Modify | Add `to`, `cc` fields |
| `Aerio/Persistence/DataStore.swift` | Modify | Add `to`/`cc` to CachedEmail, scoped loading with fetchLimit, purgeOldEmails |
| `Aerio/Services/UnifiedMailbox.swift` | Modify | Incremental merge instead of full rebuild |
| `Aerio/Services/GmailAPIManager.swift` | Modify | Add To/Cc to metadata headers, use merge instead of array replacement |
| `Aerio/Views/MessageWebView.swift` | Modify | In-memory HTML content cache |
| `Aerio/Views/MessageList.swift` | Modify | Remove fragile count-based scroll logic |
| `Aerio/Views/ComposeView.swift` | Modify | Sent-aware reply logic |
| `Aerio/Views/MainView.swift` | Modify | Guard duplicate folder onChange |
| `AerioTests/ModelTests.swift` | Modify | Tests for Email to/cc fields |
| `AerioTests/DataStoreTests.swift` | Modify | Tests for scoped loading, purge, to/cc persistence |
| `AerioTests/UnifiedMailboxTests.swift` | Modify | Tests for incremental merge |
| `AerioTests/GmailAPIManagerTests.swift` | Modify | Tests for To/Cc in metadata headers |

---

### Task 1: Add `to` and `cc` fields to Email model

**Files:**
- Modify: `Aerio/Models/Email.swift:3-41`
- Test: `AerioTests/ModelTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `AerioTests/ModelTests.swift`:

```swift
func testEmailToCcFields() {
    let email = Email(
        msgId: "msg1",
        from: "me@test.com",
        subject: "Test",
        date: Date(),
        snippet: "preview",
        accountId: "acc1",
        folder: .sent,
        to: "recipient@test.com",
        cc: "cc@test.com"
    )
    XCTAssertEqual(email.to, "recipient@test.com")
    XCTAssertEqual(email.cc, "cc@test.com")
}

func testEmailToCcDefaultsToEmpty() {
    let email = Email(
        msgId: "msg1",
        from: "me@test.com",
        subject: "Test",
        date: Date(),
        snippet: "preview",
        accountId: "acc1",
        folder: .inbox
    )
    XCTAssertEqual(email.to, "")
    XCTAssertEqual(email.cc, "")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/ModelTests 2>&1 | tail -20`
Expected: Compilation error — `to` and `cc` parameters don't exist on Email init.

- [ ] **Step 3: Add `to` and `cc` to Email struct**

In `Aerio/Models/Email.swift`, add the fields and update init:

```swift
struct Email: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let msgId: String
    let from: String
    let to: String
    let cc: String
    let subject: String
    let date: Date
    let snippet: String
    var isRead: Bool
    let accountId: String
    let folder: Folder
    let messageId: String?

    init(
        msgId: String,
        from: String,
        subject: String,
        date: Date,
        snippet: String,
        isRead: Bool = false,
        accountId: String,
        folder: Folder,
        messageId: String? = nil,
        to: String = "",
        cc: String = ""
    ) {
        self.id = "\(accountId)_\(folder.rawValue)_\(msgId)"
        self.msgId = msgId
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.snippet = snippet
        self.isRead = isRead
        self.accountId = accountId
        self.folder = folder
        self.messageId = messageId
    }
}
```

Note: `to` and `cc` are at the end of the init with defaults so all existing callers compile without changes.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/ModelTests 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Aerio/Models/Email.swift AerioTests/ModelTests.swift
git commit -m "feat: add to and cc fields to Email model"
```

---

### Task 2: Persist `to`/`cc` in CachedEmail and add scoped loading + purge

**Files:**
- Modify: `Aerio/Persistence/DataStore.swift:7-47` (CachedEmail), `137-152` (loadEmails), new purgeOldEmails
- Test: `AerioTests/DataStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `AerioTests/DataStoreTests.swift`:

```swift
func testSaveAndLoadPreservesToCc() {
    let store = makeStore()
    let email = Email(
        msgId: "msg1",
        from: "me@test.com",
        subject: "Test",
        date: Date(),
        snippet: "preview",
        accountId: "acc1",
        folder: .sent,
        to: "recipient@test.com",
        cc: "cc@test.com"
    )
    store.saveEmails([email])
    let loaded = store.loadEmails(for: "acc1")
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded[0].to, "recipient@test.com")
    XCTAssertEqual(loaded[0].cc, "cc@test.com")
}

func testLoadEmailsScopedByFolderWithLimit() {
    let store = makeStore()
    var emails: [Email] = []
    for i in 0..<10 {
        emails.append(Email(
            msgId: "msg\(i)",
            from: "sender@test.com",
            subject: "Subject \(i)",
            date: Date().addingTimeInterval(Double(-i * 60)),
            snippet: "snippet",
            accountId: "acc1",
            folder: .inbox
        ))
    }
    // Also add a sent email — should not appear
    emails.append(Email(
        msgId: "sent1",
        from: "me@test.com",
        subject: "Sent",
        date: Date(),
        snippet: "snippet",
        accountId: "acc1",
        folder: .sent
    ))
    store.saveEmails(emails)

    let loaded = store.loadEmails(for: "acc1", folder: .inbox, limit: 5)
    XCTAssertEqual(loaded.count, 5)
    // Should be sorted by date desc — most recent first
    XCTAssertEqual(loaded[0].msgId, "msg0")
}

func testPurgeOldEmails() {
    let store = makeStore()
    var emails: [Email] = []
    for i in 0..<5 {
        emails.append(Email(
            msgId: "msg\(i)",
            from: "sender@test.com",
            subject: "Subject \(i)",
            date: Date().addingTimeInterval(Double(-i * 3600)),
            snippet: "snippet",
            accountId: "acc1",
            folder: .inbox
        ))
    }
    store.saveEmails(emails)
    XCTAssertEqual(store.emailCount, 5)

    store.purgeOldEmails(keepLast: 3)
    XCTAssertEqual(store.emailCount, 3)

    // Kept the 3 most recent
    let loaded = store.loadEmails(for: "acc1")
    XCTAssertEqual(loaded[0].msgId, "msg0")
    XCTAssertEqual(loaded[2].msgId, "msg2")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/EmailCacheTests 2>&1 | tail -20`
Expected: Compilation errors — `to`/`cc` not on CachedEmail, no `folder:limit:` overload, no `purgeOldEmails`.

- [ ] **Step 3: Update CachedEmail with `to`/`cc`, add scoped loading and purge**

In `Aerio/Persistence/DataStore.swift`:

**CachedEmail** — add `to` and `cc` properties (optional for migration):

```swift
@Model
final class CachedEmail {
    @Attribute(.unique) var id: String
    var msgId: String
    var from: String
    var to: String?
    var cc: String?
    var subject: String
    var date: Date
    var snippet: String
    var isRead: Bool
    var accountId: String
    var folderRaw: String
    var messageId: String?

    init(from email: Email) {
        self.id = email.id
        self.msgId = email.msgId
        self.from = email.from
        self.to = email.to
        self.cc = email.cc
        self.subject = email.subject
        self.date = email.date
        self.snippet = email.snippet
        self.isRead = email.isRead
        self.accountId = email.accountId
        self.folderRaw = email.folder.rawValue
        self.messageId = email.messageId
    }

    func toEmail() -> Email? {
        guard let folder = Folder(rawValue: folderRaw) else { return nil }
        return Email(
            msgId: msgId,
            from: from,
            subject: subject,
            date: date,
            snippet: snippet,
            isRead: isRead,
            accountId: accountId,
            folder: folder,
            messageId: messageId,
            to: to ?? "",
            cc: cc ?? ""
        )
    }
}
```

Also update `saveEmails` to persist `to`/`cc`:

```swift
if let existing {
    existing.from = email.from
    existing.to = email.to
    existing.cc = email.cc
    existing.subject = email.subject
    // ... rest unchanged
}
```

**Add scoped loading overload** (keep existing `loadEmails(for:)` for backward compatibility):

```swift
func loadEmails(for accountId: String, folder: Folder, limit: Int = 200) -> [Email] {
    let folderRaw = folder.rawValue
    var descriptor = FetchDescriptor<CachedEmail>(
        predicate: #Predicate { $0.accountId == accountId && $0.folderRaw == folderRaw },
        sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    let cached = (try? modelContext.fetch(descriptor)) ?? []
    return cached.compactMap { $0.toEmail() }
}
```

**Add purgeOldEmails:**

```swift
func purgeOldEmails(keepLast: Int) {
    let descriptor = FetchDescriptor<CachedEmail>(
        sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    let all = (try? modelContext.fetch(descriptor)) ?? []
    guard all.count > keepLast else { return }
    let toDelete = all.dropFirst(keepLast)
    for item in toDelete {
        modelContext.delete(item)
    }
    do {
        try modelContext.save()
        logger.info("Purged \(toDelete.count) old cached emails, keeping \(keepLast)")
    } catch {
        logger.error("Failed to purge old emails: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/EmailCacheTests 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Aerio/Persistence/DataStore.swift AerioTests/DataStoreTests.swift
git commit -m "feat: add to/cc to CachedEmail, scoped loading with limit, purgeOldEmails"
```

---

### Task 3: Parse To/Cc from Gmail API metadata headers

**Files:**
- Modify: `Aerio/Services/GmailAPIManager.swift:247,389,481,777` (metadataHeaders), `857-887` (convertGmailMessageToEmail)
- Test: `AerioTests/GmailAPIManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `AerioTests/GmailAPIManagerTests.swift`:

```swift
func testConvertGmailMessageIncludesToCc() {
    let (_, api) = makeManager()
    let message = GmailMessage(
        id: "msg1",
        threadId: "thread1",
        labelIds: ["INBOX", "UNREAD"],
        snippet: "Hello",
        historyId: "12345",
        internalDate: String(Int(Date().timeIntervalSince1970 * 1000)),
        payload: GmailPayload(
            mimeType: "text/plain",
            headers: [
                GmailHeader(name: "From", value: "sender@test.com"),
                GmailHeader(name: "To", value: "recipient@test.com"),
                GmailHeader(name: "Cc", value: "cc1@test.com, cc2@test.com"),
                GmailHeader(name: "Subject", value: "Test Subject"),
                GmailHeader(name: "Date", value: "Mon, 31 Mar 2026 10:00:00 +0000"),
            ],
            body: nil,
            parts: nil,
            filename: nil
        ),
        sizeEstimate: nil
    )
    let email = api.convertGmailMessageToEmail(message, accountId: "acc1", folder: .inbox)
    XCTAssertNotNil(email)
    XCTAssertEqual(email?.to, "recipient@test.com")
    XCTAssertEqual(email?.cc, "cc1@test.com, cc2@test.com")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/GmailAPIManagerTests/testConvertGmailMessageIncludesToCc 2>&1 | tail -20`
Expected: FAIL — `email?.to` is `""`, `email?.cc` is `""`.

- [ ] **Step 3: Update convertGmailMessageToEmail and metadata header requests**

In `Aerio/Services/GmailAPIManager.swift`:

**Update `convertGmailMessageToEmail`** (around line 863-887) — add To/Cc parsing:

```swift
let from = headers.first(where: { $0.name.lowercased() == "from" })?.value ?? ""
let to = headers.first(where: { $0.name.lowercased() == "to" })?.value ?? ""
let cc = headers.first(where: { $0.name.lowercased() == "cc" })?.value ?? ""
let subject = headers.first(where: { $0.name.lowercased() == "subject" })?.value ?? "(No Subject)"
```

And in the return statement:

```swift
return Email(
    msgId: message.id,
    from: from,
    subject: subject,
    date: date,
    snippet: snippet,
    isRead: isRead,
    accountId: accountId,
    folder: folder,
    messageId: messageId,
    to: to,
    cc: cc
)
```

**Update all 4 metadataHeaders arrays** (lines 247, 389, 481, 777) — add "To" and "Cc":

```swift
metadataHeaders: ["From", "To", "Cc", "Subject", "Date", "Message-ID"]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/GmailAPIManagerTests 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Aerio/Services/GmailAPIManager.swift AerioTests/GmailAPIManagerTests.swift
git commit -m "feat: parse To/Cc from Gmail API metadata headers"
```

---

### Task 4: Sent-aware reply logic in ComposeView

**Files:**
- Modify: `Aerio/Views/ComposeView.swift:487-511` (setupInitialValues), `558-611` (fetchReplyHeaders)

- [ ] **Step 1: Update setupInitialValues for sent folder**

In `Aerio/Views/ComposeView.swift`, update the reply/replyAll cases in `setupInitialValues()`:

```swift
case .reply:
    if email.folder == .sent {
        toField = email.to
    } else {
        toField = email.from
    }
    subjectField = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
    bodyText = "\n\n---\nOn \(email.date.formatted()), \(email.from) wrote:\n> \(email.snippet)"
    fetchReplyHeaders(email: email, includeAllRecipients: false)
case .replyAll:
    if email.folder == .sent {
        toField = email.to
        ccField = email.cc
    } else {
        toField = email.from
    }
    subjectField = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
    bodyText = "\n\n---\nOn \(email.date.formatted()), \(email.from) wrote:\n> \(email.snippet)"
    fetchReplyHeaders(email: email, includeAllRecipients: email.folder != .sent)
```

Note: For sent + replyAll, we set To and CC immediately from the model fields and skip `fetchReplyHeaders` recipient logic (pass `includeAllRecipients: false` effectively — or `email.folder != .sent`). The `fetchReplyHeaders` call still runs to capture Message-ID for threading.

- [ ] **Step 2: Update fetchReplyHeaders for sent folder**

In the `fetchReplyHeaders` method, update the Reply-To / To logic:

```swift
// Use Reply-To header if present (for non-sent emails), otherwise keep current toField
if email.folder != .sent {
    if let replyToHeader = headers.first(where: { $0.name.lowercased() == "reply-to" })?.value,
       !replyToHeader.isEmpty {
        toField = replyToHeader
    }
}

if includeAllRecipients {
    // ... existing replyAll logic (only runs for non-sent emails now)
}
```

For sent emails, `toField` and `ccField` are already set from `setupInitialValues`, so `fetchReplyHeaders` only grabs Message-ID for threading.

- [ ] **Step 3: Remove own address from CC for sent replyAll**

In `setupInitialValues`, after setting `ccField = email.cc` for sent replyAll, filter out the user's own email:

```swift
case .replyAll:
    if email.folder == .sent {
        toField = email.to
        // Remove self from CC
        let myEmail = accountManager.accounts.first { $0.id == email.accountId }?.email.lowercased() ?? ""
        let ccAddresses = email.cc.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        ccField = ccAddresses.filter { extractEmail(from: $0).lowercased() != myEmail }.joined(separator: ", ")
    } else {
        toField = email.from
    }
```

Note: `extractEmail(from:)` is already a private method in ComposeView (line 613).

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Aerio/Views/ComposeView.swift
git commit -m "feat: sent-aware reply uses original To/Cc instead of From"
```

---

### Task 5: Incremental merge in UnifiedMailbox

**Files:**
- Modify: `Aerio/Services/UnifiedMailbox.swift`
- Test: `AerioTests/UnifiedMailboxTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `AerioTests/UnifiedMailboxTests.swift`:

```swift
func testMergeEmailsInsertsNewAtCorrectPosition() {
    let (_, api) = makeManager()
    let mailbox = UnifiedMailbox(apiManager: api)

    let now = Date()
    let email1 = makeEmail(msgId: "m1", date: now.addingTimeInterval(-200), accountId: "acc1", folder: .inbox)
    let email3 = makeEmail(msgId: "m3", date: now, accountId: "acc1", folder: .inbox)

    api.emailsByAccount["acc1"] = [email1, email3]
    // Trigger initial build
    mailbox.selectedFolder = .inbox

    // Wait for Combine pipeline
    let expectation = XCTestExpectation(description: "emails rebuild")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        XCTAssertEqual(mailbox.emails.count, 2)
        XCTAssertEqual(mailbox.emails[0].msgId, "m3")
        XCTAssertEqual(mailbox.emails[1].msgId, "m1")

        // Now add a new email between the two
        let email2 = self.makeEmail(msgId: "m2", date: now.addingTimeInterval(-100), accountId: "acc1", folder: .inbox)
        api.emailsByAccount["acc1"] = [email1, email2, email3]

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(mailbox.emails.count, 3)
            XCTAssertEqual(mailbox.emails[0].msgId, "m3")
            XCTAssertEqual(mailbox.emails[1].msgId, "m2")
            XCTAssertEqual(mailbox.emails[2].msgId, "m1")
            expectation.fulfill()
        }
    }
    wait(for: [expectation], timeout: 2)
}

func testMergeEmailsRemovesDeleted() {
    let (_, api) = makeManager()
    let mailbox = UnifiedMailbox(apiManager: api)

    let now = Date()
    let email1 = makeEmail(msgId: "m1", date: now.addingTimeInterval(-100), accountId: "acc1", folder: .inbox)
    let email2 = makeEmail(msgId: "m2", date: now, accountId: "acc1", folder: .inbox)

    api.emailsByAccount["acc1"] = [email1, email2]
    mailbox.selectedFolder = .inbox

    let expectation = XCTestExpectation(description: "emails rebuild")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        XCTAssertEqual(mailbox.emails.count, 2)

        // Remove email1
        api.emailsByAccount["acc1"] = [email2]

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(mailbox.emails.count, 1)
            XCTAssertEqual(mailbox.emails[0].msgId, "m2")
            expectation.fulfill()
        }
    }
    wait(for: [expectation], timeout: 2)
}
```

- [ ] **Step 2: Run tests to verify they pass (baseline)**

These tests should already pass with the current `rebuildEmails` since the Combine pipeline still works. Run:

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/UnifiedMailboxTests 2>&1 | tail -20`
Expected: PASS — confirming the test setup is correct.

- [ ] **Step 3: Replace rebuildEmails with incremental merge**

Replace `rebuildEmails` in `Aerio/Services/UnifiedMailbox.swift`:

```swift
private func rebuildEmails(from emailsByAccount: [String: [Email]], folder: Folder, accountId: String?) {
    // Collect source emails for current view
    var sourceEmails: [Email]
    if let accountId {
        sourceEmails = emailsByAccount[accountId] ?? []
    } else {
        sourceEmails = emailsByAccount.values.flatMap { $0 }
    }
    sourceEmails = sourceEmails.filter { $0.folder == folder }

    // Incremental merge: compute diff by ID
    let newIds = Set(sourceEmails.map(\.id))
    let oldIds = Set(emails.map(\.id))

    let removedIds = oldIds.subtracting(newIds)
    let addedIds = newIds.subtracting(oldIds)

    // If nothing changed, skip update entirely
    if removedIds.isEmpty && addedIds.isEmpty {
        // Check for in-place updates (e.g. isRead changed)
        let oldById = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
        var needsUpdate = false
        for email in sourceEmails {
            if let old = oldById[email.id], old != email {
                needsUpdate = true
                break
            }
        }
        if !needsUpdate { return }
    }

    // Remove deleted
    if !removedIds.isEmpty {
        emails.removeAll { removedIds.contains($0.id) }
    }

    // Update existing emails in-place (e.g. isRead change)
    let sourceById = Dictionary(uniqueKeysWithValues: sourceEmails.map { ($0.id, $0) })
    for i in emails.indices {
        if let updated = sourceById[emails[i].id], updated != emails[i] {
            emails[i] = updated
        }
    }

    // Insert new emails at correct sorted position (date descending)
    let added = sourceEmails.filter { addedIds.contains($0.id) }
    for email in added {
        let insertIndex = emails.firstIndex { $0.date < email.date } ?? emails.endIndex
        emails.insert(email, at: insertIndex)
    }
}
```

Also optimize `emails(for:accountId:)` to avoid re-sorting when it's the current view:

```swift
func emails(for folder: Folder, accountId: String? = nil) -> [Email] {
    // Fast path: if requesting the current view, return cached sorted array
    if folder == selectedFolder && accountId == selectedAccountId {
        return emails
    }
    // Slow path: filter and sort from source
    let source: [Email]
    if let accountId {
        source = apiManager.emailsByAccount[accountId] ?? []
    } else {
        source = apiManager.emailsByAccount.values.flatMap { $0 }
    }
    return Email.sortedByDate(source.filter { $0.folder == folder })
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/UnifiedMailboxTests 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Aerio/Services/UnifiedMailbox.swift AerioTests/UnifiedMailboxTests.swift
git commit -m "perf: incremental merge in UnifiedMailbox instead of full rebuild"
```

---

### Task 6: Scoped cache loading in GmailAPIManager + purge

**Files:**
- Modify: `Aerio/Services/GmailAPIManager.swift:44-52` (loadCachedEmails), `284` (replaceEmails call), `434` (replaceEmails call)

- [ ] **Step 1: Update loadCachedEmails to use scoped loading**

In `Aerio/Services/GmailAPIManager.swift`, update `loadCachedEmails`:

```swift
private func loadCachedEmails(from dataStore: EmailCache) {
    for account in accountManager.accounts {
        let emails = dataStore.loadEmails(for: account.id, folder: currentFolder, limit: 200)
        logger.debug("Cache: loaded \(emails.count) emails for account \(account.id), folder=\(self.currentFolder.displayName)")
        if !emails.isEmpty {
            emailsByAccount[account.id] = emails
        }
    }
}
```

- [ ] **Step 2: Add purge call after sync**

In `incrementalSync`, after the `dataStore?.replaceEmails` loop (around line 434), add:

```swift
dataStore?.purgeOldEmails(keepLast: 1000)
```

- [ ] **Step 3: Build and run tests**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add Aerio/Services/GmailAPIManager.swift
git commit -m "perf: scoped cache loading with limit, purge old emails after sync"
```

---

### Task 7: In-memory HTML content cache in MessageWebView

**Files:**
- Modify: `Aerio/Views/MessageWebView.swift:187-240` (NativeMessageDetail), `446-596` (loadContent), `646-671` (BodyWebViewStore)

- [ ] **Step 1: Add content cache to BodyWebViewStore**

In `Aerio/Views/MessageWebView.swift`, add a static cache to `BodyWebViewStore`:

```swift
@MainActor
final class BodyWebViewStore: ObservableObject {
    let webView: WKWebView
    private let navigationDelegate = BodyWebViewNavigationDelegate()

    // In-memory HTML cache: email ID → rendered HTML
    private static var htmlCache: [String: String] = [:]
    private static let cacheLimit = 50

    init() {
        // ... existing init unchanged
    }

    func loadHTML(_ html: String, emailId: String? = nil) {
        if let emailId {
            // Evict oldest if over limit (simple: remove arbitrary entry)
            if Self.htmlCache.count >= Self.cacheLimit {
                Self.htmlCache.removeValue(forKey: Self.htmlCache.keys.first!)
            }
            Self.htmlCache[emailId] = html
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    func cachedHTML(for emailId: String) -> String? {
        Self.htmlCache[emailId]
    }

    // ... existing scrollContent unchanged
}
```

- [ ] **Step 2: Use cache in loadContent**

Update `loadContent()` in `NativeMessageDetail` — add cache check at the top of the Task:

```swift
private func loadContent() {
    // Check in-memory HTML cache first (fastest path)
    if let cachedHTML = bodyWebViewStore.cachedHTML(for: email.id) {
        bodyWebViewStore.loadHTML(cachedHTML)
        isLoading = false
        // Still load headers for display if not already set
        if messageContent == nil {
            loadHeadersOnly()
        }
        return
    }

    isLoading = true
    errorMessage = nil
    // ... rest of existing loadContent unchanged, but update loadHTML calls:
    // bodyWebViewStore.loadHTML(html) → bodyWebViewStore.loadHTML(html, emailId: email.id)
}
```

Add a lightweight `loadHeadersOnly()` helper that only fetches from SwiftData content cache (no API call):

```swift
private func loadHeadersOnly() {
    if let cached = apiManager.dataStore?.loadContent(accountId: email.accountId, msgId: email.msgId) {
        messageContent = MessageContentData(
            from: cached.headers["from"] ?? email.from,
            to: cached.headers["to"] ?? email.to,
            cc: cached.headers["cc"] ?? email.cc,
            subject: cached.headers["subject"] ?? email.subject,
            date: cached.headers["date"] ?? email.date.shortRelative,
            bodyHTML: cached.bodyHTML,
            attachments: cached.attachments.map { dict in
                MessageContentData.AttachmentInfo(
                    name: dict["name"] ?? "",
                    size: dict["size"] ?? "",
                    attachmentId: dict["attachmentId"],
                    messageId: dict["messageId"],
                    mimeType: dict["mimeType"]
                )
            }
        )
    }
}
```

- [ ] **Step 3: Update all loadHTML calls to pass emailId**

In `loadContent()`, update the two places where `bodyWebViewStore.loadHTML` is called:

1. SwiftData cache hit path (around line 472): `bodyWebViewStore.loadHTML(html, emailId: email.id)`
2. API fetch path (around line 563): `bodyWebViewStore.loadHTML(displayHTML, emailId: email.id)`

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Aerio/Views/MessageWebView.swift
git commit -m "perf: in-memory HTML content cache in BodyWebViewStore"
```

---

### Task 8: Fix scroll stability in MessageList

**Files:**
- Modify: `Aerio/Views/MessageList.swift:19` (knownEmailIds), `71-106` (onChange handlers)

- [ ] **Step 1: Remove count-based scroll logic**

In `Aerio/Views/MessageList.swift`:

Remove `@State private var knownEmailIds: Set<String> = []` (line 19).

Remove the entire `onChange(of: filteredEmails.count)` block (lines 71-92).

Remove the `.onAppear` block that initializes `knownEmailIds` (lines 104-106).

Keep the other `onChange` handlers:
- `onChange(of: selectedEmailId)` — keep as-is (scrolls to selected on keyboard nav)
- `onChange(of: selectedFolder)` — keep as-is (scrolls to top on folder switch)
- `onChange(of: selectedAccountId)` — keep as-is (scrolls to top on account switch)

- [ ] **Step 2: Build and run tests**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 3: Commit**

```bash
git add Aerio/Views/MessageList.swift
git commit -m "fix: remove fragile count-based scroll logic, rely on stable IDs"
```

---

### Task 9: Guard duplicate folder selection in MainView

**Files:**
- Modify: `Aerio/Views/MainView.swift:224-228`

- [ ] **Step 1: Add guard to onChange(of: selectedFolder)**

In `Aerio/Views/MainView.swift`, update the `onChange(of: selectedFolder)` handler:

```swift
.onChange(of: selectedFolder) { oldValue, newValue in
    guard oldValue != newValue else { return }
    unifiedMailbox.selectedFolder = newValue
    if !isNavigatingProgrammatically { selectedEmailId = nil }
    Task { await apiManager.navigateAllToFolder(newValue) }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Aerio/Views/MainView.swift
git commit -m "fix: guard duplicate folder selection to prevent unnecessary re-fetches"
```

---

### Task 10: Full integration test — build and run all tests

**Files:** None (verification only)

- [ ] **Step 1: Run all tests**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' 2>&1 | tail -30`
Expected: All tests pass.

- [ ] **Step 2: Build release and launch**

Run: `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Release -derivedDataPath build build && cp -R build/Build/Products/Release/Aerio.app /Applications/Aerio.app && open /Applications/Aerio.app`
Expected: App launches, emails load, switching between emails is responsive.

- [ ] **Step 3: Manual verification checklist**

1. Switch between emails rapidly — should be noticeably faster
2. Leave app in background, let new emails arrive, return — scroll position should be stable, sidebar folder should stay highlighted
3. Open a sent email, click Reply — To field should show the original recipient, not your address
4. Open a sent email with CC, click Reply All — To field should show original recipients, CC should show original CC minus your address

- [ ] **Step 4: Final commit (if any test fixes needed)**

Only if Step 1 required fixes. Otherwise skip.
