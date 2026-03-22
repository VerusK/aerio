import SwiftUI

struct SettingsView: View {
    @AppStorage(AppState.showDockBadgeKey) private var showDockBadge = true
    @AppStorage(AppState.downloadsDirectoryKey) private var downloadsDirectory = ""

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
            Section("Dock Badge") {
                Toggle("Show unread count on dock icon", isOn: $showDockBadge)
            }

            Section("Downloads") {
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
        .frame(width: 400, height: 500)
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

    static func resolvedDownloadsDirectory() -> URL {
        let saved = UserDefaults.standard.string(forKey: AppState.downloadsDirectoryKey) ?? ""
        if !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}
