import SwiftUI
import WebKit

struct ThreadMessageView: View {
    let message: ThreadMessage
    let apiManager: GmailAPIManager

    var onReply: (() -> Void)?
    var onReplyAll: (() -> Void)?
    var onForward: (() -> Void)?

    @StateObject private var bodyWebViewStore = BodyWebViewStore()
    @State private var isLoading = true
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
                BodyWebView(webView: bodyWebViewStore.webView)
                    .frame(minHeight: 60, maxHeight: 400)
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
            let wrapped = wrapEmailHTML(html, subject: message.subject)
            bodyWebViewStore.loadHTML(wrapped, emailId: message.id)
            isLoading = false
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
