# Thread/Conversation View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display email threads as a conversation view in the detail panel — each message shown as a separate block with avatar, headers, body, and per-message reply actions.

**Architecture:** Add `threadId` to Email model, implement Gmail Threads API (`threads.get`), create `ThreadDetailView` (container with shared thread actions) and `ThreadMessageView` (individual message block with WKWebView body). MainView switches between thread view and single-message view based on thread size.

**Tech Stack:** Swift, SwiftUI, WKWebView, Gmail REST API (threads.get), SwiftData

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Aerio/Models/Email.swift` | Modify | Add `threadId: String` field |
| `Aerio/Persistence/DataStore.swift` | Modify | Add `threadId` to CachedEmail |
| `Aerio/Models/GmailAPIModels.swift` | Modify | Add `GmailThread` struct |
| `Aerio/Services/GmailAPIClient.swift` | Modify | Add `getThread()` API method |
| `Aerio/Services/GmailAPIManager.swift` | Modify | Add `ThreadMessage`, `fetchThread()`, thread cache, threadId in `convertGmailMessageToEmail` |
| `Aerio/Views/ThreadDetailView.swift` | **Create** | Thread conversation container (subject, shared actions, message list) |
| `Aerio/Views/ThreadMessageView.swift` | **Create** | Single message in thread (avatar, headers, body, per-message actions) |
| `Aerio/Views/MainView.swift` | Modify | Switch between ThreadDetailView and NativeMessageDetail |
| `AerioTests/ModelTests.swift` | Modify | Test threadId on Email |
| `AerioTests/DataStoreTests.swift` | Modify | Test threadId persistence |
| `AerioTests/GmailAPIManagerTests.swift` | Modify | Test convertGmailMessageToEmail with threadId |

---

### Task 1: Add `threadId` to Email model and CachedEmail

**Files:**
- Modify: `Aerio/Models/Email.swift`
- Modify: `Aerio/Persistence/DataStore.swift`
- Test: `AerioTests/ModelTests.swift`
- Test: `AerioTests/DataStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `AerioTests/ModelTests.swift` (in the `EmailTests` class):

```swift
func testEmailThreadIdField() {
    let email = Email(
        msgId: "msg1",
        from: "test@test.com",
        subject: "Test",
        date: Date(),
        snippet: "preview",
        accountId: "acc1",
        folder: .inbox,
        threadId: "thread123"
    )
    XCTAssertEqual(email.threadId, "thread123")
}

func testEmailThreadIdDefaultsToEmpty() {
    let email = Email(
        msgId: "msg1",
        from: "test@test.com",
        subject: "Test",
        date: Date(),
        snippet: "preview",
        accountId: "acc1",
        folder: .inbox
    )
    XCTAssertEqual(email.threadId, "")
}
```

Add to `AerioTests/DataStoreTests.swift` (in the `EmailCacheTests` class):

```swift
func testSaveAndLoadPreservesThreadId() {
    let store = makeStore()
    let email = Email(
        msgId: "msg1",
        from: "test@test.com",
        subject: "Test",
        date: Date(),
        snippet: "preview",
        accountId: "acc1",
        folder: .inbox,
        threadId: "thread456"
    )
    store.saveEmails([email])
    let loaded = store.loadEmails(for: "acc1")
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded[0].threadId, "thread456")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/ModelTests 2>&1 | tail -20`
Expected: Compilation error — `threadId` parameter doesn't exist.

- [ ] **Step 3: Add `threadId` to Email struct**

In `Aerio/Models/Email.swift`, add the field and update init. Place `threadId` at the end of the init params with a default so all existing callers compile:

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
    let threadId: String

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
        cc: String = "",
        threadId: String = ""
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
        self.threadId = threadId
    }

    static func sortedByDate(_ emails: [Email], ascending: Bool = false) -> [Email] {
        emails.sorted { ascending ? $0.date < $1.date : $0.date > $1.date }
    }
}
```

- [ ] **Step 4: Add `threadId` to CachedEmail**

In `Aerio/Persistence/DataStore.swift`, add `threadId: String?` to `CachedEmail`:

After the existing `var cc: String?` line, add:
```swift
var threadId: String?
```

In `init(from email:)`, add:
```swift
self.threadId = email.threadId
```

In `toEmail()`, add `threadId` to the Email init:
```swift
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
    cc: cc ?? "",
    threadId: threadId ?? ""
)
```

In `saveEmails`, in the `if let existing` block, add:
```swift
existing.threadId = email.threadId
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/ModelTests -only-testing:AerioTests/EmailCacheTests 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add Aerio/Models/Email.swift Aerio/Persistence/DataStore.swift AerioTests/ModelTests.swift AerioTests/DataStoreTests.swift
git commit -m "feat: add threadId to Email model and CachedEmail"
```

---

### Task 2: Add GmailThread model and `getThread` API method

**Files:**
- Modify: `Aerio/Models/GmailAPIModels.swift`
- Modify: `Aerio/Services/GmailAPIClient.swift`

- [ ] **Step 1: Add `GmailThread` struct**

In `Aerio/Models/GmailAPIModels.swift`, add after the `GmailMessage` struct (after line 28):

```swift
// MARK: - Thread

struct GmailThread: Codable {
    let id: String
    let messages: [GmailMessage]?
    let historyId: String?
}
```

- [ ] **Step 2: Add `getThread` method to GmailAPIClient**

In `Aerio/Services/GmailAPIClient.swift`, add after the `getMessages` method (after line 112):

```swift
func getThread(id: String, format: String = "full") async throws -> GmailThread {
    let queryItems = [URLQueryItem(name: "format", value: format)]
    let request = try buildRequest(path: "/threads/\(id)", queryItems: queryItems)
    return try await execute(request: request)
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Aerio/Models/GmailAPIModels.swift Aerio/Services/GmailAPIClient.swift
git commit -m "feat: add GmailThread model and getThread API method"
```

---

### Task 3: Add `ThreadMessage`, `fetchThread`, thread cache, and threadId parsing in GmailAPIManager

**Files:**
- Modify: `Aerio/Services/GmailAPIManager.swift`
- Test: `AerioTests/GmailAPIManagerTests.swift`

- [ ] **Step 1: Write the failing test for threadId in convertGmailMessageToEmail**

Add to `AerioTests/GmailAPIManagerTests.swift`:

```swift
func testConvertGmailMessageIncludesThreadId() {
    let account = Account(email: "test@gmail.com", name: "Test")
    accountManager.addAccount(account)
    manager.syncClients(with: accountManager.accounts)

    let message = GmailMessage(
        id: "msg1",
        threadId: "thread_abc",
        labelIds: ["INBOX", "UNREAD"],
        snippet: "Hello",
        payload: GmailPayload(
            mimeType: "text/plain",
            headers: [
                GmailHeader(name: "From", value: "sender@test.com"),
                GmailHeader(name: "Subject", value: "Test"),
            ],
            body: nil,
            parts: nil,
            filename: nil
        ),
        internalDate: String(Int(Date().timeIntervalSince1970 * 1000)),
        historyId: nil,
        sizeEstimate: nil
    )
    let email = manager.convertGmailMessageToEmail(message, accountId: account.id, folder: .inbox)
    XCTAssertNotNil(email)
    XCTAssertEqual(email?.threadId, "thread_abc")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/GmailAPIManagerTests/testConvertGmailMessageIncludesThreadId 2>&1 | tail -20`
Expected: FAIL — `email?.threadId` is `""`.

- [ ] **Step 3: Add threadId to convertGmailMessageToEmail**

In `Aerio/Services/GmailAPIManager.swift`, in the `convertGmailMessageToEmail` method (around line 881-893), update the return statement to include `threadId`:

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
    cc: cc,
    threadId: message.threadId
)
```

- [ ] **Step 4: Add ThreadMessage struct and fetchThread method**

In `Aerio/Services/GmailAPIManager.swift`, add the `ThreadMessage` struct near the top of the file (after imports, before the class):

```swift
struct ThreadMessage: Identifiable {
    let id: String
    let from: String
    let to: String
    let cc: String
    let date: Date
    let subject: String
    let bodyHTML: String
    let attachments: [MessageContentData.AttachmentInfo]
    let inlineImages: [(cid: String, attachmentId: String, mimeType: String)]
    let accountId: String
    let msgId: String
    let messageId: String?
    let folder: Folder
    let isRead: Bool
}
```

Add thread cache as a static property inside `GmailAPIManager`:

```swift
private static var threadCache: [String: [ThreadMessage]] = [:]
private static let threadCacheLimit = 20
```

Add the `fetchThread` method inside `GmailAPIManager`:

```swift
func fetchThread(threadId: String, accountId: String) async throws -> [ThreadMessage] {
    // Check cache first
    let cacheKey = "\(accountId)_\(threadId)"
    if let cached = Self.threadCache[cacheKey] {
        return cached
    }

    guard let client = clients[accountId] else {
        throw GmailAPIError.unauthorized
    }

    let thread = try await client.getThread(id: threadId, format: "full")
    guard let messages = thread.messages else { return [] }

    var threadMessages: [ThreadMessage] = []
    for message in messages {
        let headers = message.payload?.headers ?? []
        let from = headers.first { $0.name.lowercased() == "from" }?.value ?? ""
        let to = headers.first { $0.name.lowercased() == "to" }?.value ?? ""
        let cc = headers.first { $0.name.lowercased() == "cc" }?.value ?? ""
        let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? ""
        let messageId = headers.first { $0.name.lowercased() == "message-id" }?.value

        let date: Date
        if let internalDate = message.internalDate, let ms = Double(internalDate) {
            date = Date(timeIntervalSince1970: ms / 1000)
        } else {
            date = Date()
        }

        var bodyHTML = ""
        if let payload = message.payload {
            let extracted = extractBodyFromPayload(payload)
            bodyHTML = extracted.isEmpty ? "<p>No message body</p>" : extracted
        }

        let attachments: [MessageContentData.AttachmentInfo]
        if let payload = message.payload {
            let allInlineIds: Set<String> = Set(extractInlineImages(payload).map { $0.attachmentId })
            attachments = extractAttachments(payload, messageId: message.id)
                .filter { att in
                    guard let attId = att.attachmentId else { return true }
                    return !allInlineIds.contains(attId)
                }
        } else {
            attachments = []
        }

        let inlineImages = message.payload.map { extractInlineImages($0) } ?? []

        let labelIds = message.labelIds ?? []
        let isRead = !labelIds.contains(GmailLabelId.unread)
        let folder = Folder.allCases.first { $0.matchesLabels(labelIds) } ?? .inbox

        threadMessages.append(ThreadMessage(
            id: message.id,
            from: from,
            to: to,
            cc: cc,
            date: date,
            subject: subject,
            bodyHTML: bodyHTML,
            attachments: attachments,
            inlineImages: inlineImages,
            accountId: accountId,
            msgId: message.id,
            messageId: messageId,
            folder: folder,
            isRead: isRead
        ))
    }

    // Sort chronologically (oldest first)
    threadMessages.sort { $0.date < $1.date }

    // Cache with LRU eviction
    if Self.threadCache.count >= Self.threadCacheLimit {
        Self.threadCache.removeValue(forKey: Self.threadCache.keys.first!)
    }
    Self.threadCache[cacheKey] = threadMessages

    return threadMessages
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS' -only-testing:AerioTests/GmailAPIManagerTests 2>&1 | tail -20`
Expected: All pass (including the new threadId test).

- [ ] **Step 6: Commit**

```bash
git add Aerio/Services/GmailAPIManager.swift AerioTests/GmailAPIManagerTests.swift
git commit -m "feat: add ThreadMessage, fetchThread with cache, threadId in convertGmailMessageToEmail"
```

---

### Task 4: Create ThreadMessageView

**Files:**
- Create: `Aerio/Views/ThreadMessageView.swift`

- [ ] **Step 1: Create ThreadMessageView**

Create `Aerio/Views/ThreadMessageView.swift`:

```swift
import SwiftUI
import WebKit

struct ThreadMessageView: View {
    let message: ThreadMessage
    let apiManager: GmailAPIManager

    var onReply: (() -> Void)?
    var onReplyAll: (() -> Void)?
    var onForward: (() -> Void)?

    @StateObject private var bodyWebViewStore = BodyWebViewStore()
    @State private var isLoading = true
    @State private var downloadingAttachment: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: avatar + from/to/date
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(message.from)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(message.date.shortRelative)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if !message.to.isEmpty {
                        Text("To: \(message.to)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !message.cc.isEmpty {
                        Text("Cc: \(message.cc)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Body: WKWebView
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                BodyWebView(webView: bodyWebViewStore.webView)
                    .frame(minHeight: 60, maxHeight: 400)
            }

            // Attachments
            if !message.attachments.isEmpty {
                attachmentChips
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            // Per-message actions: Reply, Reply All, Forward
            HStack(spacing: 4) {
                actionButton(icon: "arrowshape.turn.up.left", tooltip: "Reply", action: onReply)
                actionButton(icon: "arrowshape.turn.up.left.2", tooltip: "Reply All", action: onReplyAll)
                actionButton(icon: "arrowshape.turn.up.right", tooltip: "Forward", action: onForward)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Thick divider
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 4)
        }
        .onAppear { loadBody() }
    }

    private var avatar: some View {
        let initial = String(message.from.prefix(1)).uppercased()
        let color = avatarColor(for: message.from)
        return Circle()
            .fill(color)
            .frame(width: 32, height: 32)
            .overlay(
                Text(initial)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            )
    }

    private func avatarColor(for email: String) -> Color {
        let hash = abs(email.hashValue)
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .mint]
        return colors[hash % colors.count]
    }

    private func actionButton(icon: String, tooltip: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .disabled(action == nil)
    }

    private var attachmentChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(message.attachments, id: \.name) { att in
                HStack(spacing: 6) {
                    if downloadingAttachment == att.name {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "doc")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                    }
                    Text(att.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    if !att.size.isEmpty {
                        Text(att.size)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .onTapGesture {
                    downloadAttachment(att)
                }
            }
        }
    }

    private func loadBody() {
        var html = message.bodyHTML

        // Resolve inline CID images
        Task {
            for inline in message.inlineImages {
                guard html.contains("cid:\(inline.cid)") else { continue }
                do {
                    let data = try await apiManager.downloadAttachment(
                        messageId: message.id,
                        attachmentId: inline.attachmentId,
                        accountId: message.accountId
                    )
                    let base64 = data.base64EncodedString()
                    let dataURI = "data:\(inline.mimeType);base64,\(base64)"
                    html = html.replacingOccurrences(of: "cid:\(inline.cid)", with: dataURI)
                } catch {}
            }

            let wrapped = wrapEmailHTML(html, subject: message.subject)
            bodyWebViewStore.loadHTML(wrapped, emailId: message.id)
            isLoading = false
        }
    }

    private func downloadAttachment(_ att: MessageContentData.AttachmentInfo) {
        guard let attachmentId = att.attachmentId, let messageId = att.messageId else { return }
        downloadingAttachment = att.name
        Task {
            do {
                let data = try await apiManager.downloadAttachment(
                    messageId: messageId,
                    attachmentId: attachmentId,
                    accountId: message.accountId
                )
                let downloadsDir = SettingsView.resolvedDownloadsDirectory()
                try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
                let fileURL = downloadsDir.appendingPathComponent(att.name)
                try data.write(to: fileURL)
                NSWorkspace.shared.open(fileURL)
            } catch {}
            downloadingAttachment = nil
        }
    }
}
```

- [ ] **Step 2: Add the new file to the Xcode project**

Run: `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build 2>&1 | tail -10`

If the file is not auto-discovered, it needs to be added to the project. Since Aerio uses a flat file structure without explicit file references (all `.swift` files in Aerio/ are compiled), it should be auto-discovered.

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Aerio/Views/ThreadMessageView.swift
git commit -m "feat: create ThreadMessageView for individual messages in thread"
```

---

### Task 5: Create ThreadDetailView

**Files:**
- Create: `Aerio/Views/ThreadDetailView.swift`

- [ ] **Step 1: Create ThreadDetailView**

Create `Aerio/Views/ThreadDetailView.swift`:

```swift
import SwiftUI

struct ThreadDetailView: View {
    let email: Email
    let apiManager: GmailAPIManager
    let folder: Folder

    var onReply: ((ThreadMessage) -> Void)?
    var onReplyAll: ((ThreadMessage) -> Void)?
    var onForward: ((ThreadMessage) -> Void)?
    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSpam: (() -> Void)?
    var onMoveToInbox: (() -> Void)?
    var onRegisterScroll: ((@escaping (Int) -> Void) -> Void)?

    @State private var threadMessages: [ThreadMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Shared thread action bar
            threadActionBar
            // Thread subject
            threadHeader
            Divider()

            if isLoading {
                ProgressView("Loading thread…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { loadThread() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(threadMessages) { message in
                                ThreadMessageView(
                                    message: message,
                                    apiManager: apiManager,
                                    onReply: { onReply?(message) },
                                    onReplyAll: { onReplyAll?(message) },
                                    onForward: { onForward?(message) }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .onAppear {
                        // Scroll to last message
                        if let lastId = threadMessages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                        onRegisterScroll? { direction in
                            // Thread view doesn't need keyboard scroll — ScrollView handles it
                        }
                    }
                }
            }
        }
        .onAppear { loadThread() }
        .onChange(of: email.threadId) { _, _ in loadThread() }
    }

    private var threadActionBar: some View {
        HStack(spacing: 4) {
            if folder == .inbox {
                actionButton(icon: "archivebox", tooltip: "Archive", action: onArchive)
            }
            if folder != .inbox {
                actionButton(icon: "tray.and.arrow.down", tooltip: "Move to Inbox", action: onMoveToInbox)
            }
            actionButton(icon: "exclamationmark.octagon", tooltip: "Spam", action: onSpam)
            actionButton(icon: "trash", tooltip: "Delete", action: onDelete)

            Spacer()

            if !threadMessages.isEmpty {
                Text("\(threadMessages.count) messages")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var threadHeader: some View {
        Text(email.subject)
            .font(.system(size: 16, weight: .semibold))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func actionButton(icon: String, tooltip: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .disabled(action == nil)
    }

    private func loadThread() {
        isLoading = true
        loadError = nil
        Task {
            do {
                threadMessages = try await apiManager.fetchThread(
                    threadId: email.threadId,
                    accountId: email.accountId
                )
                isLoading = false
            } catch {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Aerio/Views/ThreadDetailView.swift
git commit -m "feat: create ThreadDetailView for conversation display"
```

---

### Task 6: Integrate thread view in MainView

**Files:**
- Modify: `Aerio/Views/MainView.swift`

- [ ] **Step 1: Update messageDetailPanel to switch between thread and single view**

In `Aerio/Views/MainView.swift`, find the `messageDetailPanel` computed property (around line 332-367). Replace the `NativeMessageDetail` block with logic that switches based on thread size.

Replace the content inside `if let selectedEmailId, let email = findEmail(by: selectedEmailId)` (lines 339-353):

```swift
if let selectedEmailId,
   let email = findEmail(by: selectedEmailId) {
    if email.threadId.isEmpty || !hasMultipleThreadMessages(email) {
        // Single message — existing behavior
        NativeMessageDetail(
            email: email,
            apiManager: apiManager,
            folder: selectedFolder,
            onReply: { triggerCompose(.reply, msgId: email.msgId) },
            onReplyAll: { triggerCompose(.replyAll, msgId: email.msgId) },
            onForward: { triggerCompose(.forward, msgId: email.msgId) },
            onArchive: { executeActionOnEmail(email, action: .archive) },
            onDelete: { executeActionOnEmail(email, action: .delete) },
            onSpam: { executeActionOnEmail(email, action: .spam) },
            onMoveToInbox: { executeActionOnEmail(email, action: .moveToInbox) },
            onEditDraft: { openDraft(email) },
            onRegisterScroll: { handler in detailScrollHandler = handler }
        )
        .id(email.id)
    } else {
        // Thread view
        ThreadDetailView(
            email: email,
            apiManager: apiManager,
            folder: selectedFolder,
            onReply: { msg in triggerComposeFromThread(.reply, message: msg) },
            onReplyAll: { msg in triggerComposeFromThread(.replyAll, message: msg) },
            onForward: { msg in triggerComposeFromThread(.forward, message: msg) },
            onArchive: { executeActionOnEmail(email, action: .archive) },
            onDelete: { executeActionOnEmail(email, action: .delete) },
            onSpam: { executeActionOnEmail(email, action: .spam) },
            onMoveToInbox: { executeActionOnEmail(email, action: .moveToInbox) },
            onRegisterScroll: { handler in detailScrollHandler = handler }
        )
        .id(email.threadId)
    }
}
```

- [ ] **Step 2: Add helper methods**

Add these helper methods to `MainView`:

```swift
private func hasMultipleThreadMessages(_ email: Email) -> Bool {
    let allEmails = apiManager.emailsByAccount.values.flatMap { $0 }
    return allEmails.filter { $0.threadId == email.threadId }.count > 1
}

private func triggerComposeFromThread(_ type: ComposeType, message: ThreadMessage) {
    // Convert ThreadMessage to Email for compose
    let email = Email(
        msgId: message.msgId,
        from: message.from,
        subject: message.subject,
        date: message.date,
        snippet: "",
        isRead: message.isRead,
        accountId: message.accountId,
        folder: message.folder,
        messageId: message.messageId,
        to: message.to,
        cc: message.cc,
        threadId: ""
    )
    composeType = type
    composeTargetMsgId = email.msgId
    showingCompose = true
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Aerio/Views/MainView.swift
git commit -m "feat: integrate ThreadDetailView in MainView detail panel"
```

---

### Task 7: Full build, test, and deploy

**Files:** None (verification only)

- [ ] **Step 1: Run all tests**

Run: `xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS'; rm -rf ~/Library/Developer/Xcode/DerivedData/Aerio-*/Build/Products/Debug/Aerio.app`
Expected: Tests pass (3 pre-existing GmailAPIClientTests failures are known/unrelated).

- [ ] **Step 2: Build release and deploy**

Run: `xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Release -derivedDataPath build build && rm -rf /Applications/Aerio.app && cp -R build/Build/Products/Release/Aerio.app /Applications/Aerio.app && rm -rf build/Build/Products/Release/Aerio.app && open /Applications/Aerio.app`
Expected: App launches, select a thread email — should show conversation view.

- [ ] **Step 3: Manual verification**

1. Select an email that is part of a conversation → Thread view shows all messages chronologically with avatars, headers, body
2. Select a standalone email (no thread) → Shows single message as before (NativeMessageDetail)
3. Click Reply on a specific message in the thread → Compose opens with that message's sender as recipient
4. Click Archive/Delete at the top of thread → Works on the whole thread
5. Thick divider (4px) visible between messages
6. Thread auto-scrolls to the last message on open
