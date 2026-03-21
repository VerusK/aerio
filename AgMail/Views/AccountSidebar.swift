import SwiftUI

struct AccountSidebar: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var unifiedMailbox: UnifiedMailbox
    @ObservedObject var webViewPool: WebViewPool
    var scraperManager: GmailScraperManager?
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
        }
        .padding(.vertical, 8)
        .frame(width: 64)
        .sheet(isPresented: $showingAccountSetup) {
            AccountSetupView(accountManager: accountManager, webViewPool: webViewPool)
        }
    }

    private var addAccountButton: some View {
        Button {
            showingAccountSetup = true
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 48, height: 48)
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account-add")
    }

    private var allAccountsButton: some View {
        Button {
            selectedAccountId = nil
        } label: {
            ZStack {
                Circle()
                    .fill(selectedAccountId == nil ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 48, height: 48)
                Text("All")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selectedAccountId == nil ? .white : .primary)
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
                    .frame(width: 48, height: 48)
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
        scraperManager?.removeScraper(for: account.id)
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
                    .offset(x: 16, y: -16)
            }
        }
    }
}
