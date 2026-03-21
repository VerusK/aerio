import SwiftUI

struct AccountSidebar: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var unifiedMailbox: UnifiedMailbox
    let oauthManager: OAuthManager
    var apiManager: GmailAPIManager?
    @Binding var selectedAccountId: String?
    @State private var showingAccountSetup = false

    var body: some View {
        VStack(spacing: 12) {
            allAccountsButton
            Divider()
            ForEach(accountManager.accounts) { account in
                accountButton(for: account)
            }
            Spacer()
            addAccountButton
            settingsButton
        }
        .padding(.vertical, 8)
        .frame(width: 56)
        .sheet(isPresented: $showingAccountSetup) {
            AccountSetupView(accountManager: accountManager, oauthManager: oauthManager)
        }
    }

    private var settingsButton: some View {
        Button {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-button")
    }

    private var addAccountButton: some View {
        Button {
            showingAccountSetup = true
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 36, height: 36)
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account-add")
    }

    private var allAccountsButton: some View {
        let totalUnread = unifiedMailbox.unreadCount(for: .inbox)
        return Button {
            selectedAccountId = nil
        } label: {
            ZStack {
                Circle()
                    .fill(selectedAccountId == nil ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 36, height: 36)
                Text("All")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selectedAccountId == nil ? .white : .primary)
                if totalUnread > 0 {
                    Text(totalUnread > 99 ? "99+" : "\(totalUnread)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 12, y: -12)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account-all")
    }

    private func accountButton(for account: Account) -> some View {
        Button {
            selectedAccountId = account.id
        } label: {
            ZStack {
                Circle()
                    .fill(selectedAccountId == account.id ? account.color.swiftUIColor : account.color.swiftUIColor.opacity(0.3))
                    .frame(width: 36, height: 36)
                Text(account.avatarLetter)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selectedAccountId == account.id ? .white : .primary)
                unreadBadge(for: account)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account-\(account.id)")
        .contextMenu {
            Button(role: .destructive) {
                removeAccount(account)
            } label: {
                Label("Remove Account", systemImage: "trash")
            }
        }
    }

    private func removeAccount(_ account: Account) {
        if selectedAccountId == account.id {
            selectedAccountId = nil
        }
        // removeClient is triggered automatically by GmailAPIManager's account observation
        accountManager.removeAccount(id: account.id)
    }

    private func unreadBadge(for account: Account) -> some View {
        let count = unifiedMailbox.unreadCount(for: .inbox, accountId: account.id)
        return Group {
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red)
                    .clipShape(Capsule())
                    .offset(x: 12, y: -12)
            }
        }
    }
}
