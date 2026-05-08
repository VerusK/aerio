import Foundation
import os.log

private let logger = Logger(subsystem: "Aerio", category: "OutboxService")

/// Receives notifications about outbox item lifecycle. Production: OutboxNotifier (in NotificationManager.swift).
/// Tests: NoopNotifier or RecordingNotifier.
protocol OutboxNotifying: Sendable {
    func notifySuccess(item: OutboxItem) async
    func notifyFailure(item: OutboxItem, permanent: Bool) async
}

@MainActor
final class OutboxService: ObservableObject {
    @Published private(set) var items: [OutboxItem] = []

    private let store: OutboxStore
    private var sendersByAccount: [String: OutboxSender]
    private let notifier: OutboxNotifying
    private let postSendRefresh: @MainActor () async -> Void
    private let now: @Sendable () -> Date

    private var processTask: Task<Void, Never>?
    private var nextWakeTimer: Task<Void, Never>?
    private var signalContinuation: AsyncStream<Void>.Continuation?
    private var signalStream: AsyncStream<Void>?

    init(
        store: OutboxStore,
        sendersByAccount: [String: OutboxSender],
        notifier: OutboxNotifying,
        postSendRefresh: @escaping @MainActor () async -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.sendersByAccount = sendersByAccount
        self.notifier = notifier
        self.postSendRefresh = postSendRefresh
        self.now = now
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.signalStream = stream
        self.signalContinuation = continuation
    }

    func setSenders(_ senders: [String: OutboxSender]) {
        self.sendersByAccount = senders
    }

    func enqueue(_ item: OutboxItem) async throws {
        try await store.insert(item)
        await reloadItems()
        signal()
    }

    private func reloadItems() async {
        do {
            items = try await store.allItems()
        } catch {
            logger.error("Failed to reload outbox items: \(error.localizedDescription)")
        }
    }

    private func signal() {
        signalContinuation?.yield()
    }
}

// MARK: - Processing

extension OutboxService {
    /// Processes one ready item if any. Exposed for testing; production uses processLoop.
    func processOnce() async {
        do {
            let ready = try await store.pendingReady(asOf: now())
            guard let item = ready.first else { return }
            await attemptSend(item)
            await reloadItems()
        } catch {
            logger.error("processOnce failed: \(error.localizedDescription)")
        }
    }

    /// Per-item processing wrapped in do/catch so a corrupt item cannot stall the queue.
    fileprivate func attemptSend(_ item: OutboxItem) async {
        do {
            try await attemptSendInner(item)
        } catch {
            logger.error("attemptSend crashed unexpectedly: \(error.localizedDescription); item=\(item.id)")
            item.status = .failed
            item.lastError = "Processing crashed: \(error.localizedDescription)"
            try? store.save()
            await notifier.notifyFailure(item: item, permanent: true)
        }
    }

    private func attemptSendInner(_ item: OutboxItem) async throws {
        item.status = .sending
        try store.save()

        guard let sender = sendersByAccount[item.accountId] else {
            item.status = .failed
            item.lastError = "Account removed"
            try? store.save()
            await notifier.notifyFailure(item: item, permanent: true)
            return
        }

        do {
            // First attempt skips the idempotency probe.
            if item.attemptCount > 0 {
                if try await sender.findInSent(messageId: item.messageIdHeader) {
                    logger.info("idempotency: \(item.messageIdHeader) already in SENT, treating as success")
                    await onSuccess(item, sentMessage: nil)
                    return
                }
            }

            let raw = String(data: item.rawMime, encoding: .utf8) ?? ""
            let sentMessage = try await sender.sendMessage(rawBase64URL: raw, threadId: item.threadId)
            await onSuccess(item, sentMessage: sentMessage)
        } catch {
            let classification = Self.classify(error)
            item.attemptCount += 1
            item.lastError = error.localizedDescription
            if classification == .permanent {
                item.status = .failed
                try? store.save()
                await notifier.notifyFailure(item: item, permanent: true)
            } else if item.attemptCount >= 3 {
                item.status = .failed
                try? store.save()
                await notifier.notifyFailure(item: item, permanent: false)
            } else {
                item.status = .pending
                item.nextAttemptAt = now().addingTimeInterval(Self.backoffSeconds(for: item.attemptCount))
                try? store.save()
            }
        }
    }

    private func onSuccess(_ item: OutboxItem, sentMessage: GmailMessage?) async {
        let sender = sendersByAccount[item.accountId]

        // 1. Delete consumed draft (best-effort).
        if let draftId = item.draftIdToConsume, let sender {
            do { try await sender.deleteDraft(draftId: draftId) }
            catch { logger.error("deleteDraft failed (ignored): \(error.localizedDescription)") }
        }

        // 2. Archive replied-to inbox message (best-effort).
        if let archiveId = item.archiveOnSuccessForMsgId,
           let archiveAccount = item.archiveOnSuccessForAccountId,
           let archiveSender = sendersByAccount[archiveAccount] {
            do { _ = try await archiveSender.modifyMessage(id: archiveId, addLabels: nil, removeLabels: ["INBOX"]) }
            catch { logger.error("archive inbox failed (ignored): \(error.localizedDescription)") }
        }

        // 3. Strip INBOX label from self-sent messages so they don't clutter the user's inbox.
        if let sent = sentMessage, (sent.labelIds ?? []).contains("INBOX"), let sender {
            do { _ = try await sender.modifyMessage(id: sent.id, addLabels: nil, removeLabels: ["INBOX"]) }
            catch { logger.error("self-send INBOX strip failed (ignored): \(error.localizedDescription)") }
        }

        try? await store.delete(id: item.id)
        await notifier.notifySuccess(item: item)
        await postSendRefresh()
    }

    private enum ErrorClassification { case transient, permanent }

    private static func classify(_ error: Error) -> ErrorClassification {
        if let gmailError = error as? GmailAPIError {
            switch gmailError {
            case .networkError, .serverError, .rateLimited:
                return .transient
            case .forbidden, .notFound, .sessionExpired, .decodingError, .historyExpired, .unauthorized:
                return .permanent
            }
        }
        return .transient
    }

    static func backoffSeconds(for attemptCount: Int) -> TimeInterval {
        switch attemptCount {
        case 1: return 10
        case 2: return 60
        default: return 300
        }
    }

    @discardableResult
    func resumeOnLaunch() async throws -> Int {
        let count = try await store.resetSendingToPending()
        await reloadItems()
        if count > 0 { signal() }
        return count
    }

    func cancel(itemId: UUID) async throws {
        try await store.delete(id: itemId)
        await reloadItems()
    }

    func retry(itemId: UUID) async throws {
        guard let item = try await store.item(byId: itemId) else { return }
        item.status = .pending
        item.attemptCount = 0
        item.lastError = nil
        item.nextAttemptAt = now()
        try store.save()
        await reloadItems()
        signal()
    }
}
