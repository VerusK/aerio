import XCTest
@testable import Aerio

// MARK: - Test helpers

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

/// Holds a value written from inside a MainActor hook so the test can assert on it afterwards.
@MainActor
final class ObservedValue<T> {
    var value: T?
}

actor NoopNotifier: OutboxNotifying {
    func notifySuccess(snapshot: OutboxItemSnapshot) { }
    func notifyFailure(snapshot: OutboxItemSnapshot, permanent: Bool) { }
}

actor RecordingNotifier: OutboxNotifying {
    var successCalls: [OutboxItemSnapshot] = []
    var failureCalls: [(OutboxItemSnapshot, Bool)] = []
    func notifySuccess(snapshot: OutboxItemSnapshot) { successCalls.append(snapshot) }
    func notifyFailure(snapshot: OutboxItemSnapshot, permanent: Bool) { failureCalls.append((snapshot, permanent)) }
}

// MARK: - Enqueue tests

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

// MARK: - Process tests

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
        let successCount = await notifier.successCalls.count
        XCTAssertEqual(successCount, 1)
        XCTAssertTrue(refreshed)
        let probeCount = await sender.findInSentCalls.count
        XCTAssertEqual(probeCount, 0, "no idempotency probe on first attempt")
    }

    func testProcess_transientErrorReschedulesPendingWithBackoff() async throws {
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
        // nextAttemptAt must be <= fixedNow for the item to be picked up by processOnce.
        let item = makeItem(account: "a", nextAttemptAt: fixedNow)
        try await store.insert(item)

        await service.processOnce()

        let after = try await store.allItems()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.status, .pending)
        XCTAssertEqual(after.first?.attemptCount, 1)
        XCTAssertEqual(after.first?.nextAttemptAt, fixedNow.addingTimeInterval(10))
        let failureCount = await notifier.failureCalls.count
        XCTAssertEqual(failureCount, 0)
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
        // Previously-attempted item: nextAttemptAt is in the past, attemptCount 2.
        let item = makeItem(account: "a", nextAttemptAt: fixedNow.addingTimeInterval(-1), attemptCount: 2)
        try await store.insert(item)

        await service.processOnce()

        let after = try await store.allItems()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.status, .failed)
        XCTAssertEqual(after.first?.attemptCount, 3)
        let failureCount = await notifier.failureCalls.count
        XCTAssertEqual(failureCount, 1)
        let permanentFlag = await notifier.failureCalls.first?.1
        XCTAssertEqual(permanentFlag, false, "permanent flag should be false (exhausted, not permanent)")
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
        let permanentFlag = await notifier.failureCalls.first?.1
        XCTAssertEqual(permanentFlag, true, "permanent should be true")
    }

    func testProcess_http4xxMarksFailedImmediately() async throws {
        // A 4xx (e.g. 413 payload too large, 400 malformed MIME) will fail identically
        // on every retry, so it must be classified permanent and fail fast — not
        // retried 3× like a transient network error.
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        await sender.setSendBehavior(.throwError(GmailAPIError.httpError(413, "Request Entity Too Large")))
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
        XCTAssertEqual(after.first?.attemptCount, 1, "must not retry a permanent 4xx")
        let permanentFlag = await notifier.failureCalls.first?.1
        XCTAssertEqual(permanentFlag, true, "4xx should be reported as permanent")
        XCTAssertEqual(after.first?.lastError, "HTTP 413: Request Entity Too Large")
    }

    func testProcess_http5xxIsTransient() async throws {
        // A 5xx is worth retrying — it should reschedule as pending, not fail.
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        await sender.setSendBehavior(.throwError(GmailAPIError.httpError(503, "Service Unavailable")))
        let notifier = RecordingNotifier()
        let fixedNow = Date(timeIntervalSince1970: 1000)
        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: notifier, postSendRefresh: { },
            now: { fixedNow }
        )
        let item = makeItem(account: "a", nextAttemptAt: fixedNow)
        try await store.insert(item)

        await service.processOnce()

        let after = try await store.allItems()
        XCTAssertEqual(after.first?.status, .pending)
        XCTAssertEqual(after.first?.attemptCount, 1)
        let failureCount = await notifier.failureCalls.count
        XCTAssertEqual(failureCount, 0)
    }

    // MARK: - Idempotency

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
        let probeCount = await sender.findInSentCalls.count
        XCTAssertEqual(probeCount, 1)
        let sendCount = await sender.sendMessageCalls.count
        XCTAssertEqual(sendCount, 0, "should NOT send when already in SENT")
        let successCount = await notifier.successCalls.count
        XCTAssertEqual(successCount, 1)
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

        let probeCount = await sender.findInSentCalls.count
        XCTAssertEqual(probeCount, 0)
        let sendCount = await sender.sendMessageCalls.count
        XCTAssertEqual(sendCount, 1)
    }

    // MARK: - Resume on launch

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

    func testResumeOnLaunch_recoveredItemIsCheckedInSentInsteadOfResent() async throws {
        // Still `.sending` at launch means the app died mid-send, so Gmail may already
        // have the message. It must be looked up in SENT rather than sent a second time.
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        await sender.setFindInSent(true)
        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: NoopNotifier(), postSendRefresh: { }
        )
        let interrupted = makeItem(account: "a", status: .sending, attemptCount: 0)
        let messageId = interrupted.messageIdHeader
        try await store.insert(interrupted)

        try await service.resumeOnLaunch()
        await service.processOnce()

        let sendCount = await sender.sendMessageCalls.count
        XCTAssertEqual(sendCount, 0, "a message Gmail already has must not be sent twice")
        let probes = await sender.findInSentCalls
        XCTAssertEqual(probes, [messageId])
        let remaining = try await store.allItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Side effects

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

        let calls = await sender.deleteDraftCalls
        XCTAssertEqual(calls, ["draft-99"])
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

    func testSideEffects_stripsInboxFromSelfSentMessage() async throws {
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        await sender.setSendBehavior(.success(GmailMessage(
            id: "sent-abc", threadId: "t1", labelIds: ["INBOX", "SENT"],
            snippet: nil, payload: nil, internalDate: nil,
            historyId: nil, sizeEstimate: nil
        )))
        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: NoopNotifier(), postSendRefresh: { }
        )
        try await store.insert(makeItem(account: "a"))

        await service.processOnce()

        let calls = await sender.modifyMessageCalls
        XCTAssertEqual(calls.count, 1, "exactly one INBOX-strip call")
        XCTAssertEqual(calls.first?.id, "sent-abc")
        XCTAssertEqual(calls.first?.remove ?? [], ["INBOX"])
    }

    func testSideEffects_doesNotStripInboxWhenLabelAbsent() async throws {
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        await sender.setSendBehavior(.success(GmailMessage(
            id: "sent-xyz", threadId: "t1", labelIds: ["SENT"],
            snippet: nil, payload: nil, internalDate: nil,
            historyId: nil, sizeEstimate: nil
        )))
        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: NoopNotifier(), postSendRefresh: { }
        )
        try await store.insert(makeItem(account: "a"))

        await service.processOnce()

        let calls = await sender.modifyMessageCalls
        XCTAssertTrue(calls.isEmpty, "no modifyMessage call when INBOX absent")
    }

    func testSideEffects_failureIsLoggedNotPropagated() async throws {
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        await sender.setDeleteDraftThrows(GmailAPIError.networkError("dropped"))
        let notifier = RecordingNotifier()
        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: notifier, postSendRefresh: { }
        )
        let item = makeItem(account: "a", draftIdToConsume: "d-1")
        try await store.insert(item)

        await service.processOnce()

        let successCount = await notifier.successCalls.count
        XCTAssertEqual(successCount, 1)
        let stored = try await store.allItems()
        XCTAssertTrue(stored.isEmpty)
    }

    func testSuccess_itemLeavesOutboxBeforeSideEffectsRun() async throws {
        // Side effects are extra network calls made after Gmail accepted the message.
        // If the app quits during them, the item must already be gone — otherwise the
        // next launch picks it up and the message goes out again.
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        let itemsDuringSideEffects = ObservedValue<Int>()
        await sender.setOnDeleteDraft { @MainActor in
            itemsDuringSideEffects.value = (try? await store.allItems())?.count
        }
        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: NoopNotifier(), postSendRefresh: { }
        )
        try await store.insert(makeItem(account: "a", draftIdToConsume: "d-1"))

        await service.processOnce()

        XCTAssertEqual(itemsDuringSideEffects.value, 0,
                       "the item must be deleted before the draft-cleanup call starts")
    }

    // MARK: - Corrupt item resilience

    func testProcess_corruptItemDoesNotStallQueue() async throws {
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()

        let bad = makeItem(account: "missing-account", subject: "bad")
        let good = makeItem(account: "a", subject: "good")
        try await store.insert(bad)
        try await store.insert(good)

        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: NoopNotifier(), postSendRefresh: { }
        )

        await service.processOnce()
        await service.processOnce()

        let stored = try await store.allItems()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.status, .failed, "bad item is failed")
        XCTAssertEqual(stored.first?.subject, "bad")
        let sendCount = await sender.sendMessageCalls.count
        XCTAssertEqual(sendCount, 1, "good item was sent")
    }
}

// MARK: - Cancel + retry

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
    }

    func testRetry_checksSentBeforeSendingAgain() async throws {
        // A failed item can still have reached Gmail — e.g. a timeout after the server
        // accepted it — so a manual retry must look it up in SENT before resending.
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        await sender.setFindInSent(true)
        let failed = makeItem(account: "a", status: .failed, attemptCount: 3)
        let failedId = failed.id
        try await store.insert(failed)
        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: NoopNotifier(), postSendRefresh: { }
        )

        try await service.retry(itemId: failedId)
        await service.processOnce()

        let sendCount = await sender.sendMessageCalls.count
        XCTAssertEqual(sendCount, 0, "a message already in SENT must not be sent again")
        let probeCount = await sender.findInSentCalls.count
        XCTAssertEqual(probeCount, 1)
    }

    func testRetry_transientFailureAfterRetryReschedulesInsteadOfFailing() async throws {
        // A manual retry must buy further automatic attempts, not a single shot.
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        await sender.setSendBehavior(.throwError(GmailAPIError.networkError("offline")))
        let failed = makeItem(account: "a", status: .failed, attemptCount: 3)
        let failedId = failed.id
        try await store.insert(failed)
        let service = OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: NoopNotifier(), postSendRefresh: { }
        )

        try await service.retry(itemId: failedId)
        await service.processOnce()

        let stored = try await store.item(byId: failedId)
        XCTAssertEqual(stored?.status, .pending)
    }
}

// MARK: - Editing a queued message

@MainActor
final class OutboxServiceEditTests: XCTestCase {
    private let pdf = RFC2822Builder.Attachment(
        filename: "a.pdf", mimeType: "application/pdf", data: Data(repeating: 1, count: 64))
    private let png = RFC2822Builder.InlineImage(
        cid: "img1", mimeType: "image/png", data: Data(repeating: 2, count: 64))

    /// An item whose rawMime is what compose really produces for this content.
    private func queuedItem(
        status: OutboxStatus = .pending,
        cc: String? = nil,
        htmlBody: String? = nil,
        attachments: [RFC2822Builder.Attachment] = [],
        inlineImages: [RFC2822Builder.InlineImage] = []
    ) -> OutboxItem {
        let raw = RFC2822Builder.build(ComposePayload(
            from: "me@example.com", to: "you@example.com", cc: cc, subject: "s", body: "body",
            inReplyTo: nil, references: nil, htmlBody: htmlBody,
            attachments: attachments, inlineImages: inlineImages, messageId: "<m@aerio.local>"
        ))
        let item = makeItem(account: "a", status: status)
        item.rawMime = Data(raw.utf8)
        return item
    }

    private func makeService(store: OutboxStore, sender: MockOutboxSender) -> OutboxService {
        OutboxService(
            store: store, sendersByAccount: ["a": sender],
            notifier: NoopNotifier(), postSendRefresh: { }
        )
    }

    // MARK: pauseForEditing

    func testPauseForEditing_pendingItemIsNoLongerSentAutomatically() async throws {
        // Otherwise the original goes out when its delay elapses, and the edited copy
        // follows it — the recipient gets both.
        let store = OutboxStore(inMemory: true)
        let sender = MockOutboxSender()
        let service = makeService(store: store, sender: sender)
        let item = queuedItem()
        let id = item.id
        try await store.insert(item)

        let paused = try await service.pauseForEditing(itemId: id)
        await service.processOnce()

        XCTAssertTrue(paused)
        let sendCount = await sender.sendMessageCalls.count
        XCTAssertEqual(sendCount, 0)
        let stored = try await store.item(byId: id)
        XCTAssertEqual(stored?.status, .failed, "a paused item stays in the Outbox, recoverable via Retry")
    }

    func testPauseForEditing_refusesItemAlreadySending() async throws {
        let store = OutboxStore(inMemory: true)
        let service = makeService(store: store, sender: MockOutboxSender())
        let item = queuedItem(status: .sending)
        let id = item.id
        try await store.insert(item)

        let paused = try await service.pauseForEditing(itemId: id)

        XCTAssertFalse(paused, "a send in flight can't be stopped, so editing would produce a duplicate")
        let stored = try await store.item(byId: id)
        XCTAssertEqual(stored?.status, .sending)
    }

    func testPauseForEditing_allowsFailedItem() async throws {
        let store = OutboxStore(inMemory: true)
        let service = makeService(store: store, sender: MockOutboxSender())
        let item = queuedItem(status: .failed)
        let id = item.id
        try await store.insert(item)

        let paused = try await service.pauseForEditing(itemId: id)

        XCTAssertTrue(paused)
    }

    func testPauseForEditing_refusesItemThatIsGone() async throws {
        // The row can outlive its item by a moment (e.g. it was just sent and deleted);
        // opening an editor for it would let the user send the message a second time.
        let store = OutboxStore(inMemory: true)
        let service = makeService(store: store, sender: MockOutboxSender())

        let paused = try await service.pauseForEditing(itemId: UUID())

        XCTAssertFalse(paused)
    }

    // MARK: canEdit

    func testCanEdit_plainTextMessage() {
        XCTAssertTrue(OutboxItemSnapshot(queuedItem()).canEdit)
    }

    func testCanEdit_htmlMessage() {
        XCTAssertTrue(OutboxItemSnapshot(queuedItem(htmlBody: "<b>hi</b>")).canEdit)
    }

    func testCanEdit_falseWhenMessageHasAttachment() {
        // The editor only gets recipients, subject and plain text back, so resending
        // from it would silently drop the file and delete the original.
        XCTAssertFalse(OutboxItemSnapshot(queuedItem(attachments: [pdf])).canEdit)
    }

    func testCanEdit_falseWhenMessageHasInlineImage() {
        XCTAssertFalse(OutboxItemSnapshot(queuedItem(inlineImages: [png])).canEdit)
    }

    func testCanEdit_falseForAttachmentBehindLongRecipientList() {
        // The Content-Type header comes after To/Cc, so a big Cc list pushes it far
        // from the start of the message.
        let cc = (1...300).map { "person\($0)@example.com" }.joined(separator: ", ")
        XCTAssertFalse(OutboxItemSnapshot(queuedItem(cc: cc, attachments: [pdf])).canEdit)
    }

    func testCanEdit_falseWhileSending() {
        XCTAssertFalse(OutboxItemSnapshot(queuedItem(status: .sending)).canEdit)
    }
}

// MARK: - processLoop driver

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
        while Date() < deadline {
            let current = try await store.allItems()
            if current.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let stored = try await store.allItems()
        XCTAssertTrue(stored.isEmpty)
        let successCount = await notifier.successCalls.count
        XCTAssertEqual(successCount, 1)

        service.stopLoop()
    }
}
