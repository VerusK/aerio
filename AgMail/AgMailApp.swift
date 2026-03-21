import SwiftUI

@main
struct AgMailApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView(
                accountManager: appState.accountManager,
                unifiedMailbox: appState.unifiedMailbox,
                webViewPool: appState.webViewPool,
                scraperManager: appState.scraperManager
            )
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let accountManager: AccountManager
    let webViewPool: WebViewPool
    let emailCache: EmailCache
    let scraperManager: GmailScraperManager
    let unifiedMailbox: UnifiedMailbox

    init() {
        let am = AccountManager()
        let pool = WebViewPool()
        let cache = EmailCache()
        let sm = GmailScraperManager(accountManager: am, webViewPool: pool, dataStore: cache)
        self.accountManager = am
        self.webViewPool = pool
        self.emailCache = cache
        self.scraperManager = sm
        self.unifiedMailbox = UnifiedMailbox(scraperManager: sm)
    }
}
