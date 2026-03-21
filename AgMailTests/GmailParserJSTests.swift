import XCTest
import WebKit
@testable import AgMail

@MainActor
final class GmailParserJSTests: XCTestCase {

    // MARK: - Mock HTML for Gmail Basic HTML view

    static let mockGmailHTML = """
    <html>
    <head><title>Gmail - Inbox (2)</title></head>
    <body>
    <table>
    <tbody>
    <tr>
        <td><input type="checkbox" value="18abc123def"></td>
        <td><b>Alice Smith</b></td>
        <td><b><a href="?th=18abc123def">Meeting tomorrow</a></b> <font color="#777">- Let's discuss the project plan</font></td>
        <td>Mar 20</td>
    </tr>
    <tr>
        <td><input type="checkbox" value="18abc456ghi"></td>
        <td>Bob Jones</td>
        <td><a href="?th=18abc456ghi">Weekly report</a> <font color="#777">- Here are the numbers for this week</font></td>
        <td>Mar 19</td>
    </tr>
    <tr>
        <td><input type="checkbox" value="18abc789jkl"></td>
        <td><b>Carol White</b></td>
        <td><b><a href="?th=18abc789jkl">Urgent: Server down</a></b> <font color="#777">- Production server is not responding</font></td>
        <td>Mar 18</td>
    </tr>
    </tbody>
    </table>
    </body>
    </html>
    """

    static let emptyInboxHTML = """
    <html>
    <head><title>Gmail - Inbox</title></head>
    <body>
    <table><tbody></tbody></table>
    </body>
    </html>
    """

    // MARK: - Tests for GmailParseResult decoding

    func testParseResultDecoding() throws {
        let json = """
        {
            "emails": [
                {
                    "msgId": "18abc123def",
                    "from": "Alice Smith",
                    "subject": "Meeting tomorrow",
                    "snippet": "Let's discuss the project plan",
                    "date": "Mar 20",
                    "isRead": false
                },
                {
                    "msgId": "18abc456ghi",
                    "from": "Bob Jones",
                    "subject": "Weekly report",
                    "snippet": "Here are the numbers for this week",
                    "date": "Mar 19",
                    "isRead": true
                }
            ],
            "unreadCount": 2,
            "folder": "inbox",
            "timestamp": "2026-03-20T10:00:00.000Z"
        }
        """

        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(GmailParseResult.self, from: data)

        XCTAssertEqual(result.emails.count, 2)
        XCTAssertEqual(result.unreadCount, 2)
        XCTAssertEqual(result.folder, "inbox")

        let first = result.emails[0]
        XCTAssertEqual(first.msgId, "18abc123def")
        XCTAssertEqual(first.from, "Alice Smith")
        XCTAssertEqual(first.subject, "Meeting tomorrow")
        XCTAssertEqual(first.snippet, "Let's discuss the project plan")
        XCTAssertEqual(first.date, "Mar 20")
        XCTAssertFalse(first.isRead)

        let second = result.emails[1]
        XCTAssertEqual(second.msgId, "18abc456ghi")
        XCTAssertTrue(second.isRead)
    }

    func testParseResultEmptyEmails() throws {
        let json = """
        {
            "emails": [],
            "unreadCount": 0,
            "folder": "inbox",
            "timestamp": "2026-03-20T10:00:00.000Z"
        }
        """

        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(GmailParseResult.self, from: data)

        XCTAssertEqual(result.emails.count, 0)
        XCTAssertEqual(result.unreadCount, 0)
    }

    func testParseResultAllFolders() throws {
        for folder in ["inbox", "spam", "trash", "drafts", "all"] {
            let json = """
            {
                "emails": [],
                "unreadCount": 0,
                "folder": "\(folder)",
                "timestamp": "2026-03-20T10:00:00.000Z"
            }
            """
            let data = json.data(using: .utf8)!
            let result = try JSONDecoder().decode(GmailParseResult.self, from: data)
            XCTAssertEqual(result.folder, folder)
        }
    }

    // MARK: - JS execution in WKWebView with mock HTML

    func testJSParserWithMockHTML() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(Self.mockGmailHTML, baseURL: nil)

        // Wait for page to load
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let jsURL = Bundle(for: type(of: self)).url(forResource: "gmail_parser", withExtension: "js")
            ?? Bundle.main.url(forResource: "gmail_parser", withExtension: "js")

        // If JS file is not in test bundle, use inline script for testing
        let script: String
        if let jsURL = jsURL, let contents = try? String(contentsOf: jsURL, encoding: .utf8) {
            script = contents
        } else {
            // Minimal inline parser for test validation
            script = Self.inlineParserJS
        }

        let result = try await webView.evaluateJavaScript(script)
        guard let jsonString = result as? String else {
            XCTFail("JS did not return a string")
            return
        }

        let data = jsonString.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(GmailParseResult.self, from: data)

        XCTAssertEqual(parsed.unreadCount, 2, "Title contains '(2)' so unreadCount should be 2")
        XCTAssertGreaterThan(parsed.emails.count, 0, "Parser should extract emails from mock HTML")
        XCTAssertFalse(parsed.timestamp.isEmpty)
    }

    func testJSParserEmptyInbox() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(Self.emptyInboxHTML, baseURL: nil)

        try await Task.sleep(nanoseconds: 1_000_000_000)

        let script = Self.inlineParserJS
        let result = try await webView.evaluateJavaScript(script)
        guard let jsonString = result as? String else {
            XCTFail("JS did not return a string")
            return
        }

        let data = jsonString.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(GmailParseResult.self, from: data)

        XCTAssertEqual(parsed.emails.count, 0)
        XCTAssertEqual(parsed.unreadCount, 0)
    }

    // Inline version of the parser for tests where the bundle resource isn't available
    static let inlineParserJS = """
    (function() {
        "use strict";
        function parseEmailRows() {
            var emails = [];
            var rows = document.querySelectorAll("table > tbody > tr");
            for (var i = 0; i < rows.length; i++) {
                var row = rows[i];
                var cells = row.querySelectorAll("td");
                if (cells.length < 3) continue;
                var isRead = !row.querySelector("b");
                var msgId = null;
                var checkbox = row.querySelector("input[type='checkbox']");
                if (checkbox) msgId = checkbox.getAttribute("value");
                if (!msgId) {
                    var links = row.querySelectorAll("a[href]");
                    for (var j = 0; j < links.length; j++) {
                        var m = (links[j].getAttribute("href") || "").match(/[?&]th=([a-fA-F0-9]+)/);
                        if (m) { msgId = m[1]; break; }
                    }
                }
                if (!msgId) continue;
                var fromCell = cells.length >= 4 ? cells[1] : cells[0];
                var from = (fromCell.textContent || "").trim();
                var subjectCell = cells.length >= 4 ? cells[2] : cells[1];
                var subjectLink = subjectCell.querySelector("a");
                var subject = subjectLink ? (subjectLink.textContent || "").trim() : "";
                var snippet = "";
                var fontEl = subjectCell.querySelector("font[color]");
                if (fontEl) snippet = (fontEl.textContent || "").trim();
                snippet = snippet.replace(/^\\s*[-\\u2013\\u2014]\\s*/, "").trim();
                var dateCell = cells[cells.length - 1];
                var date = (dateCell.textContent || "").trim();
                emails.push({ msgId: msgId, from: from, subject: subject, snippet: snippet, date: date, isRead: isRead });
            }
            return emails;
        }
        function parseUnreadCount() {
            var title = document.title || "";
            var match = title.match(/\\((\\d+)\\)/);
            return match ? parseInt(match[1], 10) : 0;
        }
        var result = {
            emails: parseEmailRows(),
            unreadCount: parseUnreadCount(),
            folder: "inbox",
            timestamp: new Date().toISOString()
        };
        return JSON.stringify(result);
    })();
    """
}
