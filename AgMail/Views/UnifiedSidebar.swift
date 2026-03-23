import SwiftUI

struct UnifiedSidebar: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var unifiedMailbox: UnifiedMailbox
    let oauthManager: OAuthManager
    @Binding var selectedFolder: Folder
    @Binding var selectedAccountId: String?
    @Binding var expandedFolders: Set<Folder>
    var isFocused: Bool = false
    var isRefreshing: Bool = false
    var onRefresh: (() -> Void)?
    @State private var showingAccountSetup = false
    @State private var editingAccount: Account?

    var body: some View {
        VStack(spacing: 0) {
            Color.accentColor.opacity(isFocused ? 1 : 0).frame(height: 2)
            List {
                ForEach(Folder.allCases) { folder in
                    folderSection(folder)
                }
            }
            .listStyle(.sidebar)

            Divider()

            bottomButtons
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
        .sheet(isPresented: $showingAccountSetup) {
            AccountSetupView(accountManager: accountManager, oauthManager: oauthManager)
        }
        .sheet(item: $editingAccount) { account in
            AccountEditSheet(account: account) { updated in
                accountManager.updateAccount(updated)
            }
        }
    }

    // MARK: - Folder section

    @ViewBuilder
    private func folderSection(_ folder: Folder) -> some View {
        if accountManager.accounts.count > 1 {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedFolders.contains(folder) },
                    set: { newValue in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            if newValue { expandedFolders.insert(folder) }
                            else { expandedFolders.remove(folder) }
                        }
                    }
                )
            ) {
                ForEach(accountManager.accounts) { account in
                    accountRow(account, folder: folder)
                }
            } label: {
                folderLabel(folder)
            }
            .listRowBackground(
                selectedFolder == folder && selectedAccountId == nil
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
            .accessibilityIdentifier("folder-\(folder.rawValue)")
        } else {
            folderLabel(folder)
                .listRowBackground(
                    selectedFolder == folder && selectedAccountId == nil
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear
                )
                .accessibilityIdentifier("folder-\(folder.rawValue)")
        }
    }

    private func folderLabel(_ folder: Folder) -> some View {
        let isActive = selectedFolder == folder
        return HStack {
            Image(systemName: folder.iconName)
                .frame(width: 20)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(folder.displayName)
                .lineLimit(1)
                .fontWeight(isActive ? .semibold : .regular)
            Spacer()
            let count = folder == .drafts
                ? unifiedMailbox.totalCount(for: folder)
                : unifiedMailbox.unreadCount(for: folder)
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedFolder = folder
            selectedAccountId = nil
        }
    }

    // MARK: - Account row

    private func accountRow(_ account: Account, folder: Folder) -> some View {
        let isSelected = selectedFolder == folder && selectedAccountId == account.id
        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(account.color.swiftUIColor)
                    .frame(width: 22, height: 22)
                Circle()
                    .strokeBorder(account.color.swiftUIColor.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                Text(account.initials)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(account.email)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            let count = folder == .drafts
                ? unifiedMailbox.totalCount(for: folder, accountId: account.id)
                : unifiedMailbox.unreadCount(for: folder, accountId: account.id)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedFolder = folder
            selectedAccountId = account.id
        }
        .listRowBackground(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear
        )
        .accessibilityIdentifier("folder-\(folder.rawValue)-account-\(account.id)")
        .contextMenu {
            Button {
                editingAccount = account
            } label: {
                Label("Edit Account", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                removeAccount(account)
            } label: {
                Label("Remove Account", systemImage: "trash")
            }
        }
    }

    // MARK: - Bottom buttons

    private var bottomButtons: some View {
        HStack(spacing: 12) {
            Button {
                showingAccountSetup = true
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .help("Add Account")
            .accessibilityIdentifier("account-add")

            Spacer()

            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            } else {
                Button {
                    onRefresh?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .help("Refresh (⌘⇧E)")
                .accessibilityIdentifier("refresh-button")
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-button")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func removeAccount(_ account: Account) {
        if selectedAccountId == account.id {
            selectedAccountId = nil
        }
        accountManager.removeAccount(id: account.id)
    }
}

// MARK: - Account Edit Sheet

struct AccountEditSheet: View {
    @State private var editedName: String
    @State private var editedColor: AccountColor
    private let account: Account
    private let onSave: (Account) -> Void
    @Environment(\.dismiss) private var dismiss

    init(account: Account, onSave: @escaping (Account) -> Void) {
        self.account = account
        self.onSave = onSave
        _editedName = State(initialValue: account.displayName)
        _editedColor = State(initialValue: account.color)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Account")
                .font(.headline)

            // Avatar preview
            ZStack {
                Circle()
                    .fill(editedColor.swiftUIColor)
                    .frame(width: 48, height: 48)
                Circle()
                    .strokeBorder(editedColor.swiftUIColor.opacity(0.6), lineWidth: 2)
                    .frame(width: 48, height: 48)
                Text(Account.computeInitials(from: editedName))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(account.email)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                TextField("Display Name", text: $editedName)
                    .accessibilityIdentifier("edit-account-name")

                Picker("Color", selection: $editedColor) {
                    ForEach(AccountColor.allCases, id: \.self) { color in
                        HStack {
                            Circle()
                                .fill(color.swiftUIColor)
                                .frame(width: 12, height: 12)
                            Text(color.rawValue.capitalized)
                        }
                        .tag(color)
                    }
                }
                .accessibilityIdentifier("edit-account-color")
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    var updated = account
                    updated.displayName = editedName
                    updated.color = editedColor
                    updated.avatarLetter = String(editedName.prefix(1)).uppercased()
                    onSave(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editedName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 320, height: 360)
    }
}

