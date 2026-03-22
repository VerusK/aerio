import XCTest
@testable import AgMail

final class ComposeDraftTests: XCTestCase {

    // MARK: - Draft Save Decision Logic (hasNonEmptyContent)

    func testAllFieldsEmpty_noDraft() {
        XCTAssertFalse(ComposeView.hasNonEmptyContent(to: "", cc: "", subject: "", body: ""))
    }

    func testWhitespaceOnlyFields_noDraft() {
        XCTAssertFalse(ComposeView.hasNonEmptyContent(to: "  ", cc: "  ", subject: "  ", body: "  \n  "))
    }

    func testToFieldFilled_shouldSaveDraft() {
        XCTAssertTrue(ComposeView.hasNonEmptyContent(to: "alice@example.com", cc: "", subject: "", body: ""))
    }

    func testCcFieldFilled_shouldSaveDraft() {
        XCTAssertTrue(ComposeView.hasNonEmptyContent(to: "", cc: "bob@example.com", subject: "", body: ""))
    }

    func testSubjectFieldFilled_shouldSaveDraft() {
        XCTAssertTrue(ComposeView.hasNonEmptyContent(to: "", cc: "", subject: "Hello", body: ""))
    }

    func testBodyFieldFilled_shouldSaveDraft() {
        XCTAssertTrue(ComposeView.hasNonEmptyContent(to: "", cc: "", subject: "", body: "Some content"))
    }

    func testAllFieldsFilled_shouldSaveDraft() {
        XCTAssertTrue(ComposeView.hasNonEmptyContent(to: "alice@example.com", cc: "bob@example.com", subject: "Hi", body: "Body text"))
    }

    // MARK: - GmailDraftRequest Model

    func testDraftRequestEncoding() throws {
        let request = GmailDraftRequest(message: GmailDraftMessage(raw: "raw_data_here"))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(GmailDraftRequest.self, from: data)
        XCTAssertEqual(decoded.message.raw, "raw_data_here")
    }

    func testDraftResponseDecoding() throws {
        let json = """
        {"id": "draft123", "message": {"id": "msg1", "threadId": "thread1"}}
        """
        let draft = try JSONDecoder().decode(GmailDraft.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(draft.id, "draft123")
        XCTAssertEqual(draft.message?.id, "msg1")
    }

    func testDraftResponseWithoutMessage() throws {
        let json = """
        {"id": "draft456"}
        """
        let draft = try JSONDecoder().decode(GmailDraft.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(draft.id, "draft456")
        XCTAssertNil(draft.message)
    }
}
