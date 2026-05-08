import Foundation

struct ComposePayload {
    let from: String
    let to: String
    let cc: String?
    let subject: String
    let body: String
    let inReplyTo: String?
    let references: String?
    let htmlBody: String?
    let attachments: [RFC2822Builder.Attachment]
    let inlineImages: [RFC2822Builder.InlineImage]
    /// Optional `<uuid@aerio.local>` style identifier; when present, embedded as `Message-ID:` header.
    let messageId: String?
}
