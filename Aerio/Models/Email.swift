import Foundation

struct Email: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let msgId: String
    let from: String
    let to: String
    let cc: String
    let subject: String
    let date: Date
    let snippet: String
    var isRead: Bool
    let accountId: String
    let folder: Folder
    let messageId: String?
    let threadId: String

    init(
        msgId: String,
        from: String,
        subject: String,
        date: Date,
        snippet: String,
        isRead: Bool = false,
        accountId: String,
        folder: Folder,
        messageId: String? = nil,
        to: String = "",
        cc: String = "",
        threadId: String = ""
    ) {
        self.id = "\(accountId)_\(folder.rawValue)_\(msgId)"
        self.msgId = msgId
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.snippet = snippet
        self.isRead = isRead
        self.accountId = accountId
        self.folder = folder
        self.messageId = messageId
        self.threadId = threadId
    }

    static func sortedByDate(_ emails: [Email], ascending: Bool = false) -> [Email] {
        emails.sorted { ascending ? $0.date < $1.date : $0.date > $1.date }
    }
}
