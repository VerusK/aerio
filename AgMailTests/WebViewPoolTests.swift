import XCTest
import WebKit
@testable import AgMail

@MainActor
final class WebViewPoolTests: XCTestCase {
    private var pool: WebViewPool!

    override func setUp() {
        super.setUp()
        pool = WebViewPool()
    }

    override func tearDown() {
        pool.removeAll()
        pool = nil
        super.tearDown()
    }

    func testCreateWebViewsReturnsEntry() {
        let entry = pool.createWebViews(for: "acc1")
        XCTAssertEqual(entry.accountId, "acc1")
        XCTAssertNotNil(entry.hiddenWebView)
        XCTAssertNotNil(entry.visibleWebView)
    }

    func testCreateWebViewsReturnsSameEntryForSameAccount() {
        let entry1 = pool.createWebViews(for: "acc1")
        let entry2 = pool.createWebViews(for: "acc1")
        XCTAssertTrue(entry1.hiddenWebView === entry2.hiddenWebView)
        XCTAssertTrue(entry1.visibleWebView === entry2.visibleWebView)
    }

    func testDifferentAccountsGetDifferentDataStores() {
        let entry1 = pool.createWebViews(for: "acc1")
        let entry2 = pool.createWebViews(for: "acc2")
        XCTAssertFalse(entry1.dataStore === entry2.dataStore)
    }

    func testDifferentAccountsGetDifferentWebViews() {
        let entry1 = pool.createWebViews(for: "acc1")
        let entry2 = pool.createWebViews(for: "acc2")
        XCTAssertFalse(entry1.hiddenWebView === entry2.hiddenWebView)
        XCTAssertFalse(entry1.visibleWebView === entry2.visibleWebView)
    }

    func testHiddenAndVisibleShareDataStore() {
        let entry = pool.createWebViews(for: "acc1")
        let hiddenStore = entry.hiddenWebView.configuration.websiteDataStore
        let visibleStore = entry.visibleWebView.configuration.websiteDataStore
        XCTAssertTrue(hiddenStore === visibleStore)
    }

    func testDataStoreIsNonPersistent() {
        let entry = pool.createWebViews(for: "acc1")
        XCTAssertFalse(entry.dataStore.isPersistent)
    }

    func testRemoveWebViews() {
        _ = pool.createWebViews(for: "acc1")
        XCTAssertNotNil(pool.entry(for: "acc1"))
        pool.removeWebViews(for: "acc1")
        XCTAssertNil(pool.entry(for: "acc1"))
    }

    func testRemoveAll() {
        _ = pool.createWebViews(for: "acc1")
        _ = pool.createWebViews(for: "acc2")
        XCTAssertEqual(pool.entries.count, 2)
        pool.removeAll()
        XCTAssertTrue(pool.entries.isEmpty)
    }

    func testEntryForId() {
        XCTAssertNil(pool.entry(for: "acc1"))
        _ = pool.createWebViews(for: "acc1")
        XCTAssertNotNil(pool.entry(for: "acc1"))
        XCTAssertNil(pool.entry(for: "acc2"))
    }
}
