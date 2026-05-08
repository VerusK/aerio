import XCTest
@testable import Aerio

final class RFC2822BuilderPayloadTests: XCTestCase {
    func testBuild_plainBody_decodesToValidRFC2822WithExpectedHeaders() {
        let payload = ComposePayload(
            from: "me@example.com",
            to: "you@example.com",
            cc: nil,
            subject: "Hello",
            body: "World",
            inReplyTo: nil,
            references: nil,
            htmlBody: nil,
            attachments: [],
            inlineImages: [],
            messageId: nil
        )
        let raw = RFC2822Builder.build(payload)
        let decoded = String(data: RFC2822Builder.base64URLDecode(raw)!, encoding: .utf8)!
        XCTAssertTrue(decoded.contains("From: me@example.com"))
        XCTAssertTrue(decoded.contains("To: you@example.com"))
        XCTAssertTrue(decoded.contains("Subject: Hello"))
        XCTAssertFalse(decoded.contains("Message-ID:"))
    }

    func testBuild_withMessageId_embedsMessageIDHeader() {
        let payload = ComposePayload(
            from: "me@example.com", to: "you@example.com", cc: nil,
            subject: "Hi", body: "B", inReplyTo: nil, references: nil,
            htmlBody: nil, attachments: [], inlineImages: [],
            messageId: "<abc-123@aerio.local>"
        )
        let raw = RFC2822Builder.build(payload)
        let decoded = String(data: RFC2822Builder.base64URLDecode(raw)!, encoding: .utf8)!
        XCTAssertTrue(decoded.contains("Message-ID: <abc-123@aerio.local>"))
    }

    func testBuild_withHtmlBody_producesMultipartAlternative() {
        let payload = ComposePayload(
            from: "a@b.c", to: "d@e.f", cc: nil,
            subject: "S", body: "PLAIN", inReplyTo: nil, references: nil,
            htmlBody: "<p>HTML</p>", attachments: [], inlineImages: [],
            messageId: "<x@aerio.local>"
        )
        let raw = RFC2822Builder.build(payload)
        let decoded = String(data: RFC2822Builder.base64URLDecode(raw)!, encoding: .utf8)!
        XCTAssertTrue(decoded.contains("multipart/alternative"))
        XCTAssertTrue(decoded.contains("Message-ID: <x@aerio.local>"))
    }

    func testBuild_withAttachments_producesMultipartMixedWithMessageId() {
        let payload = ComposePayload(
            from: "a@b", to: "c@d", cc: nil,
            subject: "S", body: "B", inReplyTo: nil, references: nil,
            htmlBody: "<p>H</p>",
            attachments: [.init(filename: "f.txt", mimeType: "text/plain", data: Data("FILE".utf8))],
            inlineImages: [],
            messageId: "<y@aerio.local>"
        )
        let raw = RFC2822Builder.build(payload)
        let decoded = String(data: RFC2822Builder.base64URLDecode(raw)!, encoding: .utf8)!
        XCTAssertTrue(decoded.contains("multipart/mixed"))
        XCTAssertTrue(decoded.contains("Message-ID: <y@aerio.local>"))
        XCTAssertTrue(decoded.contains("filename=\"f.txt\""))
    }
}
