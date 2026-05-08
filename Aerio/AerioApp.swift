import SwiftUI
import Combine
import CoreServices
import UserNotifications
import os.log

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Prevent WindowGroup from creating a new window when the app is reactivated
    /// (e.g. clicking a notification or Dock icon when already running)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Bring existing window back if it was closed/minimized
            sender.windows.first { $0.className != "NSStatusBarWindow" }?.makeKeyAndOrderFront(nil)
        }
        return false
    }
}

@main
struct AerioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    init() {
        UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay")
        // Register with Launch Services so notification clicks don't show
        // "The application can't be opened" when running from a build directory
        if let bundleURL = Bundle.main.bundleURL as CFURL? {
            LSRegisterURL(bundleURL, true)
        }
        // Close Settings window on Escape
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  let window = event.window,
                  window.styleMask.contains(.titled),
                  window.title == "Settings" else { return event }
            window.close()
            return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView(
                accountManager: appState.accountManager,
                unifiedMailbox: appState.unifiedMailbox,
                apiManager: appState.apiManager,
                oauthManager: appState.oauthManager,
                contactsCache: appState.contactsCache,
                notificationManager: appState.notificationManager
            )
            .environmentObject(appState.outboxService)
            .background(WindowAccessor())
            .navigationTitle("")
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            // Suppress default Cmd+N "New Window" — KeyEventMonitor
            // handles it as "Compose new email"
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environmentObject(appState.emailCache)
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
    let contactsCache: ContactsCache
    let notificationManager: NotificationManager
    let outboxStore: OutboxStore
    let outboxService: OutboxService
    let defaults: UserDefaults
    private var badgeCancellable: AnyCancellable?
    private var defaultsCancellable: AnyCancellable?
    var badgeCountHandler: ((Int) -> Void)?

    static let showDockBadgeKey = "showDockBadge"
    static let downloadsDirectoryKey = "downloadsDirectory"
    static let pollIntervalKey = "pollInterval"
    static let defaultPollInterval: Double = 45
    static let sendDelaySecondsKey = "sendDelaySeconds"
    static let defaultSendDelaySeconds: Int = 15
    static let cacheRetentionDaysKey = "cacheRetentionDays"
    static let defaultCacheRetentionDays: Int = 30
    static let archiveOnReplyKey = "archiveOnReply"

    private static let logger = Logger(subsystem: "Aerio", category: "AppState")

    init() {
        let am = AccountManager()
        let isTestHost = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        let keychain: KeychainStore = isTestHost ? InMemoryKeychainStore() : KeychainHelper.shared
        let oauth = OAuthManager(keychainStore: keychain)
        let cache = EmailCache()

        let api = GmailAPIManager(accountManager: am, oauthManager: oauth, dataStore: cache, keychainStore: keychain)
        let contacts = ContactsCache()
        api.contactsCache = contacts
        let notifications = NotificationManager()
        api.notificationManager = notifications
        let outboxStore = OutboxStore()
        let sendersByAccount: [String: OutboxSender] = api.clients.mapValues { $0 as OutboxSender }
        let outbox = OutboxService(
            store: outboxStore,
            sendersByAccount: sendersByAccount,
            notifier: OutboxNotifier(manager: notifications),
            postSendRefresh: { [weak api] in await api?.refreshAll() }
        )
        self.accountManager = am
        self.oauthManager = oauth
        self.emailCache = cache
        self.apiManager = api
        self.unifiedMailbox = UnifiedMailbox(apiManager: api)
        self.contactsCache = contacts
        self.notificationManager = notifications
        self.outboxStore = outboxStore
        self.outboxService = outbox
        self.defaults = .standard

        defaults.register(defaults: [
            AppState.showDockBadgeKey: true,
            AppState.pollIntervalKey: AppState.defaultPollInterval,
            AppState.cacheRetentionDaysKey: AppState.defaultCacheRetentionDays,
            AppState.archiveOnReplyKey: true,
            AppState.sendDelaySecondsKey: AppState.defaultSendDelaySeconds
        ])
        observeDockBadge()

        // Purge expired cached message bodies
        let retentionDays = defaults.integer(forKey: AppState.cacheRetentionDaysKey)
        cache.purgeOldContent(olderThanDays: retentionDays > 0 ? retentionDays : AppState.defaultCacheRetentionDays)

        Task {
            await notifications.requestPermission()
        }

        // Outbox: resume any items stuck in .sending from a previous run, then start the loop.
        Task { @MainActor in
            do { _ = try await outbox.resumeOnLaunch() }
            catch { Self.logger.error("outbox resumeOnLaunch failed: \(error.localizedDescription)") }
            outbox.startLoop()
        }

        // Wire Retry-from-notification handler.
        notifications.onOutboxRetry = { [weak outbox] itemId in
            Task { @MainActor in try? await outbox?.retry(itemId: itemId) }
        }

        // Keep Outbox senders in sync with active GmailAPIManager.clients.
        // GmailAPIManager.clients is @Published — react to changes.
        Task { @MainActor [weak api, weak outbox] in
            guard let api else { return }
            for await clients in api.$clients.values {
                outbox?.setSenders(clients.mapValues { $0 as OutboxSender })
            }
        }
    }

    init(accountManager: AccountManager, apiManager: GmailAPIManager, defaults: UserDefaults = .standard, notificationManager: NotificationManager? = nil, keychainStore: KeychainStore = KeychainHelper.shared) {
        self.accountManager = accountManager
        self.oauthManager = OAuthManager(keychainStore: keychainStore)
        self.emailCache = EmailCache()
        self.apiManager = apiManager
        self.unifiedMailbox = UnifiedMailbox(apiManager: apiManager)
        let contacts = ContactsCache()
        self.contactsCache = contacts
        apiManager.contactsCache = contacts
        let notifications = notificationManager ?? NotificationManager()
        self.notificationManager = notifications
        let outboxStore = OutboxStore(inMemory: true)
        self.outboxStore = outboxStore
        self.outboxService = OutboxService(
            store: outboxStore, sendersByAccount: [:],
            notifier: OutboxNotifier(manager: notifications),
            postSendRefresh: { }
        )
        self.defaults = defaults

        defaults.register(defaults: [
            AppState.showDockBadgeKey: true,
            AppState.pollIntervalKey: AppState.defaultPollInterval,
            AppState.cacheRetentionDaysKey: AppState.defaultCacheRetentionDays,
            AppState.archiveOnReplyKey: true,
            AppState.sendDelaySecondsKey: AppState.defaultSendDelaySeconds
        ])
        observeDockBadge()
    }


    private func observeDockBadge() {
        badgeCancellable = apiManager.$unreadCountsByAccount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] counts in
                self?.updateDockBadge(counts: counts)
            }
        defaultsCancellable = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateDockBadge(counts: self.apiManager.unreadCountsByAccount)
            }
    }

    func updateDockBadge(counts: [String: Int]) {
        let enabled = defaults.bool(forKey: AppState.showDockBadgeKey)
        guard enabled else {
            setBadgeCount(0)
            return
        }
        let total = counts.values.reduce(0, +)
        setBadgeCount(total)
    }

    private func setBadgeCount(_ count: Int) {
        if let handler = badgeCountHandler {
            handler(count)
            return
        }
        Task {
            do {
                try await UNUserNotificationCenter.current().setBadgeCount(count)
            } catch {
                Self.logger.warning("Failed to set badge count: \(error.localizedDescription)")
            }
        }
    }
}
