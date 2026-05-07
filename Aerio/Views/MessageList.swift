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

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filteredEmails) { email in
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
                        selectedEmailId = email.id
                    }
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
            .onChange(of: selectedEmailId) { _, newValue in
                if let newValue {
                    // Use .center so the selected row is always clearly visible.
                    // anchor: nil on macOS List often fails to scroll when the row
                    // is technically "partially visible" or just off-screen.
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .onChange(of: selectedFolder) { _, _ in
                // Scroll to top when switching folders
                if let first = filteredEmails.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
            .onChange(of: selectedAccountId) { _, _ in
                if let first = filteredEmails.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
        // Recreate List only when the top row changes (new email arrived or top archived) —
        // macOS List won't recalc content size on prepend otherwise, hiding new rows.
        // Keyed on first id only, NOT on count — that's what made every poll/archive freeze.
        .id(filteredEmails.first?.id ?? "")
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
        // Use @Published emails directly so SwiftUI detects changes
        unifiedMailbox.emails
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
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(email.date.shortRelative)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Text(email.subject)
                    .font(.system(size: 12, weight: email.isRead ? .regular : .medium))
                    .foregroundStyle(email.isRead ? .secondary : .primary)
                    .lineLimit(1)

                Text(email.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("message-\(email.msgId)")
    }
}
