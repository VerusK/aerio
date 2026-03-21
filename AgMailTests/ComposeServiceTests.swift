import XCTest
@testable import AgMail

final class ComposeServiceTests: XCTestCase {

    // MARK: - New Compose

    func testNewComposeURL() {
        let url = ComposeService.composeURL(type: .new)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("view=cm"))
        XCTAssertTrue(url!.absoluteString.contains("fs=1"))
        XCTAssertTrue(url!.absoluteString.contains("tf=1"))
    }

    func testNewComposeWithRecipient() {
        let url = ComposeService.composeURL(type: .new, to: "alice@example.com")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("to=alice"))
    }

    func testNewComposeWithSubject() {
        let url = ComposeService.composeURL(type: .new, subject: "Hello")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("su=Hello"))
    }

    func testNewComposeWithBody() {
        let url = ComposeService.composeURL(type: .new, body: "Hi there")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("body=Hi"))
    }

    func testNewComposeWithAllFields() {
        let url = ComposeService.composeURL(
            type: .new,
            to: "bob@example.com",
            subject: "Test",
            body: "Content"
        )
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertTrue(s.contains("to=bob"))
        XCTAssertTrue(s.contains("su=Test"))
        XCTAssertTrue(s.contains("body=Content"))
    }

    // MARK: - Reply

    func testReplyURL() {
        let url = ComposeService.composeURL(type: .reply, msgId: "18abc123def")
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertTrue(s.contains("rm=18abc123def"))
        XCTAssertTrue(s.contains("rmt=reply"))
    }

    func testReplyWithoutMsgIdReturnsNil() {
        let url = ComposeService.composeURL(type: .reply)
        XCTAssertNil(url)
    }

    // MARK: - Reply All

    func testReplyAllURL() {
        let url = ComposeService.composeURL(type: .replyAll, msgId: "18abc123def")
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertTrue(s.contains("rm=18abc123def"))
        XCTAssertTrue(s.contains("rmt=replyall"))
    }

    func testReplyAllWithoutMsgIdReturnsNil() {
        let url = ComposeService.composeURL(type: .replyAll)
        XCTAssertNil(url)
    }

    // MARK: - Forward

    func testForwardURL() {
        let url = ComposeService.composeURL(type: .forward, msgId: "18abc123def")
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertTrue(s.contains("rm=18abc123def"))
        XCTAssertTrue(s.contains("rmt=forward"))
    }

    func testForwardWithRecipient() {
        let url = ComposeService.composeURL(type: .forward, to: "carol@example.com", msgId: "18abc123def")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("to=carol"))
    }

    func testForwardWithoutMsgIdReturnsNil() {
        let url = ComposeService.composeURL(type: .forward)
        XCTAssertNil(url)
    }

    // MARK: - Account Index

    func testAccountIndex() {
        let url = ComposeService.composeURL(type: .new, accountIndex: 2)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("/mail/u/2/"))
    }

    func testDefaultAccountIndex() {
        let url = ComposeService.composeURL(type: .new)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("/mail/u/0/"))
    }
}
