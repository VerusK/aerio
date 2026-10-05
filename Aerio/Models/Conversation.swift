import Foundation

/// Messages of one Gmail thread in one folder of one account, shown as a single
/// row in the message list. Drafts and messages without a threadId stay alone.
struct Conversation: Identifiable, Equatable {
    /// `accountId_folder_t_threadId` for a thread, the member's `Email.id` when alone.
    let id: String
    /// Never empty; newest first.
    let messages: [Email]

    var newest: Email { messages[0] }
    var count: Int { messages.count }
    var isUnread: Bool { messages.contains { !$0.isRead } }

    func contains(emailId: String) -> Bool {
        messages.contains { $0.id == emailId }
    }

    /// Groups an already filtered folder view. The order never depends on the input
    /// order: the unified view is built from unordered dictionary values.
    static func group(_ emails: [Email]) -> [Conversation] {
        var buckets: [String: [Email]] = [:]
        for email in emails {
            buckets[key(for: email), default: []].append(email)
        }
        return buckets
            .map { key, members in Conversation(id: key, messages: members.sorted(by: isNewer)) }
            .sorted { lhs, rhs in
                if lhs.newest.date != rhs.newest.date { return lhs.newest.date > rhs.newest.date }
                return lhs.id < rhs.id
            }
    }

    private static func key(for email: Email) -> String {
        if email.threadId.isEmpty || email.folder == .drafts { return email.id }
        return "\(email.accountId)_\(email.folder.rawValue)_t_\(email.threadId)"
    }

    private static func isNewer(_ lhs: Email, _ rhs: Email) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.msgId < rhs.msgId
    }
}

extension Array where Element == Conversation {
    func conversation(containing emailId: String?) -> Conversation? {
        guard let emailId else { return nil }
        return first { $0.contains(emailId: emailId) }
    }

    /// The newest member of the row `offset` rows away, clamped to the list. With no
    /// selection, or one no longer listed, the first row.
    func adjacentSelection(from emailId: String?, offset: Int) -> String? {
        guard !isEmpty else { return nil }
        guard let emailId, let index = firstIndex(where: { $0.contains(emailId: emailId) }) else {
            return first?.newest.id
        }
        let target = Swift.min(Swift.max(index + offset, 0), count - 1)
        return self[target].newest.id
    }

    /// What to select once the row is gone: the next row, else the previous one.
    func selectionAfterRemoving(conversationId: String) -> String? {
        guard let index = firstIndex(where: { $0.id == conversationId }) else { return nil }
        if index + 1 < count { return self[index + 1].newest.id }
        if index > 0 { return self[index - 1].newest.id }
        return nil
    }

    /// The messages an action on `email` applies to: its whole row in this folder.
    func actionTargets(for email: Email) -> [Email] {
        conversation(containing: email.id)?.messages ?? [email]
    }
}
