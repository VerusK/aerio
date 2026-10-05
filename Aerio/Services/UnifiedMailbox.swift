import Foundation
import Combine

@MainActor
final class UnifiedMailbox: ObservableObject {
    @Published private(set) var emails: [Email] = []
    /// `emails` grouped into rows; always assigned together with `emails`.
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var unreadCounts: [Folder: Int] = [:]
    @Published var selectedFolder: Folder = .inbox
    @Published var selectedAccountId: String?

    private let apiManager: GmailAPIManager
    private var cancellables = Set<AnyCancellable>()

    init(apiManager: GmailAPIManager) {
        self.apiManager = apiManager
        observeAPIManager()
        // Force initial rebuild from any pre-loaded cache data
        rebuildEmails(from: apiManager.emailsByAccount, folder: selectedFolder, accountId: selectedAccountId)
        rebuildUnreadCounts(from: apiManager.emailsByAccount)
    }

    private func observeAPIManager() {
        apiManager.$emailsByAccount
            .combineLatest($selectedFolder, $selectedAccountId)
            .sink { [weak self] emailsByAccount, folder, accountId in
                guard let self else { return }
                self.rebuildEmails(from: emailsByAccount, folder: folder, accountId: accountId)
            }
            .store(in: &cancellables)

        apiManager.$emailsByAccount
            .sink { [weak self] emailsByAccount in
                guard let self else { return }
                self.rebuildUnreadCounts(from: emailsByAccount)
            }
            .store(in: &cancellables)
    }

    private func rebuildEmails(from emailsByAccount: [String: [Email]], folder: Folder, accountId: String?) {
        // Collect source emails for current view
        var sourceEmails: [Email]
        if let accountId {
            sourceEmails = emailsByAccount[accountId] ?? []
        } else {
            sourceEmails = emailsByAccount.values.flatMap { $0 }
        }
        sourceEmails = sourceEmails.filter { $0.folder == folder }

        // Incremental merge: compute diff by ID
        let newIds = Set(sourceEmails.map(\.id))
        let oldIds = Set(emails.map(\.id))

        let removedIds = oldIds.subtracting(newIds)
        let addedIds = newIds.subtracting(oldIds)

        // If nothing changed, check for in-place updates (e.g. isRead changed)
        if removedIds.isEmpty && addedIds.isEmpty {
            let oldById = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
            var needsUpdate = false
            for email in sourceEmails {
                if let old = oldById[email.id], old != email {
                    needsUpdate = true
                    break
                }
            }
            if !needsUpdate { return }
        }

        // Build the final array in one place so `emails` and `conversations` are
        // assigned together on both paths.
        var updated: [Email]

        // Large change (e.g. folder switch): full sort is O(n log n) vs O(n²) for incremental insert
        let changedCount = removedIds.count + addedIds.count
        let totalCount = max(oldIds.count, newIds.count, 1)
        if changedCount > totalCount / 2 {
            updated = Email.sortedByDate(sourceEmails)
        } else {
            // Small change (e.g. new emails arrived): incremental merge
            updated = emails

            // Remove deleted
            if !removedIds.isEmpty {
                updated.removeAll { removedIds.contains($0.id) }
            }

            // Update existing emails in-place (e.g. isRead change)
            let sourceById = Dictionary(uniqueKeysWithValues: sourceEmails.map { ($0.id, $0) })
            for i in updated.indices {
                if let changed = sourceById[updated[i].id], changed != updated[i] {
                    updated[i] = changed
                }
            }

            // Insert new emails at correct sorted position (date descending)
            let added = sourceEmails.filter { addedIds.contains($0.id) }
            for email in added {
                let insertIndex = updated.firstIndex { $0.date < email.date } ?? updated.endIndex
                updated.insert(email, at: insertIndex)
            }
        }

        emails = updated
        conversations = Conversation.group(updated)
    }

    private func rebuildUnreadCounts(from emailsByAccount: [String: [Email]]) {
        var counts: [Folder: Int] = [:]
        let allEmails = emailsByAccount.values.flatMap { $0 }
        for folder in Folder.allCases {
            counts[folder] = allEmails.filter { $0.folder == folder && !$0.isRead }.count
        }
        unreadCounts = counts
    }

    func unreadCount(for folder: Folder, accountId: String? = nil) -> Int {
        let source: [Email]
        if let accountId {
            source = apiManager.emailsByAccount[accountId] ?? []
        } else {
            source = apiManager.emailsByAccount.values.flatMap { $0 }
        }
        return source.filter { $0.folder == folder && !$0.isRead }.count
    }

    func totalCount(for folder: Folder, accountId: String? = nil) -> Int {
        let source: [Email]
        if let accountId {
            source = apiManager.emailsByAccount[accountId] ?? []
        } else {
            source = apiManager.emailsByAccount.values.flatMap { $0 }
        }
        return source.filter { $0.folder == folder }.count
    }

    func hasMoreEmails(folder: Folder, accountId: String? = nil) -> Bool {
        if let accountId {
            if let token = apiManager.pageTokens[accountId]?[folder], !token.isEmpty {
                return true
            }
            return false
        }
        // Any account has more pages for this folder
        for (_, folderTokens) in apiManager.pageTokens {
            if let token = folderTokens[folder], !token.isEmpty {
                return true
            }
        }
        return false
    }

    func emails(for folder: Folder, accountId: String? = nil) -> [Email] {
        // Fast path: if requesting the current view, return cached sorted array
        if folder == selectedFolder && accountId == selectedAccountId {
            return emails
        }
        // Slow path: filter and sort from source
        let source: [Email]
        if let accountId {
            source = apiManager.emailsByAccount[accountId] ?? []
        } else {
            source = apiManager.emailsByAccount.values.flatMap { $0 }
        }
        return Email.sortedByDate(source.filter { $0.folder == folder })
    }

    func conversations(for folder: Folder, accountId: String? = nil) -> [Conversation] {
        // Fast path: the current view is already grouped
        if folder == selectedFolder && accountId == selectedAccountId {
            return conversations
        }
        return Conversation.group(emails(for: folder, accountId: accountId))
    }
}
