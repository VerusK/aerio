import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "Aerio", category: "AccountManager")

@MainActor
final class AccountManager: ObservableObject {
    static let storageKey = "aerio_accounts"

    @Published private(set) var accounts: [Account] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadAccounts()
    }

    func addAccount(_ account: Account) {
        guard !accounts.contains(where: { $0.id == account.id || $0.email == account.email }) else { return }
        accounts.append(account)
        saveAccounts()
    }

    func removeAccount(id: String) {
        accounts.removeAll { $0.id == id }
        saveAccounts()
    }

    func account(for id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    func updateAccount(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        saveAccounts()
    }

    private func saveAccounts() {
        do {
            let data = try JSONEncoder().encode(accounts)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            logger.error("Failed to encode accounts: \(error.localizedDescription)")
        }
    }

    private func loadAccounts() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            accounts = try JSONDecoder().decode([Account].self, from: data)
        } catch {
            logger.error("Failed to decode accounts: \(error.localizedDescription)")
        }
    }
}
