import Foundation
import Combine

@MainActor
final class GmailScraperManager: ObservableObject {
    @Published private(set) var scrapers: [String: GmailScraper] = [:]
    @Published var emailsByAccount: [String: [Email]] = [:]
    @Published var unreadCountsByAccount: [String: Int] = [:]
    @Published private(set) var isPolling = false

    private let accountManager: AccountManager
    private var webViewPool: WebViewPool?
    private var cancellables = Set<AnyCancellable>()
    private var currentFolder: Folder = .inbox
    private var currentPollInterval: TimeInterval = 45
    var dataStore: EmailCache?

    init(accountManager: AccountManager, webViewPool: WebViewPool? = nil, dataStore: EmailCache? = nil) {
        self.accountManager = accountManager
        self.webViewPool = webViewPool
        self.dataStore = dataStore
        if let dataStore {
            loadCachedEmails(from: dataStore)
        }
        observeAccounts()
    }

    private func loadCachedEmails(from dataStore: EmailCache) {
        for account in accountManager.accounts {
            let emails = dataStore.loadEmails(for: account.id)
            if !emails.isEmpty {
                emailsByAccount[account.id] = emails
            }
        }
    }

    private func observeAccounts() {
        accountManager.$accounts
            .sink { [weak self] accounts in
                guard let self else { return }
                self.syncScrapers(with: accounts)
            }
            .store(in: &cancellables)
    }

    private func syncScrapers(with accounts: [Account]) {
        let currentIds = Set(scrapers.keys)
        let newIds = Set(accounts.map(\.id))

        for id in currentIds.subtracting(newIds) {
            removeScraper(for: id)
        }

        for account in accounts where !currentIds.contains(account.id) {
            addScraper(for: account)
        }
    }

    func addScraper(for account: Account) {
        guard scrapers[account.id] == nil else { return }
        let scraper = GmailScraper(accountId: account.id)

        if let pool = webViewPool {
            let entry = pool.createWebViews(for: account.id)
            scraper.configure(webView: entry.hiddenWebView)
            entry.hiddenWebView.navigationDelegate = scraper
        }

        scraper.setOnEmailsParsed { [weak self] emails, unreadCount, folder in
            guard let self, self.scrapers[account.id] != nil else { return }
            var existing = self.emailsByAccount[account.id] ?? []
            existing.removeAll { $0.folder == folder }
            existing.append(contentsOf: emails)
            self.emailsByAccount[account.id] = existing
            if folder == .inbox {
                self.unreadCountsByAccount[account.id] = unreadCount
            }
            self.dataStore?.replaceEmails(for: account.id, folder: folder, with: emails)
        }
        scrapers[account.id] = scraper

        if isPolling {
            if currentFolder != .inbox {
                scraper.navigateToFolder(currentFolder)
            }
            scraper.startPolling(interval: currentPollInterval)
        }
    }

    func removeScraper(for accountId: String) {
        scrapers[accountId]?.stopPolling()
        scrapers.removeValue(forKey: accountId)
        emailsByAccount.removeValue(forKey: accountId)
        unreadCountsByAccount.removeValue(forKey: accountId)
        webViewPool?.removeWebViews(for: accountId)
        dataStore?.clearEmails(for: accountId)
    }

    func removeEmail(id: String, accountId: String, msgId: String, allFolders: Bool = false) {
        if allFolders {
            emailsByAccount[accountId]?.removeAll { $0.msgId == msgId }
            dataStore?.deleteEmails(msgId: msgId, accountId: accountId)
        } else {
            emailsByAccount[accountId]?.removeAll { $0.id == id }
            dataStore?.deleteEmail(id: id)
        }
    }

    func scraper(for accountId: String) -> GmailScraper? {
        scrapers[accountId]
    }

    func startPollingAll(interval: TimeInterval = 45) {
        isPolling = true
        currentPollInterval = interval
        for scraper in scrapers.values {
            scraper.startPolling(interval: interval)
        }
    }

    func navigateAllToFolder(_ folder: Folder) {
        currentFolder = folder
        for scraper in scrapers.values {
            scraper.navigateToFolder(folder)
        }
    }

    func stopPollingAll() {
        isPolling = false
        for scraper in scrapers.values {
            scraper.stopPolling()
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for scraper in scrapers.values {
                group.addTask { @MainActor in
                    do {
                        _ = try await scraper.injectAndParse()
                    } catch {
                        // Individual scraper errors are reflected in scraper.state
                    }
                }
            }
        }
    }

    var allEmails: [Email] {
        Email.sortedByDate(emailsByAccount.values.flatMap { $0 })
    }

    var totalUnreadCount: Int {
        unreadCountsByAccount.values.reduce(0, +)
    }
}
