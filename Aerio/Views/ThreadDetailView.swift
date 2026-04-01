import SwiftUI
import WebKit

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

                let cacheKey = "\(email.accountId)_\(email.threadId)"
                if let cachedHTML = Self.threadHTMLCache[cacheKey] {
                    webViewStore.loadHTML(cachedHTML)
                    isLoading = false
                    return
                }

                // Build single HTML document for entire thread
                let html = buildThreadHTML(messages: messages)
                Self.threadHTMLCache[cacheKey] = html
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
            var bodyHTML = message.bodyHTML
            bodyHTML = stripQuotedContent(bodyHTML)

            let initial = String(message.from.prefix(1)).uppercased()
            let color = avatarColor(for: message.from)
            let dateStr = message.date.shortRelative
            let toLine = message.to.isEmpty ? "" : "<div style=\"font-size:11px;color:#888;margin-top:2px;\">To: \(escapeHTML(message.to))</div>"
            let ccLine = message.cc.isEmpty ? "" : "<div style=\"font-size:11px;color:#888;margin-top:1px;\">Cc: \(escapeHTML(message.cc))</div>"

            // Build attachment chips HTML
            var attachmentsHTML = ""
            if !message.attachments.isEmpty {
                var chips: [String] = []
                for att in message.attachments {
                    let sizeStr = att.size.isEmpty ? "" : " <span style=\"color:#999;font-size:10px;\">(\(escapeHTML(att.size)))</span>"
                    chips.append("""
                    <span style="display:inline-block;background:#2a2a2a;border:1px solid #444;border-radius:6px;padding:3px 8px;margin:2px 4px 2px 0;font-size:11px;">
                        📎 \(escapeHTML(att.name))\(sizeStr)
                    </span>
                    """)
                }
                attachmentsHTML = "<div style=\"padding-top:4px;\">\(chips.joined())</div>"
            }

            let section = """
            <div style="border-bottom: 4px solid #333; padding-bottom: 8px; margin-bottom: 8px;">
                <div style="display:flex;align-items:flex-start;gap:10px;padding:12px 0 8px 0;">
                    <div style="width:32px;height:32px;border-radius:50%;background:\(color);display:flex;align-items:center;justify-content:center;font-size:13px;color:white;flex-shrink:0;">\(initial)</div>
                    <div style="flex:1;min-width:0;">
                        <div style="display:flex;justify-content:space-between;align-items:baseline;">
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
        let gmailQuotePattern = #"<div\s+class\s*=\s*"gmail_quote"[\s\S]*$"#
        if let regex = try? NSRegularExpression(pattern: gmailQuotePattern, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        let blockquotePattern = #"<blockquote[\s\S]*?</blockquote>"#
        if let regex = try? NSRegularExpression(pattern: blockquotePattern, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        let onWrotePattern = #"(?m)^On .+wrote:\s*$"#
        if let regex = try? NSRegularExpression(pattern: onWrotePattern, options: []) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        let quotedLinePattern = #"(?m)^&gt;.*$"#
        if let regex = try? NSRegularExpression(pattern: quotedLinePattern, options: []) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
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
