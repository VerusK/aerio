import XCTest
@testable import AgMail

final class RFC2822BuilderTests: XCTestCase {

    func testPlainASCIIMessage() {
        let raw = RFC2822Builder.buildRawMessage(
            from: "sender@test.com",
            to: "recipient@test.com",
            subject: "Hello World",
            body: "This is a test message."
        )

        // Decode and verify structure
        guard let data = RFC2822Builder.base64URLDecode(raw) else {
            XCTFail("Failed to decode raw message")
            return
        }
        let message = String(data: data, encoding: .utf8)!

        XCTAssertTrue(message.contains("From: sender@test.com"))
        XCTAssertTrue(message.contains("To: recipient@test.com"))
        XCTAssertTrue(message.contains("Subject: Hello World"))
        XCTAssertTrue(message.contains("MIME-Version: 1.0"))
        XCTAssertTrue(message.contains("Content-Type: text/plain; charset=UTF-8"))
        XCTAssertFalse(message.contains("Cc:"))
        XCTAssertFalse(message.contains("In-Reply-To:"))
    }

    func testNonASCIISubjectQEncoding() {
        let raw = RFC2822Builder.buildRawMessage(
            from: "sender@test.com",
            to: "recipient@test.com",
            subject: "Привет мир",
            body: "Test"
        )

        guard let data = RFC2822Builder.base64URLDecode(raw) else {
            XCTFail("Failed to decode raw message")
            return
        }
        let message = String(data: data, encoding: .utf8)!

        XCTAssertTrue(message.contains("=?UTF-8?Q?"))
        XCTAssertTrue(message.contains("?="))
        // Should not contain raw non-ASCII in Subject line
        XCTAssertFalse(message.contains("Subject: Привет"))
    }

    func testASCIISubjectNotQEncoded() {
        let raw = RFC2822Builder.buildRawMessage(
            from: "a@b.com",
            to: "c@d.com",
            subject: "Plain subject",
            body: "Test"
        )

        guard let data = RFC2822Builder.base64URLDecode(raw) else {
            XCTFail("Failed to decode raw message")
            return
        }
        let message = String(data: data, encoding: .utf8)!

        XCTAssertTrue(message.contains("Subject: Plain subject"))
        XCTAssertFalse(message.contains("=?UTF-8?Q?"))
    }

    func testBase64URLEncodeDecodeRoundtrip() {
        let original = "Hello, World! This is a test with special chars: +/= and more"
        let data = Data(original.utf8)
        let encoded = RFC2822Builder.base64URLEncode(data)

        // base64url should NOT contain +, /, or =
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))

        guard let decoded = RFC2822Builder.base64URLDecode(encoded) else {
            XCTFail("Failed to decode")
            return
        }
        XCTAssertEqual(String(data: decoded, encoding: .utf8), original)
    }

    func testMessageWithCcAndInReplyTo() {
        let raw = RFC2822Builder.buildRawMessage(
            from: "sender@test.com",
            to: "recipient@test.com",
            cc: "cc@test.com",
            subject: "Re: Thread",
            body: "Reply body",
            inReplyTo: "<msg123@mail.gmail.com>",
            references: "<msg123@mail.gmail.com>"
        )

        guard let data = RFC2822Builder.base64URLDecode(raw) else {
            XCTFail("Failed to decode raw message")
            return
        }
        let message = String(data: data, encoding: .utf8)!

        XCTAssertTrue(message.contains("Cc: cc@test.com"))
        XCTAssertTrue(message.contains("In-Reply-To: <msg123@mail.gmail.com>"))
        XCTAssertTrue(message.contains("References: <msg123@mail.gmail.com>"))
    }

    func testEmptyCcAndInReplyToOmitted() {
        let raw = RFC2822Builder.buildRawMessage(
            from: "a@b.com",
            to: "c@d.com",
            cc: "",
            subject: "Test",
            body: "Body",
            inReplyTo: "",
            references: ""
        )

        guard let data = RFC2822Builder.base64URLDecode(raw) else {
            XCTFail("Failed to decode raw message")
            return
        }
        let message = String(data: data, encoding: .utf8)!

        XCTAssertFalse(message.contains("Cc:"))
        XCTAssertFalse(message.contains("In-Reply-To:"))
        XCTAssertFalse(message.contains("References:"))
    }
}
