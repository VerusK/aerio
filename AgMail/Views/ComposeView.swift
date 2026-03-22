import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "AgMail", category: "ComposeView")

enum ComposeType: Sendable {
    case new
    case reply
    case replyAll
    case forward
    case draft
}

struct ComposeView: View {
    let accountManager: AccountManager
    let apiManager: GmailAPIManager
    var contactsCache: ContactsCache?
    var composeType: ComposeType = .new
    var replyToEmail: Email?
    var preselectedAccountId: String?
    var onDismiss: (() -> Void)?

    struct ComposeAttachment: Identifiable {
        let id = UUID()
        let filename: String
        let mimeType: String
        let data: Data

        var sizeString: String {
            let bytes = data.count
            if bytes < 1024 { return "\(bytes) B" }
            if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }

    @State private var selectedAccountId: String = ""
    @State private var toField: String = ""
    @State private var ccField: String = ""
    @State private var subjectField: String = ""
    @State private var bodyText: String = ""
    @State private var attachments: [ComposeAttachment] = []
    @State private var isSending = false
    @State private var hasSent = false
    @State private var isLoadingRecipients = false
    @State private var sendError: String?
    @State private var replyAllWarning: String?
    @State private var fetchedMessageId: String?
    @State private var toSuggestions: [CachedContact] = []
    @State private var ccSuggestions: [CachedContact] = []
    @State private var selectedSuggestionIndex: Int = -1
    @State private var isDirty = false
    @State private var isInitialized = false
    @State private var isPopulatingHeaders = false
    @State private var draftId: String?
    @State private var isLoadingDraft = false
    @StateObject private var editorState = ComposeEditorState()
    @FocusState private var focusedField: ComposeField?

    enum ComposeField: Hashable {
        case to, cc, subject
    }

    enum AutocompleteField {
        case to, cc
    }

    var body: some View {
        VStack(spacing: 0) {
            composeForm
            Divider()
            toolbar
        }
        .frame(minWidth: 450, maxWidth: .infinity, minHeight: 350, maxHeight: .infinity)
        .onAppear {
            setupInitialValues()
            // Defer so onChange handlers ignore initial setup
            DispatchQueue.main.async {
                isInitialized = true
                setInitialFocus()
            }
        }
        .onDisappear {
            saveDraftIfNeeded()
        }
        .onChange(of: toField) { _, _ in if isInitialized && !isPopulatingHeaders { isDirty = true } }
        .onChange(of: ccField) { _, _ in if isInitialized && !isPopulatingHeaders { isDirty = true } }
        .onChange(of: subjectField) { _, _ in if isInitialized && !isPopulatingHeaders { isDirty = true } }
        .onChange(of: bodyText) { _, _ in if isInitialized && !isPopulatingHeaders { isDirty = true } }
    }

    private var composeForm: some View {
        VStack(spacing: 0) {
            // From picker
            HStack {
                Text("From:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                FromPickerView(accounts: accountManager.accounts, selectedAccountId: $selectedAccountId)
                    .frame(height: 22)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            // To
            autocompleteFieldRow("To:", text: $toField, suggestions: $toSuggestions, field: .to, focusField: .to)
                .disabled(isLoadingRecipients)
            Divider()

            // Cc
            autocompleteFieldRow("Cc:", text: $ccField, suggestions: $ccSuggestions, field: .cc, focusField: .cc)
                .disabled(isLoadingRecipients)
            Divider()

            // Subject
            fieldRow("Subject:", text: $subjectField, focusField: .subject)
            Divider()

            // Formatting toolbar
            formattingToolbar
            Divider()

            // Body
            ComposeBodyEditor(
                text: $bodyText,
                editorState: editorState,
                cursorAtStart: composeType == .reply || composeType == .replyAll || composeType == .forward,
                onTab: { focusedField = .to },
                onBackTab: { focusedField = .subject },
                onAttachFiles: { urls in
                    for url in urls { addAttachment(from: url) }
                },
                onAttachImageData: { data, filename in
                    addAttachmentFromData(data, filename: filename, mimeType: "image/png")
                }
            )
            .frame(maxHeight: .infinity)

            // Attachments
            if !attachments.isEmpty {
                Divider()
                attachmentsList
            }

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

    private func fieldRow(_ label: String, text: Binding<String>, focusField: ComposeField) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focusedField, equals: focusField)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func autocompleteFieldRow(_ label: String, text: Binding<String>, suggestions: Binding<[CachedContact]>, field: AutocompleteField, focusField: ComposeField) -> some View {
        let items = Array(suggestions.wrappedValue.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focusedField, equals: focusField)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        updateSuggestions(for: field, query: newValue)
                    }
                    .onKeyPress(.downArrow) {
                        guard !items.isEmpty else { return .ignored }
                        selectedSuggestionIndex = min(selectedSuggestionIndex + 1, items.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !items.isEmpty else { return .ignored }
                        selectedSuggestionIndex = max(selectedSuggestionIndex - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard !items.isEmpty, selectedSuggestionIndex >= 0, selectedSuggestionIndex < items.count else { return .ignored }
                        insertContact(items[selectedSuggestionIndex], into: text, field: field)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !items.isEmpty else { return .ignored }
                        clearSuggestions(for: field)
                        return .handled
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element) { index, contact in
                        Button {
                            insertContact(contact, into: text, field: field)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                if let name = contact.displayName {
                                    Text(name)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                Text(contact.email)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(index == selectedSuggestionIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                selectedSuggestionIndex = index
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
                .padding(.horizontal, 62)
                .padding(.bottom, 4)
            }
        }
    }

    private func updateSuggestions(for field: AutocompleteField, query: String) {
        guard let cache = contactsCache else {
            clearSuggestions(for: field)
            return
        }
        let currentToken = Self.extractCurrentToken(from: query)
        guard !currentToken.isEmpty else {
            clearSuggestions(for: field)
            return
        }
        let alreadyAdded = Self.existingEmails(in: query)
        let results = cache.search(currentToken).filter { !alreadyAdded.contains($0.email) }
        selectedSuggestionIndex = -1
        switch field {
        case .to: toSuggestions = results
        case .cc: ccSuggestions = results
        }
    }

    private static func existingEmails(in field: String) -> Set<String> {
        let parts = field.components(separatedBy: ",")
        guard parts.count > 1 else { return [] }
        var emails = Set<String>()
        for part in parts.dropLast() {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let parsed = ContactsCache.parseFromHeader(trimmed)
            if !parsed.email.isEmpty {
                emails.insert(parsed.email.lowercased())
            }
        }
        return emails
    }

    private func clearSuggestions(for field: AutocompleteField) {
        switch field {
        case .to: toSuggestions = []
        case .cc: ccSuggestions = []
        }
    }

    private func insertContact(_ contact: CachedContact, into text: Binding<String>, field: AutocompleteField) {
        let current = text.wrappedValue
        let parts = current.components(separatedBy: ",")
        var mutableParts = parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
        mutableParts.append(contact.formatted)
        text.wrappedValue = mutableParts.joined(separator: ", ") + ", "
        selectedSuggestionIndex = -1
        clearSuggestions(for: field)
    }

    static func extractCurrentToken(from text: String) -> String {
        let parts = text.components(separatedBy: ",")
        return parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private var formattingToolbar: some View {
        HStack(spacing: 2) {
            formatButton("Bold", symbol: "bold", shortcut: "⌘B", isActive: editorState.isBold) {
                editorState.toggleBold()
            }
            formatButton("Italic", symbol: "italic", shortcut: "⌘I", isActive: editorState.isItalic) {
                editorState.toggleItalic()
            }
            formatButton("Underline", symbol: "underline", shortcut: "⌘U", isActive: editorState.isUnderlined) {
                editorState.toggleUnderline()
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            formatButton("Bullet List", symbol: "list.bullet", shortcut: nil, isActive: false) {
                editorState.toggleBulletList()
            }
            formatButton("Numbered List", symbol: "list.number", shortcut: nil, isActive: false) {
                editorState.toggleNumberedList()
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func formatButton(_ label: String, symbol: String, shortcut: String?, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            // Return focus to the text editor after toolbar button click
            DispatchQueue.main.async {
                if let tv = editorState.textView {
                    tv.window?.makeFirstResponder(tv)
                }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: isActive ? .bold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .frame(width: 26, height: 22)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
    }

    private var attachmentsList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { att in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                            .font(.system(size: 10))
                        Text("\(att.filename) (\(att.sizeString))")
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Button {
                            attachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var toolbar: some View {
        HStack {
            if isLoadingRecipients {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading recipients…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isLoadingDraft {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading draft…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isSending {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Sending…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                pickFiles()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                    Text("Attach")
                }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("Attach files (⇧⌘A)")

            Button {
                sendMessage()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                    Text("Send")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isSending || isLoadingRecipients || isLoadingDraft || toField.isEmpty)
            .help("Send message (⌘Return)")
        }
        .padding()
    }

    private func setInitialFocus() {
        switch composeType {
        case .new:
            focusedField = .to
        case .reply, .replyAll, .forward, .draft:
            // Focus the NSTextView body editor directly
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow,
                   let textView = Self.findTextView(in: window.contentView) {
                    window.makeFirstResponder(textView)
                }
            }
        }
    }

    private static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? TabAwareTextView { return tv }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
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
            case .draft:
                selectedAccountId = email.accountId
                loadDraftContent(email: email)
            case .new:
                break
            }
            if composeType != .draft {
                selectedAccountId = email.accountId
            }
        }
    }

    private func loadDraftContent(email: Email) {
        isLoadingDraft = true
        isPopulatingHeaders = true
        Task {
            do {
                if let draft = try await apiManager.fetchDraftByMessageId(msgId: email.msgId, accountId: email.accountId) {
                    draftId = draft.id
                    if let message = draft.message, let payload = message.payload {
                        let headers = payload.headers ?? []
                        let to = headers.first { $0.name.lowercased() == "to" }?.value ?? ""
                        let cc = headers.first { $0.name.lowercased() == "cc" }?.value ?? ""
                        let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? ""

                        toField = to
                        ccField = cc
                        subjectField = subject
                        bodyText = extractPlainTextFromPayload(payload)
                    }
                }
            } catch {
                sendError = "Failed to load draft"
                logger.error("Draft load failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                isLoadingDraft = false
                isPopulatingHeaders = false
            }
        }
    }

    /// Extract plain text body from MIME payload for draft editing.
    private func extractPlainTextFromPayload(_ payload: GmailPayload) -> String {
        if let parts = payload.parts, !parts.isEmpty {
            for part in parts {
                let result = extractPlainTextFromPayload(part)
                if !result.isEmpty { return result }
            }
            return ""
        }
        let mime = payload.mimeType?.lowercased() ?? ""
        guard mime == "text/plain" else { return "" }
        guard let bodyData = payload.body?.data, !bodyData.isEmpty else { return "" }
        guard let decoded = RFC2822Builder.base64URLDecode(bodyData) else { return "" }
        return String(data: decoded, encoding: .utf8) ?? ""
    }

    private func fetchReplyHeaders(email: Email, includeAllRecipients: Bool) {
        isLoadingRecipients = true
        isPopulatingHeaders = true
        Task {
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
            // Defer flag reset to next run loop so SwiftUI .onChange handlers
            // see isPopulatingHeaders == true during the coalesced update
            DispatchQueue.main.async {
                isLoadingRecipients = false
                isPopulatingHeaders = false
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

    var hasContent: Bool {
        Self.hasNonEmptyContent(to: toField, cc: ccField, subject: subjectField, body: bodyText)
    }

    static func hasNonEmptyContent(to: String, cc: String, subject: String, body: String) -> Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty ||
        !cc.trimmingCharacters(in: .whitespaces).isEmpty ||
        !subject.trimmingCharacters(in: .whitespaces).isEmpty ||
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                addAttachment(from: url)
            }
        }
    }

    private func addAttachment(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let mimeType = mimeTypeForURL(url)
        let attachment = ComposeAttachment(filename: url.lastPathComponent, mimeType: mimeType, data: data)
        attachments.append(attachment)
        isDirty = true
    }

    private func addAttachmentFromData(_ data: Data, filename: String, mimeType: String) {
        // Generate unique name for screenshots
        var name = filename
        if filename == "screenshot.png" {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            name = "Screenshot \(formatter.string(from: Date())).png"
        }
        let attachment = ComposeAttachment(filename: name, mimeType: mimeType, data: data)
        attachments.append(attachment)
        isDirty = true
    }

    private func mimeTypeForURL(_ url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }

    private func saveDraftIfNeeded() {
        guard !hasSent else { return }
        // Don't create a new draft when editing an existing one
        guard composeType != .draft else { return }
        guard isDirty, hasContent else { return }
        guard let fromEmail = accountManager.accounts.first(where: { $0.id == selectedAccountId })?.email else { return }

        let (html, editorInlineImages) = editorState.htmlBodyWithInlineImages()
        let rfcAttachments = attachments.map { RFC2822Builder.Attachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        let rfcInlineImages = editorInlineImages.map { RFC2822Builder.InlineImage(cid: $0.cid, mimeType: $0.mimeType, data: $0.data) }
        Task {
            do {
                try await apiManager.saveDraft(
                    from: fromEmail,
                    to: toField,
                    cc: ccField.isEmpty ? nil : ccField,
                    subject: subjectField,
                    body: bodyText,
                    accountId: selectedAccountId,
                    inReplyTo: replyToEmail?.messageId ?? fetchedMessageId,
                    references: replyToEmail?.messageId ?? fetchedMessageId,
                    htmlBody: html.isEmpty ? nil : html,
                    attachments: rfcAttachments,
                    inlineImages: rfcInlineImages
                )
            } catch {
                logger.error("Draft save failed: \(error.localizedDescription)")
            }
        }
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

        let (html, editorInlineImages) = editorState.htmlBodyWithInlineImages()
        let rfcAttachments = attachments.map { RFC2822Builder.Attachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        let rfcInlineImages = editorInlineImages.map { RFC2822Builder.InlineImage(cid: $0.cid, mimeType: $0.mimeType, data: $0.data) }
        Task {
            do {
                if let draftId, composeType == .draft {
                    try await apiManager.sendDraft(draftId: draftId, accountId: selectedAccountId)
                } else {
                    try await apiManager.sendEmail(
                        from: fromEmail,
                        to: toField,
                        cc: ccField.isEmpty ? nil : ccField,
                        subject: subjectField,
                        body: bodyText,
                        accountId: selectedAccountId,
                        inReplyTo: replyToEmail?.messageId ?? fetchedMessageId,
                        references: replyToEmail?.messageId ?? fetchedMessageId,
                        htmlBody: html.isEmpty ? nil : html,
                        attachments: rfcAttachments,
                        inlineImages: rfcInlineImages
                    )
                }
                hasSent = true
                onDismiss?()
                Task { await apiManager.refreshAll() }
            } catch {
                sendError = error.localizedDescription
            }
            isSending = false
        }
    }
}

// MARK: - Rich text editor state

class ComposeEditorState: ObservableObject {
    weak var textView: NSTextView?
    @Published var isBold = false
    @Published var isItalic = false
    @Published var isUnderlined = false

    private let defaultFont = NSFont.systemFont(ofSize: 13)

    func updateState() {
        guard let textView else { return }
        let attrs = textView.selectedRange().length > 0
            ? textView.textStorage?.attributes(at: textView.selectedRange().location, effectiveRange: nil) ?? textView.typingAttributes
            : textView.typingAttributes
        if let font = attrs[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            isBold = traits.contains(.bold)
            isItalic = traits.contains(.italic)
        } else {
            isBold = false
            isItalic = false
        }
        isUnderlined = (attrs[.underlineStyle] as? Int ?? 0) != 0
    }

    func toggleBold() {
        toggleTrait(.bold, mask: .boldFontMask)
    }

    func toggleItalic() {
        toggleTrait(.italic, mask: .italicFontMask)
    }

    private func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits, mask: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let fm = NSFontManager.shared

        let toggle: (NSFont) -> NSFont = { font in
            if font.fontDescriptor.symbolicTraits.contains(trait) {
                return fm.convert(font, toNotHaveTrait: mask)
            } else {
                return fm.convert(font, toHaveTrait: mask)
            }
        }

        if range.length == 0 {
            var attrs = textView.typingAttributes
            let font = attrs[.font] as? NSFont ?? self.defaultFont
            attrs[.font] = toggle(font)
            attrs[.foregroundColor] = NSColor.labelColor
            textView.typingAttributes = attrs
        } else {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                let font = value as? NSFont ?? self.defaultFont
                storage.addAttribute(.font, value: toggle(font), range: r)
            }
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            storage.endEditing()
        }
        updateState()
    }

    func toggleUnderline() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()

        if range.length == 0 {
            var attrs = textView.typingAttributes
            let current = attrs[.underlineStyle] as? Int ?? 0
            attrs[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attrs
        } else {
            var hasUnderline = false
            storage.enumerateAttribute(.underlineStyle, in: range) { value, _, stop in
                if (value as? Int ?? 0) != 0 { hasUnderline = true; stop.pointee = true }
            }
            let newValue = hasUnderline ? 0 : NSUnderlineStyle.single.rawValue
            storage.beginEditing()
            storage.addAttribute(.underlineStyle, value: newValue, range: range)
            storage.endEditing()
        }
        updateState()
    }

    func toggleBulletList() {
        toggleListPrefix("•\t")
    }

    func toggleNumberedList() {
        guard let textView, let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let paraRange = string.paragraphRange(for: textView.selectedRange())
        let text = string.substring(with: paraRange)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        let hasNumbers = lines.allSatisfy { $0.range(of: "^\\d+\\.\\t", options: .regularExpression) != nil }

        storage.beginEditing()
        if hasNumbers {
            // Remove numbering
            let mutable = NSMutableString(string: text)
            let regex = try! NSRegularExpression(pattern: "^\\d+\\.\\t", options: .anchorsMatchLines)
            regex.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: "")
            storage.replaceCharacters(in: paraRange, with: mutable as String)
        } else {
            // Remove bullets if present, then add numbers
            var cleaned = text
            cleaned = cleaned.replacingOccurrences(of: "^•\\t", with: "", options: .regularExpression)
            let numberedLines = cleaned.components(separatedBy: "\n").enumerated().map { i, line in
                line.isEmpty ? line : "\(i + 1).\t\(line)"
            }
            storage.replaceCharacters(in: paraRange, with: numberedLines.joined(separator: "\n"))
        }
        storage.endEditing()
    }

    private func toggleListPrefix(_ prefix: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let paraRange = string.paragraphRange(for: textView.selectedRange())
        let text = string.substring(with: paraRange)
        let lines = text.components(separatedBy: "\n")

        let allHavePrefix = lines.filter({ !$0.isEmpty }).allSatisfy { $0.hasPrefix(prefix) }

        storage.beginEditing()
        if allHavePrefix {
            let stripped = lines.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
            storage.replaceCharacters(in: paraRange, with: stripped.joined(separator: "\n"))
        } else {
            // Remove numbers if present, then add bullets
            var cleaned = text
            cleaned = cleaned.replacingOccurrences(of: "^\\d+\\.\\t", with: "", options: .regularExpression)
            let prefixed = cleaned.components(separatedBy: "\n").map { $0.isEmpty ? $0 : "\(prefix)\($0)" }
            storage.replaceCharacters(in: paraRange, with: prefixed.joined(separator: "\n"))
        }
        storage.endEditing()
    }

    struct InlineImage {
        let cid: String
        let mimeType: String
        let data: Data
    }

    /// Extract inline images from text storage and return HTML with cid: references.
    func htmlBodyWithInlineImages() -> (html: String, inlineImages: [InlineImage]) {
        guard let textView, let storage = textView.textStorage else { return ("", []) }
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return ("", []) }

        // Find all NSTextAttachment images and collect their data
        var images: [InlineImage] = []
        var attachmentRanges: [(range: NSRange, cid: String)] = []

        storage.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var image: NSImage?
            if let cell = attachment.attachmentCell as? NSTextAttachmentCell {
                image = cell.image
            }
            guard let img = image else { return }

            guard let tiff = img.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

            let cid = "inline_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))@agmail"
            images.append(InlineImage(cid: cid, mimeType: "image/png", data: pngData))
            attachmentRanges.append((range: range, cid: cid))
        }

        if images.isEmpty {
            // No inline images — use standard HTML export
            guard let data = try? storage.data(
                from: fullRange,
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ]
            ) else { return ("", []) }
            return (String(data: data, encoding: .utf8) ?? "", [])
        }

        // Replace attachments with placeholder text, then export HTML, then swap placeholders for cid:
        let mutable = NSMutableAttributedString(attributedString: storage)
        // Process in reverse to preserve range positions
        for (range, cid) in attachmentRanges.reversed() {
            let placeholder = "%%CID_\(cid)%%"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]
            mutable.replaceCharacters(in: range, with: NSAttributedString(string: placeholder, attributes: attrs))
        }

        let exportRange = NSRange(location: 0, length: mutable.length)
        guard let htmlData = try? mutable.data(
            from: exportRange,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
        ) else { return ("", []) }

        var html = String(data: htmlData, encoding: .utf8) ?? ""
        // Replace placeholders with <img src="cid:...">
        for (_, cid) in attachmentRanges {
            let placeholder = "%%CID_\(cid)%%"
            html = html.replacingOccurrences(of: placeholder, with: "<img src=\"cid:\(cid)\" style=\"max-width:100%;\">")
        }

        return (html, images)
    }

    var htmlBody: String {
        htmlBodyWithInlineImages().html
    }

    var plainBody: String {
        textView?.string ?? ""
    }
}

// MARK: - Body text editor (NSTextView wrapper)

struct ComposeBodyEditor: NSViewRepresentable {
    @Binding var text: String
    var editorState: ComposeEditorState
    var cursorAtStart: Bool = false
    var onTab: (() -> Void)?
    var onBackTab: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    var onAttachImageData: ((Data, String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = TabAwareTextView()
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onTab = onTab
        textView.onBackTab = onBackTab
        textView.onAttachFiles = onAttachFiles
        textView.onAttachImageData = onAttachImageData
        textView.editorState = editorState
        textView.string = text
        textView.registerForDraggedTypes([.fileURL])

        editorState.textView = textView

        scrollView.documentView = textView

        if cursorAtStart {
            DispatchQueue.main.async {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let safeRange = NSRange(
                location: min(selectedRange.location, text.utf16.count),
                length: 0
            )
            textView.setSelectedRange(safeRange)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeBodyEditor
        init(_ parent: ComposeBodyEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.editorState.updateState()
        }
    }
}

/// NSTextView subclass that intercepts Tab/Shift-Tab, handles auto-list,
/// drag-drop file attachments, and paste image from clipboard.
class TabAwareTextView: NSTextView {
    var onTab: (() -> Void)?
    var onBackTab: (() -> Void)?
    weak var editorState: ComposeEditorState?
    var onAttachFiles: (([URL]) -> Void)?
    var onAttachImageData: ((Data, String) -> Void)?

    // keyCode constants (layout-independent)
    private static let kVK_ANSI_B: UInt16 = 11
    private static let kVK_ANSI_I: UInt16 = 34
    private static let kVK_ANSI_U: UInt16 = 32
    private static let kVK_ANSI_V: UInt16 = 9

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case Self.kVK_ANSI_B:
                editorState?.toggleBold()
                return
            case Self.kVK_ANSI_I:
                editorState?.toggleItalic()
                return
            case Self.kVK_ANSI_U:
                editorState?.toggleUnderline()
                return
            case Self.kVK_ANSI_V:
                if pasteImageFromClipboard() { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - Drag & Drop file attachments

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic"]

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !fileURLs.isEmpty {
            var nonImageURLs: [URL] = []
            for url in fileURLs {
                if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                    insertInlineImage(from: url)
                } else {
                    nonImageURLs.append(url)
                }
            }
            if !nonImageURLs.isEmpty {
                onAttachFiles?(nonImageURLs)
            }
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: - Paste image from clipboard

    /// Returns true if an image was pasted, false if pasteboard has no image.
    func pasteImageFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        let types = pb.types ?? []

        let hasString = types.contains(.string) || types.contains(.rtf) || types.contains(.html)
        let hasImage = types.contains(.tiff) || types.contains(.png)
            || types.contains(NSPasteboard.PasteboardType("public.jpeg"))

        if hasImage && !hasString, let image = NSImage(pasteboard: pb) {
            insertInlineImage(image)
            return true
        }

        // File URLs that are images (e.g., copied from Finder)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let imageURLs = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            if !imageURLs.isEmpty && !hasString {
                for url in imageURLs {
                    insertInlineImage(from: url)
                }
                return true
            }
        }

        return false
    }

    // MARK: - Inline image insertion

    private func insertInlineImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            onAttachFiles?([url])
            return
        }
        insertInlineImage(image)
    }

    private func insertInlineImage(_ image: NSImage) {
        let maxWidth: CGFloat = min(textContainer?.containerSize.width ?? 500, 600) - 20
        let imageSize = image.size
        let scale = imageSize.width > maxWidth ? maxWidth / imageSize.width : 1.0
        let displaySize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)

        let attachment = NSTextAttachment()
        let cell = NSTextAttachmentCell(imageCell: image)
        cell.image?.size = displaySize
        attachment.attachmentCell = cell

        // Save typing attributes before insertion
        let savedAttrs = typingAttributes

        let attrStr = NSAttributedString(attachment: attachment)
        let location = selectedRange().location
        textStorage?.insert(attrStr, at: location)
        setSelectedRange(NSRange(location: location + 1, length: 0))

        // Restore typing attributes so text after image keeps correct color/font
        typingAttributes = savedAttrs

        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
    }

    override func insertTab(_ sender: Any?) {
        if let onTab {
            onTab()
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if let onBackTab {
            onBackTab()
        } else {
            super.insertBacktab(sender)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let cursorLoc = selectedRange().location
        let nsString = (string as NSString)
        let lineRange = nsString.lineRange(for: NSRange(location: cursorLoc, length: 0))
        let line = nsString.substring(with: NSRange(location: lineRange.location, length: cursorLoc - lineRange.location))

        // Continue numbered list: "1. text" → next line "2. "
        if let match = line.range(of: "^(\\d+)\\. ", options: .regularExpression) {
            let numStr = line[match].components(separatedBy: ".").first ?? "0"
            if let num = Int(numStr) {
                // Empty list item (just "N. ") → remove it and stop the list
                let afterPrefix = String(line[match.upperBound...])
                if afterPrefix.trimmingCharacters(in: .whitespaces).isEmpty {
                    let deleteRange = NSRange(location: lineRange.location, length: cursorLoc - lineRange.location)
                    insertText("", replacementRange: deleteRange)
                    return
                }
                super.insertNewline(sender)
                insertText("\(num + 1). ", replacementRange: selectedRange())
                return
            }
        }

        // Continue bullet list: "- text" or "• text" → next line with same prefix
        if let match = line.range(of: "^([-•]) ", options: .regularExpression) {
            let prefix = String(line[match])
            let afterPrefix = String(line[match.upperBound...])
            if afterPrefix.trimmingCharacters(in: .whitespaces).isEmpty {
                let deleteRange = NSRange(location: lineRange.location, length: cursorLoc - lineRange.location)
                insertText("", replacementRange: deleteRange)
                return
            }
            super.insertNewline(sender)
            insertText(prefix, replacementRange: selectedRange())
            return
        }

        super.insertNewline(sender)
    }
}

// MARK: - From picker (NSPopUpButton wrapper)

/// Keyboard-accessible NSPopUpButton that participates in Tab loop.
struct FromPickerView: NSViewRepresentable {
    let accounts: [Account]
    @Binding var selectedAccountId: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .texturedRounded
        popup.font = .systemFont(ofSize: 12)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.selectionChanged(_:))
        popup.refusesFirstResponder = false
        updateItems(popup)
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        updateItems(popup)
    }

    private func updateItems(_ popup: NSPopUpButton) {
        let currentTitles = (0..<popup.numberOfItems).map { popup.item(at: $0)?.title ?? "" }
        let newTitles = accounts.map(\.email)
        if currentTitles != newTitles {
            popup.removeAllItems()
            for account in accounts {
                popup.addItem(withTitle: account.email)
                popup.lastItem?.representedObject = account.id
            }
        }
        if let idx = accounts.firstIndex(where: { $0.id == selectedAccountId }) {
            popup.selectItem(at: idx)
        }
    }

    class Coordinator: NSObject {
        var parent: FromPickerView
        init(_ parent: FromPickerView) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            if let id = sender.selectedItem?.representedObject as? String {
                parent.selectedAccountId = id
            }
        }
    }
}
