import XCTest
@testable import Aerio

final class ComposeDraftTests: XCTestCase {

    // MARK: - Recipient validation (pre-send)

    func testBareNameRecipientIsRejected() {
        // The actual bug: "Stonebraker" (no email) reached the To header → Gmail 400.
        let problem = ComposeView.invalidRecipientMessage(to: "Stonebraker", cc: "")
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem!.contains("Stonebraker"))
    }

    func testValidEmailRecipientPasses() {
        XCTAssertNil(ComposeView.invalidRecipientMessage(to: "alice@example.com", cc: ""))
    }

    func testValidNamedRecipientPasses() {
        XCTAssertNil(ComposeView.invalidRecipientMessage(to: "Alice <alice@example.com>", cc: ""))
        XCTAssertNil(ComposeView.invalidRecipientMessage(to: "Иван <ivan@example.com>", cc: ""))
    }

    func testQuotedCommaNameRecipientPasses() {
        // A "Last, First" contact, properly quoted, is ONE valid recipient.
        XCTAssertNil(ComposeView.invalidRecipientMessage(
            to: "\"Stonebraker, Kelli Elizabeth\" <kellistonebraker@synovus.com>", cc: ""))
    }

    func testEmptyToIsRejected() {
        XCTAssertNotNil(ComposeView.invalidRecipientMessage(to: "", cc: ""))
        XCTAssertNotNil(ComposeView.invalidRecipientMessage(to: "   ", cc: ""))
    }

    func testInvalidCcIsRejected() {
        XCTAssertNotNil(ComposeView.invalidRecipientMessage(to: "alice@example.com", cc: "bob"))
    }

    func testOneBadAmongGoodRecipientsIsRejected() {
        let problem = ComposeView.invalidRecipientMessage(to: "alice@example.com, Stonebraker", cc: "")
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem!.contains("Stonebraker"))
    }

    func testIsValidEmail() {
        XCTAssertTrue(ComposeView.isValidEmail("a@b.co"))
        XCTAssertTrue(ComposeView.isValidEmail("alice.smith@mail.example.com"))
        XCTAssertFalse(ComposeView.isValidEmail("Stonebraker"))
        XCTAssertFalse(ComposeView.isValidEmail("no-at-sign.com"))
        XCTAssertFalse(ComposeView.isValidEmail("missing@domain"))
        XCTAssertFalse(ComposeView.isValidEmail("two@@at.com"))
        XCTAssertFalse(ComposeView.isValidEmail("space in@email.com"))
        XCTAssertFalse(ComposeView.isValidEmail("@example.com"))
    }

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
