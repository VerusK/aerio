import SwiftUI

struct MessageList: View {
    @ObservedObject var unifiedMailbox: UnifiedMailbox
    @ObservedObject var accountManager: AccountManager
    @Binding var selectedEmailId: String?
    var selectedFolder: Folder
    var selectedAccountId: String?

    var body: some View {
        List(filteredEmails, selection: $selectedEmailId) { email in
            MessageRow(
                email: email,
                account: accountManager.account(for: email.accountId),
                showAccountIndicator: selectedAccountId == nil
            )
            .tag(email.id)
        }
        .listStyle(.inset)
        .frame(minWidth: 250)
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
