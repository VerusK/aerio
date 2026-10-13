import XCTest
@testable import Aerio

@MainActor
final class MailtoRouterTests: XCTestCase {
    /// Cold launch: the link arrives before MainView has registered its handler.
    func testLinksReceivedBeforeHandlerAreDeliveredInOrder() {
        let router = MailtoRouter()
        router.open(URL(string: "mailto:first@x.com")!)
        router.open(URL(string: "mailto:second@x.com")!)

        var received: [String] = []
        router.handler = { received.append($0.to) }

        XCTAssertEqual(received, ["first@x.com", "second@x.com"])
    }

    func testLinkAfterHandlerIsDeliveredImmediately() {
        let router = MailtoRouter()
        var received: [String] = []
        router.handler = { received.append($0.to) }

        router.open(URL(string: "mailto:a@b.com")!)

        XCTAssertEqual(received, ["a@b.com"])
    }

    func testQueuedLinksAreDeliveredOnlyOnce() {
        let router = MailtoRouter()
        router.open(URL(string: "mailto:a@b.com")!)

        var count = 0
        router.handler = { _ in count += 1 }
        router.handler = { _ in count += 1 }

        XCTAssertEqual(count, 1)
    }

    func testNonMailtoURLIsIgnored() {
        let router = MailtoRouter()
        var count = 0
        router.handler = { _ in count += 1 }

        router.open(URL(string: "https://example.com")!)

        XCTAssertEqual(count, 0)
    }
}
