import Foundation
import WebKit

@MainActor
final class WebViewPool: ObservableObject {
    struct PoolEntry {
        let accountId: String
        let dataStore: WKWebsiteDataStore
        let hiddenWebView: WKWebView
        let visibleWebView: WKWebView
        let composeWebView: WKWebView
    }

    private(set) var entries: [String: PoolEntry] = [:]

    func createWebViews(for accountId: String) -> PoolEntry {
        if let existing = entries[accountId] {
            return existing
        }

        let dataStore: WKWebsiteDataStore
        if let uuid = UUID(uuidString: accountId) {
            dataStore = WKWebsiteDataStore(forIdentifier: uuid)
        } else {
            dataStore = WKWebsiteDataStore.nonPersistent()
        }

        let hiddenConfig = WKWebViewConfiguration()
        hiddenConfig.websiteDataStore = dataStore

        let visibleConfig = WKWebViewConfiguration()
        visibleConfig.websiteDataStore = dataStore

        let hiddenWebView = WKWebView(frame: .zero, configuration: hiddenConfig)
        let visibleWebView = WKWebView(frame: .zero, configuration: visibleConfig)

        let composeConfig = WKWebViewConfiguration()
        composeConfig.websiteDataStore = dataStore
        let composeWebView = WKWebView(frame: .zero, configuration: composeConfig)

        let entry = PoolEntry(
            accountId: accountId,
            dataStore: dataStore,
            hiddenWebView: hiddenWebView,
            visibleWebView: visibleWebView,
            composeWebView: composeWebView
        )
        entries[accountId] = entry
        return entry
    }

    func removeWebViews(for accountId: String) {
        guard let entry = entries.removeValue(forKey: accountId) else { return }
        entry.hiddenWebView.stopLoading()
        entry.hiddenWebView.navigationDelegate = nil
        entry.visibleWebView.stopLoading()
        entry.visibleWebView.navigationDelegate = nil
        entry.composeWebView.stopLoading()
        entry.composeWebView.navigationDelegate = nil
        let dataStore = entry.dataStore
        dataStore.fetchDataRecords(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()
        ) { records in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: records
            ) {}
        }
    }

    func entry(for accountId: String) -> PoolEntry? {
        entries[accountId]
    }

    func removeAll() {
        let allIds = Array(entries.keys)
        for id in allIds {
            removeWebViews(for: id)
        }
    }
}
