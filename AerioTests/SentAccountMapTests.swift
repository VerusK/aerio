import XCTest
@testable import Aerio

@MainActor
final class SentAccountMapTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "SentAccountMapTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeMap(cap: Int = 2000) -> SentAccountMap {
        SentAccountMap(defaults: defaults, cap: cap)
    }

    func testRecordThenLookupRoundTrip() {
        let m = makeMap()
        m.record(recipient: "alice@example.com", accountId: "acct-1")
        XCTAssertEqual(m.accountId(forRecipient: "alice@example.com"), "acct-1")
    }

    func testLookupNormalizesCaseAndWhitespace() {
        let m = makeMap()
        m.record(recipient: "Alice@Example.com", accountId: "acct-1")
        XCTAssertEqual(m.accountId(forRecipient: "  alice@example.com "), "acct-1")
    }

    func testNewerWriteWins() {
        let m = makeMap()
        m.record(recipient: "bob@x.com", accountId: "acct-1", at: Date(timeIntervalSince1970: 100))
        m.record(recipient: "bob@x.com", accountId: "acct-2", at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(m.accountId(forRecipient: "bob@x.com"), "acct-2")
    }

    func testUnknownRecipientReturnsNil() {
        XCTAssertNil(makeMap().accountId(forRecipient: "nobody@x.com"))
    }

    func testEmptyInputsIgnored() {
        let m = makeMap()
        m.record(recipient: "", accountId: "acct-1")
        m.record(recipient: "a@x.com", accountId: "")
        XCTAssertNil(m.accountId(forRecipient: ""))
        XCTAssertNil(m.accountId(forRecipient: "a@x.com"))
    }

    func testRecordRecipientsCoversToAndCc() {
        let m = makeMap()
        m.recordRecipients(to: "Alice <alice@x.com>", cc: "bob@x.com", accountId: "acct-7")
        XCTAssertEqual(m.accountId(forRecipient: "alice@x.com"), "acct-7")
        XCTAssertEqual(m.accountId(forRecipient: "bob@x.com"), "acct-7")
    }

    func testRecordRecipientsHandlesQuotedCommaDisplayName() {
        let m = makeMap()
        m.recordRecipients(to: "\"Doe, Jane\" <jane@x.com>, ted@x.com", cc: "", accountId: "acct-9")
        // The quoted comma must NOT split into a bogus "Doe" entry.
        XCTAssertEqual(m.accountId(forRecipient: "jane@x.com"), "acct-9")
        XCTAssertEqual(m.accountId(forRecipient: "ted@x.com"), "acct-9")
        XCTAssertNil(m.accountId(forRecipient: "\"Doe"))
    }

    func testPersistsAcrossInstances() {
        makeMap().record(recipient: "carol@x.com", accountId: "acct-3")
        let reopened = makeMap()
        XCTAssertEqual(reopened.accountId(forRecipient: "carol@x.com"), "acct-3")
    }

    func testCapEvictsOldestFirst() {
        let m = makeMap(cap: 2)
        m.record(recipient: "old@x.com", accountId: "a", at: Date(timeIntervalSince1970: 1))
        m.record(recipient: "mid@x.com", accountId: "a", at: Date(timeIntervalSince1970: 2))
        m.record(recipient: "new@x.com", accountId: "a", at: Date(timeIntervalSince1970: 3))
        XCTAssertNil(m.accountId(forRecipient: "old@x.com"), "oldest entry evicted when over cap")
        XCTAssertEqual(m.accountId(forRecipient: "mid@x.com"), "a")
        XCTAssertEqual(m.accountId(forRecipient: "new@x.com"), "a")
    }
}
