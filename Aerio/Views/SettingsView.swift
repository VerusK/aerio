import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var emailCache: EmailCache
    @AppStorage(AppState.showDockBadgeKey) private var showDockBadge = true
    @AppStorage(AppState.downloadsDirectoryKey) private var downloadsDirectory = ""
    @AppStorage(AppState.pollIntervalKey) private var pollInterval = AppState.defaultPollInterval
    @AppStorage(AppState.cacheRetentionDaysKey) private var cacheRetentionDays = AppState.defaultCacheRetentionDays
    @AppStorage(AppState.archiveOnReplyKey) private var archiveOnReply = true
    @State private var cacheDetails: [(name: String, path: String, size: Int64)] = []
    @State private var contentCacheCount: Int = 0
    @State private var cacheTotal: String = "Calculating…"

    private var shortcuts: [ShortcutAction] {
        ShortcutAction.allCases.filter {
            $0 != .openSettings && $0 != .nextMessageAlt && $0 != .previousMessageAlt && $0 != .sendMessage
        }
    }

    private var downloadsDisplayPath: String {
        if downloadsDirectory.isEmpty {
            return defaultDownloadsPath
        }
        return (downloadsDirectory as NSString).abbreviatingWithTildeInPath
    }

    private var defaultDownloadsPath: String {
        let path = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads"
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private var isCustomDownloadsDirectory: Bool {
        guard !downloadsDirectory.isEmpty else { return false }
        let defaultPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads"
        return downloadsDirectory != defaultPath
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show unread count on dock icon", isOn: $showDockBadge)
                Toggle("Archive messages after replying from Inbox", isOn: $archiveOnReply)

                HStack {
                    Text("Save attachments to:")
                    Spacer()
                    Text(downloadsDisplayPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") {
                        pickDownloadsDirectory()
                    }
                }
                if isCustomDownloadsDirectory {
                    Button("Reset to default (~/Downloads)") {
                        downloadsDirectory = ""
                    }
                    .font(.caption)
                }

                HStack {
                    Text("Check for new mail every")
                    TextField("", value: $pollInterval, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("sec")
                        .foregroundStyle(.secondary)
                }
                if pollInterval < 10 {
                    Text("Values below 10 seconds may cause rate limiting")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("Delete cached messages older than")
                    TextField("", value: $cacheRetentionDays, format: .number)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Text("days")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cache") {
                if contentCacheCount > 0 {
                    HStack {
                        Text("Cached message bodies")
                        Spacer()
                        Text("\(contentCacheCount)")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(cacheDetails, id: \.path) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        Text(item.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                HStack {
                    Text("Total")
                        .fontWeight(.medium)
                    Spacer()
                    Text(cacheTotal)
                        .foregroundStyle(.secondary)
                        .fontWeight(.medium)
                }
                Button("Clear Cache") {
                    clearCache()
                }
                .font(.caption)
            }

            Section("Keyboard Shortcuts") {
                ForEach(shortcuts, id: \.self) { action in
                    HStack {
                        Text(action.displayName)
                        Spacer()
                        Text(action.shortcutLabel)
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(width: 400, height: 600)
        .onAppear {
            calculateCacheSize()
            contentCacheCount = emailCache.contentCacheCount
        }
    }

    private func pickDownloadsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to save attachments"
        if panel.runModal() == .OK, let url = panel.url {
            let defaultPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads"
            downloadsDirectory = url.path == defaultPath ? "" : url.path
        }
    }

    private func calculateCacheSize() {
        Task.detached {
            let fm = FileManager.default
            var items: [(name: String, path: String, size: Int64)] = []

            // SwiftData store files (default.store*)
            if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let storeSize = Self.directorySize(at: appSupport, matching: { $0.lastPathComponent.hasPrefix("default.store") })
                if storeSize > 0 {
                    items.append((
                        name: "Email database (SwiftData)",
                        path: (appSupport.path as NSString).abbreviatingWithTildeInPath,
                        size: storeSize
                    ))
                }
            }

            // URL/WebKit caches
            if let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let bundleId = Bundle.main.bundleIdentifier ?? "com.aerio.Aerio"
                let appCacheDir = cachesDir.appendingPathComponent(bundleId)
                let cacheSize = Self.directorySize(at: appCacheDir)
                if cacheSize > 0 {
                    items.append((
                        name: "Network & WebKit cache",
                        path: (appCacheDir.path as NSString).abbreviatingWithTildeInPath,
                        size: cacheSize
                    ))
                }
            }

            let total = items.reduce(Int64(0)) { $0 + $1.size }
            let formatted = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            await MainActor.run {
                cacheDetails = items
                cacheTotal = formatted
            }
        }
    }

    private static func directorySize(at url: URL, matching filter: ((URL) -> Bool)? = nil) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0

        if let filter {
            // Match only specific files in this directory (non-recursive)
            guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            for fileURL in contents where filter(fileURL) {
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                total += Int64(size)
            }
        } else {
            // Recursively sum all files
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
            while let fileURL = enumerator.nextObject() as? URL {
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func clearCache() {
        let fm = FileManager.default

        // Remove SwiftData store files
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let contents = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) {
            for fileURL in contents where fileURL.lastPathComponent.hasPrefix("default.store") {
                try? fm.removeItem(at: fileURL)
            }
        }

        // Remove app caches
        if let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let bundleId = Bundle.main.bundleIdentifier ?? "com.aerio.Aerio"
            let appCacheDir = cachesDir.appendingPathComponent(bundleId)
            try? fm.removeItem(at: appCacheDir)
        }

        emailCache.clearContent()

        cacheDetails = []
        cacheTotal = "0 bytes"
        contentCacheCount = 0
    }

    static func resolvedDownloadsDirectory() -> URL {
        let saved = UserDefaults.standard.string(forKey: AppState.downloadsDirectoryKey) ?? ""
        if !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}

