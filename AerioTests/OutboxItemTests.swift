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
