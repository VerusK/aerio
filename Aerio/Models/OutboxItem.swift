import Foundation
import SwiftData

enum OutboxStatus: String, Sendable {
    case pending
    case sending
    case failed
}

@Model
final class OutboxItem {
    @Attribute(.unique) var id: UUID
    var accountId: String
    var rawMime: Data
    var messageIdHeader: String
    var threadId: String?
    var draftIdToConsume: String?
    var subject: String
    var recipientsPreview: String

    /// Human-readable composed content, stored so a failed/queued send can be
    /// recovered (copied back, or re-edited) without parsing `rawMime`.
    /// Defaulted for lightweight SwiftData migration of pre-existing items.
    var toRecipients: String = ""
    var ccRecipients: String = ""
    var bodyText: String = ""

    /// Raw storage for SwiftData; use `status` accessor.
    var statusRaw: String
    var attemptCount: Int
    var lastError: String?
    var createdAt: Date
    var nextAttemptAt: Date

    /// If set, after successful send remove INBOX label from this msgId on this account.
    var archiveOnSuccessForMsgId: String?
    var archiveOnSuccessForAccountId: String?

    var status: OutboxStatus {
        get { OutboxStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID,
        accountId: String,
        rawMime: Data,
        messageIdHeader: String,
        threadId: String?,
        draftIdToConsume: String?,
        subject: String,
        recipientsPreview: String,
        status: OutboxStatus,
        attemptCount: Int,
        createdAt: Date,
        nextAttemptAt: Date,
        archiveOnSuccessForMsgId: String?,
        archiveOnSuccessForAccountId: String?,
        toRecipients: String = "",
        ccRecipients: String = "",
        bodyText: String = ""
    ) {
        self.id = id
        self.accountId = accountId
        self.rawMime = rawMime
        self.messageIdHeader = messageIdHeader
        self.threadId = threadId
        self.draftIdToConsume = draftIdToConsume
        self.subject = subject
        self.recipientsPreview = recipientsPreview
        self.toRecipients = toRecipients
        self.ccRecipients = ccRecipients
        self.bodyText = bodyText
        self.statusRaw = status.rawValue
        self.attemptCount = attemptCount
        self.lastError = nil
        self.createdAt = createdAt
        self.nextAttemptAt = nextAttemptAt
        self.archiveOnSuccessForMsgId = archiveOnSuccessForMsgId
        self.archiveOnSuccessForAccountId = archiveOnSuccessForAccountId
    }
}
