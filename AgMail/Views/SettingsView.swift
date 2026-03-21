import SwiftUI

struct SettingsView: View {
    @AppStorage(AppState.showDockBadgeKey) private var showDockBadge = true

    private var shortcuts: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0 != .openSettings && $0 != .nextMessageAlt && $0 != .previousMessageAlt }
    }

    var body: some View {
        Form {
            Section("Dock Badge") {
                Toggle("Show unread count on dock icon", isOn: $showDockBadge)
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
}
