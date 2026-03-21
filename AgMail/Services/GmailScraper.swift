import Foundation
import WebKit

struct GmailParseResult: Codable, Sendable {
    let emails: [ParsedEmail]
    let unreadCount: Int
    let folder: String
    let timestamp: String

    struct ParsedEmail: Codable, Sendable {
        let msgId: String
        let from: String
        let subject: String
        let snippet: String
        let date: String
        let isRead: Bool
    }
}

@MainActor
final class GmailScraper: NSObject, ObservableObject {
    enum ScraperError: Error, Equatable {
        case noWebView
        case scriptNotFound
        case parseError(String)
        case navigationFailed(String)
    }

    enum State: Equatable {
        case idle
        case loading
        case polling
        case error(String)
    }

    static let gmailBasicHTMLURL = "https://mail.google.com/mail/u/0/h/"

    @Published private(set) var state: State = .idle
    @Published private(set) var lastResult: GmailParseResult?

    let accountId: String
    private weak var webView: WKWebView?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 45
    private var jsScript: String?
    private var onEmailsParsed: (([Email], Int, Folder) -> Void)?
    private var targetFolder: Folder = .inbox

    init(accountId: String, webView: WKWebView? = nil) {
        self.accountId = accountId
        self.webView = webView
        super.init()
        loadJSScript()
    }

    func configure(webView: WKWebView) {
        self.webView = webView
    }

    func setOnEmailsParsed(_ handler: @escaping ([Email], Int, Folder) -> Void) {
        self.onEmailsParsed = handler
    }

    // MARK: - Folder Navigation

    static func folderURL(for folder: Folder) -> URL? {
        var urlString = gmailBasicHTMLURL
        switch folder {
        case .inbox:
            break // default view
        case .archive:
            urlString += "?s=a"
        case .trash:
            urlString += "?s=t"
        case .spam:
            urlString += "?s=s"
        case .drafts:
            urlString += "?s=d"
        }
        return URL(string: urlString)
    }

    func navigateToFolder(_ folder: Folder) {
        guard let webView = webView,
              let url = Self.folderURL(for: folder) else {
            state = .error("No WebView configured")
            return
        }
        targetFolder = folder
        state = .loading
        webView.load(URLRequest(url: url))
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 45) {
        stopPolling()
        pollInterval = interval
        state = .polling
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.reloadKeepingState()
            }
        }
        // Initial load
        reloadKeepingState()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if state == .polling {
            state = .idle
        }
    }

    func reload() {
        guard let webView = webView else {
            state = .error("No WebView configured")
            return
        }
        if webView.url == nil {
            navigateToFolder(.inbox)
        } else {
            webView.reload()
        }
    }

    private func reloadKeepingState() {
        guard let webView = webView else { return }
        if webView.url == nil {
            guard let url = Self.folderURL(for: targetFolder) else { return }
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    // MARK: - JS Injection & Parsing

    func injectAndParse() async throws -> GmailParseResult {
        guard let webView = webView else {
            throw ScraperError.noWebView
        }
        guard let script = jsScript else {
            throw ScraperError.scriptNotFound
        }

        let result: Any
        do {
            result = try await webView.evaluateJavaScript(script)
        } catch {
            throw ScraperError.parseError("JS evaluation failed: \(error.localizedDescription)")
        }

        guard let jsonString = result as? String else {
            throw ScraperError.parseError("JS returned non-string result")
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw ScraperError.parseError("Failed to convert JSON string to data")
        }

        let parseResult: GmailParseResult
        do {
            parseResult = try JSONDecoder().decode(GmailParseResult.self, from: data)
        } catch {
            throw ScraperError.parseError("JSON decode failed: \(error.localizedDescription)")
        }

        lastResult = parseResult
        let emails = convertToEmails(parseResult)
        let folder = folderFromString(parseResult.folder)
        onEmailsParsed?(emails, parseResult.unreadCount, folder)
        return parseResult
    }

    // MARK: - Conversion

    func convertToEmails(_ result: GmailParseResult) -> [Email] {
        let folder = folderFromString(result.folder)

        return result.emails.compactMap { parsed in
            let date = Self.parseDate(parsed.date)
            return Email(
                msgId: parsed.msgId,
                from: parsed.from,
                subject: parsed.subject,
                date: date,
                snippet: parsed.snippet,
                isRead: parsed.isRead,
                accountId: accountId,
                folder: folder
            )
        }
    }

    // MARK: - Actions

    func executeAction(_ action: String, msgIds: [String]) async throws {
        guard let webView = webView else {
            throw ScraperError.noWebView
        }
        guard let url = Bundle.main.url(forResource: "gmail_actions", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw ScraperError.scriptNotFound
        }
        let args: [String: Any] = ["action": action, "msgIds": msgIds]
        let result = try await webView.callAsyncJavaScript(script, arguments: args, contentWorld: .page)
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           parsed["success"] as? Bool == false {
            let errorMsg = parsed["error"] as? String ?? "Action failed"
            throw ScraperError.navigationFailed(errorMsg)
        }
    }

    // MARK: - Private Helpers

    private func loadJSScript() {
        if let url = Bundle.main.url(forResource: "gmail_parser", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            jsScript = script
        }
    }

    func loadJSScriptFromString(_ script: String) {
        jsScript = script
    }

    private static let dateFormats: [String] = [
        "MMM d",      // "Mar 15", "Jan 2"
        "h:mm a",     // "3:45 PM", "11:20 AM"
        "M/d/yy",     // "1/15/24", "12/3/23"
        "M/dd/yy",    // "1/15/24"
        "MM/d/yy",    // "12/3/23"
    ]

    static func parseDate(_ dateString: String) -> Date {
        let locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateFormat = format
            if var date = formatter.date(from: dateString) {
                // "MMM d" and "h:mm a" formats lack a year; DateFormatter defaults to 2000.
                // Adjust to current year (or previous year if the date would be in the future).
                if format == "MMM d" || format == "h:mm a" {
                    let cal = Calendar.current
                    let now = Date()
                    var comps = cal.dateComponents([.month, .day, .hour, .minute], from: date)
                    comps.year = cal.component(.year, from: now)
                    if format == "h:mm a" {
                        // Time-only stamps always refer to today
                        comps.month = cal.component(.month, from: now)
                        comps.day = cal.component(.day, from: now)
                    }
                    if let adjusted = cal.date(from: comps) {
                        // Only roll back year for date-only formats, not time-only
                        if format == "MMM d", adjusted > Date(), let prev = cal.date(byAdding: .year, value: -1, to: adjusted) {
                            date = prev
                        } else {
                            date = adjusted
                        }
                    }
                }
                return date
            }
        }
        return Date.distantPast
    }

    private func folderFromString(_ str: String) -> Folder {
        switch str {
        case "spam": return .spam
        case "trash": return .trash
        case "drafts": return .drafts
        case "all": return .archive
        default: return .inbox
        }
    }

    // No deinit needed: stopPolling() is called by GmailScraperManager.removeScraper()
    // before the scraper is released. Accessing @MainActor-isolated pollTimer in
    // nonisolated deinit would be a data race.
}

// MARK: - WKNavigationDelegate

extension GmailScraper: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let url = webView.url?.absoluteString else { return }

            // Detect session expiration: redirected to login page
            if url.contains("accounts.google.com") || url.contains("accounts.youtube.com") {
                state = .error("Session expired — please re-authenticate")
                return
            }

            guard url.contains("mail.google.com/mail") else {
                return
            }
            do {
                _ = try await injectAndParse()
                if state == .loading {
                    state = .polling
                }
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            state = .error("Navigation failed: \(error.localizedDescription)")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            state = .error("Navigation failed: \(error.localizedDescription)")
        }
    }
}
