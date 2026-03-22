import XCTest
@testable import AgMail

final class GmailAPIModelsTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - GmailHistoryResponse

    func testHistoryResponseDecoding() throws {
        let json = """
        {
            "historyId": "12345",
            "nextPageToken": "token123",
            "history": [
                {
                    "id": "100",
                    "messages": [
                        {"id": "msg1", "threadId": "thread1", "labelIds": ["INBOX"]}
                    ]
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(GmailHistoryResponse.self, from: json)
        XCTAssertEqual(response.historyId, "12345")
        XCTAssertEqual(response.nextPageToken, "token123")
        XCTAssertEqual(response.history?.count, 1)
        XCTAssertEqual(response.history?[0].id, "100")
        XCTAssertEqual(response.history?[0].messages?.count, 1)
        XCTAssertEqual(response.history?[0].messages?[0].id, "msg1")
    }

    func testHistoryResponseDecodingEmptyHistory() throws {
        let json = """
        {
            "historyId": "99999"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(GmailHistoryResponse.self, from: json)
        XCTAssertEqual(response.historyId, "99999")
        XCTAssertNil(response.history)
        XCTAssertNil(response.nextPageToken)
    }

    // MARK: - GmailHistoryRecord

    func testHistoryRecordDecodingMessagesAdded() throws {
        let json = """
        {
            "id": "200",
            "messagesAdded": [
                {"message": {"id": "msg2", "threadId": "thread2", "labelIds": ["INBOX", "UNREAD"]}}
            ]
        }
        """.data(using: .utf8)!

        let record = try decoder.decode(GmailHistoryRecord.self, from: json)
        XCTAssertEqual(record.id, "200")
        XCTAssertEqual(record.messagesAdded?.count, 1)
        XCTAssertEqual(record.messagesAdded?[0].message.id, "msg2")
        XCTAssertEqual(record.messagesAdded?[0].message.labelIds, ["INBOX", "UNREAD"])
        XCTAssertNil(record.messagesDeleted)
        XCTAssertNil(record.labelsAdded)
        XCTAssertNil(record.labelsRemoved)
    }

    func testHistoryRecordDecodingMessagesDeleted() throws {
        let json = """
        {
            "id": "201",
            "messagesDeleted": [
                {"message": {"id": "msg3", "threadId": "thread3"}}
            ]
        }
        """.data(using: .utf8)!

        let record = try decoder.decode(GmailHistoryRecord.self, from: json)
        XCTAssertEqual(record.messagesDeleted?.count, 1)
        XCTAssertEqual(record.messagesDeleted?[0].message.id, "msg3")
    }

    func testHistoryRecordDecodingLabelsAdded() throws {
        let json = """
        {
            "id": "202",
            "labelsAdded": [
                {"message": {"id": "msg4", "threadId": "thread4"}, "labelIds": ["STARRED"]}
            ]
        }
        """.data(using: .utf8)!

        let record = try decoder.decode(GmailHistoryRecord.self, from: json)
        XCTAssertEqual(record.labelsAdded?.count, 1)
        XCTAssertEqual(record.labelsAdded?[0].message.id, "msg4")
        XCTAssertEqual(record.labelsAdded?[0].labelIds, ["STARRED"])
    }

    func testHistoryRecordDecodingLabelsRemoved() throws {
        let json = """
        {
            "id": "203",
            "labelsRemoved": [
                {"message": {"id": "msg5", "threadId": "thread5"}, "labelIds": ["UNREAD", "IMPORTANT"]}
            ]
        }
        """.data(using: .utf8)!

        let record = try decoder.decode(GmailHistoryRecord.self, from: json)
        XCTAssertEqual(record.labelsRemoved?.count, 1)
        XCTAssertEqual(record.labelsRemoved?[0].message.id, "msg5")
        XCTAssertEqual(record.labelsRemoved?[0].labelIds, ["UNREAD", "IMPORTANT"])
    }

    func testHistoryRecordDecodingAllFields() throws {
        let json = """
        {
            "id": "300",
            "messages": [
                {"id": "msgA", "threadId": "threadA"}
            ],
            "messagesAdded": [
                {"message": {"id": "msgB", "threadId": "threadB"}}
            ],
            "messagesDeleted": [
                {"message": {"id": "msgC", "threadId": "threadC"}}
            ],
            "labelsAdded": [
                {"message": {"id": "msgD", "threadId": "threadD"}, "labelIds": ["INBOX"]}
            ],
            "labelsRemoved": [
                {"message": {"id": "msgE", "threadId": "threadE"}, "labelIds": ["SPAM"]}
            ]
        }
        """.data(using: .utf8)!

        let record = try decoder.decode(GmailHistoryRecord.self, from: json)
        XCTAssertEqual(record.id, "300")
        XCTAssertEqual(record.messages?.count, 1)
        XCTAssertEqual(record.messagesAdded?.count, 1)
        XCTAssertEqual(record.messagesDeleted?.count, 1)
        XCTAssertEqual(record.labelsAdded?.count, 1)
        XCTAssertEqual(record.labelsRemoved?.count, 1)
    }

    // MARK: - GmailDraftsListResponse

    func testDraftsListResponseDecoding() throws {
        let json = """
        {
            "drafts": [
                {"id": "draft1", "message": {"id": "msg10", "threadId": "thread10"}},
                {"id": "draft2", "message": {"id": "msg11"}}
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(GmailDraftsListResponse.self, from: json)
        XCTAssertEqual(response.drafts?.count, 2)
        XCTAssertEqual(response.drafts?[0].id, "draft1")
        XCTAssertEqual(response.drafts?[0].message?.id, "msg10")
        XCTAssertEqual(response.drafts?[0].message?.threadId, "thread10")
        XCTAssertEqual(response.drafts?[1].id, "draft2")
        XCTAssertNil(response.drafts?[1].message?.threadId)
    }

    func testDraftsListResponseDecodingEmpty() throws {
        let json = """
        {}
        """.data(using: .utf8)!

        let response = try decoder.decode(GmailDraftsListResponse.self, from: json)
        XCTAssertNil(response.drafts)
    }

    // MARK: - GmailAttachment

    func testAttachmentDecoding() throws {
        let json = """
        {
            "attachmentId": "att123",
            "size": 2048,
            "data": "SGVsbG8gV29ybGQ="
        }
        """.data(using: .utf8)!

        let attachment = try decoder.decode(GmailAttachment.self, from: json)
        XCTAssertEqual(attachment.attachmentId, "att123")
        XCTAssertEqual(attachment.size, 2048)
        XCTAssertEqual(attachment.data, "SGVsbG8gV29ybGQ=")
    }

    func testAttachmentDecodingMinimalFields() throws {
        let json = """
        {}
        """.data(using: .utf8)!

        let attachment = try decoder.decode(GmailAttachment.self, from: json)
        XCTAssertNil(attachment.attachmentId)
        XCTAssertNil(attachment.size)
        XCTAssertNil(attachment.data)
    }

    // MARK: - Missing optional fields (graceful defaults)

    func testMessageDecodingWithMinimalFields() throws {
        let json = """
        {
            "id": "minimal1",
            "threadId": "minThread1"
        }
        """.data(using: .utf8)!

        let message = try decoder.decode(GmailMessage.self, from: json)
        XCTAssertEqual(message.id, "minimal1")
        XCTAssertEqual(message.threadId, "minThread1")
        XCTAssertNil(message.labelIds)
        XCTAssertNil(message.snippet)
        XCTAssertNil(message.payload)
        XCTAssertNil(message.internalDate)
        XCTAssertNil(message.historyId)
        XCTAssertNil(message.sizeEstimate)
    }

    func testMessageListResponseWithMissingOptionals() throws {
        let json = """
        {
            "resultSizeEstimate": 0
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(GmailMessageListResponse.self, from: json)
        XCTAssertNil(response.messages)
        XCTAssertNil(response.nextPageToken)
        XCTAssertNil(response.historyId)
        XCTAssertEqual(response.resultSizeEstimate, 0)
    }

    func testPayloadDecodingWithNestedParts() throws {
        let json = """
        {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "Content-Type", "value": "multipart/mixed"}],
            "parts": [
                {
                    "mimeType": "text/plain",
                    "body": {"size": 100, "data": "dGVzdA=="}
                },
                {
                    "mimeType": "application/pdf",
                    "filename": "report.pdf",
                    "body": {"attachmentId": "att456", "size": 5000}
                }
            ]
        }
        """.data(using: .utf8)!

        let payload = try decoder.decode(GmailPayload.self, from: json)
        XCTAssertEqual(payload.mimeType, "multipart/mixed")
        XCTAssertEqual(payload.headers?.count, 1)
        XCTAssertEqual(payload.parts?.count, 2)
        XCTAssertEqual(payload.parts?[0].mimeType, "text/plain")
        XCTAssertEqual(payload.parts?[0].body?.data, "dGVzdA==")
        XCTAssertEqual(payload.parts?[1].filename, "report.pdf")
        XCTAssertEqual(payload.parts?[1].body?.attachmentId, "att456")
    }

    func testDraftDecodingWithFullMessage() throws {
        let json = """
        {
            "id": "draftFull",
            "message": {
                "id": "msgFull",
                "threadId": "threadFull",
                "labelIds": ["DRAFT"],
                "snippet": "Hello world"
            }
        }
        """.data(using: .utf8)!

        let draft = try decoder.decode(GmailDraft.self, from: json)
        XCTAssertEqual(draft.id, "draftFull")
        XCTAssertEqual(draft.message?.id, "msgFull")
        XCTAssertEqual(draft.message?.labelIds, ["DRAFT"])
        XCTAssertEqual(draft.message?.snippet, "Hello world")
    }

    func testDraftDecodingWithoutMessage() throws {
        let json = """
        {
            "id": "draftNoMsg"
        }
        """.data(using: .utf8)!

        let draft = try decoder.decode(GmailDraft.self, from: json)
        XCTAssertEqual(draft.id, "draftNoMsg")
        XCTAssertNil(draft.message)
    }

    func testLabelDecodingWithAllFields() throws {
        let json = """
        {
            "id": "Label_1",
            "name": "Custom Label",
            "messageListVisibility": "show",
            "labelListVisibility": "labelShow",
            "type": "user",
            "messagesTotal": 42,
            "messagesUnread": 5,
            "threadsTotal": 30,
            "threadsUnread": 3
        }
        """.data(using: .utf8)!

        let label = try decoder.decode(GmailLabel.self, from: json)
        XCTAssertEqual(label.id, "Label_1")
        XCTAssertEqual(label.name, "Custom Label")
        XCTAssertEqual(label.messagesTotal, 42)
        XCTAssertEqual(label.messagesUnread, 5)
        XCTAssertEqual(label.type, "user")
    }

    func testLabelDecodingMinimal() throws {
        let json = """
        {"id": "INBOX"}
        """.data(using: .utf8)!

        let label = try decoder.decode(GmailLabel.self, from: json)
        XCTAssertEqual(label.id, "INBOX")
        XCTAssertNil(label.name)
        XCTAssertNil(label.messagesTotal)
    }
}
