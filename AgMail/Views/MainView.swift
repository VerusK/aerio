import SwiftUI
import os.log

private let logger = Logger(subsystem: "AgMail", category: "MainView")

// MARK: - SplitView configurator

/// Manually saves and restores NSSplitView divider positions via UserDefaults.
struct SplitViewConfigurator: NSViewRepresentable {
    let autosaveName: String
    static let maxRetries = 20
    static let retryInterval: TimeInterval = 0.1

    private var defaultsKey: String {
        "AgMailSplit_\(autosaveName)"
    }

    class Coordinator {
        var splitView: NSSplitView?
        var observer: NSObjectProtocol?
        var saveTimer: Timer?
        var defaultsKey: String = ""
        private var lastPositions: [Double] = []

        deinit {
            if let obs = observer { NotificationCenter.default.removeObserver(obs) }
            saveTimer?.invalidate()
        }

        func saveDividerPositions() {
            guard let splitView else { return }
            let count = splitView.arrangedSubviews.isEmpty
                ? splitView.subviews.count
                : splitView.arrangedSubviews.count
            // Use NSSplitView API: number of dividers = arrangedSubviews - 1
            let dividerCount = max(0, count - 1)
            guard dividerCount > 0 else { return }
            // Collect divider positions from panel frames
            // Panels are the arranged subviews; divider i sits between panel i and i+1
            let panels = splitView.arrangedSubviews.isEmpty ? Array(splitView.subviews) : splitView.arrangedSubviews
            var positions: [Double] = []
            for i in 0..<dividerCount {
                let panelFrame = panels[i].frame
                // For vertical split (horizontal dividers): position = maxX of panel
                if splitView.isVertical {
                    positions.append(Double(panelFrame.maxX))
                } else {
                    positions.append(Double(panelFrame.maxY))
                }
            }
            guard positions != lastPositions else { return }
            lastPositions = positions
            UserDefaults.standard.set(positions, forKey: defaultsKey)
            logger.debug("SplitViewConfigurator: saved divider positions \(positions)")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.defaultsKey = defaultsKey
        findAndConfigure(from: view, coordinator: context.coordinator, attempt: 0)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func findAndConfigure(from view: NSView, coordinator: Coordinator, attempt: Int) {
        DispatchQueue.main.async {
            if let splitView = Self.findSplitViewUp(from: view) {
                coordinator.splitView = splitView
                // Listen for both resize and willResize notifications
                coordinator.observer = NotificationCenter.default.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification,
                    object: splitView,
                    queue: .main
                ) { _ in
                    coordinator.saveDividerPositions()
                }
                // Also observe window resize which triggers split view layout
                if let window = splitView.window {
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification,
                        object: window,
                        queue: .main
                    ) { _ in
                        coordinator.saveDividerPositions()
                    }
                }
                // Save periodically via a timer to catch drag changes
                coordinator.saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                    DispatchQueue.main.async {
                        coordinator.saveDividerPositions()
                    }
                }
                logger.debug("SplitViewConfigurator: configured on attempt \(attempt)")
                // Hide window, restore positions, then show — avoids visible jump
                let hasSaved = UserDefaults.standard.array(forKey: self.defaultsKey) != nil
                if hasSaved {
                    splitView.window?.alphaValue = 0
                }
                // Restore immediately, then once more after layout settles
                self.restoreDividerPositions(splitView)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.restoreDividerPositions(splitView)
                    splitView.window?.alphaValue = 1
                }
            } else if attempt < Self.maxRetries {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) {
                    self.findAndConfigure(from: view, coordinator: coordinator, attempt: attempt + 1)
                }
            } else {
                logger.warning("SplitViewConfigurator: NSSplitView not found after \(Self.maxRetries) retries")
            }
        }
    }

    private func restoreDividerPositions(_ splitView: NSSplitView) {
        guard let saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Double],
              !saved.isEmpty else {
            logger.debug("SplitViewConfigurator: no saved positions")
            return
        }
        for (i, position) in saved.enumerated() {
            splitView.setPosition(CGFloat(position), ofDividerAt: i)
            logger.debug("SplitViewConfigurator: setPosition(\(position), ofDividerAt: \(i))")
        }
        logger.debug("SplitViewConfigurator: restore complete")
    }

    static func findSplitViewUp(from view: NSView) -> NSSplitView? {
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
    var contactsCache: ContactsCache?
    var notificationManager: NotificationManager?
    @State private var selectedAccountId: String?
    @State private var selectedFolder: Folder = .inbox
    @State private var selectedEmailId: String?
    @State private var showingCompose = false
    @State private var composeType: ComposeType = .new
    @State private var composeTargetMsgId: String?
    @State private var isRefreshing = false
    @State private var showingSearch = false
    @State private var isNavigatingProgrammatically = false
    @StateObject private var searchViewModel: SearchViewModel

    init(accountManager: AccountManager, unifiedMailbox: UnifiedMailbox, apiManager: GmailAPIManager, oauthManager: OAuthManager, contactsCache: ContactsCache? = nil, notificationManager: NotificationManager? = nil) {
        self.accountManager = accountManager
        self.unifiedMailbox = unifiedMailbox
        self.apiManager = apiManager
        self.oauthManager = oauthManager
        self.contactsCache = contactsCache
        self.notificationManager = notificationManager
        self._searchViewModel = StateObject(wrappedValue: SearchViewModel(apiManager: apiManager))
    }

    private var currentEmails: [Email] {
        unifiedMailbox.emails(for: selectedFolder, accountId: selectedAccountId)
    }

    var body: some View {
        HSplitView {
            UnifiedSidebar(
                accountManager: accountManager,
                unifiedMailbox: unifiedMailbox,
                oauthManager: oauthManager,
                selectedFolder: $selectedFolder,
                selectedAccountId: $selectedAccountId
            )
            .background(SplitViewConfigurator(autosaveName: "AgMailMainSplit"))

            MessageList(
                unifiedMailbox: unifiedMailbox,
                accountManager: accountManager,
                selectedEmailId: $selectedEmailId,
                selectedFolder: selectedFolder,
                selectedAccountId: selectedAccountId,
                onReply: { email in triggerCompose(.reply, msgId: email.msgId) },
                onReplyAll: { email in triggerCompose(.replyAll, msgId: email.msgId) },
                onForward: { email in triggerCompose(.forward, msgId: email.msgId) },
                onArchive: { email in executeActionOnEmail(email, action: .archive) },
                onDelete: { email in executeActionOnEmail(email, action: .delete) },
                onSpam: { email in executeActionOnEmail(email, action: .spam) },
                onLoadMore: { loadMoreEmails() },
                hasMoreEmails: unifiedMailbox.hasMoreEmails(folder: selectedFolder, accountId: selectedAccountId)
            )
            .overlay {
                messageListOverlay
            }
            .frame(minWidth: 250, idealWidth: 350)

            messageDetailPanel
                .frame(minWidth: 300, idealWidth: 500)
        }
        .background(KeyEventInterceptor(handler: { event in
            handleKeyEvent(event)
        }))
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
            if !isNavigatingProgrammatically { selectedEmailId = nil }
        }
        .onChange(of: selectedEmailId) { _, newId in
            if let newId, let email = findEmail(by: newId), !email.isRead {
                apiManager.markAsRead(emailId: email.id, accountId: email.accountId)
            }
        }
        .onChange(of: selectedFolder) { _, newValue in
            unifiedMailbox.selectedFolder = newValue
            if !isNavigatingProgrammatically { selectedEmailId = nil }
            Task { await apiManager.navigateAllToFolder(newValue) }
        }
        .onAppear {
            apiManager.startPollingAll()
            notificationManager?.onNotificationClick = { [self] emailId, accountId in
                navigateToEmail(msgId: emailId, accountId: accountId)
            }
        }
        .onDisappear {
            apiManager.stopPollingAll()
        }
        .sheet(isPresented: $showingCompose) {
            composeSheet
        }
        .overlay {
            if showingSearch {
                SearchOverlay(
                    isPresented: $showingSearch,
                    searchViewModel: searchViewModel,
                    accountManager: accountManager,
                    onSelectEmail: { email in
                        // Inject search result into emailsByAccount so findEmail can locate it
                        let accountId = email.accountId
                        var emails = apiManager.emailsByAccount[accountId] ?? []
                        if !emails.contains(where: { $0.id == email.id }) {
                            emails.append(email)
                            apiManager.emailsByAccount[accountId] = emails
                        }
                        isNavigatingProgrammatically = true
                        selectedFolder = email.folder
                        selectedAccountId = email.accountId
                        selectedEmailId = email.id
                        DispatchQueue.main.async { isNavigatingProgrammatically = false }
                    }
                )
            }
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
                    folder: selectedFolder,
                    onReply: { triggerCompose(.reply, msgId: email.msgId) },
                    onReplyAll: { triggerCompose(.replyAll, msgId: email.msgId) },
                    onForward: { triggerCompose(.forward, msgId: email.msgId) },
                    onArchive: { executeActionOnEmail(email, action: .archive) },
                    onDelete: { executeActionOnEmail(email, action: .delete) },
                    onSpam: { executeActionOnEmail(email, action: .spam) }
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
            contactsCache: contactsCache,
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

    private func navigateToEmail(msgId: String, accountId: String) {
        NSApp.activate(ignoringOtherApps: true)
        // Search across all accounts/folders for the email
        if let emails = apiManager.emailsByAccount[accountId],
           let email = emails.first(where: { $0.msgId == msgId }) {
            isNavigatingProgrammatically = true
            selectedFolder = email.folder
            selectedAccountId = email.accountId
            selectedEmailId = email.id
            DispatchQueue.main.async { isNavigatingProgrammatically = false }
        } else {
            // Email not yet in memory — switch to inbox so next poll will show it
            selectedFolder = .inbox
            selectedAccountId = accountId
        }
    }

    /// Returns true when the user is typing in a text field (TextField, TextEditor, NSTextField).
    private var isTextFieldFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
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
            triggerCompose(.new, msgId: "")
            composeTargetMsgId = nil
        case .reply:
            if let msgId = selectedEmailMsgId {
                triggerCompose(.reply, msgId: msgId)
            }
        case .replyAll:
            if let msgId = selectedEmailMsgId {
                triggerCompose(.replyAll, msgId: msgId)
            }
        case .forward:
            if let msgId = selectedEmailMsgId {
                triggerCompose(.forward, msgId: msgId)
            }
        case .archiveMessage:
            if selectedFolder == .inbox { executeActionOnSelected(.archive) }
        case .deleteMessage:
            executeActionOnSelected(.delete)
        case .spamMessage:
            executeActionOnSelected(.spam)
        case .refresh:
            performRefresh()
        case .openSettings:
            KeyboardShortcuts.openSettings()
        case .search:
            showingSearch.toggle()
        case .sendMessage:
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

    private func triggerCompose(_ type: ComposeType, msgId: String) {
        composeType = type
        composeTargetMsgId = msgId
        showingCompose = true
    }

    enum EmailAction: CustomStringConvertible {
        case archive, delete, spam
        var description: String {
            switch self {
            case .archive: return "archive"
            case .delete: return "delete"
            case .spam: return "spam"
            }
        }
    }

    private func executeActionOnSelected(_ action: EmailAction) {
        guard let selectedEmailId,
              let email = findEmail(by: selectedEmailId) else { return }
        executeActionOnEmail(email, action: action)
    }

    private func executeActionOnEmail(_ email: Email, action: EmailAction) {
        let accountId = email.accountId
        let msgId = email.msgId
        let folder = email.folder
        Task {
            do {
                switch action {
                case .archive:
                    try await apiManager.archiveEmail(msgId: msgId, accountId: accountId, folder: folder)
                case .delete:
                    try await apiManager.deleteEmail(msgId: msgId, accountId: accountId, folder: folder)
                case .spam:
                    try await apiManager.spamEmail(msgId: msgId, accountId: accountId, folder: folder)
                }
                self.selectedEmailId = nil
            } catch {
                logger.error("Action '\(action)' failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadMoreEmails() {
        let folder = selectedFolder
        Task {
            if let accountId = selectedAccountId {
                await apiManager.fetchMoreEmails(accountId: accountId, folder: folder)
            } else {
                // Load more for all accounts that have more pages
                await withTaskGroup(of: Void.self) { group in
                    for accountId in apiManager.clients.keys {
                        if apiManager.pageTokens[accountId]?[folder] != nil {
                            group.addTask { @MainActor in
                                await self.apiManager.fetchMoreEmails(accountId: accountId, folder: folder)
                            }
                        }
                    }
                }
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
