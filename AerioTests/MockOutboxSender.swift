import Foundation
@testable import Aerio

actor MockOutboxSender: OutboxSender {
    enum Behavior {
        case success(GmailMessage)
        case throwError(Error)
    }

    static let defaultSentMessage = GmailMessage(
        id: "sent-1", threadId: "t1", labelIds: [],
        snippet: nil, payload: nil, internalDate: nil,
        historyId: nil, sizeEstimate: nil
    )

    var sendBehavior: Behavior = .success(MockOutboxSender.defaultSentMessage)
    var findInSentReturns: Bool = false
    var deleteDraftThrows: Error?
    var modifyMessageThrows: Error?

    private(set) var sendMessageCalls: [(raw: String, threadId: String?)] = []
    private(set) var findInSentCalls: [String] = []
    private(set) var deleteDraftCalls: [String] = []
    private(set) var modifyMessageCalls: [(id: String, add: [String]?, remove: [String]?)] = []

    func setSendBehavior(_ b: Behavior) { sendBehavior = b }
    func setFindInSent(_ v: Bool) { findInSentReturns = v }
    func setDeleteDraftThrows(_ e: Error?) { deleteDraftThrows = e }
    func setModifyMessageThrows(_ e: Error?) { modifyMessageThrows = e }

    func sendMessage(rawBase64URL: String, threadId: String?) async throws -> GmailMessage {
        sendMessageCalls.append((rawBase64URL, threadId))
        switch sendBehavior {
        case .success(let m): return m
        case .throwError(let e): throw e
        }
    }

    func findInSent(messageId: String) async throws -> Bool {
        findInSentCalls.append(messageId)
        return findInSentReturns
    }

    func deleteDraft(draftId: String) async throws {
        deleteDraftCalls.append(draftId)
        if let e = deleteDraftThrows { throw e }
    }

    func modifyMessage(id: String, addLabels: [String]?, removeLabels: [String]?) async throws -> GmailMessage {
        modifyMessageCalls.append((id, addLabels, removeLabels))
        if let e = modifyMessageThrows { throw e }
        return GmailMessage(
            id: id, threadId: "t1", labelIds: nil,
            snippet: nil, payload: nil, internalDate: nil,
            historyId: nil, sizeEstimate: nil
        )
    }
}
