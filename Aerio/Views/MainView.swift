import SwiftUI
import WebKit
import os.log

private let logger = Logger(subsystem: "Aerio", category: "MainView")

// MARK: - SplitView configurator

/// Manually saves and restores NSSplitView divider positions via UserDefaults.
struct SplitViewConfigurator: NSViewRepresentable {
    let autosaveName: String
    static let maxRetries = 20
    static let retryInterval: TimeInterval = 0.1

    private var defaultsKey: String {
        "AerioSplit_\(autosaveName)"
    }

    class Coordinator {
        var splitView: NSSplitView?
        var observer: NSObjectProtocol?
        var windowObserver: NSObjectProtocol?
        var defaultsKey: String = ""
        private var lastPositions: [Double] = []

        deinit {
            if let obs = observer { NotificationCenter.default.removeObserver(obs) }
            if let obs = windowObserver { NotificationCenter.default.removeObserver(obs) }
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
                coordinator.observer = NotificationCenter.default.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification,
                    object: splitView,
                    queue: .main
                ) { [weak coordinator] _ in
                    coordinator?.saveDividerPositions()
                }
                // Save divider positions on window close
                if let window = splitView.window {
                    coordinator.windowObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification,
                        object: window,
                        queue: .main
                    ) { [weak coordinator] _ in
                        coordinator?.saveDividerPositions()
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
    @State private var keyMonitor = KeyEventMonitor()
    @State private var focusedPanel: FocusedPanel = .messageList
    @State private var detailScrollHandler: ((Int) -> Void)?
    @State private var expandedFolders: Set<Folder> = []

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
                selectedAccountId: $selectedAccountId,
                expandedFolders: $expandedFolders,
                isFocused: focusedPanel == .sidebar,
                isRefreshing: isRefreshing,
                onRefresh: { performRefresh() }
            )
            .background(SplitViewConfigurator(autosaveName: "AerioMainSplit"))

            VStack(spacing: 0) {
                Color.accentColor.opacity(focusedPanel == .messageList ? 1 : 0).frame(height: 2)
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
                    onMoveToInbox: { email in executeActionOnEmail(email, action: .moveToInbox) },
                    onLoadMore: { loadMoreEmails() },
                    hasMoreEmails: unifiedMailbox.hasMoreEmails(folder: selectedFolder, accountId: selectedAccountId)
                )
                .overlay {
                    messageListOverlay
                }
            }
            .frame(minWidth: 250, idealWidth: 350)

            messageDetailPanel
                .frame(minWidth: 300, idealWidth: 500)
        }
        .frame(minWidth: 900, minHeight: 600)
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
            keyMonitor.install { event in handleKeyEvent(event) }
            let interval = UserDefaults.standard.double(forKey: AppState.pollIntervalKey)
            apiManager.startPollingAll(interval: interval > 0 ? interval : AppState.defaultPollInterval)
            notificationManager?.onNotificationClick = { [self] emailId, accountId in
                navigateToEmail(msgId: emailId, accountId: accountId)
            }
        }
        .onDisappear {
            keyMonitor.uninstall()
            apiManager.stopPollingAll()
        }
        .onChange(of: showingCompose) { _, show in
            if show {
                ComposeWindowManager.shared.open(
                    accountManager: accountManager,
                    apiManager: apiManager,
                    contactsCache: contactsCache,
                    composeType: composeType,
                    replyToEmail: composeTargetMsgId.flatMap { findEmail(byMsgId: $0) },
                    preselectedAccountId: composeAccount?.id
                )
                showingCompose = false
            }
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
            .background(.background)
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
                .background(.background)
            } else if apiManager.hasLoadedAny {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No emails in \(selectedFolder.displayName)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            } else {
                ProgressView("Loading emails…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
    }

    // MARK: - Detail panel

    @ViewBuilder
    private var messageDetailPanel: some View {
        VStack(spacing: 0) {
            Color.accentColor.opacity(focusedPanel == .detail ? 1 : 0).frame(height: 2)
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
                        onSpam: { executeActionOnEmail(email, action: .spam) },
                        onMoveToInbox: { executeActionOnEmail(email, action: .moveToInbox) },
                        onEditDraft: { openDraft(email) },
                        onRegisterScroll: { handler in detailScrollHandler = handler }
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
    /// Excludes WKWebView's internal NSTextView — that's a read-only email display, not a text input.
    private var isTextFieldFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let view = responder as? NSView, Self.isInsideWebView(view) { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private static func isInsideWebView(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is WKWebView { return true }
            current = v.superview
        }
        return false
    }

    /// Handle an NSEvent keyDown. Returns `true` if the event was consumed.
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Only handle keys when the main window is key (not compose windows)
        guard event.window === NSApp.mainWindow else { return false }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isBareKey = flags.isEmpty

        // Skip bare keys when typing in a text field.
        // Cmd/Option shortcuts should always work.
        if isTextFieldFocused && !flags.contains(.command) && !flags.contains(.option) {
            keyMonitor.cancelGoTo()
            return false
        }

        // Go-To state machine: waiting for second key
        if keyMonitor.pendingGoTo {
            keyMonitor.cancelGoTo()
            if isBareKey, let goToAction = KeyboardShortcuts.goToAction(for: event) {
                handleGoTo(goToAction)
                return true
            }
            // Invalid second key — fall through to normal handling
        }

        // Go-To prefix: bare G starts the sequence
        if isBareKey && KeyboardShortcuts.isGoToPrefix(for: event) {
            keyMonitor.beginGoTo()
            return true
        }

        guard let action = KeyboardShortcuts.action(for: event) else {
            return false
        }

        switch action {
        // Panel focus
        case .focusLeft, .escape:
            moveFocus(direction: .left)
        case .focusRight:
            moveFocus(direction: .right)
        case .toggleExpand:
            toggleSidebarExpand()
        // In-panel navigation
        case .navigateUp:
            handleNavigate(offset: -1)
        case .navigateDown:
            handleNavigate(offset: 1)
        // Alt navigation (Opt+↑/↓ always navigates message list)
        case .nextMessageAlt:
            selectAdjacentEmail(offset: 1)
        case .previousMessageAlt:
            selectAdjacentEmail(offset: -1)
        // Open message / edit draft
        case .openMessage:
            openSelectedDraftOrFocusDetail()
        // Compose
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
        // Message actions
        case .archiveMessage:
            if selectedFolder == .inbox { executeActionOnSelected(.archive) }
        case .moveToInbox:
            if selectedFolder != .inbox { executeActionOnSelected(.moveToInbox) }
        case .deleteMessage:
            executeActionOnSelected(.delete)
        case .spamMessage:
            executeActionOnSelected(.spam)
        // Other
        case .refresh:
            performRefresh()
        case .openSettings:
            return false // let macOS handle Cmd+, natively via Settings scene
        case .search:
            showingSearch.toggle()
        case .sendMessage:
            return false
        default:
            return false
        }
        return true
    }

    // MARK: - Panel focus navigation

    private enum FocusDirection { case left, right }

    private func moveFocus(direction: FocusDirection) {
        switch direction {
        case .left:
            switch focusedPanel {
            case .detail: focusedPanel = .messageList
            case .messageList: focusedPanel = .sidebar
            case .sidebar: break
            }
        case .right:
            switch focusedPanel {
            case .sidebar: focusedPanel = .messageList
            case .messageList: focusedPanel = .detail
            case .detail: break
            }
        }
    }

    // MARK: - In-panel navigation

    private func handleNavigate(offset: Int) {
        switch focusedPanel {
        case .sidebar:
            navigateFolder(offset: offset)
        case .messageList:
            selectAdjacentEmail(offset: offset)
        case .detail:
            scrollDetail(offset: offset)
        }
    }

    /// Sidebar item for flat-list navigation
    private enum SidebarItem: Equatable {
        case folder(Folder)
        case account(Folder, String) // folder + accountId
    }

    /// Build flat list of visible sidebar items based on expanded state
    private var visibleSidebarItems: [SidebarItem] {
        var items: [SidebarItem] = []
        let hasMultipleAccounts = accountManager.accounts.count > 1
        for folder in Folder.allCases {
            items.append(.folder(folder))
            if hasMultipleAccounts && expandedFolders.contains(folder) {
                for account in accountManager.accounts {
                    items.append(.account(folder, account.id))
                }
            }
        }
        return items
    }

    /// Current sidebar cursor position
    private var currentSidebarItem: SidebarItem {
        if let accountId = selectedAccountId {
            return .account(selectedFolder, accountId)
        }
        return .folder(selectedFolder)
    }

    private func navigateFolder(offset: Int) {
        let items = visibleSidebarItems
        guard let currentIndex = items.firstIndex(of: currentSidebarItem) else { return }
        let newIndex = min(max(currentIndex + offset, 0), items.count - 1)
        let newItem = items[newIndex]
        applySidebarItem(newItem)
    }

    private func applySidebarItem(_ item: SidebarItem) {
        switch item {
        case .folder(let folder):
            if selectedFolder != folder || selectedAccountId != nil {
                selectedFolder = folder
                selectedAccountId = nil
            }
        case .account(let folder, let accountId):
            selectedFolder = folder
            selectedAccountId = accountId
        }
    }

    private func toggleSidebarExpand() {
        guard focusedPanel == .sidebar else { return }
        guard accountManager.accounts.count > 1 else { return }
        if expandedFolders.contains(selectedFolder) {
            expandedFolders.remove(selectedFolder)
            // If we were on an account row, go back to folder
            selectedAccountId = nil
        } else {
            expandedFolders.insert(selectedFolder)
        }
    }

    private func scrollDetail(offset: Int) {
        detailScrollHandler?(offset)
    }

    // MARK: - Go-To folders

    private func handleGoTo(_ action: ShortcutAction) {
        let folder: Folder
        switch action {
        case .goToInbox:   folder = .inbox
        case .goToSent:    folder = .sent
        case .goToArchive: folder = .archive
        case .goToTrash:   folder = .trash
        case .goToDrafts:  folder = .drafts
        case .goToSpam:    folder = .spam
        default: return
        }
        selectedAccountId = nil
        selectedFolder = folder
        focusedPanel = .messageList
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

    private func openSelectedDraftOrFocusDetail() {
        guard let selectedEmailId, let email = findEmail(by: selectedEmailId) else { return }
        if selectedFolder == .drafts {
            openDraft(email)
        } else {
            focusedPanel = .detail
        }
    }

    private func openDraft(_ email: Email) {
        ComposeWindowManager.shared.open(
            accountManager: accountManager,
            apiManager: apiManager,
            contactsCache: contactsCache,
            composeType: .draft,
            replyToEmail: email,
            preselectedAccountId: email.accountId
        )
    }

    enum EmailAction: CustomStringConvertible {
        case archive, delete, spam, moveToInbox
        var description: String {
            switch self {
            case .archive: return "archive"
            case .delete: return "delete"
            case .spam: return "spam"
            case .moveToInbox: return "move to inbox"
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

        // Calculate next email to select before the action removes this one
        let emails = currentEmails
        let nextEmailId: String? = {
            guard let idx = emails.firstIndex(where: { $0.id == email.id }) else { return nil }
            if idx + 1 < emails.count {
                return emails[idx + 1].id
            } else if idx > 0 {
                return emails[idx - 1].id
            }
            return nil
        }()

        Task {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedEmailId = nextEmailId
            }
            do {
                switch action {
                case .archive:
                    try await apiManager.archiveEmail(msgId: msgId, accountId: accountId, folder: folder)
                case .delete:
                    try await apiManager.deleteEmail(msgId: msgId, accountId: accountId, folder: folder)
                case .spam:
                    try await apiManager.spamEmail(msgId: msgId, accountId: accountId, folder: folder)
                case .moveToInbox:
                    try await apiManager.moveToInbox(msgId: msgId, accountId: accountId, folder: folder)
                }
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
