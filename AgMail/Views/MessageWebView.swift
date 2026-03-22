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
        let attachmentId: String?
        let messageId: String?
        let mimeType: String?
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

/// Extract attachment info from MIME parts, including IDs needed for download.
func extractAttachments(_ payload: GmailPayload, messageId: String? = nil) -> [MessageContentData.AttachmentInfo] {
    var result: [MessageContentData.AttachmentInfo] = []
    if let parts = payload.parts {
        for part in parts {
            if let filename = part.filename, !filename.isEmpty {
                let size = part.body?.size ?? 0
                let sizeStr = size > 0 ? formatSize(size) : ""
                result.append(.init(
                    name: filename,
                    size: sizeStr,
                    attachmentId: part.body?.attachmentId,
                    messageId: messageId,
                    mimeType: part.mimeType
                ))
            }
            result.append(contentsOf: extractAttachments(part, messageId: messageId))
        }
    }
    return result
}

/// Extract inline image CID mappings: Content-ID → (attachmentId, mimeType).
/// These parts have a Content-ID header and attachmentId but may or may not have a filename.
func extractInlineImages(_ payload: GmailPayload) -> [(cid: String, attachmentId: String, mimeType: String)] {
    var result: [(cid: String, attachmentId: String, mimeType: String)] = []
    if let parts = payload.parts {
        for part in parts {
            if let headers = part.headers,
               let cidHeader = headers.first(where: { $0.name.lowercased() == "content-id" }),
               let attachmentId = part.body?.attachmentId,
               let mimeType = part.mimeType, mimeType.lowercased().hasPrefix("image/") {
                // Strip angle brackets from CID: "<image001>" → "image001"
                let cid = cidHeader.value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                result.append((cid: cid, attachmentId: attachmentId, mimeType: mimeType))
            }
            result.append(contentsOf: extractInlineImages(part))
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
    var onEditDraft: (() -> Void)?
    /// Called by parent to register a scroll handler for keyboard navigation.
    var onRegisterScroll: ((@escaping (Int) -> Void) -> Void)?

    @State private var messageContent: MessageContentData?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var downloadingAttachment: String?
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    FlowLayout(spacing: 8) {
                        ForEach(attachments, id: \.name) { att in
                            HStack(spacing: 0) {
                                // Main area: click to open
                                Button {
                                    downloadAttachment(att, openAfter: true)
                                } label: {
                                    HStack(spacing: 6) {
                                        if downloadingAttachment == att.name {
                                            ProgressView()
                                                .scaleEffect(0.6)
                                                .frame(width: 14, height: 14)
                                        } else {
                                            Image(systemName: iconForAttachment(att.mimeType))
                                                .font(.system(size: 14))
                                                .foregroundStyle(.blue)
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(att.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            if !att.size.isEmpty {
                                                Text(att.size)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                }
                                .help("Open \(att.name)")

                                Divider().frame(height: 20)

                                // Download-only button
                                Button {
                                    downloadAttachment(att, openAfter: false)
                                } label: {
                                    Image(systemName: "arrow.down.to.line")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                }
                                .help("Save to Downloads")
                            }
                            .background(Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
    }

    private var actionButtonBar: some View {
        HStack(spacing: 4) {
            if folder == .drafts {
                actionButton(icon: "square.and.pencil", tooltip: "Edit Draft (Enter)", action: onEditDraft)

                Divider()
                    .frame(height: 16)
            } else {
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
                actionButton(icon: "exclamationmark.octagon", tooltip: "Spam (\(ShortcutAction.spamMessage.shortcutLabel))", action: onSpam)
            }
            actionButton(icon: "trash", tooltip: "Delete (\(ShortcutAction.deleteMessage.shortcutLabel))", action: onDelete)
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

    private func iconForAttachment(_ mimeType: String?) -> String {
        guard let mime = mimeType?.lowercased() else { return "doc" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "music.note" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("zip") || mime.contains("archive") || mime.contains("compressed") { return "doc.zipper" }
        if mime.contains("spreadsheet") || mime.contains("excel") { return "tablecells" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.on.rectangle" }
        if mime.contains("word") || mime.contains("document") { return "doc.text" }
        return "doc"
    }

    private func downloadAttachment(_ att: MessageContentData.AttachmentInfo, openAfter: Bool) {
        guard let attachmentId = att.attachmentId, let messageId = att.messageId else { return }
        downloadingAttachment = att.name
        Task {
            do {
                let data = try await apiManager.downloadAttachment(
                    messageId: messageId,
                    attachmentId: attachmentId,
                    accountId: email.accountId
                )
                let downloadsDir = SettingsView.resolvedDownloadsDirectory()
                try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
                var fileURL = downloadsDir.appendingPathComponent(att.name)
                var counter = 1
                let baseName = (att.name as NSString).deletingPathExtension
                let ext = (att.name as NSString).pathExtension
                while FileManager.default.fileExists(atPath: fileURL.path) {
                    let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
                    fileURL = downloadsDir.appendingPathComponent(newName)
                    counter += 1
                }
                try data.write(to: fileURL)
                if openAfter {
                    NSWorkspace.shared.open(fileURL)
                } else {
                    // Bounce in Dock to signal download complete
                    NSApp.requestUserAttention(.informationalRequest)
                }
            } catch {
                logger.error("Failed to download attachment: \(error.localizedDescription)")
            }
            downloadingAttachment = nil
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

                var bodyHTML: String
                if let payload = message.payload {
                    let extracted = extractBodyFromPayload(payload)
                    bodyHTML = extracted.isEmpty ? "<p>No message body</p>" : extracted
                } else {
                    bodyHTML = "<p>No message body</p>"
                }

                // Resolve inline CID images → data URIs, and collect resolved CIDs
                var resolvedAttachmentIds: Set<String> = []
                if let payload = message.payload {
                    let inlineImages = extractInlineImages(payload)
                    for inline in inlineImages {
                        guard bodyHTML.contains("cid:\(inline.cid)") else { continue }
                        do {
                            let data = try await apiManager.downloadAttachment(
                                messageId: message.id,
                                attachmentId: inline.attachmentId,
                                accountId: email.accountId
                            )
                            let base64 = data.base64EncodedString()
                            let dataURI = "data:\(inline.mimeType);base64,\(base64)"
                            bodyHTML = bodyHTML.replacingOccurrences(of: "cid:\(inline.cid)", with: dataURI)
                            resolvedAttachmentIds.insert(inline.attachmentId)
                        } catch {
                            logger.debug("Failed to resolve inline image \(inline.cid): \(error.localizedDescription)")
                        }
                    }
                }

                let attachments = message.payload.map { extractAttachments($0, messageId: message.id) } ?? []

                // Embed remaining image attachments (not resolved via CID) at the end of the body
                let unresolvedImages = attachments.filter {
                    guard let mime = $0.mimeType?.lowercased(), mime.hasPrefix("image/") else { return false }
                    guard let attId = $0.attachmentId else { return false }
                    return !resolvedAttachmentIds.contains(attId)
                }
                if !unresolvedImages.isEmpty {
                    var imagesHTML = "<div style=\"margin-top: 16px;\">"
                    for imgAtt in unresolvedImages {
                        guard let attachmentId = imgAtt.attachmentId else { continue }
                        do {
                            let data = try await apiManager.downloadAttachment(
                                messageId: message.id,
                                attachmentId: attachmentId,
                                accountId: email.accountId
                            )
                            let base64 = data.base64EncodedString()
                            let mime = imgAtt.mimeType ?? "image/png"
                            imagesHTML += "<p><img src=\"data:\(mime);base64,\(base64)\" style=\"max-width:100%;\" alt=\"\(imgAtt.name)\"></p>"
                        } catch {
                            logger.debug("Failed to embed image \(imgAtt.name): \(error.localizedDescription)")
                        }
                    }
                    imagesHTML += "</div>"
                    bodyHTML += imagesHTML
                }

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
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: https:; font-src 'none';">
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

/// Simple horizontal flow layout that wraps items to the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (offsets: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (offsets, CGSize(width: maxX, height: y + rowHeight))
    }
}
