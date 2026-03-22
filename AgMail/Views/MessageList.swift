import SwiftUI

struct MessageList: View {
    @ObservedObject var unifiedMailbox: UnifiedMailbox
    @ObservedObject var accountManager: AccountManager
    @Binding var selectedEmailId: String?
    var selectedFolder: Folder
    var selectedAccountId: String?
    var onReply: ((Email) -> Void)?
    var onReplyAll: ((Email) -> Void)?
    var onForward: ((Email) -> Void)?
    var onArchive: ((Email) -> Void)?
    var onDelete: ((Email) -> Void)?
    var onSpam: ((Email) -> Void)?
    var onMoveToInbox: ((Email) -> Void)?
    var onLoadMore: (() -> Void)?
    var hasMoreEmails: Bool = false
    var processingEmailId: String? = nil

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filteredEmails) { email in
                    let isProcessing = processingEmailId == email.id
                    let isSelected = selectedEmailId == email.id
                    MessageRow(
                        email: email,
                        account: accountManager.account(for: email.accountId),
                        showAccountIndicator: selectedAccountId == nil
                    )
                    .id(email.id)
                    .listRowBackground(
                        isSelected
                            ? Color.accentColor.opacity(0.25)
                            : nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isProcessing {
                            selectedEmailId = email.id
                        }
                    }
                    .overlay {
                        if isProcessing {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Processing…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background.opacity(0.8))
                        }
                    }
                    .opacity(isProcessing ? 0.6 : 1.0)
                    .contextMenu {
                        contextMenuItems(for: email)
                    }
                }

                if hasMoreEmails {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .onAppear {
                        onLoadMore?()
                    }
                    .accessibilityIdentifier("load-more-sentinel")
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 250)
            .onChange(of: filteredEmails.count) {
                if let selectedEmailId {
                    proxy.scrollTo(selectedEmailId, anchor: nil)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for email: Email) -> some View {
        Button {
            onReply?(email)
        } label: {
            Text("Reply  \(ShortcutAction.reply.shortcutLabel)")
            Image(systemName: "arrowshape.turn.up.left")
        }

        Button {
            onReplyAll?(email)
        } label: {
            Text("Reply All  \(ShortcutAction.replyAll.shortcutLabel)")
            Image(systemName: "arrowshape.turn.up.left.2")
        }

        Button {
            onForward?(email)
        } label: {
            Text("Forward  \(ShortcutAction.forward.shortcutLabel)")
            Image(systemName: "arrowshape.turn.up.right")
        }

        Divider()

        if selectedFolder == .inbox {
            Button {
                onArchive?(email)
            } label: {
                Text("Archive  \(ShortcutAction.archiveMessage.shortcutLabel)")
                Image(systemName: "archivebox")
            }
        }

        if selectedFolder != .inbox {
            Button {
                onMoveToInbox?(email)
            } label: {
                Text("Move to Inbox  \(ShortcutAction.moveToInbox.shortcutLabel)")
                Image(systemName: "tray.and.arrow.down")
            }
        }

        Button {
            onDelete?(email)
        } label: {
            Text("Delete  \(ShortcutAction.deleteMessage.shortcutLabel)")
            Image(systemName: "trash")
        }

        Button(role: .destructive) {
            onSpam?(email)
        } label: {
            Text("Spam  \(ShortcutAction.spamMessage.shortcutLabel)")
            Image(systemName: "exclamationmark.octagon")
        }
    }

    var filteredEmails: [Email] {
        unifiedMailbox.emails(for: selectedFolder, accountId: selectedAccountId)
    }
}

extension Date {
    private static let monthDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt
    }()
    private static let shortDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d/yy"
        return fmt
    }()

    var shortRelative: String {
        let now = Date()
        let interval = now.timeIntervalSince(self)
        let cal = Calendar.current

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400 && cal.isDateInToday(self) {
            return "\(Int(interval / 3600))h"
        } else if cal.isDateInYesterday(self) {
            return "Yesterday"
        } else if cal.component(.year, from: self) == cal.component(.year, from: now) {
            return Self.monthDayFormatter.string(from: self)
        } else {
            return Self.shortDateFormatter.string(from: self)
        }
    }
}

struct MessageRow: View {
    let email: Email
    let account: Account?
    let showAccountIndicator: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showAccountIndicator {
                Circle()
                    .fill(account?.color.swiftUIColor ?? .gray)
                    .frame(width: 8, height: 8)
                    .accessibilityIdentifier("account-indicator-\(email.accountId)")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(email.from)
                        .font(.system(size: 13, weight: email.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(email.date.shortRelative)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(email.subject)
                    .font(.system(size: 12, weight: email.isRead ? .regular : .medium))
                    .lineLimit(1)

                Text(email.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .opacity(email.isRead ? 0.75 : 1.0)
        .accessibilityIdentifier("message-\(email.msgId)")
    }
}
