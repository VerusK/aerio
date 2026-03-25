import XCTest
import WebKit
@testable import Aerio

@MainActor
final class GmailActionsJSTests: XCTestCase {

    struct ActionResult: Codable {
        let success: Bool
        let action: String?
        let count: Int?
        let error: String?
    }

    // Mock HTML simulating Gmail Basic HTML with checkboxes and action buttons
    static let mockGmailWithActions = """
    <html>
    <head><title>Gmail - Inbox (2)</title></head>
    <body>
    <form>
    <input type="submit" value="Archive">
    <input type="submit" value="Delete">
    <input type="submit" value="Report Spam">
    <input type="submit" value="Mark as read">
    <input type="submit" value="Mark as unread">
    <table>
    <tbody>
    <tr>
        <td><input type="checkbox" value="18abc123def"></td>
        <td><b>Alice Smith</b></td>
        <td><b><a href="?th=18abc123def">Meeting tomorrow</a></b></td>
        <td>Mar 20</td>
    </tr>
    <tr>
        <td><input type="checkbox" value="18abc456ghi"></td>
        <td>Bob Jones</td>
        <td><a href="?th=18abc456ghi">Weekly report</a></td>
        <td>Mar 19</td>
    </tr>
    </tbody>
    </table>
    </form>
    </body>
    </html>
    """

    static let mockGmailNoButtons = """
    <html>
    <body>
    <table><tbody>
    <tr>
        <td><input type="checkbox" value="18abc123def"></td>
        <td>Alice</td>
        <td><a href="?th=18abc123def">Test</a></td>
        <td>Mar 20</td>
    </tr>
    </tbody></table>
    </body>
    </html>
    """

    private func executeAction(_ webView: WKWebView, action: String, msgIds: [String]) async throws -> ActionResult {
        let msgIdsJSON = try String(data: JSONSerialization.data(withJSONObject: msgIds), encoding: .utf8)!
        let setupJS = """
        window.__aerio_action = "\(action)";
        window.__aerio_msgIds = \(msgIdsJSON);
        """
        _ = try await webView.evaluateJavaScript(setupJS)

        let actionsJS = Self.inlineActionsJS
        let result = try await webView.evaluateJavaScript(actionsJS)

        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8) else {
            XCTFail("JS did not return a valid JSON string")
            return ActionResult(success: false, action: nil, count: nil, error: "Invalid result")
        }

        return try JSONDecoder().decode(ActionResult.self, from: data)
    }

    func testArchiveAction() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(Self.mockGmailWithActions, baseURL: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let result = try await executeAction(webView, action: "archive", msgIds: ["18abc123def"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.action, "archive")
        XCTAssertEqual(result.count, 1)
    }

    func testDeleteAction() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(Self.mockGmailWithActions, baseURL: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let result = try await executeAction(webView, action: "delete", msgIds: ["18abc123def"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.action, "delete")
    }

    func testSpamAction() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(Self.mockGmailWithActions, baseURL: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let result = try await executeAction(webView, action: "spam", msgIds: ["18abc456ghi"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.action, "spam")
    }

    func testMultipleMessages() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(Self.mockGmailWithActions, baseURL: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let result = try await executeAction(webView, action: "archive", msgIds: ["18abc123def", "18abc456ghi"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.count, 2)
    }

    func testUnknownAction() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(Self.mockGmailWithActions, baseURL: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let result = try await executeAction(webView, action: "unknown", msgIds: ["18abc123def"])
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }

    func testNoMessagesFound() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(Self.mockGmailWithActions, baseURL: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let result = try await executeAction(webView, action: "archive", msgIds: ["nonexistent"])
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }

    func testActionWithNoButtons() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(Self.mockGmailNoButtons, baseURL: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let result = try await executeAction(webView, action: "archive", msgIds: ["18abc123def"])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Archive button not found")
    }

    // Inline version of gmail_actions.js for tests
    static let inlineActionsJS = """
    (function() {
        "use strict";
        function selectMessage(msgId) {
            var checkboxes = document.querySelectorAll("input[type='checkbox']");
            for (var i = 0; i < checkboxes.length; i++) {
                var val = checkboxes[i].getAttribute("value") || checkboxes[i].getAttribute("name") || "";
                if (val === msgId) { checkboxes[i].checked = true; return true; }
            }
            return false;
        }
        function clickButton(buttonName) {
            var inputs = document.querySelectorAll("input[type='submit'], button");
            for (var i = 0; i < inputs.length; i++) {
                var val = (inputs[i].getAttribute("value") || inputs[i].textContent || "").toLowerCase();
                if (val.indexOf(buttonName.toLowerCase()) !== -1) { inputs[i].click(); return true; }
            }
            return false;
        }
        function doAction(action, msgIds) {
            var selected = 0;
            for (var i = 0; i < msgIds.length; i++) { if (selectMessage(msgIds[i])) selected++; }
            if (selected === 0) return { success: false, error: "No messages found to select" };
            var buttonMap = { archive: "archive", "delete": "delete", spam: "report spam", markAsRead: "mark as read", markAsUnread: "mark as unread" };
            var btnName = buttonMap[action];
            if (!btnName) return { success: false, error: "Unknown action: " + action };
            if (clickButton(btnName)) return { success: true, action: action, count: selected };
            // Try shorter name for spam
            if (action === "spam" && clickButton("spam")) return { success: true, action: action, count: selected };
            return { success: false, error: btnName.charAt(0).toUpperCase() + btnName.slice(1) + " button not found" };
        }
        var action = window.__aerio_action || "";
        var msgIds = window.__aerio_msgIds || [];
        if (!action) return JSON.stringify({ success: false, error: "Unknown action: " });
        var result = doAction(action, msgIds);
        return JSON.stringify(result);
    })();
    """
}
