import SwiftUI
import WebKit
import os.log

private let logger = Logger(subsystem: "AgMail", category: "MessageDetail")

struct MessageContentData {
    let from: String
    let to: String
    let cc: String
    let subject: String
    let date: String
    let bodyHTML: String
    let attachments: [AttachmentInfo]

    struct AttachmentInfo {
        let name: String
        let size: String
    }
}

/// Recursively extract body HTML from a Gmail MIME payload.
/// Prefers text/html; falls back to text/plain wrapped in <pre>.
func extractBodyFromPayload(_ payload: GmailPayload) -> String {
    // Depth-first search: find text/html first, then text/plain as fallback
    if let html = findLeaf(payload, mimeType: "text/html") {
        return html
    }
    if let plain = findLeaf(payload, mimeType: "text/plain") {
        let escaped = plain
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre style=\"white-space: pre-wrap; word-wrap: break-word; font-family: inherit;\">\(escaped)</pre>"
    }
    return ""
}

/// Depth-first search for a leaf node with the specified MIME type.
private func findLeaf(_ payload: GmailPayload, mimeType target: String) -> String? {
    if let parts = payload.parts, !parts.isEmpty {
        for part in parts {
            if let result = findLeaf(part, mimeType: target) {
                return result
            }
        }
        return nil
    }

    // Leaf node
    let mime = payload.mimeType?.lowercased() ?? ""
    guard mime == target else { return nil }
    guard let bodyData = payload.body?.data, !bodyData.isEmpty else { return nil }
    guard let decoded = base64URLDecode(bodyData) else { return nil }
    return String(data: decoded, encoding: .utf8)
}

/// Extract attachment names from MIME parts.
func extractAttachments(_ payload: GmailPayload) -> [MessageContentData.AttachmentInfo] {
    var result: [MessageContentData.AttachmentInfo] = []
    if let parts = payload.parts {
        for part in parts {
            if let filename = part.filename, !filename.isEmpty {
                let size = part.body?.size ?? 0
                let sizeStr = size > 0 ? formatSize(size) : ""
                result.append(.init(name: filename, size: sizeStr))
            }
            result.append(contentsOf: extractAttachments(part))
        }
    }
    return result
}

private func formatSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
    return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
}

private func base64URLDecode(_ str: String) -> Data? {
    Data.fromBase64URL(str)
}

/// Native message detail: SwiftUI headers + WKWebView for HTML body
struct NativeMessageDetail: View {
    let email: Email
    let apiManager: GmailAPIManager
    let folder: Folder

    var onReply: (() -> Void)?
    var onReplyAll: (() -> Void)?
    var onForward: (() -> Void)?
    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSpam: (() -> Void)?
    var onMoveToInbox: (() -> Void)?
    /// Called by parent to register a scroll handler for keyboard navigation.
    var onRegisterScroll: ((@escaping (Int) -> Void) -> Void)?

    @State private var messageContent: MessageContentData?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @StateObject private var bodyWebViewStore = BodyWebViewStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionButtonBar
            messageHeaders
            Divider()
            if isLoading {
                ProgressView("Loading message…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Retry") { loadContent() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BodyWebView(webView: bodyWebViewStore.webView)
            }
        }
        .onAppear {
            loadContent()
            onRegisterScroll? { direction in
                bodyWebViewStore.scrollContent(direction: direction)
            }
        }
        .onChange(of: email.id) { _, _ in loadContent() }
    }

    private var messageHeaders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(messageContent?.subject ?? email.subject)
                .font(.system(size: 16, weight: .semibold))
                .textSelection(.enabled)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    headerRow("From", value: messageContent?.from ?? email.from)
                    if let to = messageContent?.to, !to.isEmpty {
                        headerRow("To", value: to)
                    }
                    if let cc = messageContent?.cc, !cc.isEmpty {
                        headerRow("Cc", value: cc)
                    }
                }
                Spacer()
                Text(messageContent?.date ?? email.date.shortRelative)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let attachments = messageContent?.attachments, !attachments.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(attachments, id: \.name) { att in
                        Text("\(att.name) \(att.size)")
                            .font(.system(size: 11))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(12)
    }

    private var actionButtonBar: some View {
        HStack(spacing: 4) {
            actionButton(icon: "arrowshape.turn.up.left", tooltip: "Reply (\(ShortcutAction.reply.shortcutLabel))", action: onReply)
            actionButton(icon: "arrowshape.turn.up.left.2", tooltip: "Reply All (\(ShortcutAction.replyAll.shortcutLabel))", action: onReplyAll)
            actionButton(icon: "arrowshape.turn.up.right", tooltip: "Forward (\(ShortcutAction.forward.shortcutLabel))", action: onForward)

            Divider()
                .frame(height: 16)

            if folder == .inbox {
                actionButton(icon: "archivebox", tooltip: "Archive (\(ShortcutAction.archiveMessage.shortcutLabel))", action: onArchive)
            }
            if folder != .inbox {
                actionButton(icon: "tray.and.arrow.down", tooltip: "Move to Inbox (\(ShortcutAction.moveToInbox.shortcutLabel))", action: onMoveToInbox)
            }
            actionButton(icon: "trash", tooltip: "Delete (\(ShortcutAction.deleteMessage.shortcutLabel))", action: onDelete)
            actionButton(icon: "exclamationmark.octagon", tooltip: "Spam (\(ShortcutAction.spamMessage.shortcutLabel))", action: onSpam)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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

    private func headerRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label + ":")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func loadContent() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let message = try await apiManager.fetchMessageContent(msgId: email.msgId, accountId: email.accountId)
                let headers = message.payload?.headers ?? []
                let from = headers.first { $0.name.lowercased() == "from" }?.value ?? email.from
                let to = headers.first { $0.name.lowercased() == "to" }?.value ?? ""
                let cc = headers.first { $0.name.lowercased() == "cc" }?.value ?? ""
                let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? email.subject
                let dateStr = headers.first { $0.name.lowercased() == "date" }?.value ?? email.date.shortRelative

                let bodyHTML: String
                if let payload = message.payload {
                    let extracted = extractBodyFromPayload(payload)
                    bodyHTML = extracted.isEmpty ? "<p>No message body</p>" : extracted
                } else {
                    bodyHTML = "<p>No message body</p>"
                }

                let attachments = message.payload.map { extractAttachments($0) } ?? []

                let content = MessageContentData(
                    from: from, to: to, cc: cc, subject: subject,
                    date: dateStr, bodyHTML: bodyHTML, attachments: attachments
                )
                messageContent = content

                let html = wrapHTML(bodyHTML, subject: subject)
                bodyWebViewStore.loadHTML(html)
                isLoading = false
            } catch {
                logger.error("Failed to load message: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func wrapHTML(_ body: String, subject: String) -> String {
        wrapEmailHTML(body, subject: subject)
    }
}

/// Wraps email body HTML in a full document with light-only styling (no dark mode).
func wrapEmailHTML(_ body: String, subject: String) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none';">
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            font-size: 14px;
            line-height: 1.5;
            color: #1d1d1f;
            padding: 16px;
            margin: 0;
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        img { max-width: 100%; height: auto; }
        blockquote {
            border-left: 3px solid #ccc;
            margin: 8px 0;
            padding-left: 12px;
            color: #666;
        }
        pre, code {
            background: #f4f4f4;
            border-radius: 4px;
            padding: 2px 6px;
            font-size: 13px;
        }
        table { max-width: 100%; }
    </style>
    </head>
    <body>
    \(body)
    </body>
    </html>
    """
}

@MainActor
final class BodyWebViewStore: ObservableObject {
    let webView: WKWebView
    private let navigationDelegate = BodyWebViewNavigationDelegate()

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        self.webView.appearance = NSAppearance(named: .aqua)
        self.webView.navigationDelegate = navigationDelegate
    }

    func loadHTML(_ html: String) {
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// Scroll the web view content by a fixed amount.
    /// direction: negative = up, positive = down.
    func scrollContent(direction: Int) {
        let pixels = direction > 0 ? 100 : -100
        webView.evaluateJavaScript("window.scrollBy(0, \(pixels))", completionHandler: nil)
    }
}

/// Intercepts navigation to open links in the default browser instead of inside the webview.
final class BodyWebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

struct BodyWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
