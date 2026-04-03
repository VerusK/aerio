import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "Aerio", category: "GmailAPIManager")

struct ThreadMessage: Identifiable {
    let id: String
    let from: String
    let to: String
    let cc: String
    let date: Date
    let subject: String
    let bodyHTML: String
    let attachments: [MessageContentData.AttachmentInfo]
    let inlineImages: [(cid: String, attachmentId: String, mimeType: String)]
    let accountId: String
    let msgId: String
    let messageId: String?
    let folder: Folder
    let isRead: Bool
}

@MainActor
final class GmailAPIManager: ObservableObject {
    @Published private(set) var clients: [String: GmailAPIClient] = [:]
    @Published var emailsByAccount: [String: [Email]] = [:]
    @Published var unreadCountsByAccount: [String: Int] = [:]
    @Published private(set) var isPolling = false
    @Published private(set) var clientStates: [String: ClientState] = [:]

    private let accountManager: AccountManager
    private let oauthManager: OAuthManager
    let keychainStore: KeychainStore
    private var cancellables = Set<AnyCancellable>()
    private var clientCancellables: [String: AnyCancellable] = [:]
    private var currentFolder: Folder = .inbox
    private var currentPollInterval: TimeInterval = 45
    private var pollingTask: Task<Void, Never>?
    var historyIds: [String: String] = [:]
    var dataStore: EmailCache?
    var contactsCache: ContactsCache?
    var notificationManager: NotificationManager?
    private(set) var accountsWithCompletedFetch = Set<String>()
    var pageTokens: [String: [Folder: String]] = [:]
    private var fetchingMore: Set<String> = []

    // Factory closure for creating clients — allows test injection
    var clientFactory: ((String, OAuthManager) -> GmailAPIClient)?

    init(accountManager: AccountManager, oauthManager: OAuthManager, dataStore: EmailCache? = nil, keychainStore: KeychainStore = KeychainHelper.shared) {
        self.accountManager = accountManager
        self.oauthManager = oauthManager
        self.keychainStore = keychainStore
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
        guard clients[account.id] == nil else {
            logger.debug("[\(account.id)] addClient skipped — client already exists")
            return
        }

        // Verify tokens exist before creating client
        let hasTokens: Bool
        do {
            let tokens = try keychainStore.loadTokens(for: account.id)
            hasTokens = tokens != nil
            if let tokens {
                logger.info("[\(account.id)] addClient: tokens found (expired=\(tokens.isExpired), email=\(tokens.email ?? "nil"))")
            } else {
                logger.warning("[\(account.id)] addClient: no tokens in keychain — client will fail on first API call")
            }
        } catch {
            hasTokens = false
            logger.error("[\(account.id)] addClient: failed to load tokens — \(error.localizedDescription)")
        }

        let client: GmailAPIClient
        if let factory = clientFactory {
            client = factory(account.id, oauthManager)
        } else {
            client = GmailAPIClient(accountId: account.id, oauthManager: oauthManager, keychainStore: keychainStore)
        }

        clients[account.id] = client
        clientStates[account.id] = client.state
        logger.info("[\(account.id)] addClient: client created (hasTokens=\(hasTokens), totalClients=\(self.clients.count))")

        clientCancellables[account.id] = client.$state
            .sink { [weak self] newState in
                if case .error(let msg) = newState {
                    logger.error("[\(account.id)] client state → error: \(msg)")
                }
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
        pageTokens.removeValue(forKey: accountId)
        accountsWithCompletedFetch.remove(accountId)
        try? keychainStore.deleteTokens(for: accountId)
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
        pageTokens.removeAll()
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
        guard let client = clients[accountId] else {
            logger.warning("[\(accountId)] fetchEmails: no client found — skipping (available clients: \(Array(self.clients.keys)))")
            return
        }

        client.state = .syncing
        logger.info("[\(accountId)] fetchEmails: starting for folder=\(self.currentFolder.displayName)")
        let folder = currentFolder
        do {
            var pageToken: String?
            var listHistoryId: String?
            var allFetchedEmails: [Email] = []

            // Fetch first page of message IDs (50 per batch)
            let listResponse: GmailMessageListResponse
            if folder.gmailLabelIds.isEmpty {
                listResponse = try await client.listMessages(query: folder.gmailQuery, maxResults: 50, pageToken: pageToken)
            } else {
                listResponse = try await client.listMessages(labelIds: folder.gmailLabelIds, maxResults: 50, pageToken: pageToken)
            }

            if let hid = listResponse.historyId {
                listHistoryId = hid
            }

            let messageIds = listResponse.messages?.map(\.id) ?? []
            pageToken = listResponse.nextPageToken

            guard !messageIds.isEmpty else {
                // No emails at all for this folder — clear both cache and in-memory list
                client.state = .idle
                accountsWithCompletedFetch.insert(accountId)
                pageTokens[accountId, default: [:]][folder] = nil
                emailsByAccount[accountId]?.removeAll { $0.folder == folder }
                dataStore?.replaceEmails(for: accountId, folder: folder, with: [])
                return
            }

            // Fetch full metadata for this batch
            let messages = try await client.getMessages(ids: messageIds, format: "metadata", metadataHeaders: ["From", "To", "Cc", "Subject", "Date", "Message-ID"])
            let batchEmails = messages.compactMap { convertGmailMessageToEmail($0, accountId: accountId, folder: folder) }
            allFetchedEmails.append(contentsOf: batchEmails)

            // Update UI — replace folder emails with fetched batch (avoids blank flash)
            var current = emailsByAccount[accountId] ?? []
            let oldFolderEmails = current.filter { $0.folder == folder }
            current.removeAll { $0.folder == folder }
            current.append(contentsOf: batchEmails)
            // Skip update if data unchanged (avoids unnecessary re-render after cache load)
            if oldFolderEmails != batchEmails {
                emailsByAccount[accountId] = current
            }

            // Update historyId from messages in this batch
            if listHistoryId == nil {
                let maxHid = messages.compactMap(\.historyId).compactMap(UInt64.init).max()
                if let maxHid {
                    listHistoryId = String(maxHid)
                }
            }

            logger.debug("[\(accountId)] fetchEmails: batch loaded \(batchEmails.count) emails, total=\(allFetchedEmails.count), hasMore=\(pageToken != nil)")

            // Save historyId for incremental sync
            if let listHistoryId {
                historyIds[accountId] = listHistoryId
            }

            // Save pageToken for infinite scroll (nil means all loaded)
            pageTokens[accountId, default: [:]][folder] = pageToken

            // Update unread count
            await fetchUnreadCount(for: accountId, client: client)

            client.state = .idle
            accountsWithCompletedFetch.insert(accountId)
            dataStore?.replaceEmails(for: accountId, folder: folder, with: allFetchedEmails)
            contactsCache?.addContacts(from: allFetchedEmails)
        } catch let apiError as GmailAPIError {
            logger.error("[\(accountId)] fetchEmails failed (API): \(apiError.localizedDescription) — folder=\(self.currentFolder.displayName)")
            switch apiError {
            case .unauthorized, .sessionExpired:
                logger.error("[\(accountId)] fetchEmails: auth failure — token may be missing or expired, user may need to re-authenticate")
            case .forbidden(let detail):
                logger.error("[\(accountId)] fetchEmails: forbidden — \(detail) — check OAuth scopes or account permissions")
            case .rateLimited:
                logger.warning("[\(accountId)] fetchEmails: rate limited — too many requests to Gmail API")
            default:
                break
            }
            client.state = .error(apiError.localizedDescription)
        } catch {
            logger.error("[\(accountId)] fetchEmails failed (unexpected): \(error.localizedDescription) — folder=\(self.currentFolder.displayName)")
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
            let previousEmailIds = Set(currentEmails.map(\.msgId))

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
                    metadataHeaders: ["From", "To", "Cc", "Subject", "Date", "Message-ID"]
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

                // Trigger notifications for new inbox+unread emails
                let notifiable = NotificationManager.newInboxUnreadEmails(
                    newEmails: newEmails,
                    previousEmailIds: previousEmailIds
                )
                for email in notifiable {
                    notificationManager?.showNotification(
                        from: email.from,
                        subject: email.subject,
                        snippet: email.snippet,
                        emailId: email.msgId,
                        accountId: email.accountId
                    )
                }
            }

            // Track which folders had emails before the sync
            let foldersBefore = Set((emailsByAccount[accountId] ?? []).map(\.folder))

            emailsByAccount[accountId] = currentEmails
            contactsCache?.addContacts(from: currentEmails)
            await fetchUnreadCount(for: accountId, client: client)
            client.state = .idle

            // Persist all folders that currently have emails OR previously had emails
            let foldersAfter = Set(currentEmails.map(\.folder))
            let allAffectedFolders = foldersBefore.union(foldersAfter)
            for folder in allAffectedFolders {
                dataStore?.replaceEmails(for: accountId, folder: folder, with: currentEmails.filter { $0.folder == folder })
            }
            dataStore?.purgeOldEmails(keepLast: 1000)
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

    func fetchMoreEmails(accountId: String, folder: Folder) async {
        let fetchKey = "\(accountId)_\(folder.rawValue)"
        guard !fetchingMore.contains(fetchKey),
              let client = clients[accountId],
              let pageToken = pageTokens[accountId]?[folder] else {
            return
        }

        fetchingMore.insert(fetchKey)
        defer { fetchingMore.remove(fetchKey) }

        logger.debug("[\(accountId)] fetchMoreEmails: loading more for folder=\(folder.displayName), pageToken=\(pageToken)")
        do {
            let listResponse: GmailMessageListResponse
            if folder.gmailLabelIds.isEmpty {
                listResponse = try await client.listMessages(query: folder.gmailQuery, maxResults: 50, pageToken: pageToken)
            } else {
                listResponse = try await client.listMessages(labelIds: folder.gmailLabelIds, maxResults: 50, pageToken: pageToken)
            }

            let messageIds = listResponse.messages?.map(\.id) ?? []
            let nextPageToken = listResponse.nextPageToken

            // Update stored page token (nil if no more pages)
            pageTokens[accountId, default: [:]][folder] = nextPageToken

            guard !messageIds.isEmpty else { return }

            let messages = try await client.getMessages(ids: messageIds, format: "metadata", metadataHeaders: ["From", "To", "Cc", "Subject", "Date", "Message-ID"])
            let newEmails = messages.compactMap { convertGmailMessageToEmail($0, accountId: accountId, folder: folder) }

            // Append to existing emails, avoiding duplicates
            var current = emailsByAccount[accountId] ?? []
            let existingMsgIds = Set(current.filter { $0.folder == folder }.map(\.msgId))
            let uniqueNewEmails = newEmails.filter { !existingMsgIds.contains($0.msgId) }
            current.append(contentsOf: uniqueNewEmails)
            emailsByAccount[accountId] = current

            dataStore?.saveEmails(uniqueNewEmails)
            logger.debug("[\(accountId)] fetchMoreEmails: appended \(uniqueNewEmails.count) emails, hasMore=\(nextPageToken != nil)")
        } catch {
            logger.error("[\(accountId)] fetchMoreEmails failed: \(error.localizedDescription)")
        }
    }

    func fetchMessageContent(msgId: String, accountId: String) async throws -> GmailMessage {
        guard let client = clients[accountId] else {
            throw GmailAPIError.unauthorized
        }
        return try await client.getMessage(id: msgId, format: "full")
    }

    func downloadAttachment(messageId: String, attachmentId: String, accountId: String) async throws -> Data {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let attachment = try await client.getAttachment(messageId: messageId, attachmentId: attachmentId)
        guard let base64Data = attachment.data, let data = Data.fromBase64URL(base64Data) else {
            throw GmailAPIError.decodingError("Failed to decode attachment data")
        }
        return data
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
            dataStore?.deleteContent(accountId: accountId, msgId: msgId)
        } else {
            unreadInboxRemoved = emailsByAccount[accountId]?.filter { $0.id == id && $0.folder == .inbox && !$0.isRead }.count ?? 0
            emailsByAccount[accountId]?.removeAll { $0.id == id }
            dataStore?.deleteEmail(id: id)
        }
        if unreadInboxRemoved > 0, let current = unreadCountsByAccount[accountId], current >= unreadInboxRemoved {
            unreadCountsByAccount[accountId] = current - unreadInboxRemoved
        }
    }

    // MARK: - Optimistic Email Actions

    func archiveEmail(msgId: String, accountId: String, folder: Folder) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let emailCopy = emailsByAccount[accountId]?.first { $0.msgId == msgId && $0.folder == folder }

        let removal = removeEmailFromMemory(accountId: accountId, msgId: msgId, allFolders: true)
        let movedEmail = emailCopy.map { moveEmailInMemory($0, targetFolder: .archive, accountId: accountId) }

        do {
            _ = try await client.modifyMessage(id: msgId, removeLabels: [GmailLabelId.inbox])
        } catch {
            revertOptimisticUpdate(removal: removal, movedEmail: movedEmail, accountId: accountId)
            throw error
        }

        persistRemoval(accountId: accountId, msgId: msgId, allFolders: true)
        if let movedEmail { persistMove(movedEmail) }
    }

    func deleteEmail(msgId: String, accountId: String, folder: Folder) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let emailCopy = emailsByAccount[accountId]?.first { $0.msgId == msgId && $0.folder == folder }

        let removal = removeEmailFromMemory(accountId: accountId, msgId: msgId, allFolders: true)
        let movedEmail = emailCopy.map { moveEmailInMemory($0, targetFolder: .trash, accountId: accountId) }

        do {
            _ = try await client.trashMessage(id: msgId)
        } catch {
            revertOptimisticUpdate(removal: removal, movedEmail: movedEmail, accountId: accountId)
            throw error
        }

        persistRemoval(accountId: accountId, msgId: msgId, allFolders: true)
        if let movedEmail { persistMove(movedEmail) }
    }

    func spamEmail(msgId: String, accountId: String, folder: Folder) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let emailCopy = emailsByAccount[accountId]?.first { $0.msgId == msgId && $0.folder == folder }

        let removal = removeEmailFromMemory(accountId: accountId, msgId: msgId, allFolders: true)
        let movedEmail = emailCopy.map { moveEmailInMemory($0, targetFolder: .spam, accountId: accountId) }

        do {
            _ = try await client.modifyMessage(id: msgId, addLabels: [GmailLabelId.spam], removeLabels: [GmailLabelId.inbox])
        } catch {
            revertOptimisticUpdate(removal: removal, movedEmail: movedEmail, accountId: accountId)
            throw error
        }

        persistRemoval(accountId: accountId, msgId: msgId, allFolders: true)
        if let movedEmail { persistMove(movedEmail) }
    }

    func moveToInbox(msgId: String, accountId: String, folder: Folder) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let emailCopy = emailsByAccount[accountId]?.first { $0.msgId == msgId && $0.folder == folder }

        let allFolders = folder == .trash
        let removal = removeEmailFromMemory(accountId: accountId, msgId: msgId, allFolders: allFolders)
        let movedEmail = emailCopy.map { moveEmailInMemory($0, targetFolder: .inbox, accountId: accountId) }

        do {
            switch folder {
            case .trash:
                _ = try await client.untrashMessage(id: msgId)
                _ = try await client.modifyMessage(id: msgId, addLabels: [GmailLabelId.inbox])
            case .spam:
                _ = try await client.modifyMessage(id: msgId, addLabels: [GmailLabelId.inbox], removeLabels: [GmailLabelId.spam])
            case .archive:
                _ = try await client.modifyMessage(id: msgId, addLabels: [GmailLabelId.inbox])
            default:
                _ = try await client.modifyMessage(id: msgId, addLabels: [GmailLabelId.inbox])
            }
        } catch {
            revertOptimisticUpdate(removal: removal, movedEmail: movedEmail, accountId: accountId)
            throw error
        }

        persistRemoval(accountId: accountId, msgId: msgId, allFolders: allFolders)
        if let movedEmail { persistMove(movedEmail) }
    }

    // MARK: - Optimistic Update Helpers

    private func removeEmailFromMemory(accountId: String, msgId: String, allFolders: Bool) -> (emails: [Email], unreadInboxCount: Int) {
        let removed: [Email]
        let unreadInboxRemoved: Int
        if allFolders {
            removed = emailsByAccount[accountId]?.filter { $0.msgId == msgId } ?? []
            unreadInboxRemoved = removed.filter { $0.folder == .inbox && !$0.isRead }.count
            emailsByAccount[accountId]?.removeAll { $0.msgId == msgId }
        } else {
            removed = emailsByAccount[accountId]?.filter { $0.msgId == msgId } ?? []
            unreadInboxRemoved = removed.filter { $0.folder == .inbox && !$0.isRead }.count
            emailsByAccount[accountId]?.removeAll { $0.msgId == msgId }
        }
        if unreadInboxRemoved > 0, let current = unreadCountsByAccount[accountId], current >= unreadInboxRemoved {
            unreadCountsByAccount[accountId] = current - unreadInboxRemoved
        }
        return (removed, unreadInboxRemoved)
    }

    private func moveEmailInMemory(_ email: Email, targetFolder: Folder, accountId: String) -> Email {
        let movedEmail = Email(
            msgId: email.msgId,
            from: email.from,
            subject: email.subject,
            date: email.date,
            snippet: email.snippet,
            isRead: email.isRead,
            accountId: accountId,
            folder: targetFolder,
            messageId: email.messageId
        )
        emailsByAccount[accountId, default: []].append(movedEmail)
        logger.debug("[\(accountId)] moved email \(email.msgId) to \(targetFolder.displayName)")
        return movedEmail
    }

    private func revertOptimisticUpdate(removal: (emails: [Email], unreadInboxCount: Int), movedEmail: Email?, accountId: String) {
        if let movedEmail {
            emailsByAccount[accountId]?.removeAll { $0.id == movedEmail.id }
        }
        emailsByAccount[accountId, default: []].append(contentsOf: removal.emails)
        if removal.unreadInboxCount > 0 {
            unreadCountsByAccount[accountId, default: 0] += removal.unreadInboxCount
        }
        logger.debug("[\(accountId)] reverted optimistic update, restored \(removal.emails.count) emails")
    }

    private func persistRemoval(accountId: String, msgId: String, allFolders: Bool) {
        Task { @MainActor [dataStore] in
            if allFolders {
                dataStore?.deleteEmails(msgId: msgId, accountId: accountId)
                dataStore?.deleteContent(accountId: accountId, msgId: msgId)
            } else {
                dataStore?.deleteEmails(msgId: msgId, accountId: accountId)
            }
        }
    }

    private func persistMove(_ email: Email) {
        Task { @MainActor [dataStore] in
            dataStore?.saveEmails([email])
        }
    }

    private func buildRawMessage(from: String, to: String, cc: String?, subject: String, body: String, inReplyTo: String?, references: String?, htmlBody: String?, attachments: [RFC2822Builder.Attachment], inlineImages: [RFC2822Builder.InlineImage]) -> String {
        if !attachments.isEmpty || !inlineImages.isEmpty {
            return RFC2822Builder.buildRawHTMLMessageWithAttachments(
                from: from, to: to, cc: cc, subject: subject,
                htmlBody: htmlBody ?? "", plainBody: body,
                attachments: attachments, inlineImages: inlineImages,
                inReplyTo: inReplyTo, references: references
            )
        } else if let htmlBody, !htmlBody.isEmpty {
            return RFC2822Builder.buildRawHTMLMessage(
                from: from, to: to, cc: cc, subject: subject,
                htmlBody: htmlBody, plainBody: body,
                inReplyTo: inReplyTo, references: references
            )
        } else {
            return RFC2822Builder.buildRawMessage(
                from: from, to: to, cc: cc, subject: subject, body: body,
                inReplyTo: inReplyTo, references: references
            )
        }
    }

    func sendEmail(from: String, to: String, cc: String? = nil, subject: String, body: String, accountId: String, inReplyTo: String? = nil, references: String? = nil, htmlBody: String? = nil, attachments: [RFC2822Builder.Attachment] = [], inlineImages: [RFC2822Builder.InlineImage] = [], threadId: String? = nil) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let raw = buildRawMessage(from: from, to: to, cc: cc, subject: subject, body: body, inReplyTo: inReplyTo, references: references, htmlBody: htmlBody, attachments: attachments, inlineImages: inlineImages)
        let sent = try await client.sendMessage(raw: raw, threadId: threadId)
        // Remove INBOX label from self-sent messages so they don't appear in inbox
        if (sent.labelIds ?? []).contains(GmailLabelId.inbox) {
            _ = try? await client.modifyMessage(id: sent.id, removeLabels: [GmailLabelId.inbox])
        }
    }

    func searchEmails(query: String) async -> [Email] {
        let (emails, _) = await searchEmailsWithTokens(query: query)
        return emails
    }

    func searchEmailsWithTokens(query: String, pageTokens: [String: String] = [:]) async -> ([Email], [String: String]) {
        await withTaskGroup(of: (String, [Email], String?).self) { group in
            for (accountId, client) in clients {
                // Skip accounts that had no more pages on previous call
                if !pageTokens.isEmpty && pageTokens[accountId] == nil { continue }
                let token = pageTokens[accountId]
                group.addTask { @MainActor in
                    do {
                        let listResponse = try await client.listMessages(query: query, maxResults: 20, pageToken: token)
                        let messageIds = listResponse.messages?.map(\.id) ?? []
                        guard !messageIds.isEmpty else { return (accountId, [], nil) }
                        let messages = try await client.getMessages(ids: messageIds, format: "metadata", metadataHeaders: ["From", "To", "Cc", "Subject", "Date", "Message-ID"])
                        let emails = messages.compactMap { msg -> Email? in
                            let labelIds = msg.labelIds ?? []
                            let folder = Folder.allCases.first { $0.matchesLabels(labelIds) } ?? .inbox
                            return self.convertGmailMessageToEmail(msg, accountId: accountId, folder: folder, skipLabelCheck: true)
                        }
                        return (accountId, emails, listResponse.nextPageToken)
                    } catch {
                        logger.error("[\(accountId)] searchEmails failed: \(error.localizedDescription)")
                        return (accountId, [], nil)
                    }
                }
            }
            var results: [Email] = []
            var nextTokens: [String: String] = [:]
            for await (accountId, emails, nextToken) in group {
                results.append(contentsOf: emails)
                if let nextToken {
                    nextTokens[accountId] = nextToken
                }
            }
            return (Email.sortedByDate(results), nextTokens)
        }
    }

    func saveDraft(from: String, to: String, cc: String? = nil, subject: String, body: String, accountId: String, inReplyTo: String? = nil, references: String? = nil, htmlBody: String? = nil, attachments: [RFC2822Builder.Attachment] = [], inlineImages: [RFC2822Builder.InlineImage] = []) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let raw = buildRawMessage(from: from, to: to, cc: cc, subject: subject, body: body, inReplyTo: inReplyTo, references: references, htmlBody: htmlBody, attachments: attachments, inlineImages: inlineImages)
        let draft = try await client.createDraft(raw: raw)
        logger.info("[\(accountId)] draft saved")

        // Optimistic UI update: add draft email immediately
        let msgId = draft.message?.id ?? draft.id
        let snippet = String(body.prefix(100))
        let draftEmail = Email(
            msgId: msgId,
            from: from,
            subject: subject,
            date: Date(),
            snippet: snippet,
            isRead: true,
            accountId: accountId,
            folder: .drafts
        )
        var current = emailsByAccount[accountId] ?? []
        current.insert(draftEmail, at: 0)
        emailsByAccount[accountId] = current
        dataStore?.replaceEmails(for: accountId, folder: .drafts, with: current.filter { $0.folder == .drafts })

        // Background sync to get accurate server state
        Task { await syncAllAccounts() }
    }

    /// Find draft ID by message ID and return full draft content.
    func fetchDraftByMessageId(msgId: String, accountId: String) async throws -> GmailDraft? {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let listResponse = try await client.listDrafts()
        guard let drafts = listResponse.drafts else { return nil }
        guard let match = drafts.first(where: { $0.message?.id == msgId }) else { return nil }
        return try await client.getDraft(draftId: match.id)
    }

    func sendDraft(draftId: String, accountId: String) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        let sent = try await client.sendDraft(draftId: draftId)
        logger.info("[\(accountId)] draft sent: \(draftId)")
        // Remove INBOX label from self-sent messages so they don't appear in inbox
        if (sent.labelIds ?? []).contains(GmailLabelId.inbox) {
            _ = try? await client.modifyMessage(id: sent.id, removeLabels: [GmailLabelId.inbox])
        }
    }

    func deleteDraft(draftId: String, accountId: String) async throws {
        guard let client = clients[accountId] else { throw GmailAPIError.unauthorized }
        try await client.deleteDraft(draftId: draftId)
        logger.info("[\(accountId)] draft deleted: \(draftId)")
    }

    // MARK: - Thread Fetching

    private struct ThreadCacheEntry {
        let messages: [ThreadMessage]
        let timestamp: Date
    }
    private static var threadCache: [String: ThreadCacheEntry] = [:]
    private static let threadCacheTTL: TimeInterval = 30

    func fetchThread(threadId: String, accountId: String) async throws -> [ThreadMessage] {
        let cacheKey = "\(accountId)_\(threadId)"
        if let cached = Self.threadCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < Self.threadCacheTTL {
            return cached.messages
        }

        guard let client = clients[accountId] else {
            throw GmailAPIError.unauthorized
        }

        let thread = try await client.getThread(id: threadId, format: "full")
        guard let messages = thread.messages else { return [] }

        var threadMessages: [ThreadMessage] = []
        for message in messages {
            let headers = message.payload?.headers ?? []
            let from = headers.first { $0.name.lowercased() == "from" }?.value ?? ""
            let to = headers.first { $0.name.lowercased() == "to" }?.value ?? ""
            let cc = headers.first { $0.name.lowercased() == "cc" }?.value ?? ""
            let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? ""
            let messageId = headers.first { $0.name.lowercased() == "message-id" }?.value

            let date: Date
            if let internalDate = message.internalDate, let ms = Double(internalDate) {
                date = Date(timeIntervalSince1970: ms / 1000)
            } else {
                date = Date()
            }

            var bodyHTML = ""
            if let payload = message.payload {
                let extracted = extractBodyFromPayload(payload)
                bodyHTML = extracted.isEmpty ? "<p>No message body</p>" : extracted
            }

            let attachments: [MessageContentData.AttachmentInfo]
            if let payload = message.payload {
                let allInlineIds: Set<String> = Set(extractInlineImages(payload).map { $0.attachmentId })
                attachments = extractAttachments(payload, messageId: message.id)
                    .filter { att in
                        guard let attId = att.attachmentId else { return true }
                        return !allInlineIds.contains(attId)
                    }
            } else {
                attachments = []
            }

            let inlineImages = message.payload.map { extractInlineImages($0) } ?? []

            let labelIds = message.labelIds ?? []
            let isRead = !labelIds.contains(GmailLabelId.unread)
            let folder = Folder.allCases.first { $0.matchesLabels(labelIds) } ?? .inbox

            threadMessages.append(ThreadMessage(
                id: message.id,
                from: from,
                to: to,
                cc: cc,
                date: date,
                subject: subject,
                bodyHTML: bodyHTML,
                attachments: attachments,
                inlineImages: inlineImages,
                accountId: accountId,
                msgId: message.id,
                messageId: messageId,
                folder: folder,
                isRead: isRead
            ))
        }

        threadMessages.sort { $0.date > $1.date }

        Self.threadCache[cacheKey] = ThreadCacheEntry(messages: threadMessages, timestamp: Date())

        return threadMessages
    }

    /// Returns true if the thread has multiple messages based on locally loaded emails.
    func threadHasMultipleMessages(_ threadId: String) -> Bool {
        let allEmails = emailsByAccount.values.flatMap { $0 }
        return allEmails.filter { $0.threadId == threadId }.count > 1
    }

    // MARK: - Conversion

    func convertGmailMessageToEmail(_ message: GmailMessage, accountId: String, folder: Folder, skipLabelCheck: Bool = false) -> Email? {
        let labelIds = message.labelIds ?? []
        if !skipLabelCheck {
            guard folder.matchesLabels(labelIds) else { return nil }
        }

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
        let to = headers.first(where: { $0.name.lowercased() == "to" })?.value ?? ""
        let cc = headers.first(where: { $0.name.lowercased() == "cc" })?.value ?? ""

        return Email(
            msgId: message.id,
            from: from,
            subject: subject,
            date: date,
            snippet: snippet,
            isRead: isRead,
            accountId: accountId,
            folder: folder,
            messageId: messageId,
            to: to,
            cc: cc,
            threadId: message.threadId
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
