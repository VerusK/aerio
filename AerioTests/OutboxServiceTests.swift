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
    func notifySuccess(item: OutboxItem) { }
    func notifyFailure(item: OutboxItem, permanent: Bool) { }
}

actor RecordingNotifier: OutboxNotifying {
    var successCalls: [OutboxItem] = []
    var failureCalls: [(OutboxItem, Bool)] = []
    func notifySuccess(item: OutboxItem) { successCalls.append(item) }
    func notifyFailure(item: OutboxItem, permanent: Bool) { failureCalls.append((item, permanent)) }
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
