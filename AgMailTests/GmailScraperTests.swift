import XCTest
import WebKit
@testable import AgMail

@MainActor
final class GmailScraperTests: XCTestCase {

    // MARK: - Initialization

    func testInitialization() {
        let scraper = GmailScraper(accountId: "acc1")
        XCTAssertEqual(scraper.accountId, "acc1")
        XCTAssertEqual(scraper.state, .idle)
        XCTAssertNil(scraper.lastResult)
    }

    func testConfigureWebView() {
        let scraper = GmailScraper(accountId: "acc1")
        let webView = WKWebView(frame: .zero)
        scraper.configure(webView: webView)
        // No crash, webView is set (internal, so we verify indirectly via navigateToFolder)
        XCTAssertEqual(scraper.state, .idle)
    }

    // MARK: - Folder URLs

    func testFolderURLInbox() {
        let url = GmailScraper.folderURL(for: .inbox)
        XCTAssertEqual(url?.absoluteString, "https://mail.google.com/mail/u/0/h/")
    }

    func testFolderURLArchive() {
        let url = GmailScraper.folderURL(for: .archive)
        XCTAssertEqual(url?.absoluteString, "https://mail.google.com/mail/u/0/h/?s=a")
    }

    func testFolderURLTrash() {
        let url = GmailScraper.folderURL(for: .trash)
        XCTAssertEqual(url?.absoluteString, "https://mail.google.com/mail/u/0/h/?s=t")
    }

    func testFolderURLSpam() {
        let url = GmailScraper.folderURL(for: .spam)
        XCTAssertEqual(url?.absoluteString, "https://mail.google.com/mail/u/0/h/?s=s")
    }

    func testFolderURLDrafts() {
        let url = GmailScraper.folderURL(for: .drafts)
        XCTAssertEqual(url?.absoluteString, "https://mail.google.com/mail/u/0/h/?s=d")
    }

    func testAllFolderURLsAreValid() {
        for folder in Folder.allCases {
            let url = GmailScraper.folderURL(for: folder)
            XCTAssertNotNil(url, "URL for folder \(folder) should not be nil")
            XCTAssertTrue(url!.absoluteString.hasPrefix("https://mail.google.com/mail/u/0/h/"))
        }
    }

    // MARK: - State transitions

    func testNavigateToFolderWithoutWebViewSetsError() {
        let scraper = GmailScraper(accountId: "acc1")
        scraper.navigateToFolder(.inbox)
        XCTAssertEqual(scraper.state, .error("No WebView configured"))
    }

    func testNavigateToFolderWithWebViewSetsLoading() {
        let scraper = GmailScraper(accountId: "acc1")
        let webView = WKWebView(frame: .zero)
        scraper.configure(webView: webView)
        scraper.navigateToFolder(.inbox)
        XCTAssertEqual(scraper.state, .loading)
    }

    func testStartPollingSetsPollingState() {
        let scraper = GmailScraper(accountId: "acc1")
        let webView = WKWebView(frame: .zero)
        scraper.configure(webView: webView)
        scraper.startPolling(interval: 60)
        XCTAssertEqual(scraper.state, .polling)
        scraper.stopPolling()
    }

    func testStopPollingSetsIdleState() {
        let scraper = GmailScraper(accountId: "acc1")
        let webView = WKWebView(frame: .zero)
        scraper.configure(webView: webView)
        scraper.startPolling(interval: 60)
        scraper.stopPolling()
        XCTAssertEqual(scraper.state, .idle)
    }

    func testStopPollingWhenNotPollingSafe() {
        let scraper = GmailScraper(accountId: "acc1")
        scraper.stopPolling() // Should not crash
        XCTAssertEqual(scraper.state, .idle)
    }

    // MARK: - Error handling

    func testInjectAndParseWithoutWebViewThrows() async {
        let scraper = GmailScraper(accountId: "acc1")
        do {
            _ = try await scraper.injectAndParse()
            XCTFail("Should have thrown noWebView error")
        } catch let error as GmailScraper.ScraperError {
            XCTAssertEqual(error, .noWebView)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testInjectAndParseWithEmptyScriptThrowsParseError() async {
        let scraper = GmailScraper(accountId: "acc1")
        let webView = WKWebView(frame: .zero)
        scraper.configure(webView: webView)
        // Empty JS returns undefined, which is not a string -> parseError
        scraper.loadJSScriptFromString("")
        do {
            _ = try await scraper.injectAndParse()
            XCTFail("Should have thrown a ScraperError")
        } catch let error as GmailScraper.ScraperError {
            switch error {
            case .parseError:
                break // expected: empty JS returns non-string result
            default:
                XCTFail("Expected parseError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Convert to Emails

    func testConvertToEmails() {
        let scraper = GmailScraper(accountId: "acc1")

        let parseResult = GmailParseResult(
            emails: [
                .init(msgId: "msg1", from: "Alice", subject: "Hello", snippet: "Hi there", date: "Mar 20", isRead: false),
                .init(msgId: "msg2", from: "Bob", subject: "Re: Hello", snippet: "Thanks", date: "Mar 19", isRead: true),
            ],
            unreadCount: 1,
            folder: "inbox",
            timestamp: "2026-03-20T10:00:00.000Z"
        )

        let emails = scraper.convertToEmails(parseResult)

        XCTAssertEqual(emails.count, 2)
        XCTAssertEqual(emails[0].msgId, "msg1")
        XCTAssertEqual(emails[0].from, "Alice")
        XCTAssertEqual(emails[0].subject, "Hello")
        XCTAssertEqual(emails[0].snippet, "Hi there")
        XCTAssertFalse(emails[0].isRead)
        XCTAssertEqual(emails[0].accountId, "acc1")
        XCTAssertEqual(emails[0].folder, .inbox)

        XCTAssertEqual(emails[1].msgId, "msg2")
        XCTAssertTrue(emails[1].isRead)
    }

    func testConvertToEmailsFolderMapping() {
        let scraper = GmailScraper(accountId: "acc1")

        let folderMap: [(String, Folder)] = [
            ("inbox", .inbox),
            ("spam", .spam),
            ("trash", .trash),
            ("drafts", .drafts),
            ("all", .archive),
        ]

        for (folderStr, expectedFolder) in folderMap {
            let result = GmailParseResult(
                emails: [.init(msgId: "m1", from: "A", subject: "S", snippet: "", date: "Mar 1", isRead: false)],
                unreadCount: 0,
                folder: folderStr,
                timestamp: ""
            )
            let emails = scraper.convertToEmails(result)
            XCTAssertEqual(emails.first?.folder, expectedFolder, "Folder string '\(folderStr)' should map to \(expectedFolder)")
        }
    }

    func testConvertToEmailsEmpty() {
        let scraper = GmailScraper(accountId: "acc1")
        let result = GmailParseResult(emails: [], unreadCount: 0, folder: "inbox", timestamp: "")
        let emails = scraper.convertToEmails(result)
        XCTAssertEqual(emails.count, 0)
    }

    // MARK: - Callback

    func testOnEmailsParsedCallbackRegistration() {
        let scraper = GmailScraper(accountId: "acc1")
        var receivedEmails: [Email] = []
        var receivedUnreadCount = -1

        scraper.setOnEmailsParsed { emails, unread, _ in
            receivedEmails = emails
            receivedUnreadCount = unread
        }

        // convertToEmails does not invoke callback (only injectAndParse does)
        let result = GmailParseResult(
            emails: [.init(msgId: "m1", from: "A", subject: "S", snippet: "", date: "Mar 1", isRead: false)],
            unreadCount: 5,
            folder: "inbox",
            timestamp: ""
        )
        let emails = scraper.convertToEmails(result)
        XCTAssertEqual(emails.count, 1, "convertToEmails should return 1 email")
        XCTAssertEqual(emails.first?.msgId, "m1")
        XCTAssertEqual(emails.first?.folder, .inbox)
        XCTAssertEqual(receivedEmails.count, 0, "Callback not invoked by convertToEmails")
        XCTAssertEqual(receivedUnreadCount, -1, "Callback not invoked by convertToEmails")
    }

    // MARK: - parseDate

    func testParseDateMonthDay() {
        let date = GmailScraper.parseDate("Mar 20")
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.month, from: date), 3)
        XCTAssertEqual(cal.component(.day, from: date), 20)
    }

    func testParseDateTimeOnly() {
        let date = GmailScraper.parseDate("3:45 PM")
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.hour, from: date), 15)
        XCTAssertEqual(cal.component(.minute, from: date), 45)
        // Time-only stamps refer to today
        XCTAssertEqual(cal.component(.day, from: date), cal.component(.day, from: Date()))
    }

    func testParseDateNumeric() {
        let date = GmailScraper.parseDate("1/15/24")
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.month, from: date), 1)
        XCTAssertEqual(cal.component(.day, from: date), 15)
    }

    func testParseDateUnparseable() {
        let date = GmailScraper.parseDate("not a date")
        XCTAssertEqual(date, Date.distantPast)
    }

    // MARK: - ScraperError Equatable

    func testScraperErrorEquatable() {
        XCTAssertEqual(GmailScraper.ScraperError.noWebView, GmailScraper.ScraperError.noWebView)
        XCTAssertEqual(GmailScraper.ScraperError.scriptNotFound, GmailScraper.ScraperError.scriptNotFound)
        XCTAssertEqual(
            GmailScraper.ScraperError.parseError("test"),
            GmailScraper.ScraperError.parseError("test")
        )
        XCTAssertNotEqual(
            GmailScraper.ScraperError.noWebView,
            GmailScraper.ScraperError.scriptNotFound
        )
    }

    // MARK: - State Equatable

    func testStateEquatable() {
        XCTAssertEqual(GmailScraper.State.idle, GmailScraper.State.idle)
        XCTAssertEqual(GmailScraper.State.loading, GmailScraper.State.loading)
        XCTAssertEqual(GmailScraper.State.polling, GmailScraper.State.polling)
        XCTAssertEqual(GmailScraper.State.error("x"), GmailScraper.State.error("x"))
        XCTAssertNotEqual(GmailScraper.State.idle, GmailScraper.State.loading)
    }

    // MARK: - Integration: JS in WebView with loaded script

    func testInjectAndParseWithLoadedScript() async throws {
        let scraper = GmailScraper(accountId: "acc1")
        let webView = WKWebView(frame: .zero)
        scraper.configure(webView: webView)

        // Load mock HTML
        webView.loadHTMLString(GmailParserJSTests.mockGmailHTML, baseURL: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Load JS script manually (since bundle resource won't be available in tests)
        scraper.loadJSScriptFromString(GmailParserJSTests.inlineParserJS)

        let result = try await scraper.injectAndParse()

        XCTAssertEqual(result.unreadCount, 2)
        XCTAssertEqual(result.folder, "inbox")
        XCTAssertGreaterThan(result.emails.count, 0, "Parser should extract emails from mock HTML")
        XCTAssertNotNil(scraper.lastResult)
    }
}
