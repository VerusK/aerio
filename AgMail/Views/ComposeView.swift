import SwiftUI

enum ComposeType: Sendable {
    case new
    case reply
    case replyAll
    case forward
}

struct ComposeView: View {
    let accountManager: AccountManager
    let apiManager: GmailAPIManager
    var composeType: ComposeType = .new
    var replyToEmail: Email?
    var preselectedAccountId: String?
    var onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountId: String = ""
    @State private var toField: String = ""
    @State private var ccField: String = ""
    @State private var subjectField: String = ""
    @State private var bodyText: String = ""
    @State private var isSending = false
    @State private var isLoadingRecipients = false
    @State private var sendError: String?
    @State private var replyAllWarning: String?
    @State private var fetchedMessageId: String?


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            composeForm
            Divider()
            toolbar
        }
        .frame(width: 600, height: 500)
        .onAppear { setupInitialValues() }
    }

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)
            Spacer()
            if isSending {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Sending…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Close") {
                onDismiss?()
                dismiss()
            }
            .keyboardShortcut(.escape)
        }
        .padding()
    }

    private var headerTitle: String {
        switch composeType {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        }
    }

    private var composeForm: some View {
        VStack(spacing: 0) {
            // From picker
            HStack {
                Text("From:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
                Picker("", selection: $selectedAccountId) {
                    ForEach(accountManager.accounts) { account in
                        Text(account.email).tag(account.id)
                    }
                }
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            // To
            fieldRow("To:", text: $toField)
                .disabled(isLoadingRecipients)
            Divider()

            // Cc
            fieldRow("Cc:", text: $ccField)
                .disabled(isLoadingRecipients)
            Divider()

            // Subject
            fieldRow("Subject:", text: $subjectField)
            Divider()

            // Body
            TextEditor(text: $bodyText)
                .font(.system(size: 13))
                .padding(8)
                .frame(maxHeight: .infinity)

            if let replyAllWarning {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(replyAllWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            if let sendError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(sendError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    private func fieldRow(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var toolbar: some View {
        HStack {
            Button {
                sendMessage()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                    Text("Send")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isSending || isLoadingRecipients || toField.isEmpty)

            if isLoadingRecipients {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading recipients…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }

    private func setupInitialValues() {
        if let preselectedAccountId, !preselectedAccountId.isEmpty {
            selectedAccountId = preselectedAccountId
        } else {
            selectedAccountId = accountManager.accounts.first?.id ?? ""
        }

        if let email = replyToEmail {
            switch composeType {
            case .reply:
                toField = email.from
                subjectField = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
                bodyText = "\n\n---\nOn \(email.date.formatted()), \(email.from) wrote:\n> \(email.snippet)"
                fetchReplyHeaders(email: email, includeAllRecipients: false)
            case .replyAll:
                toField = email.from
                subjectField = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
                bodyText = "\n\n---\nOn \(email.date.formatted()), \(email.from) wrote:\n> \(email.snippet)"
                fetchReplyHeaders(email: email, includeAllRecipients: true)
            case .forward:
                subjectField = email.subject.hasPrefix("Fwd:") ? email.subject : "Fwd: \(email.subject)"
                bodyText = "\n\n---\nForwarded message from \(email.from):\n\(email.snippet)"
            case .new:
                break
            }
            selectedAccountId = email.accountId
        }
    }

    private func fetchReplyHeaders(email: Email, includeAllRecipients: Bool) {
        isLoadingRecipients = true
        Task {
            defer { isLoadingRecipients = false }
            do {
                let message = try await apiManager.fetchMessageContent(msgId: email.msgId, accountId: email.accountId)
                let headers = message.payload?.headers ?? []

                // Capture Message-ID for threading (fallback if cached email lacks it)
                if let msgIdHeader = headers.first(where: { $0.name.lowercased() == "message-id" })?.value,
                   !msgIdHeader.isEmpty {
                    fetchedMessageId = msgIdHeader
                }

                // Use Reply-To header if present, otherwise keep From
                if let replyToHeader = headers.first(where: { $0.name.lowercased() == "reply-to" })?.value,
                   !replyToHeader.isEmpty {
                    toField = replyToHeader
                }

                if includeAllRecipients {
                    let originalTo = headers.first { $0.name.lowercased() == "to" }?.value ?? ""
                    let originalCc = headers.first { $0.name.lowercased() == "cc" }?.value ?? ""

                    let myEmail = accountManager.accounts.first { $0.id == email.accountId }?.email.lowercased() ?? ""
                    let replyToEmail = extractEmail(from: toField).lowercased()

                    // Combine original To and Cc, excluding reply target (already in To) and self
                    var allRecipients: [String] = []
                    let toAddresses = parseAddressList(originalTo)
                    let ccAddresses = parseAddressList(originalCc)

                    for addr in toAddresses + ccAddresses {
                        let normalized = extractEmail(from: addr).lowercased()
                        if normalized != replyToEmail && normalized != myEmail && !normalized.isEmpty {
                            allRecipients.append(addr)
                        }
                    }

                    if !allRecipients.isEmpty {
                        ccField = allRecipients.joined(separator: ", ")
                    }
                }
            } catch {
                if includeAllRecipients {
                    replyAllWarning = "Could not load all recipients — only replying to sender. Check your connection and try again."
                } else {
                    replyAllWarning = "Could not verify Reply-To address — replying to sender. If this message uses a different reply address, check your connection and retry."
                }
            }
        }
    }

    private func extractEmail(from address: String) -> String {
        if let start = address.lastIndex(of: "<"),
           let end = address.lastIndex(of: ">"),
           start < end {
            return String(address[address.index(after: start)..<end])
        }
        return address.trimmingCharacters(in: .whitespaces)
    }

    private func parseAddressList(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        // RFC 5322-aware split: only split on commas outside quoted strings
        var results: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { results.append(trimmed) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { results.append(trimmed) }
        return results
    }

    private func sendMessage() {
        guard !toField.isEmpty else { return }
        isSending = true
        sendError = nil

        guard let fromEmail = accountManager.accounts.first(where: { $0.id == selectedAccountId })?.email else {
            sendError = "No account selected"
            isSending = false
            return
        }

        Task {
            do {
                try await apiManager.sendEmail(
                    from: fromEmail,
                    to: toField,
                    cc: ccField.isEmpty ? nil : ccField,
                    subject: subjectField,
                    body: bodyText,
                    accountId: selectedAccountId,
                    inReplyTo: replyToEmail?.messageId ?? fetchedMessageId,
                    references: replyToEmail?.messageId ?? fetchedMessageId
                )
                onDismiss?()
                dismiss()
                Task { await apiManager.refreshAll() }
            } catch {
                sendError = error.localizedDescription
            }
            isSending = false
        }
    }
}
