import Foundation

/// Wire-protocol abstraction used by OutboxService. Production: GmailAPIClient.
/// Tests: MockOutboxSender. All conforming types operate inside @MainActor in production,
/// so we don't require Sendable.
protocol OutboxSender: AnyObject {
    func sendMessage(rawBase64URL: String, threadId: String?) async throws -> GmailMessage
    func findInSent(messageId: String) async throws -> Bool
    func deleteDraft(draftId: String) async throws
    func modifyMessage(id: String, addLabels: [String]?, removeLabels: [String]?) async throws -> GmailMessage
}
