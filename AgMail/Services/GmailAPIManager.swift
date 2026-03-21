import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "AgMail", category: "GmailAPIManager")

@MainActor
final class GmailAPIManager: ObservableObject {
    @Published private(set) var clients: [String: GmailAPIClient] = [:]
    @Published var emailsByAccount: [String: [Email]] = [:]
    @Published var unreadCountsByAccount: [String: Int] = [:]
    @Published private(set) var isPolling = false
    @Published private(set) var clientStates: [String: ClientState] = [:]

    private let accountManager: AccountManager
    private let oauthManager: OAuthManager
    private var cancellables = Set<AnyCancellable>()
    private var clientCancellables: [String: AnyCancellable] = [:]
    private var currentFolder: Folder = .inbox
    private var currentPollInterval: TimeInterval = 45
    private var pollingTask: Task<Void, Never>?
    var historyIds: [String: String] = [:]
    var dataStore: EmailCache?
    private(set) var accountsWithCompletedFetch = Set<String>()

    // Factory closure for creating clients — allows test injection
    var clientFactory: ((String, OAuthManager) -> GmailAPIClient)?

    init(accountManager: AccountManager, oauthManager: OAuthManager, dataStore: EmailCache? = nil) {
        self.accountManager = accountManager
        self.oauthManager = oauthManager
        self.dataStore = dataStore
        if let dataStore {
            loadCachedEmails(from: dataStore)
        }
        observeAccounts()
    }

    private func loadCachedEmails(from dataStore: EmailCache) {
        for account in accountManager.accounts {
            let emails = dataStore.loadEmails(for: account.id)
            logger.debug("Cache: loaded \(emails.count) emails for account \(account.id)")
            if !emails.isEmpty {
                emailsByAccount[account.id] = emails
            }
        }
    }

    private func observeAccounts() {
        accountManager.$accounts
            .receive(on: RunLoop.main)
            .sink { [weak self] accounts in
                guard let self else { return }
                self.syncClients(with: accounts)
            }
            .store(in: &cancellables)
    }

    private func syncClients(with accounts: [Account]) {
        let currentIds = Set(clients.keys)
        let newIds = Set(accounts.map(\.id))
        logger.debug("syncClients: \(accounts.count) accounts, \(currentIds.count) existing clients")

        for id in currentIds.subtracting(newIds) {
            logger.debug("syncClients: removing client for \(id)")
            removeClient(for: id)
        }

        for account in accounts where !currentIds.contains(account.id) {
            logger.debug("syncClients: adding client for \(account.id)")
            addClient(for: account)
        }
    }

    // MARK: - Client Management

    func addClient(for account: Account) {
        guard clients[account.id] == nil else { return }

        let client: GmailAPIClient
        if let factory = clientFactory {
            client = factory(account.id, oauthManager)
        } else {
            client = GmailAPIClient(accountId: account.id, oauthManager: oauthManager)
        }

        clients[account.id] = client
        clientStates[account.id] = client.state

        clientCancellables[account.id] = client.$state
            .sink { [weak self] newState in
                self?.clientStates[account.id] = newState
            }

        if isPolling {
            logger.debug("[\(account.id)] already polling, fetching immediately")
            Task { await self.fetchEmails(for: account.id) }
        }
    }

    func removeClient(for accountId: String) {
        clients.removeValue(forKey: accountId)
        clientCancellables.removeValue(forKey: accountId)
        clientStates.removeValue(forKey: accountId)
        emailsByAccount.removeValue(forKey: accountId)
        unreadCountsByAccount.removeValue(forKey: accountId)
        historyIds.removeValue(forKey: accountId)
        accountsWithCompletedFetch.remove(accountId)
        try? KeychainHelper.deleteTokens(for: accountId)
        dataStore?.clearEmails(for: accountId)
    }

    // MARK: - Polling

    func startPollingAll(interval: TimeInterval = 45) {
        isPolling = true
        currentPollInterval = interval
        logger.info("startPollingAll: \(self.clients.count) clients, interval=\(interval)s")

        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let strongSelf = self else { return }
            // First poll is always a full fetch
            await strongSelf.fetchAllAccounts()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard let strongSelf = self else { return }
                // Subsequent polls use incremental sync
                await strongSelf.syncAllAccounts()
            }
        }
    }

    func stopPollingAll() {
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    func navigateAllToFolder(_ folder: Folder) async {
        currentFolder = folder
        historyIds.removeAll()
        accountsWithCompletedFetch.removeAll()
        await fetchAllAccounts()
    }

    func refreshAll() async {
        await fetchAllAccounts()
    }

    // MARK: - Fetching

    func syncAllAccounts() async {
        await withTaskGroup(of: Void.self) { group in
            for accountId in clients.keys {
                group.addTask { @MainActor in
                    await self.incrementalSync(for: accountId)
                }
            }
        }
    }

    func fetchAllAccounts() async {
        await withTaskGroup(of: Void.self) { group in
            for accountId in clients.keys {
                group.addTask { @MainActor in
                    await self.fetchEmails(for: accountId)
                }
            }
        }
    }

    func fetchEmails(for accountId: String) async {
        guard let client = clients[accountId] else { return }

        client.state = .syncing
        do {
            let folder = currentFolder

            // Paginate to collect message IDs (capped to avoid quota exhaustion)
            let maxMessages = 500
            var allMessageIds: [String] = []
            var pageToken: String?
            var listHistoryId: String?
            repeat {
                let listResponse: GmailMessageListResponse
                if folder.gmailLabelIds.isEmpty {
                    listResponse = try await client.listMessages(query: folder.gmailQuery, maxResults: 500, pageToken: pageToken)
                } else {
                    listResponse = try await client.listMessages(labelIds: folder.gmailLabelIds, maxResults: 500, pageToken: pageToken)
                }
                if let ids = listResponse.messages?.map(\.id) {
                    allMessageIds.append(contentsOf: ids)
                }
                if let hid = listResponse.historyId {
                    listHistoryId = hid
                }
                pageToken = listResponse.nextPageToken
            } while pageToken != nil && allMessageIds.count < maxMessages

            if allMessageIds.count > maxMessages {
                allMessageIds = Array(allMessageIds.prefix(maxMessages))
            }

            let messageIds = allMessageIds
            guard !messageIds.isEmpty else {
                emailsByAccount[accountId] = emailsByAccount[accountId]?.filter { $0.folder != folder } ?? []
                client.state = .idle
                accountsWithCompletedFetch.insert(accountId)
                dataStore?.replaceEmails(for: accountId, folder: folder, with: [])
                return
            }

            let messages = try await client.getMessages(ids: messageIds, format: "metadata", metadataHeaders: ["From", "Subject", "Date", "Message-ID"])
            let emails = messages.compactMap { convertGmailMessageToEmail($0, accountId: accountId, folder: folder) }

            // Save historyId for incremental sync — prefer list response (current mailbox head)
            if let listHistoryId {
                historyIds[accountId] = listHistoryId
            } else {
                let maxHistoryId = messages.compactMap(\.historyId).compactMap(UInt64.init).max()
                if let maxHistoryId {
                    historyIds[accountId] = String(maxHistoryId)
                }
            }

            var existing = emailsByAccount[accountId] ?? []
            existing.removeAll { $0.folder == folder }
            existing.append(contentsOf: emails)
            emailsByAccount[accountId] = existing

            // Update unread count
            await fetchUnreadCount(for: accountId, client: client)

            client.state = .idle
            accountsWithCompletedFetch.insert(accountId)
            dataStore?.replaceEmails(for: accountId, folder: folder, with: emails)
        } catch {
            logger.error("[\(accountId)] fetchEmails failed: \(error.localizedDescription)")
            client.state = .error(error.localizedDescription)
        }
    }

    func incrementalSync(for accountId: String) async {
        guard let client = clients[accountId],
              let startHistoryId = historyIds[accountId] else {
            // No historyId yet — do a full fetch
            await fetchEmails(for: accountId)
            return
        }

        client.state = .syncing
        do {
            // Paginate through all history records
            var allRecords: [GmailHistoryRecord] = []
            var pageToken: String?
            var latestHistoryId: String?

            repeat {
                let historyResponse = try await client.listHistory(startHistoryId: startHistoryId, pageToken: pageToken)
                if let newHistoryId = historyResponse.historyId {
                    latestHistoryId = newHistoryId
                }
                if let records = historyResponse.history {
                    allRecords.append(contentsOf: records)
                }
                pageToken = historyResponse.nextPageToken
            } while pageToken != nil

            // Update historyId to latest
            if let latestHistoryId {
                historyIds[accountId] = latestHistoryId
            }

            guard !allRecords.isEmpty else {
                // No changes since last sync
                client.state = .idle
                return
            }

            var currentEmails = emailsByAccount[accountId] ?? []

            // Collect IDs of messages to fetch (added or label-changed)
            var messageIdsToFetch = Set<String>()
            var messageIdsToRemove = Set<String>()

            for record in allRecords {
                if let added = record.messagesAdded {
                    for item in added {
                        messageIdsToFetch.insert(item.message.id)
                    }
                }

                if let deleted = record.messagesDeleted {
                    for item in deleted {
                        messageIdsToRemove.insert(item.message.id)
                    }
                }

                if let labelsAdded = record.labelsAdded {
                    for item in labelsAdded {
                        messageIdsToFetch.insert(item.message.id)
                    }
                }

                if let labelsRemoved = record.labelsRemoved {
                    for item in labelsRemoved {
                        messageIdsToFetch.insert(item.message.id)
                    }
                }
            }

            // Remove deleted messages
            if !messageIdsToRemove.isEmpty {
                currentEmails.removeAll { messageIdsToRemove.contains($0.msgId) }
            }

            // Remove messages that will be re-fetched (they may have changed)
            messageIdsToFetch.subtract(messageIdsToRemove)
            if !messageIdsToFetch.isEmpty {
                currentEmails.removeAll { messageIdsToFetch.contains($0.msgId) }

                // Fetch updated messages
                let messages = try await client.getMessages(
                    ids: Array(messageIdsToFetch),
                    format: "metadata",
                    metadataHeaders: ["From", "Subject", "Date", "Message-ID"]
                )

                // Update historyId from fetched messages
                let maxHistoryId = messages.compactMap(\.historyId).compactMap(UInt64.init).max()
                if let maxHistoryId, let current = UInt64(historyIds[accountId] ?? "0"), maxHistoryId > current {
                    historyIds[accountId] = String(maxHistoryId)
                }

                // Derive folder from each message's labels instead of assuming currentFolder
                let newEmails = messages.compactMap { msg -> Email? in
                    let labelIds = msg.labelIds ?? []
                    let folder = Folder.allCases.first { $0.matchesLabels(labelIds) } ?? currentFolder
                    return convertGmailMessageToEmail(msg, accountId: accountId, folder: folder)
                }
                currentEmails.append(contentsOf: newEmails)
            }

            // Track which folders had emails before the sync
            let foldersBefore = Set((emailsByAccount[accountId] ?? []).map(\.folder))

            emailsByAccount[accountId] = currentEmails
            await fetchUnreadCount(for: accountId, client: client)
            client.state = .idle

            // Persist all folders that currently have emails OR previously had emails
            let foldersAfter = Set(currentEmails.map(\.folder))
            let allAffectedFolders = foldersBefore.union(foldersAfter)
            for folder in allAffectedFolders {
                dataStore?.replaceEmails(for: accountId, folder: folder, with: currentEmails.filter { $0.folder == folder })
            }
        } catch let apiError as GmailAPIError {
            switch apiError {
            case .historyExpired:
                // 410 Gone — historyId expired, fall back to full fetch
                logger.warning("[\(accountId)] history expired, falling back to full fetch")
                historyIds.removeValue(forKey: accountId)
                await fetchEmails(for: accountId)
            default:
                logger.error("[\(accountId)] incrementalSync failed: \(apiError.localizedDescription)")
                client.state = .error(apiError.localizedDescription)
            }
        } catch {
            logger.error("[\(accountId)] incrementalSync failed: \(error.localizedDescription)")
            client.state = .error(error.localizedDescription)
        }
    }

    func fetchMessageContent(msgId: String, accountId: String) async throws -> GmailMessage {
        guard let client = clients[accountId] else {
            throw GmailAPIError.unauthorized
        }
        return try await client.getMessage(id: msgId, format: "full")
    }

    private func fetchUnreadCount(for accountId: String, client: GmailAPIClient) async {
        do {
            let label = try await client.getLabel(id: GmailLabelId.inbox)
            unreadCountsByAccount[accountId] = label.messagesUnread ?? 0
        } catch {
            logger.warning("[\(accountId)] failed to fetch unread count: \(error.localizedDescription)")
        }
    }

    // MARK: - Email Actions

    func markAsRead(emailId: String, accountId: String) {
        guard var emails = emailsByAccount[accountId],
              let index = emails.firstIndex(where: { $0.id == emailId }) else { return }
        guard !emails[index].isRead else { return }

        let msgId = emails[index].msgId
        guard !msgId.isEmpty else { return }

        // Optimistic update: mark all folder copies as read
        var updatedEmails: [Email] = []
        var hadUnreadInbox = false
        for i in emails.indices where emails[i].msgId == msgId && !emails[i].isRead {
            if emails[i].folder == .inbox { hadUnreadInbox = true }
            emails[i].isRead = true
            updatedEmails.append(emails[i])
        }
        emailsByAccount[accountId] = emails
        if hadUnreadInbox, let current = unreadCountsByAccount[accountId], current > 0 {
            unreadCountsByAccount[accountId] = current - 1
        }
        if !updatedEmails.isEmpty {
            dataStore?.saveEmails(updatedEmails)
        }
        logger.debug("[\(accountId)] marked \(emailId) as read (local)")

        guard let client = clients[accountId] else { return }

        Task {
            do {
                _ = try await client.modifyMessage(id: msgId, removeLabels: [GmailLabelId.unread])
                logger.info("[\(accountId)] markAsRead persisted via API for msgId=\(msgId)")
            } catch {
                logger.error("[\(accountId)] markAsRead API call failed for msgId=\(msgId): \(error.localizedDescription)")
            }
        }
    }

    func removeEmail(id: String, accountId: String, msgId: String, allFolders: Bool = false) {
        let unreadInboxRemoved: Int
        if allFolders {
            unreadInboxRemoved = emailsByAccount[accountId]?.filter { $0.msgId == msgId && $0.folder == .inbox && !$0.isRead }.count ?? 0
            emailsByAccount[accountId]?.removeAll { $0.msgId == msgId }
            dataStore?.deleteEmails(msgId: msgId, accountId: accountId)
        } else {
            unreadInboxRemoved = emailsByAccount[accountId]?.filter { $0.id == id && $0.folder == .inbox && !$0.isRead }.count ?? 0
            emailsByAccount[accountId]?.removeAll { $0.id == id }
            dataStore?.deleteEmail(id: id)
        }
        if unreadInboxRemoved > 0, let current = unreadCountsByAccount[accountId], current >= unreadInboxRemoved {
            unreadCountsByAccount[accountId] = current - unreadInboxRemoved
        }
    }

    func archiveEmail(msgId: String, accountId: String, folder: Folder) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        _ = try await client.modifyMessage(id: msgId, removeLabels: [GmailLabelId.inbox])
        removeEmail(id: "\(accountId)_\(folder.rawValue)_\(msgId)", accountId: accountId, msgId: msgId, allFolders: true)
    }

    func deleteEmail(msgId: String, accountId: String, folder: Folder) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        _ = try await client.trashMessage(id: msgId)
        removeEmail(id: "\(accountId)_\(folder.rawValue)_\(msgId)", accountId: accountId, msgId: msgId, allFolders: true)
    }

    func spamEmail(msgId: String, accountId: String, folder: Folder) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        _ = try await client.modifyMessage(id: msgId, addLabels: [GmailLabelId.spam], removeLabels: [GmailLabelId.inbox])
        removeEmail(id: "\(accountId)_\(folder.rawValue)_\(msgId)", accountId: accountId, msgId: msgId, allFolders: true)
    }

    func sendEmail(from: String, to: String, cc: String? = nil, subject: String, body: String, accountId: String, inReplyTo: String? = nil, references: String? = nil) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let raw = RFC2822Builder.buildRawMessage(
            from: from, to: to, cc: cc, subject: subject, body: body,
            inReplyTo: inReplyTo, references: references
        )
        _ = try await client.sendMessage(raw: raw)
    }

    // MARK: - Conversion

    func convertGmailMessageToEmail(_ message: GmailMessage, accountId: String, folder: Folder) -> Email? {
        let labelIds = message.labelIds ?? []
        guard folder.matchesLabels(labelIds) else { return nil }

        let headers = message.payload?.headers ?? []
        let from = headers.first(where: { $0.name.lowercased() == "from" })?.value ?? ""
        let subject = headers.first(where: { $0.name.lowercased() == "subject" })?.value ?? "(No Subject)"

        let date: Date
        if let internalDate = message.internalDate, let ms = Double(internalDate) {
            date = Date(timeIntervalSince1970: ms / 1000)
        } else {
            date = Date()
        }

        let isRead = !(labelIds.contains(GmailLabelId.unread))
        let snippet = message.snippet ?? ""
        let messageId = headers.first(where: { $0.name.lowercased() == "message-id" })?.value

        return Email(
            msgId: message.id,
            from: from,
            subject: subject,
            date: date,
            snippet: snippet,
            isRead: isRead,
            accountId: accountId,
            folder: folder,
            messageId: messageId
        )
    }

    // MARK: - Computed Properties

    var hasLoadedAny: Bool {
        !accountsWithCompletedFetch.isEmpty
    }

    var clientErrors: [String] {
        clientStates.compactMap { (id, state) in
            if case .error(let msg) = state {
                return "[\(id.prefix(8))…] \(msg)"
            }
            return nil
        }
    }

    var allClientsErrored: Bool {
        !clients.isEmpty && clientStates.values.allSatisfy {
            if case .error = $0 { return true }
            return false
        }
    }

    var allEmails: [Email] {
        Email.sortedByDate(emailsByAccount.values.flatMap { $0 })
    }

    var totalUnreadCount: Int {
        unreadCountsByAccount.values.reduce(0, +)
    }
}
