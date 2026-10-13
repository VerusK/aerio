import XCTest
@testable import Aerio

final class MailtoURLTests: XCTestCase {
    private func seed(_ string: String) -> ComposeSeed? {
        MailtoURL.seed(from: URL(string: string)!)
    }

    func testPlainAddress() {
        let s = seed("mailto:sleepwalker.js@gmail.com")
        XCTAssertEqual(s?.to, "sleepwalker.js@gmail.com")
        XCTAssertEqual(s?.cc, "")
        XCTAssertEqual(s?.subject, "")
        XCTAssertEqual(s?.body, "")
    }

    func testSubjectAndBodyArePercentDecoded() {
        let s = seed("mailto:a@b.com?subject=Hello%20there&body=Line%201%0D%0ALine%202")
        XCTAssertEqual(s?.subject, "Hello there")
        XCTAssertEqual(s?.body, "Line 1\nLine 2")
    }

    func testNonASCIISubject() {
        let s = seed("mailto:a@b.com?subject=%D0%A2%D0%B5%D1%81%D1%82")
        XCTAssertEqual(s?.subject, "Тест")
    }

    /// RFC 6068: "+" is a literal plus, not an encoded space.
    func testPlusStaysLiteral() {
        let s = seed("mailto:a+tag@b.com?subject=1+1")
        XCTAssertEqual(s?.to, "a+tag@b.com")
        XCTAssertEqual(s?.subject, "1+1")
    }

    func testEncodedAmpersandInValue() {
        let s = seed("mailto:a@b.com?subject=Tom%20%26%20Jerry")
        XCTAssertEqual(s?.subject, "Tom & Jerry")
    }

    func testMultipleAddressesInPath() {
        let s = seed("mailto:a@b.com,c@d.com")
        XCTAssertEqual(s?.to, "a@b.com, c@d.com")
    }

    func testToParameterIsMergedWithPath() {
        let s = seed("mailto:a@b.com?to=c@d.com")
        XCTAssertEqual(s?.to, "a@b.com, c@d.com")
    }

    func testAddressOnlyInToParameter() {
        let s = seed("mailto:?to=c@d.com&subject=Hi")
        XCTAssertEqual(s?.to, "c@d.com")
        XCTAssertEqual(s?.subject, "Hi")
    }

    func testCc() {
        let s = seed("mailto:a@b.com?cc=c@d.com,e@f.com")
        XCTAssertEqual(s?.cc, "c@d.com, e@f.com")
    }

    func testKeysAreCaseInsensitive() {
        let s = seed("MAILTO:a@b.com?Subject=Hi&CC=c@d.com&BODY=Text")
        XCTAssertEqual(s?.to, "a@b.com")
        XCTAssertEqual(s?.subject, "Hi")
        XCTAssertEqual(s?.cc, "c@d.com")
        XCTAssertEqual(s?.body, "Text")
    }

    /// Compose has no Bcc field; bcc recipients must not leak into To or Cc.
    func testBccIsIgnored() {
        let s = seed("mailto:a@b.com?bcc=hidden@x.com")
        XCTAssertEqual(s?.to, "a@b.com")
        XCTAssertEqual(s?.cc, "")
    }

    func testEmptyMailtoOpensBlankCompose() {
        let s = seed("mailto:")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.to, "")
    }

    func testNonMailtoURLIsRejected() {
        XCTAssertNil(seed("https://example.com"))
        XCTAssertNil(seed("aerio://attachment/open/x"))
    }

    /// Clicking a link and closing the window untouched must not leave a Gmail draft.
    func testMailtoSeedDoesNotMarkComposeDirty() {
        XCTAssertEqual(seed("mailto:a@b.com?subject=Hi")?.marksDirty, false)
        XCTAssertTrue(ComposeSeed().marksDirty)
    }
    /// Subject is a single-line field: CR/LF from the link collapses into one space
    /// instead of reaching the outgoing headers.
    func testSubjectCRLFCollapsedToSpace() {
        let s = seed("mailto:victim@example.com?subject=Hello%0D%0ABcc:%20attacker@example.com")
        XCTAssertEqual(s?.subject, "Hello Bcc: attacker@example.com")
        XCTAssertEqual(seed("mailto:a@b.com?subject=One%0ATwo%0D%0A%0D%0AThree")?.subject,
                       "One Two Three")
    }

    /// A quoted local part may contain an (encoded) comma; it must stay one address.
    func testQuotedLocalPartWithCommaIsNotSplit() {
        let s = seed("mailto:%22a%2Cb%22@example.com")
        XCTAssertEqual(s?.to, "\"a,b\"@example.com")
    }
}
