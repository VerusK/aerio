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

@MainActor
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

    func testStore_resetSendingToPending() async throws {
        let store = OutboxStore(inMemory: true)
        let stuck = OutboxItem(
            id: UUID(), accountId: "a", rawMime: Data(), messageIdHeader: "<m>",
            threadId: nil, draftIdToConsume: nil, subject: "s", recipientsPreview: "r",
            status: .sending, attemptCount: 0, createdAt: Date(), nextAttemptAt: Date(),
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        try await store.insert(stuck)
        let count = try await store.resetSendingToPending()
        XCTAssertEqual(count, 1)
        let after = try await store.allItems()
        XCTAssertEqual(after.first?.status, .pending)
    }

    func testStore_earliestPendingNext_returnsFutureDateOnly() async throws {
        let store = OutboxStore(inMemory: true)
        let now = Date()
        let past = OutboxItem(
            id: UUID(), accountId: "a", rawMime: Data(), messageIdHeader: "<a>",
            threadId: nil, draftIdToConsume: nil, subject: "past", recipientsPreview: "r",
            status: .pending, attemptCount: 0,
            createdAt: now, nextAttemptAt: now.addingTimeInterval(-1),
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        let future = OutboxItem(
            id: UUID(), accountId: "a", rawMime: Data(), messageIdHeader: "<b>",
            threadId: nil, draftIdToConsume: nil, subject: "future", recipientsPreview: "r",
            status: .pending, attemptCount: 0,
            createdAt: now, nextAttemptAt: now.addingTimeInterval(120),
            archiveOnSuccessForMsgId: nil, archiveOnSuccessForAccountId: nil
        )
        try await store.insert(past)
        try await store.insert(future)
        let next = try await store.earliestPendingNext(after: now)
        XCTAssertEqual(next, now.addingTimeInterval(120))
    }
}
