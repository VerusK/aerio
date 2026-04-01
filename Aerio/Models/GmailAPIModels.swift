import Foundation

// MARK: - Message List

struct GmailMessageListResponse: Codable {
    let messages: [GmailMessageRef]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
    let historyId: String?
}

struct GmailMessageRef: Codable {
    let id: String
    let threadId: String
}

// MARK: - Full Message

struct GmailMessage: Codable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let snippet: String?
    let payload: GmailPayload?
    let internalDate: String?
    let historyId: String?
    let sizeEstimate: Int?
}

// MARK: - Thread

struct GmailThread: Codable {
    let id: String
    let messages: [GmailMessage]?
    let historyId: String?
}

struct GmailPayload: Codable {
    let mimeType: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPayload]?
    let filename: String?
}

struct GmailHeader: Codable {
    let name: String
    let value: String
}

struct GmailBody: Codable {
    let attachmentId: String?
    let size: Int?
    let data: String?
}

// MARK: - Attachment

struct GmailAttachment: Codable {
    let attachmentId: String?
    let size: Int?
    let data: String?
}

// MARK: - Labels

struct GmailLabel: Codable {
    let id: String
    let name: String?
    let messageListVisibility: String?
    let labelListVisibility: String?
    let type: String?
    let messagesTotal: Int?
    let messagesUnread: Int?
    let threadsTotal: Int?
    let threadsUnread: Int?
}

struct GmailLabelsResponse: Codable {
    let labels: [GmailLabel]?
}

// MARK: - Modify

struct GmailModifyRequest: Codable {
    let addLabelIds: [String]?
    let removeLabelIds: [String]?
}

// MARK: - Send

struct GmailSendRequest: Codable {
    let raw: String
}

// MARK: - Draft

struct GmailDraftRequest: Codable {
    let message: GmailDraftMessage
}

struct GmailDraftMessage: Codable {
    let raw: String
}

struct GmailDraft: Codable {
    let id: String
    let message: GmailMessage?
}

struct GmailDraftsListResponse: Codable {
    let drafts: [GmailDraftSummary]?
}

struct GmailDraftSummary: Codable {
    let id: String
    let message: GmailDraftMessageRef?
}

struct GmailDraftMessageRef: Codable {
    let id: String
    let threadId: String?
}

// MARK: - History

struct GmailHistoryResponse: Codable {
    let history: [GmailHistoryRecord]?
    let nextPageToken: String?
    let historyId: String?
}

struct GmailHistoryRecord: Codable {
    let id: String
    let messages: [GmailMessage]?
    let messagesAdded: [GmailHistoryMessageAdded]?
    let messagesDeleted: [GmailHistoryMessageDeleted]?
    let labelsAdded: [GmailHistoryLabelAdded]?
    let labelsRemoved: [GmailHistoryLabelRemoved]?
}

struct GmailHistoryMessageAdded: Codable {
    let message: GmailMessage
}

struct GmailHistoryMessageDeleted: Codable {
    let message: GmailMessage
}

struct GmailHistoryLabelAdded: Codable {
    let message: GmailMessage
    let labelIds: [String]
}

struct GmailHistoryLabelRemoved: Codable {
    let message: GmailMessage
    let labelIds: [String]
}

// MARK: - Label ID Constants

enum GmailLabelId {
    static let inbox = "INBOX"
    static let sent = "SENT"
    static let draft = "DRAFT"
    static let spam = "SPAM"
    static let trash = "TRASH"
    static let unread = "UNREAD"
    static let starred = "STARRED"
    static let important = "IMPORTANT"
}
