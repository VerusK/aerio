import SwiftUI
import Combine
import os.log

@main
struct AgMailApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView(
                accountManager: appState.accountManager,
                unifiedMailbox: appState.unifiedMailbox,
                apiManager: appState.apiManager,
                oauthManager: appState.oauthManager
            )
            .background(WindowAccessor())
        }

        Settings {
            SettingsView()
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    class Coordinator {
        var moveObserver: NSObjectProtocol?
        var resizeObserver: NSObjectProtocol?

        deinit {
            if let obs = moveObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = resizeObserver { NotificationCenter.default.removeObserver(obs) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            restoreFrame(window)
            context.coordinator.moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { _ in saveFrame(window) }
            context.coordinator.resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { _ in saveFrame(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func saveFrame(_ window: NSWindow) {
        let frame = window.frame
        UserDefaults.standard.set(
            [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height],
            forKey: "mainWindowFrame"
        )
    }

    private func restoreFrame(_ window: NSWindow) {
        guard let values = UserDefaults.standard.array(forKey: "mainWindowFrame") as? [CGFloat],
              values.count == 4 else { return }
        let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        guard frame.width > 100, frame.height > 100,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: false)
    }
}

@MainActor
final class AppState: ObservableObject {
    let accountManager: AccountManager
    let oauthManager: OAuthManager
    let emailCache: EmailCache
    let apiManager: GmailAPIManager
    let unifiedMailbox: UnifiedMailbox
    let defaults: UserDefaults
    private var badgeCancellable: AnyCancellable?
    private var defaultsCancellable: AnyCancellable?

    static let showDockBadgeKey = "showDockBadge"

    private static let legacyMigrationKey = "agmail_legacy_migration_done"
    private static let logger = Logger(subsystem: "AgMail", category: "AppState")

    init() {
        let am = AccountManager()
        let oauth = OAuthManager()
        let cache = EmailCache()

        // One-time migration: remove legacy accounts that have no OAuth tokens in Keychain
        if !UserDefaults.standard.bool(forKey: Self.legacyMigrationKey) {
            let migrationComplete = Self.removeLegacyAccounts(accountManager: am, emailCache: cache)
            if migrationComplete {
                UserDefaults.standard.set(true, forKey: Self.legacyMigrationKey)
            }
        }

        let api = GmailAPIManager(accountManager: am, oauthManager: oauth, dataStore: cache)
        self.accountManager = am
        self.oauthManager = oauth
        self.emailCache = cache
        self.apiManager = api
        self.unifiedMailbox = UnifiedMailbox(apiManager: api)
        self.defaults = .standard

        defaults.register(defaults: [AppState.showDockBadgeKey: true])
        observeDockBadge()
    }

    init(accountManager: AccountManager, apiManager: GmailAPIManager, defaults: UserDefaults = .standard) {
        self.accountManager = accountManager
        self.oauthManager = OAuthManager()
        self.emailCache = EmailCache()
        self.apiManager = apiManager
        self.unifiedMailbox = UnifiedMailbox(apiManager: apiManager)
        self.defaults = defaults

        defaults.register(defaults: [AppState.showDockBadgeKey: true])
        observeDockBadge()
    }

    /// Returns `true` if all accounts were checked successfully (migration complete),
    /// or `false` if any account was skipped due to Keychain errors (retry next launch).
    @discardableResult
    private static func removeLegacyAccounts(accountManager: AccountManager, emailCache: EmailCache) -> Bool {
        var removed = 0
        var hadKeychainError = false
        for account in accountManager.accounts {
            do {
                let tokens = try KeychainHelper.loadTokens(for: account.id)
                if tokens == nil {
                    // errSecItemNotFound — confirmed no tokens, safe to remove
                    logger.info("Removing legacy account without OAuth tokens: \(account.id)")
                    emailCache.clearEmails(for: account.id)
                    accountManager.removeAccount(id: account.id)
                    removed += 1
                }
            } catch {
                // Keychain error (locked, unavailable, corrupt data) — keep the account
                logger.warning("Skipping migration for account \(account.id): Keychain error: \(error.localizedDescription)")
                hadKeychainError = true
            }
        }
        if removed > 0 {
            logger.info("Removed \(removed) legacy account(s) without OAuth tokens")
        }
        return !hadKeychainError
    }

    private func observeDockBadge() {
        badgeCancellable = apiManager.$unreadCountsByAccount
            .sink { [weak self] counts in
                self?.updateDockBadge(counts: counts)
            }
        defaultsCancellable = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateDockBadge(counts: self.apiManager.unreadCountsByAccount)
            }
    }

    func updateDockBadge(counts: [String: Int]) {
        let enabled = defaults.bool(forKey: AppState.showDockBadgeKey)
        guard enabled else {
            NSApp?.dockTile.badgeLabel = nil
            return
        }
        let total = counts.values.reduce(0, +)
        NSApp?.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }
}
