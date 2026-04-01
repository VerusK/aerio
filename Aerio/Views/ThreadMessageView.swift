import SwiftUI
import WebKit

/// WKWebView subclass that forwards scroll events to the parent ScrollView.
class NonScrollingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// NSViewRepresentable for NonScrollingWebView.
struct ThreadBodyWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Manages a NonScrollingWebView for use in thread messages.
@MainActor
final class ThreadWebViewStore: ObservableObject {
    let webView: NonScrollingWebView
    private let navigationDelegate = BodyWebViewNavigationDelegate()

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        self.webView = NonScrollingWebView(frame: .zero, configuration: config)
        self.webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        self.webView.appearance = NSAppearance(named: .aqua)
        self.webView.navigationDelegate = navigationDelegate
    }

    func loadHTML(_ html: String) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

struct ThreadMessageView: View {
    let message: ThreadMessage
    let apiManager: GmailAPIManager

    var onReply: (() -> Void)?
    var onReplyAll: (() -> Void)?
    var onForward: (() -> Void)?

    @StateObject private var bodyWebViewStore = ThreadWebViewStore()
    @State private var isLoading = true
    @State private var contentHeight: CGFloat = 100
    @State private var downloadingAttachment: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: avatar + from/to/date
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(message.from)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(message.date.shortRelative)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if !message.to.isEmpty {
                        Text("To: \(message.to)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !message.cc.isEmpty {
                        Text("Cc: \(message.cc)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Body: WKWebView
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ThreadBodyWebView(webView: bodyWebViewStore.webView)
                    .frame(height: contentHeight)
            }

            // Attachments
            if !message.attachments.isEmpty {
                attachmentChips
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            // Per-message actions
            HStack(spacing: 4) {
                actionButton(icon: "arrowshape.turn.up.left", tooltip: "Reply", action: onReply)
                actionButton(icon: "arrowshape.turn.up.left.2", tooltip: "Reply All", action: onReplyAll)
                actionButton(icon: "arrowshape.turn.up.right", tooltip: "Forward", action: onForward)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Thick divider
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 4)
        }
        .onAppear { loadBody() }
    }

    private var avatar: some View {
        let initial = String(message.from.prefix(1)).uppercased()
        let color = avatarColor(for: message.from)
        return Circle()
            .fill(color)
            .frame(width: 32, height: 32)
            .overlay(
                Text(initial)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            )
    }

    private func avatarColor(for email: String) -> Color {
        let hash = abs(email.hashValue)
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .mint]
        return colors[hash % colors.count]
    }

    private func actionButton(icon: String, tooltip: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .disabled(action == nil)
    }

    private var attachmentChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(message.attachments, id: \.name) { att in
                HStack(spacing: 6) {
                    if downloadingAttachment == att.name {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "doc")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                    }
                    Text(att.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    if !att.size.isEmpty {
                        Text(att.size)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .onTapGesture {
                    downloadAttachment(att)
                }
            }
        }
    }

    private func loadBody() {
        var html = message.bodyHTML
        Task {
            for inline in message.inlineImages {
                guard html.contains("cid:\(inline.cid)") else { continue }
                do {
                    let data = try await apiManager.downloadAttachment(
                        messageId: message.id,
                        attachmentId: inline.attachmentId,
                        accountId: message.accountId
                    )
                    let base64 = data.base64EncodedString()
                    let dataURI = "data:\(inline.mimeType);base64,\(base64)"
                    html = html.replacingOccurrences(of: "cid:\(inline.cid)", with: dataURI)
                } catch {}
            }
            html = stripQuotedContent(html)
            let wrapped = wrapEmailHTML(html, subject: message.subject)
            bodyWebViewStore.loadHTML(wrapped)
            isLoading = false
            // Give WebView time to render, then measure content height
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                updateContentHeight()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                updateContentHeight()
            }
        }
    }

    /// Strip quoted previous messages from HTML body.
    /// Gmail wraps quotes in <div class="gmail_quote"> or <blockquote>.
    /// Also strips "On ... wrote:" plain-text patterns.
    private func stripQuotedContent(_ html: String) -> String {
        var result = html
        // Remove Gmail-style quoted blocks: <div class="gmail_quote">...</div>
        let gmailQuotePattern = #"<div\s+class\s*=\s*"gmail_quote"[\s\S]*$"#
        if let regex = try? NSRegularExpression(pattern: gmailQuotePattern, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Remove <blockquote> blocks (common in non-Gmail replies)
        let blockquotePattern = #"<blockquote[\s\S]*?</blockquote>"#
        if let regex = try? NSRegularExpression(pattern: blockquotePattern, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Remove "On <date>, <name> wrote:" lines (plain text emails)
        let onWrotePattern = #"(?m)^On .+wrote:\s*$"#
        if let regex = try? NSRegularExpression(pattern: onWrotePattern, options: []) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Remove lines starting with > (plain text quoting)
        let quotedLinePattern = #"(?m)^&gt;.*$"#
        if let regex = try? NSRegularExpression(pattern: quotedLinePattern, options: []) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    private func updateContentHeight() {
        bodyWebViewStore.webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
            if let height = result as? CGFloat, height > 0 {
                self.contentHeight = height + 32 // padding
            }
        }
    }

    private func downloadAttachment(_ att: MessageContentData.AttachmentInfo) {
        guard let attachmentId = att.attachmentId, let messageId = att.messageId else { return }
        downloadingAttachment = att.name
        Task {
            do {
                let data = try await apiManager.downloadAttachment(
                    messageId: messageId,
                    attachmentId: attachmentId,
                    accountId: message.accountId
                )
                let downloadsDir = SettingsView.resolvedDownloadsDirectory()
                try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
                let fileURL = downloadsDir.appendingPathComponent(att.name)
                try data.write(to: fileURL)
                NSWorkspace.shared.open(fileURL)
            } catch {}
            downloadingAttachment = nil
        }
    }
}
