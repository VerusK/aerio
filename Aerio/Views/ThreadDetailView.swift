import SwiftUI
import WebKit
import os.log

private let logger = Logger(subsystem: "Aerio", category: "ThreadDetail")

/// Navigation delegate that intercepts aerio:// attachment URLs and opens external links in browser.
final class ThreadNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var apiManager: GmailAPIManager?
    weak var webView: WKWebView?
    var threadMessages: [ThreadMessage] = []
    var onReply: ((ThreadMessage) -> Void)?
    var onReplyAll: ((ThreadMessage) -> Void)?
    var onForward: ((ThreadMessage) -> Void)?
    /// Message to bring into view once the page has loaded; nil scrolls to the top.
    var focusMessageId: String?
    private(set) var isPageLoaded = false

    func pageWillLoad() { isPageLoaded = false }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        applyFocus()
    }

    /// Scrolls to `focusMessageId` now, or right after the pending load finishes.
    func applyFocus() {
        guard isPageLoaded, let webView else { return }
        webView.evaluateJavaScript(Self.focusScript(for: focusMessageId), completionHandler: nil)
    }

    static func focusScript(for msgId: String?) -> String {
        // Gmail ids are hex; keep only alphanumerics so the id can't break out of the string.
        guard let safe = msgId?.filter({ $0.isLetter || $0.isNumber }), !safe.isEmpty else {
            return "window.scrollTo(0, 0)"
        }
        return "var el = document.getElementById('msg-\(safe)'); if (el) { el.scrollIntoView(); }"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "aerio", url.host == "attachment" {
            decisionHandler(.cancel)
            handleAttachmentURL(url)
            return
        }

        if url.scheme == "aerio", url.host == "action" {
            decisionHandler(.cancel)
            handleActionURL(url)
            return
        }

        if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    private func handleActionURL(_ url: URL) {
        // aerio://action/{reply|replyall|forward}/{msgId}
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return }
        let action = parts[0]
        let msgId = parts[1]
        guard let message = threadMessages.first(where: { $0.id == msgId }) else { return }
        Task { @MainActor in
            switch action {
            case "reply": onReply?(message)
            case "replyall": onReplyAll?(message)
            case "forward": onForward?(message)
            default: break
            }
        }
    }

    private func handleAttachmentURL(_ url: URL) {
        // aerio://attachment/{open|save}/{accountId}/{messageId}/{attachmentId}/{filename}
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4 else { return }
        let action = parts[0] // "open" or "save"
        let accountId = parts[1]
        let messageId = parts[2]
        let attachmentId = parts[3]
        let filename = parts.count > 4 ? parts[4].removingPercentEncoding ?? parts[4] : "attachment"

        let chipId = "att-\(attachmentId)"
        Task { @MainActor in
            guard let apiManager else { return }
            // Show downloading state on save button only
            webView?.evaluateJavaScript("""
                (function() {
                    var el = document.getElementById('\(chipId)');
                    if (el) { var btn = el.querySelector('.att-save'); if (btn) { btn.dataset.orig = btn.textContent; btn.textContent = '⏳'; } }
                })()
            """, completionHandler: nil)
            do {
                let data = try await apiManager.downloadAttachment(
                    messageId: messageId,
                    attachmentId: attachmentId,
                    accountId: accountId
                )
                let downloadsDir = SettingsView.resolvedDownloadsDirectory()
                try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
                var fileURL = downloadsDir.appendingPathComponent(filename)
                var counter = 1
                let baseName = (filename as NSString).deletingPathExtension
                let ext = (filename as NSString).pathExtension
                while FileManager.default.fileExists(atPath: fileURL.path) {
                    let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
                    fileURL = downloadsDir.appendingPathComponent(newName)
                    counter += 1
                }
                try data.write(to: fileURL)
                if action == "open" {
                    NSWorkspace.shared.open(fileURL)
                } else {
                    NSApp.requestUserAttention(.informationalRequest)
                }
                // Show done, then restore
                webView?.evaluateJavaScript("""
                    (function() {
                        var el = document.getElementById('\(chipId)');
                        if (el) { var btn = el.querySelector('.att-save'); if (btn) { btn.textContent = '✅'; setTimeout(function() { btn.textContent = btn.dataset.orig; }, 2000); } }
                    })()
                """, completionHandler: nil)
            } catch {
                logger.error("Failed to download attachment: \(error.localizedDescription)")
                webView?.evaluateJavaScript("""
                    (function() {
                        var el = document.getElementById('\(chipId)');
                        if (el) { var btn = el.querySelector('.att-save'); if (btn) { btn.textContent = '❌'; setTimeout(function() { btn.textContent = btn.dataset.orig; }, 2000); } }
                    })()
                """, completionHandler: nil)
            }
        }
    }
}

/// Numbers thread loads so only the newest may write the view: a forced refresh can
/// start while an earlier fetch is still in flight and finish before it.
final class LoadSequence {
    private var latest = 0

    func begin() -> Int {
        latest += 1
        return latest
    }

    func isLatest(_ id: Int) -> Bool { id == latest }
}

struct ThreadDetailView: View {
    let email: Email
    let apiManager: GmailAPIManager
    let folder: Folder
    /// The selected member when it isn't the newest (a search or notification jump).
    var focusMessageId: String? = nil
    /// Changes when a message joins or leaves the row, so an open thread refetches.
    var memberVersion: String = ""

    var onReply: ((ThreadMessage) -> Void)?
    var onReplyAll: ((ThreadMessage) -> Void)?
    var onForward: ((ThreadMessage) -> Void)?
    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSpam: (() -> Void)?
    var onMoveToInbox: (() -> Void)?
    var onRegisterScroll: ((@escaping (Int) -> Void) -> Void)?

    @State private var threadMessages: [ThreadMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @StateObject private var webViewStore = BodyWebViewStore()
    // @State keeps one delegate for the view's lifetime; a plain `let` would be
    // recreated on every re-render while the web view still points at the first one.
    @State private var threadNavDelegate = ThreadNavigationDelegate()
    @State private var loads = LoadSequence()

    /// Threads are per account: the same threadId in two accounts is two threads.
    private var threadKey: String { "\(email.accountId)_\(email.threadId)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            threadActionBar
            threadHeader
            Divider()

            if isLoading {
                ProgressView("Loading thread…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { loadThread() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BodyWebView(webView: webViewStore.webView)
            }
        }
        .onAppear {
            threadNavDelegate.apiManager = apiManager
            threadNavDelegate.webView = webViewStore.webView
            threadNavDelegate.onReply = { msg in onReply?(msg) }
            threadNavDelegate.onReplyAll = { msg in onReplyAll?(msg) }
            threadNavDelegate.onForward = { msg in onForward?(msg) }
            threadNavDelegate.focusMessageId = focusMessageId
            webViewStore.webView.navigationDelegate = threadNavDelegate
            loadThread()
            onRegisterScroll? { direction in
                webViewStore.scrollContent(direction: direction)
            }
        }
        .onChange(of: threadKey) { _, _ in loadThread() }
        // A reply joined (or a member left) the open conversation: the cached thread is stale.
        .onChange(of: memberVersion) { _, _ in loadThread(forceRefresh: true) }
        .onChange(of: focusMessageId) { _, newValue in
            threadNavDelegate.focusMessageId = newValue
            threadNavDelegate.applyFocus()
        }
    }

    private var threadActionBar: some View {
        HStack(spacing: 4) {
            // Per-message reply buttons for the newest message
            if let newest = threadMessages.first {
                actionButton(icon: "arrowshape.turn.up.left", tooltip: "Reply (\(ShortcutAction.reply.shortcutLabel))") { onReply?(newest) }
                actionButton(icon: "arrowshape.turn.up.left.2", tooltip: "Reply All (\(ShortcutAction.replyAll.shortcutLabel))") { onReplyAll?(newest) }
                actionButton(icon: "arrowshape.turn.up.right", tooltip: "Forward (\(ShortcutAction.forward.shortcutLabel))") { onForward?(newest) }

                Divider().frame(height: 16)
            }

            if folder == .inbox {
                actionButton(icon: "archivebox", tooltip: "Archive (\(ShortcutAction.archiveMessage.shortcutLabel))", action: onArchive)
            }
            if folder != .inbox {
                actionButton(icon: "tray.and.arrow.down", tooltip: "Move to Inbox (\(ShortcutAction.moveToInbox.shortcutLabel))", action: onMoveToInbox)
            }
            actionButton(icon: "exclamationmark.octagon", tooltip: "Spam (\(ShortcutAction.spamMessage.shortcutLabel))", action: onSpam)
            actionButton(icon: "trash", tooltip: "Delete (\(ShortcutAction.deleteMessage.shortcutLabel))", action: onDelete)

            Spacer()

            if !threadMessages.isEmpty {
                Text("\(threadMessages.count) messages")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var threadHeader: some View {
        Text(email.subject)
            .font(.system(size: 17, weight: .semibold))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func actionButton(icon: String, tooltip: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15))
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .disabled(action == nil)
    }

    // MARK: - Thread loading

    private static var threadHTMLCache: [String: String] = [:]

    private func loadThread(forceRefresh: Bool = false) {
        let load = loads.begin()
        if threadMessages.isEmpty {
            isLoading = true
        }
        loadError = nil
        Task {
            do {
                let messages = try await apiManager.fetchThread(
                    threadId: email.threadId,
                    accountId: email.accountId,
                    forceRefresh: forceRefresh
                )
                // A newer load (e.g. a reply joined meanwhile) owns the view now.
                guard loads.isLatest(load) else { return }
                threadMessages = messages
                threadNavDelegate.threadMessages = messages

                // Build HTML — cache keyed by message count + IDs to detect changes
                let cacheKey = messages.map(\.id).joined(separator: ",")
                let htmlCacheKey = "\(threadKey)_\(cacheKey)"
                let html: String
                if let cached = Self.threadHTMLCache[htmlCacheKey] {
                    html = cached
                } else {
                    html = Self.buildThreadHTML(messages: messages)
                    Self.threadHTMLCache[htmlCacheKey] = html
                    // Evict old entries
                    if Self.threadHTMLCache.count > 20 {
                        Self.threadHTMLCache.removeValue(forKey: Self.threadHTMLCache.keys.first!)
                    }
                }
                threadNavDelegate.pageWillLoad()
                webViewStore.loadHTML(html)
                isLoading = false
            } catch {
                guard loads.isLatest(load) else { return }
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// The whole thread as one HTML page. Static and state-free so it can be tested.
    static func buildThreadHTML(messages: [ThreadMessage]) -> String {
        var sections: [String] = []

        for message in messages {
            let bodyHTML = collapseQuotedContent(message.bodyHTML)

            let initial = String(message.from.prefix(1)).uppercased()
            let color = avatarColor(for: message.from)
            let dateStr = message.date.shortRelative
            let svgStyle = "vertical-align:middle;"
            let replyIcon = "<svg style='\(svgStyle)' width='14' height='14' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2'><path d='M9 17l-5-5 5-5'/><path d='M4 12h12a4 4 0 0 1 0 8h-1'/></svg>"
            let replyAllIcon = "<svg style='\(svgStyle)' width='14' height='14' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2'><path d='M12 17l-5-5 5-5'/><path d='M7 17l-5-5 5-5'/><path d='M7 12h12a4 4 0 0 1 0 8h-1'/></svg>"
            let forwardIcon = "<svg style='\(svgStyle)' width='14' height='14' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2'><path d='M15 17l5-5-5-5'/><path d='M20 12H8a4 4 0 0 0 0 8h1'/></svg>"
            let btnStyle = "color:#888;text-decoration:none;padding:3px 5px;border-radius:4px;display:inline-flex;align-items:center;vertical-align:middle;"
            let msgActions = """
            <span style="display:inline-flex;gap:2px;margin-right:8px;align-items:center;vertical-align:middle;">
                <a href="aerio://action/reply/\(message.id)" class="msg-action" style="\(btnStyle)" title="Reply">\(replyIcon)</a>
                <a href="aerio://action/replyall/\(message.id)" class="msg-action" style="\(btnStyle)" title="Reply All">\(replyAllIcon)</a>
                <a href="aerio://action/forward/\(message.id)" class="msg-action" style="\(btnStyle)" title="Forward">\(forwardIcon)</a>
            </span>
            """
            let toLine = message.to.isEmpty ? "" : "<div style=\"font-size:11px;color:#888;margin-top:2px;\">To: \(escapeHTML(message.to))</div>"
            let ccLine = message.cc.isEmpty ? "" : "<div style=\"font-size:11px;color:#888;margin-top:1px;\">Cc: \(escapeHTML(message.cc))</div>"

            // Build attachment chips HTML
            var attachmentsHTML = ""
            if !message.attachments.isEmpty {
                var chips: [String] = []
                for att in message.attachments {
                    let sizeStr = att.size.isEmpty ? "" : " <span style=\"color:#999;font-size:10px;\">(\(escapeHTML(att.size)))</span>"
                    let attId = att.attachmentId ?? ""
                    let msgId = att.messageId ?? message.id
                    let openURL = "aerio://attachment/open/\(message.accountId)/\(msgId)/\(attId)/\(att.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? att.name)"
                    let saveURL = "aerio://attachment/save/\(message.accountId)/\(msgId)/\(attId)/\(att.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? att.name)"
                    chips.append("""
                    <span id="att-\(attId)" style="display:inline-flex;align-items:center;background:#2a2a2a;border:1px solid #444;border-radius:6px;margin:2px 4px 2px 0;font-size:11px;transition:opacity 0.2s;">
                        <a href="\(openURL)" style="color:#ddd;text-decoration:none;padding:3px 8px;display:inline-flex;align-items:center;gap:4px;">📎 \(escapeHTML(att.name))\(sizeStr)</a>
                        <span style="border-left:1px solid #444;padding:3px 6px;">
                            <a class="att-save" href="\(saveURL)" style="color:#888;text-decoration:none;font-size:10px;" title="Save to Downloads">⬇</a>
                        </span>
                    </span>
                    """)
                }
                attachmentsHTML = "<div style=\"padding-top:4px;\">\(chips.joined())</div>"
            }

            let section = """
            <div id="msg-\(escapeHTML(message.msgId))" style="border-bottom: 4px solid #333; padding-bottom: 8px; margin-bottom: 8px;">
                <div style="display:flex;align-items:center;justify-content:flex-end;padding:8px 0 0 0;gap:4px;">
                    \(msgActions)
                </div>
                <div style="display:flex;align-items:flex-start;gap:10px;padding:0 0 8px 0;">
                    <div style="width:32px;height:32px;border-radius:50%;background:\(color);display:flex;align-items:center;justify-content:center;font-size:13px;color:white;flex-shrink:0;">\(initial)</div>
                    <div style="flex:1;min-width:0;">
                        <div style="display:flex;justify-content:space-between;align-items:center;">
                            <span style="font-size:13px;font-weight:600;">\(escapeHTML(message.from))</span>
                            <span style="font-size:11px;color:#666;">\(dateStr)</span>
                        </div>
                        \(toLine)
                        \(ccLine)
                        \(attachmentsHTML)
                    </div>
                </div>
                <div style="padding-left:42px;background:#fff;color:#1d1d1f;border-radius:6px;padding:12px;margin-top:4px;">
                    \(bodyHTML)
                </div>
            </div>
            """
            sections.append(section)
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(emailContentSecurityPolicyMeta)
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 14px;
                line-height: 1.5;
                color: #e0e0e0;
                background: #1a1a1a;
                padding: 0 16px;
                margin: 0;
                word-wrap: break-word;
            }
            img { max-width: 100%; height: auto; }
            blockquote {
                border-left: 3px solid #444;
                margin: 8px 0;
                padding-left: 12px;
                color: #888;
            }
            details.aerio-quote { margin: 6px 0; }
            details.aerio-quote > summary {
                list-style: none; display: inline-block; cursor: pointer;
                padding: 0 8px; border-radius: 8px; background: #e8e8e8; color: #555;
                font-size: 12px; line-height: 16px; letter-spacing: 1px;
            }
            details.aerio-quote > summary::-webkit-details-marker { display: none; }
            a { color: #6cb4ff; }
            /* Hover in CSS: content JavaScript is disabled, so inline onmouseover never ran. */
            a.msg-action:hover { background: #333; }
            pre, code {
                background: #2a2a2a;
                border-radius: 4px;
                padding: 2px 6px;
                font-size: 13px;
            }
        </style>
        </head>
        <body>
        \(sections.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    /// Folds every quoted part of a message into a closed `<details class="aerio-quote">`
    /// (a "•••" pill), keeping the reply itself visible. Nothing is removed, so forwarded
    /// content is never lost. Rules, each applied at most once per message:
    ///  1. Element quotes — Gmail's `gmail_quote` div and new Outlook's
    ///     `mail-editor-reference-message-container` div: exactly that element is wrapped,
    ///     so a footer the mail gateway adds after it stays visible.
    ///  2. Each top-level `<blockquote>` outside rule 1's block.
    ///  3. Tail quotes, only when rule 1 did not fire — classic Outlook's
    ///     `appendonsend` / `divRplyFwdMsg` siblings, `<p>---</p>`, plain-text `\n---\n`
    ///     and "On … wrote:" + `&gt;` lines: wrapped from the marker to the end of the body.
    static func collapseQuotedContent(_ html: String) -> String {
        let text = html as NSString
        let length = text.length
        var wraps: [QuoteWrap] = []

        func firstMatch(_ pattern: String, from location: Int = 0) -> NSRange? {
            guard location <= length,
                  let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            let match = regex.firstMatch(in: html, range: NSRange(location: location, length: length - location))
            return match?.range
        }

        /// Where a quote that runs to the end goes: before `</body>` when there is one after it.
        func tailEnd(from location: Int) -> Int {
            let body = text.range(of: "</body", options: [.caseInsensitive, .backwards])
            return body.location != NSNotFound && body.location >= location ? body.location : length
        }

        func isCollapsed(_ location: Int) -> Bool {
            wraps.contains { $0.start <= location && location < $0.end }
        }

        // 1. Element quotes: wrap exactly the element (to its balanced </div>).
        let elementMarkers = [
            #"<div\b[^>]*\bid\s*=\s*["']mail-editor-reference-message-container["']"#,
            #"<div\b[^>]*\bclass\s*=\s*["'](?:[^"']*\s)?gmail_quote(?=[\s"'])"#,
        ]
        if let start = elementMarkers.compactMap({ firstMatch($0)?.location }).min() {
            let end = balancedEnd(of: "div", in: html, from: start) ?? tailEnd(from: start)
            wraps.append(QuoteWrap(start: start, end: end))
        }
        let elementQuoteFound = !wraps.isEmpty

        // 2. Top-level blockquotes outside the element quote.
        if let regex = try? NSRegularExpression(pattern: #"<(/)?blockquote\b[^>]*>"#, options: .caseInsensitive) {
            var depth = 0
            var openedAt = 0
            var blockquotes: [QuoteWrap] = []
            for match in regex.matches(in: html, range: NSRange(location: 0, length: length)) {
                if match.range(at: 1).location == NSNotFound {
                    if depth == 0 { openedAt = match.range.location }
                    depth += 1
                } else if depth > 0 {
                    depth -= 1
                    if depth == 0 { blockquotes.append(QuoteWrap(start: openedAt, end: NSMaxRange(match.range))) }
                }
            }
            if depth > 0 { blockquotes.append(QuoteWrap(start: openedAt, end: tailEnd(from: openedAt))) }
            wraps += blockquotes.filter { !isCollapsed($0.start) }
        }

        // 3. Tail quotes: from the earliest marker to the end of the body.
        if !elementQuoteFound {
            let tailMarkers = [
                #"<div\b[^>]*\bid\s*=\s*["']appendonsend["']"#,
                // Classic Outlook's "From:/Sent:" header, with the rule drawn just above it.
                #"(?:<hr\b[^>]*>\s*)?<div\b[^>]*\bid\s*=\s*["']divRplyFwdMsg["']"#,
                #"<p[^>]*>\s*---\s*</p>"#,
                // "On … wrote:" only when followed by &gt; quoted lines (avoids false matches).
                #"<p[^>]*>\s*On .+?wrote:\s*</p>\s*<p[^>]*>\s*&gt;"#,
            ]
            var candidates: [QuoteWrap] = []
            for pattern in tailMarkers {
                // The first marker outside an already collapsed blockquote.
                var location = 0
                while let range = firstMatch(pattern, from: location) {
                    if !isCollapsed(range.location) {
                        candidates.append(QuoteWrap(start: range.location, end: tailEnd(from: range.location)))
                        break
                    }
                    location = range.location + 1
                }
            }
            // Plain-text "---" separator (text/plain bodies are shown in a <pre>).
            var searchFrom = 0
            while searchFrom < length {
                let range = text.range(of: "\n---\n", range: NSRange(location: searchFrom, length: length - searchFrom))
                guard range.location != NSNotFound else { break }
                if !isCollapsed(range.location) {
                    var wrap = QuoteWrap(start: range.location, end: tailEnd(from: range.location))
                    if let pre = openPreTag(in: text, before: range.location) {
                        // Close the <pre> before the pill and reopen it inside, so the
                        // original </pre> still has its opening tag.
                        wrap.open = "</pre>" + QuoteWrap.openTag + pre
                    }
                    candidates.append(wrap)
                    break
                }
                searchFrom = range.location + 1
            }
            if let earliest = candidates.min(by: { $0.start < $1.start }) {
                wraps.append(earliest)
            }
        }

        guard !wraps.isEmpty else { return html }

        // Insert the tags. At one offset, closings go first (innermost first), then
        // openings (outermost first), so the details blocks nest properly.
        var inserts: [(offset: Int, rank: Int, text: String)] = []
        for wrap in wraps {
            inserts.append((wrap.start, 1_000_000_000 - wrap.end, wrap.open))
            inserts.append((wrap.end, -1_000_000_000 - wrap.start, QuoteWrap.closeTag))
        }
        inserts.sort { $0.offset != $1.offset ? $0.offset < $1.offset : $0.rank < $1.rank }

        var result = ""
        var cursor = 0
        for insert in inserts {
            result += text.substring(with: NSRange(location: cursor, length: insert.offset - cursor))
            result += insert.text
            cursor = insert.offset
        }
        result += text.substring(from: cursor)
        return result
    }

    /// A quoted part to fold: `[start, end)` in UTF-16 offsets of the message HTML.
    private struct QuoteWrap {
        static let openTag = "<details class=\"aerio-quote\"><summary>•••</summary>"
        static let closeTag = "</details>"
        var start: Int
        var end: Int
        var open = openTag
    }

    /// The offset just past the tag that closes the `<tag>` starting at `start`, counting
    /// nested tags of the same name; nil when it is never closed.
    private static func balancedEnd(of tag: String, in html: String, from start: Int) -> Int? {
        let length = (html as NSString).length
        guard let regex = try? NSRegularExpression(pattern: "<(/)?\(tag)\\b[^>]*>", options: .caseInsensitive) else {
            return nil
        }
        var depth = 0
        for match in regex.matches(in: html, range: NSRange(location: start, length: length - start)) {
            depth += match.range(at: 1).location == NSNotFound ? 1 : -1
            if depth == 0 { return NSMaxRange(match.range) }
        }
        return nil
    }

    /// The start tag of a `<pre>` still open at `location`, or nil when not inside one.
    private static func openPreTag(in text: NSString, before location: Int) -> String? {
        let head = NSRange(location: 0, length: location)
        let open = text.range(of: "<pre", options: [.caseInsensitive, .backwards], range: head)
        guard open.location != NSNotFound else { return nil }
        let close = text.range(of: "</pre", options: [.caseInsensitive, .backwards], range: head)
        guard close.location == NSNotFound || close.location < open.location else { return nil }
        let tagEnd = text.range(of: ">", range: NSRange(location: open.location, length: location - open.location))
        guard tagEnd.location != NSNotFound else { return nil }
        return text.substring(with: NSRange(location: open.location, length: NSMaxRange(tagEnd) - open.location))
    }

    private static func avatarColor(for email: String) -> String {
        let hash = abs(email.hashValue)
        let colors = ["#4a7aff", "#7c3aed", "#e67e22", "#27ae60", "#e84393", "#00b894", "#4b0082", "#00cec9"]
        return colors[hash % colors.count]
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
