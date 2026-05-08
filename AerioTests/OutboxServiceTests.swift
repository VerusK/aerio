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
        XCTAssertEqual(stored.first?.attemptCount, 0, "retry resets attempt count")
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
