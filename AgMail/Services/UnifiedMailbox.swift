import Foundation
import Combine

@MainActor
final class UnifiedMailbox: ObservableObject {
    @Published private(set) var emails: [Email] = []
    @Published private(set) var unreadCounts: [Folder: Int] = [:]
    @Published var selectedFolder: Folder = .inbox
    @Published var selectedAccountId: String?

    private let apiManager: GmailAPIManager
    private var cancellables = Set<AnyCancellable>()

    init(apiManager: GmailAPIManager) {
        self.apiManager = apiManager
        observeAPIManager()
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
        var allEmails: [Email]
        if let accountId {
            allEmails = emailsByAccount[accountId] ?? []
        } else {
            allEmails = emailsByAccount.values.flatMap { $0 }
        }
        allEmails = allEmails.filter { $0.folder == folder }
        emails = Email.sortedByDate(allEmails)
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
        let source: [Email]
        if let accountId {
            source = apiManager.emailsByAccount[accountId] ?? []
        } else {
            source = apiManager.emailsByAccount.values.flatMap { $0 }
        }
        return Email.sortedByDate(source.filter { $0.folder == folder })
    }
}
