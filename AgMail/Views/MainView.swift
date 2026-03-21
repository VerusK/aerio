import SwiftUI
import os.log

private let logger = Logger(subsystem: "AgMail", category: "MainView")

struct MainView: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var unifiedMailbox: UnifiedMailbox
    @ObservedObject var webViewPool: WebViewPool
    @ObservedObject var scraperManager: GmailScraperManager
    @State private var selectedAccountId: String?
    @State private var selectedFolder: Folder = .inbox
    @State private var selectedEmailId: String?
    @State private var showingCompose = false
    @State private var composeType: ComposeType = .new
    @State private var composeTargetMsgId: String?

    private var currentEmails: [Email] {
        unifiedMailbox.emails(for: selectedFolder, accountId: selectedAccountId)
    }

    var body: some View {
        HSplitView {
            AccountSidebar(
                accountManager: accountManager,
                unifiedMailbox: unifiedMailbox,
                webViewPool: webViewPool,
                scraperManager: scraperManager,
                selectedAccountId: $selectedAccountId
            )

            FolderList(
                unifiedMailbox: unifiedMailbox,
                selectedFolder: $selectedFolder,
                selectedAccountId: selectedAccountId
            )

            MessageList(
                unifiedMailbox: unifiedMailbox,
                accountManager: accountManager,
                selectedEmailId: $selectedEmailId,
                selectedFolder: selectedFolder,
                selectedAccountId: selectedAccountId
            )

            messageDetailPanel
                .frame(minWidth: 300)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onKeyPress { press in
            handleKeyPress(press)
        }
        .onChange(of: selectedAccountId) { _, newValue in
            unifiedMailbox.selectedAccountId = newValue
            selectedEmailId = nil
        }
        .onChange(of: selectedFolder) { _, newValue in
            unifiedMailbox.selectedFolder = newValue
            scraperManager.navigateAllToFolder(newValue)
            selectedEmailId = nil
        }
        .onAppear {
            scraperManager.startPollingAll()
        }
        .sheet(isPresented: $showingCompose) {
            composeSheet
        }
    }

    @ViewBuilder
    private var messageDetailPanel: some View {
        if let selectedEmailId,
           let email = findEmail(by: selectedEmailId),
           let entry = webViewPool.entry(for: email.accountId) {
            MessageWebView(webView: entry.visibleWebView, msgId: email.msgId, folder: selectedFolder)
                .id(email.accountId)
        } else {
            VStack {
                Text("Message Detail")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Select a message to view")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var composeSheet: some View {
        if let account = composeAccount,
           let entry = webViewPool.entry(for: account.id),
           let url = ComposeService.composeURL(type: composeType, accountIndex: 0, msgId: composeTargetMsgId) {
            ComposeWebView(webView: entry.composeWebView, composeURL: url)
                .frame(width: 600, height: 500)
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

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let modifiers: EventModifiers = press.modifiers
        let key = press.key

        guard let action = KeyboardShortcuts.action(
            for: KeyEquivalent(key.character),
            modifiers: modifiers
        ) else {
            return .ignored
        }

        switch action {
        case .nextMessage:
            selectAdjacentEmail(offset: 1)
        case .previousMessage:
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
        case .search, .sendMessage:
            // Not yet implemented
            return .ignored
        case .selectAllAccounts:
            selectedAccountId = nil
        case _ where KeyboardShortcuts.isAccountSelection(action):
            if let index = KeyboardShortcuts.accountIndex(for: action),
               index < accountManager.accounts.count {
                selectedAccountId = accountManager.accounts[index].id
            }
        default:
            return .ignored
        }
        return .handled
    }

    private var selectedEmailMsgId: String? {
        guard let selectedEmailId,
              let email = findEmail(by: selectedEmailId) else { return nil }
        return email.msgId
    }

    private func executeActionOnSelected(_ action: String) {
        guard let selectedEmailId,
              let email = findEmail(by: selectedEmailId),
              let scraper = scraperManager.scraper(for: email.accountId) else { return }
        let accountId = email.accountId
        let emailId = email.id
        Task {
            do {
                try await scraper.executeAction(action, msgIds: [email.msgId])
                // Optimistically remove the email from the list and cache
                let allFolders = action == "delete" || action == "spam"
                scraperManager.removeEmail(id: emailId, accountId: accountId, msgId: email.msgId, allFolders: allFolders)
                self.selectedEmailId = nil
            } catch {
                logger.error("Action '\(action)' failed: \(error.localizedDescription)")
            }
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
