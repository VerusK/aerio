import XCTest
@testable import Aerio

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

    private func decode(_ raw: String) -> String {
        String(data: RFC2822Builder.base64URLDecode(raw)!, encoding: .utf8)!
    }

    func testNonASCIIDisplayNameInToIsEncoded() {
        // The bug: a Cyrillic display name in To went out as raw UTF-8 → Gmail
        // rejected the send with "HTTP 400: Invalid To header".
        let raw = RFC2822Builder.buildRawMessage(
            from: "sender@test.com",
            to: "Иван Петров <ivan@test.com>",
            subject: "Hi",
            body: "Test"
        )
        let message = decode(raw)
        // No raw non-ASCII in the To header…
        XCTAssertFalse(message.contains("To: Иван"))
        XCTAssertFalse(message.contains("Иван Петров <ivan@test.com>"))
        // …the display name is RFC 2047 encoded and the address preserved.
        XCTAssertTrue(message.contains("=?UTF-8?Q?"))
        XCTAssertTrue(message.contains("<ivan@test.com>"))
    }

    func testPlainEmailToHeaderPreserved() {
        let raw = RFC2822Builder.buildRawMessage(
            from: "a@b.com", to: "recipient@test.com", subject: "Hi", body: "x"
        )
        XCTAssertTrue(decode(raw).contains("To: recipient@test.com"))
    }

    func testASCIINameWithCommaIsQuoted() {
        let raw = RFC2822Builder.buildRawMessage(
            from: "a@b.com", to: "\"Doe, John\" <john@test.com>", subject: "Hi", body: "x"
        )
        let message = decode(raw)
        XCTAssertTrue(message.contains("\"Doe, John\" <john@test.com>"))
    }

    func testMultipleRecipientsEncodedAndJoined() {
        let raw = RFC2822Builder.buildRawMessage(
            from: "a@b.com",
            to: "plain@test.com, Анна <anna@test.com>",
            subject: "Hi", body: "x"
        )
        let message = decode(raw)
        XCTAssertTrue(message.contains("plain@test.com"))
        XCTAssertTrue(message.contains("<anna@test.com>"))
        XCTAssertFalse(message.contains("Анна"))
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

    // MARK: - HTML Message Tests

    private func decodeRaw(_ raw: String) -> String {
        guard let data = RFC2822Builder.base64URLDecode(raw) else {
            XCTFail("Failed to decode raw message")
            return ""
        }
        guard let string = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to decode UTF-8 from raw message")
            return ""
        }
        return string
    }

    func testBuildRawHTMLMessageStructure() {
        let raw = RFC2822Builder.buildRawHTMLMessage(
            from: "sender@test.com",
            to: "recipient@test.com",
            subject: "HTML Test",
            htmlBody: "<p>Hello</p>",
            plainBody: "Hello"
        )
        let message = decodeRaw(raw)

        XCTAssertTrue(message.contains("From: sender@test.com"))
        XCTAssertTrue(message.contains("To: recipient@test.com"))
        XCTAssertTrue(message.contains("Subject: HTML Test"))
        XCTAssertTrue(message.contains("MIME-Version: 1.0"))
        XCTAssertTrue(message.contains("Content-Type: multipart/alternative; boundary="))

        // Should have two parts: text/plain and text/html
        XCTAssertTrue(message.contains("Content-Type: text/plain; charset=UTF-8"))
        XCTAssertTrue(message.contains("Content-Type: text/html; charset=UTF-8"))

        // Both parts should be base64 encoded
        let plainBase64 = Data("Hello".utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let htmlBase64 = Data("<p>Hello</p>".utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        XCTAssertTrue(message.contains(plainBase64))
        XCTAssertTrue(message.contains(htmlBase64))

        // Verify boundary closing marker exists
        // Extract boundary from Content-Type header
        let boundaryPrefix = "boundary=\""
        guard let boundaryStart = message.range(of: boundaryPrefix) else {
            XCTFail("No boundary found")
            return
        }
        let afterPrefix = message[boundaryStart.upperBound...]
        guard let boundaryEnd = afterPrefix.firstIndex(of: "\"") else {
            XCTFail("No closing quote for boundary")
            return
        }
        let boundary = String(afterPrefix[..<boundaryEnd])
        XCTAssertTrue(message.contains("--\(boundary)--"))
    }

    func testBuildRawHTMLMessageNonASCIISubject() {
        let raw = RFC2822Builder.buildRawHTMLMessage(
            from: "sender@test.com",
            to: "recipient@test.com",
            subject: "Тема письма",
            htmlBody: "<p>Привет</p>",
            plainBody: "Привет"
        )
        let message = decodeRaw(raw)

        // Subject should be Q-encoded
        XCTAssertTrue(message.contains("=?UTF-8?Q?"))
        XCTAssertFalse(message.contains("Subject: Тема"))

        // Body content should still be present (base64 encoded)
        let plainBase64 = Data("Привет".utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        XCTAssertTrue(message.contains(plainBase64))
    }

    // MARK: - Attachment Tests

    func testBuildHTMLMessageWithInlineImages() {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header bytes
        let raw = RFC2822Builder.buildRawHTMLMessageWithAttachments(
            from: "sender@test.com",
            to: "recipient@test.com",
            subject: "Inline Image",
            htmlBody: "<p><img src=\"cid:img1\"></p>",
            plainBody: "See image",
            inlineImages: [
                RFC2822Builder.InlineImage(cid: "img1", mimeType: "image/png", data: imageData)
            ]
        )
        let message = decodeRaw(raw)

        // Top-level should be multipart/related
        XCTAssertTrue(message.contains("Content-Type: multipart/related; boundary="))
        // Should contain alternative sub-part
        XCTAssertTrue(message.contains("Content-Type: multipart/alternative; boundary="))
        // Should have inline image with CID
        XCTAssertTrue(message.contains("Content-ID: <img1>"))
        XCTAssertTrue(message.contains("Content-Disposition: inline"))
        XCTAssertTrue(message.contains("Content-Type: image/png"))
        // Image data should be base64 encoded
        let imgBase64 = imageData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        XCTAssertTrue(message.contains(imgBase64))
    }

    func testBuildHTMLMessageWithFileAttachments() {
        let fileData = Data("file content".utf8)
        let raw = RFC2822Builder.buildRawHTMLMessageWithAttachments(
            from: "sender@test.com",
            to: "recipient@test.com",
            subject: "With Attachment",
            htmlBody: "<p>See attached</p>",
            plainBody: "See attached",
            attachments: [
                RFC2822Builder.Attachment(filename: "report.pdf", mimeType: "application/pdf", data: fileData)
            ]
        )
        let message = decodeRaw(raw)

        // Top-level should be multipart/mixed
        XCTAssertTrue(message.contains("Content-Type: multipart/mixed; boundary="))
        // Should contain alternative sub-part
        XCTAssertTrue(message.contains("Content-Type: multipart/alternative; boundary="))
        // Should have attachment with correct disposition and filename
        XCTAssertTrue(message.contains("Content-Disposition: attachment; filename=\"report.pdf\""))
        XCTAssertTrue(message.contains("Content-Type: application/pdf; name=\"report.pdf\""))
        // File data should be base64 encoded
        let fileBase64 = fileData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        XCTAssertTrue(message.contains(fileBase64))
    }

    func testBuildHTMLMessageWithBothInlineAndFileAttachments() {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG header
        let fileData = Data("spreadsheet".utf8)
        let raw = RFC2822Builder.buildRawHTMLMessageWithAttachments(
            from: "sender@test.com",
            to: "recipient@test.com",
            subject: "Full combo",
            htmlBody: "<p><img src=\"cid:photo1\"> See attached</p>",
            plainBody: "See attached",
            attachments: [
                RFC2822Builder.Attachment(filename: "data.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", data: fileData)
            ],
            inlineImages: [
                RFC2822Builder.InlineImage(cid: "photo1", mimeType: "image/jpeg", data: imageData)
            ]
        )
        let message = decodeRaw(raw)

        // Top-level: multipart/mixed (because we have file attachments)
        XCTAssertTrue(message.contains("Content-Type: multipart/mixed; boundary="))
        // Second level: multipart/related (because we have inline images)
        XCTAssertTrue(message.contains("Content-Type: multipart/related; boundary="))
        // Third level: multipart/alternative (plain + html)
        XCTAssertTrue(message.contains("Content-Type: multipart/alternative; boundary="))

        // Inline image
        XCTAssertTrue(message.contains("Content-ID: <photo1>"))
        XCTAssertTrue(message.contains("Content-Type: image/jpeg"))

        // File attachment
        XCTAssertTrue(message.contains("Content-Disposition: attachment; filename=\"data.xlsx\""))

        // Verify all three boundary closing markers exist
        // Extract boundaries
        guard let mixedBoundaryRange = message.range(of: "multipart/mixed; boundary=\""),
              let mixedEnd = message[mixedBoundaryRange.upperBound...].firstIndex(of: "\"") else {
            XCTFail("Missing multipart/mixed boundary")
            return
        }
        let mixedBoundary = String(message[mixedBoundaryRange.upperBound..<mixedEnd])

        guard let relatedBoundaryRange = message.range(of: "multipart/related; boundary=\""),
              let relatedEnd = message[relatedBoundaryRange.upperBound...].firstIndex(of: "\"") else {
            XCTFail("Missing multipart/related boundary")
            return
        }
        let relatedBoundary = String(message[relatedBoundaryRange.upperBound..<relatedEnd])

        guard let altBoundaryRange = message.range(of: "multipart/alternative; boundary=\""),
              let altEnd = message[altBoundaryRange.upperBound...].firstIndex(of: "\"") else {
            XCTFail("Missing multipart/alternative boundary")
            return
        }
        let altBoundary = String(message[altBoundaryRange.upperBound..<altEnd])

        XCTAssertTrue(message.contains("--\(mixedBoundary)--"))
        XCTAssertTrue(message.contains("--\(relatedBoundary)--"))
        XCTAssertTrue(message.contains("--\(altBoundary)--"))
    }

    func testBuildHTMLMessageWithEmptyBodyAndEmptyAttachments() {
        let raw = RFC2822Builder.buildRawHTMLMessageWithAttachments(
            from: "sender@test.com",
            to: "recipient@test.com",
            subject: "Empty",
            htmlBody: "",
            plainBody: "",
            attachments: [],
            inlineImages: []
        )
        let message = decodeRaw(raw)

        // No attachments or inline => falls back to multipart/alternative
        XCTAssertTrue(message.contains("Content-Type: multipart/alternative; boundary="))
        // Should NOT contain mixed or related
        XCTAssertFalse(message.contains("multipart/mixed"))
        XCTAssertFalse(message.contains("multipart/related"))
        // Headers should still be present
        XCTAssertTrue(message.contains("From: sender@test.com"))
        XCTAssertTrue(message.contains("Subject: Empty"))
        // Both parts should exist (even if empty bodies)
        XCTAssertTrue(message.contains("Content-Type: text/plain; charset=UTF-8"))
        XCTAssertTrue(message.contains("Content-Type: text/html; charset=UTF-8"))
    }
}
