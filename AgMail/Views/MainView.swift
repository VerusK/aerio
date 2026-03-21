import SwiftUI
import os.log

private let logger = Logger(subsystem: "AgMail", category: "MainView")

// MARK: - SplitView configurator

/// Finds the underlying NSSplitView and sets autosaveName so macOS persists divider positions.
struct SplitViewConfigurator: NSViewRepresentable {
    let autosaveName: String
    static let maxRetries = 3
    static let retryInterval: TimeInterval = 0.1

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureSplitView(from: view, attempt: 0)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configureSplitView(from view: NSView, attempt: Int) {
        DispatchQueue.main.async {
            if let splitView = Self.findSplitView(from: view) {
                splitView.autosaveName = self.autosaveName
                splitView.arrangesAllSubviews = false
                logger.debug("SplitViewConfigurator: configured on attempt \(attempt)")
            } else if attempt < Self.maxRetries {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) {
                    self.configureSplitView(from: view, attempt: attempt + 1)
                }
            } else {
                logger.warning("SplitViewConfigurator: NSSplitView not found after \(Self.maxRetries) retries")
            }
        }
    }

    static func findSplitView(from view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let v = current {
            if let split = v as? NSSplitView { return split }
            current = v.superview
        }
        return nil
    }
}

struct MainView: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var unifiedMailbox: UnifiedMailbox
    @ObservedObject var apiManager: GmailAPIManager
    let oauthManager: OAuthManager
    @State private var selectedAccountId: String?
    @State private var selectedFolder: Folder = .inbox
    @State private var selectedEmailId: String?
    @State private var showingCompose = false
    @State private var composeType: ComposeType = .new
    @State private var composeTargetMsgId: String?
    @State private var isRefreshing = false
    @State private var keyMonitor: Any?

    private var currentEmails: [Email] {
        unifiedMailbox.emails(for: selectedFolder, accountId: selectedAccountId)
    }

    var body: some View {
        HSplitView {
            AccountSidebar(
                accountManager: accountManager,
                unifiedMailbox: unifiedMailbox,
                oauthManager: oauthManager,
                apiManager: apiManager,
                selectedAccountId: $selectedAccountId
            )
            .frame(width: 56)

            FolderList(
                unifiedMailbox: unifiedMailbox,
                selectedFolder: $selectedFolder,
                selectedAccountId: selectedAccountId
            )
            .frame(minWidth: 120, idealWidth: 160, maxWidth: 220)

            MessageList(
                unifiedMailbox: unifiedMailbox,
                accountManager: accountManager,
                selectedEmailId: $selectedEmailId,
                selectedFolder: selectedFolder,
                selectedAccountId: selectedAccountId
            )
            .overlay {
                messageListOverlay
            }
            .frame(minWidth: 250, idealWidth: 350)

            messageDetailPanel
                .frame(minWidth: 300, idealWidth: 500)
        }
        .background(SplitViewConfigurator(autosaveName: "AgMailMainSplit"))
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button {
                        performRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh (⌘⇧E)")
                }
            }
        }
        .onChange(of: selectedAccountId) { _, newValue in
            unifiedMailbox.selectedAccountId = newValue
            selectedEmailId = nil
        }
        .onChange(of: selectedEmailId) { _, newId in
            if let newId, let email = findEmail(by: newId), !email.isRead {
                apiManager.markAsRead(emailId: email.id, accountId: email.accountId)
            }
        }
        .onChange(of: selectedFolder) { _, newValue in
            unifiedMailbox.selectedFolder = newValue
            selectedEmailId = nil
            Task { await apiManager.navigateAllToFolder(newValue) }
        }
        .onAppear {
            apiManager.startPollingAll()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            apiManager.stopPollingAll()
        }
        .sheet(isPresented: $showingCompose) {
            composeSheet
        }
    }

    // MARK: - Message list overlay

    @ViewBuilder
    private var messageListOverlay: some View {
        if accountManager.accounts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Add an account to get started")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if currentEmails.isEmpty {
            if apiManager.allClientsErrored {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("Failed to load emails")
                        .font(.headline)
                    ForEach(apiManager.clientErrors, id: \.self) { err in
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Retry") { performRefresh() }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apiManager.hasLoadedAny {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No emails in \(selectedFolder.displayName)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading emails…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Detail panel

    @ViewBuilder
    private var messageDetailPanel: some View {
        ZStack {
            if let selectedEmailId,
               let email = findEmail(by: selectedEmailId) {
                NativeMessageDetail(
                    email: email,
                    apiManager: apiManager,
                    folder: selectedFolder
                )
                .id(email.id)
            } else {
                VStack {
                    Text("Message Detail")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Select a message to view")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var composeSheet: some View {
        ComposeView(
            accountManager: accountManager,
            apiManager: apiManager,
            composeType: composeType,
            replyToEmail: composeTargetMsgId.flatMap { findEmail(byMsgId: $0) },
            preselectedAccountId: composeAccount?.id,
            onDismiss: { showingCompose = false }
        )
    }

    /// For reply/replyAll/forward, use the account that owns the selected email.
    /// For new compose or when no email is selected, fall back to selectedAccount.
    private var composeAccount: Account? {
        if composeType != .new,
           let selectedEmailId,
           let email = findEmail(by: selectedEmailId) {
            return accountManager.accounts.first { $0.id == email.accountId }
        }
        return selectedAccount
    }

    private var selectedAccount: Account? {
        if let selectedAccountId {
            return accountManager.accounts.first { $0.id == selectedAccountId }
        }
        return accountManager.accounts.first
    }

    private func findEmail(by id: String) -> Email? {
        currentEmails.first { $0.id == id }
    }

    private func findEmail(byMsgId msgId: String) -> Email? {
        currentEmails.first { $0.msgId == msgId }
    }

    /// Returns true when the user is typing in a text field (TextField, TextEditor, NSTextField).
    private var isTextFieldFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    // MARK: - Layout-independent keyboard shortcut monitor

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Handle an NSEvent keyDown. Returns `true` if the event was consumed.
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Skip single-key shortcuts when typing in a text field.
        // Cmd/Option shortcuts should always work.
        if isTextFieldFocused && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option) {
            return false
        }

        guard let action = KeyboardShortcuts.action(for: event) else {
            return false
        }

        switch action {
        case .nextMessage, .nextMessageAlt:
            selectAdjacentEmail(offset: 1)
        case .previousMessage, .previousMessageAlt:
            selectAdjacentEmail(offset: -1)
        case .compose:
            composeType = .new
            composeTargetMsgId = nil
            showingCompose = true
        case .reply:
            if let msgId = selectedEmailMsgId {
                composeType = .reply
                composeTargetMsgId = msgId
                showingCompose = true
            }
        case .replyAll:
            if let msgId = selectedEmailMsgId {
                composeType = .replyAll
                composeTargetMsgId = msgId
                showingCompose = true
            }
        case .forward:
            if let msgId = selectedEmailMsgId {
                composeType = .forward
                composeTargetMsgId = msgId
                showingCompose = true
            }
        case .archiveMessage:
            executeActionOnSelected("archive")
        case .deleteMessage:
            executeActionOnSelected("delete")
        case .spamMessage:
            executeActionOnSelected("spam")
        case .refresh:
            performRefresh()
        case .openSettings:
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .search, .sendMessage:
            // Not yet implemented
            return false
        case .selectAllAccounts:
            selectedAccountId = nil
        case _ where KeyboardShortcuts.isAccountSelection(action):
            if let index = KeyboardShortcuts.accountIndex(for: action),
               index < accountManager.accounts.count {
                selectedAccountId = accountManager.accounts[index].id
            }
        default:
            return false
        }
        return true
    }

    private var selectedEmailMsgId: String? {
        guard let selectedEmailId,
              let email = findEmail(by: selectedEmailId) else { return nil }
        return email.msgId
    }

    private func executeActionOnSelected(_ action: String) {
        guard let selectedEmailId,
              let email = findEmail(by: selectedEmailId) else { return }
        let accountId = email.accountId
        let msgId = email.msgId
        let folder = email.folder
        Task {
            do {
                switch action {
                case "archive":
                    try await apiManager.archiveEmail(msgId: msgId, accountId: accountId, folder: folder)
                case "delete":
                    try await apiManager.deleteEmail(msgId: msgId, accountId: accountId, folder: folder)
                case "spam":
                    try await apiManager.spamEmail(msgId: msgId, accountId: accountId, folder: folder)
                default:
                    break
                }
                self.selectedEmailId = nil
            } catch {
                logger.error("Action '\(action)' failed: \(error.localizedDescription)")
            }
        }
    }

    private func performRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await apiManager.refreshAll()
            isRefreshing = false
        }
    }

    private func selectAdjacentEmail(offset: Int) {
        let emails = currentEmails
        guard !emails.isEmpty else { return }

        if let currentId = selectedEmailId,
           let currentIndex = emails.firstIndex(where: { $0.id == currentId }) {
            let newIndex = min(max(currentIndex + offset, 0), emails.count - 1)
            selectedEmailId = emails[newIndex].id
        } else {
            selectedEmailId = emails.first?.id
        }
    }
}
