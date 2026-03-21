import XCTest
@testable import AgMail

@MainActor
final class GmailScraperManagerTests: XCTestCase {

    private func makeAccountManager() -> AccountManager {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return AccountManager(defaults: defaults)
    }

    private func makeAccount(id: String = "acc1", email: String = "test@gmail.com") -> Account {
        Account(id: id, email: email, displayName: "Test", color: .blue)
    }

    // MARK: - Add/Remove scrapers

    func testAddScraperForAccount() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)
        let account = makeAccount()

        manager.addScraper(for: account)

        XCTAssertNotNil(manager.scraper(for: account.id))
        XCTAssertEqual(manager.scrapers.count, 1)
    }

    func testAddDuplicateScraperIsIgnored() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)
        let account = makeAccount()

        manager.addScraper(for: account)
        manager.addScraper(for: account)

        XCTAssertEqual(manager.scrapers.count, 1)
    }

    func testRemoveScraper() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)
        let account = makeAccount()

        manager.addScraper(for: account)
        manager.removeScraper(for: account.id)

        XCTAssertNil(manager.scraper(for: account.id))
        XCTAssertEqual(manager.scrapers.count, 0)
    }

    func testRemoveScraperCleansUpData() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)
        let account = makeAccount()

        manager.addScraper(for: account)
        manager.emailsByAccount[account.id] = [
            Email(msgId: "m1", from: "a@b.com", subject: "Hi", date: Date(), snippet: "", accountId: account.id, folder: .inbox)
        ]
        manager.unreadCountsByAccount[account.id] = 5

        manager.removeScraper(for: account.id)

        XCTAssertNil(manager.emailsByAccount[account.id])
        XCTAssertNil(manager.unreadCountsByAccount[account.id])
    }

    // MARK: - Sync with AccountManager

    func testSyncScrapersOnAccountAdd() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)

        let account = makeAccount()
        am.addAccount(account)

        // Combine publisher fires synchronously on @Published
        XCTAssertNotNil(manager.scraper(for: account.id))
    }

    func testSyncScrapersOnAccountRemove() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)

        let account = makeAccount()
        am.addAccount(account)
        XCTAssertNotNil(manager.scraper(for: account.id))

        am.removeAccount(id: account.id)
        XCTAssertNil(manager.scraper(for: account.id))
    }

    // MARK: - Multiple accounts

    func testMultipleScrapers() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)

        let acc1 = makeAccount(id: "acc1", email: "a@gmail.com")
        let acc2 = makeAccount(id: "acc2", email: "b@gmail.com")
        let acc3 = makeAccount(id: "acc3", email: "c@gmail.com")

        manager.addScraper(for: acc1)
        manager.addScraper(for: acc2)
        manager.addScraper(for: acc3)

        XCTAssertEqual(manager.scrapers.count, 3)
        XCTAssertNotNil(manager.scraper(for: "acc1"))
        XCTAssertNotNil(manager.scraper(for: "acc2"))
        XCTAssertNotNil(manager.scraper(for: "acc3"))
    }

    // MARK: - Polling state

    func testStartStopPolling() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)

        XCTAssertFalse(manager.isPolling)

        manager.startPollingAll()
        XCTAssertTrue(manager.isPolling)

        manager.stopPollingAll()
        XCTAssertFalse(manager.isPolling)
    }

    // MARK: - Aggregated data

    func testAllEmailsAggregation() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)

        let now = Date()
        manager.emailsByAccount["acc1"] = [
            Email(msgId: "m1", from: "a@b.com", subject: "Hi", date: now.addingTimeInterval(-100), snippet: "", accountId: "acc1", folder: .inbox),
        ]
        manager.emailsByAccount["acc2"] = [
            Email(msgId: "m2", from: "c@d.com", subject: "Hey", date: now, snippet: "", accountId: "acc2", folder: .inbox),
        ]

        let all = manager.allEmails
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].msgId, "m2") // newest first
    }

    func testTotalUnreadCount() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)

        manager.unreadCountsByAccount["acc1"] = 3
        manager.unreadCountsByAccount["acc2"] = 7

        XCTAssertEqual(manager.totalUnreadCount, 10)
    }

    func testTotalUnreadCountEmpty() {
        let am = makeAccountManager()
        let manager = GmailScraperManager(accountManager: am)

        XCTAssertEqual(manager.totalUnreadCount, 0)
    }
}
