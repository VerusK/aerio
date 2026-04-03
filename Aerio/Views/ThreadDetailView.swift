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

struct ThreadDetailView: View {
    let email: Email
    let apiManager: GmailAPIManager
    let folder: Folder

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
    private let threadNavDelegate = ThreadNavigationDelegate()

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
            webViewStore.webView.navigationDelegate = threadNavDelegate
            loadThread()
            onRegisterScroll? { direction in
                webViewStore.scrollContent(direction: direction)
            }
        }
        .onChange(of: email.threadId) { _, _ in loadThread() }
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var threadHeader: some View {
        Text(email.subject)
            .font(.system(size: 16, weight: .semibold))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func actionButton(icon: String, tooltip: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .disabled(action == nil)
    }

    // MARK: - Thread loading

    private static var threadHTMLCache: [String: String] = [:]

    private func loadThread() {
        if threadMessages.isEmpty {
            isLoading = true
        }
        loadError = nil
        Task {
            do {
                let messages = try await apiManager.fetchThread(
                    threadId: email.threadId,
                    accountId: email.accountId
                )
                threadMessages = messages
                threadNavDelegate.threadMessages = messages

                // Build HTML — cache keyed by message count + IDs to detect changes
                let cacheKey = messages.map(\.id).joined(separator: ",")
                let htmlCacheKey = "\(email.threadId)_\(cacheKey)"
                let html: String
                if let cached = Self.threadHTMLCache[htmlCacheKey] {
                    html = cached
                } else {
                    html = buildThreadHTML(messages: messages)
                    Self.threadHTMLCache[htmlCacheKey] = html
                    // Evict old entries
                    if Self.threadHTMLCache.count > 20 {
                        Self.threadHTMLCache.removeValue(forKey: Self.threadHTMLCache.keys.first!)
                    }
                }
                webViewStore.loadHTML(html)
                isLoading = false
            } catch {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func buildThreadHTML(messages: [ThreadMessage]) -> String {
        var sections: [String] = []

        for message in messages {
            let bodyHTML = stripQuotedContent(message.bodyHTML)

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
                <a href="aerio://action/reply/\(message.id)" style="\(btnStyle)" title="Reply" onmouseover="this.style.background='#333'" onmouseout="this.style.background='transparent'">\(replyIcon)</a>
                <a href="aerio://action/replyall/\(message.id)" style="\(btnStyle)" title="Reply All" onmouseover="this.style.background='#333'" onmouseout="this.style.background='transparent'">\(replyAllIcon)</a>
                <a href="aerio://action/forward/\(message.id)" style="\(btnStyle)" title="Forward" onmouseover="this.style.background='#333'" onmouseout="this.style.background='transparent'">\(forwardIcon)</a>
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
            <div style="border-bottom: 4px solid #333; padding-bottom: 8px; margin-bottom: 8px;">
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
            a { color: #6cb4ff; }
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

    private func stripQuotedContent(_ html: String) -> String {
        var result = html

        // 1. Gmail HTML quote blocks
        if let range = result.range(of: "<div class=\"gmail_quote\"", options: .caseInsensitive) {
            result = String(result[result.startIndex..<range.lowerBound])
        }

        // 2. HTML blockquotes
        if let regex = try? NSRegularExpression(pattern: #"<blockquote[\s\S]*?</blockquote>"#, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // 3. "---" separator in <p> tags: <p...>---</p> — truncate from there, keep </body></html>
        if let regex = try? NSRegularExpression(pattern: #"<p[^>]*>\s*---\s*</p>[\s\S]*?(</body>)"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) {
            let matchRange = Range(match.range, in: result)!
            result = String(result[result.startIndex..<matchRange.lowerBound]) + "</body></html>"
        }

        // 4. "---" separator as plain text (in <pre> blocks)
        if let range = result.range(of: "\n---\n") {
            let before = String(result[result.startIndex..<range.lowerBound])
            let closing = result.contains("</pre>") ? "</pre>" : ""
            result = before + closing
        }

        // 5. "On ... wrote:" only when followed by &gt; quoted lines (avoids false matches)
        if let regex = try? NSRegularExpression(pattern: #"<p[^>]*>\s*On .+?wrote:\s*</p>\s*<p[^>]*>\s*&gt;"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) {
            let matchRange = Range(match.range, in: result)!
            result = String(result[result.startIndex..<matchRange.lowerBound]) + "</body></html>"
        }

        return result
    }

    private func avatarColor(for email: String) -> String {
        let hash = abs(email.hashValue)
        let colors = ["#4a7aff", "#7c3aed", "#e67e22", "#27ae60", "#e84393", "#00b894", "#4b0082", "#00cec9"]
        return colors[hash % colors.count]
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
