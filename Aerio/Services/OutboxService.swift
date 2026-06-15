import Foundation
import os.log

private let logger = Logger(subsystem: "Aerio", category: "OutboxService")

/// Plain-data, Sendable view of an OutboxItem.
/// SwiftUI consumers (OutboxList, UnifiedSidebar) only ever see snapshots;
/// the live `OutboxItem` @Model never escapes OutboxService. This avoids
/// EXC_BAD_ACCESS in StackLayout when SwiftUI's layout cache holds a
/// reference to a deleted/mutated SwiftData model across re-renders.
struct OutboxItemSnapshot: Sendable, Equatable, Identifiable {
    let id: UUID
    let accountId: String
    let subject: String
    let recipientsPreview: String
    let status: OutboxStatus
    let attemptCount: Int
    let lastError: String?
    let nextAttemptAt: Date
    let draftIdToConsume: String?
    let archiveOnSuccessForMsgId: String?
    let archiveOnSuccessForAccountId: String?
    /// Composed content, surfaced so a failed/queued send can be recovered.
    let toRecipients: String
    let ccRecipients: String
    let bodyText: String

    @MainActor
    init(_ item: OutboxItem) {
        self.id = item.id
        self.accountId = item.accountId
        self.subject = item.subject
        self.recipientsPreview = item.recipientsPreview
        self.status = item.status
        self.attemptCount = item.attemptCount
        self.lastError = item.lastError
        self.nextAttemptAt = item.nextAttemptAt
        self.draftIdToConsume = item.draftIdToConsume
        self.archiveOnSuccessForMsgId = item.archiveOnSuccessForMsgId
        self.archiveOnSuccessForAccountId = item.archiveOnSuccessForAccountId
        self.toRecipients = item.toRecipients
        self.ccRecipients = item.ccRecipients
        self.bodyText = item.bodyText
    }

    init(
        id: UUID, accountId: String, subject: String, recipientsPreview: String,
        status: OutboxStatus, attemptCount: Int,
        lastError: String?, nextAttemptAt: Date,
        draftIdToConsume: String?,
        archiveOnSuccessForMsgId: String?, archiveOnSuccessForAccountId: String?,
        toRecipients: String = "", ccRecipients: String = "", bodyText: String = ""
    ) {
        self.id = id
        self.accountId = accountId
        self.subject = subject
        self.recipientsPreview = recipientsPreview
        self.status = status
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.nextAttemptAt = nextAttemptAt
        self.draftIdToConsume = draftIdToConsume
        self.archiveOnSuccessForMsgId = archiveOnSuccessForMsgId
        self.archiveOnSuccessForAccountId = archiveOnSuccessForAccountId
        self.toRecipients = toRecipients
        self.ccRecipients = ccRecipients
        self.bodyText = bodyText
    }
}

/// Receives notifications about outbox item lifecycle. Production: OutboxNotifier (in NotificationManager.swift).
/// Tests: NoopNotifier or RecordingNotifier.
protocol OutboxNotifying: Sendable {
    func notifySuccess(snapshot: OutboxItemSnapshot) async
    func notifyFailure(snapshot: OutboxItemSnapshot, permanent: Bool) async
}

@MainActor
final class OutboxService: ObservableObject {
    /// Public, SwiftUI-safe view of the queue. Value-type snapshots, never
    /// exposes the underlying SwiftData @Model. Updated atomically on every
    /// state change so SwiftUI's layout cache cannot hold a stale model.
    @Published private(set) var items: [OutboxItemSnapshot] = []

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
            let models = try await store.allItems()
            items = models.map(OutboxItemSnapshot.init)
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
            await notifier.notifyFailure(snapshot: OutboxItemSnapshot(item), permanent: true)
        }
    }

    private func attemptSendInner(_ item: OutboxItem) async throws {
        item.status = .sending
        try store.save()

        guard let sender = sendersByAccount[item.accountId] else {
            item.status = .failed
            item.lastError = "Account removed"
            try? store.save()
            await notifier.notifyFailure(snapshot: OutboxItemSnapshot(item), permanent: true)
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
                await notifier.notifyFailure(snapshot: OutboxItemSnapshot(item), permanent: true)
            } else if item.attemptCount >= 3 {
                item.status = .failed
                try? store.save()
                await notifier.notifyFailure(snapshot: OutboxItemSnapshot(item), permanent: false)
            } else {
                item.status = .pending
                item.nextAttemptAt = now().addingTimeInterval(Self.backoffSeconds(for: item.attemptCount))
                try? store.save()
            }
        }
    }

    private func onSuccess(_ item: OutboxItem, sentMessage: GmailMessage?) async {
        // Snapshot every field we'll touch AFTER the SwiftData model is deleted.
        // Reading properties on a deleted @Model is undefined behavior and
        // can segfault — surfaced as an EXC_BAD_ACCESS in SwiftUI layout
        // when the @Published items array re-renders downstream.
        let snapshot = OutboxItemSnapshot(item)
        let sender = sendersByAccount[snapshot.accountId]

        // 1. Delete consumed draft (best-effort).
        if let draftId = snapshot.draftIdToConsume, let sender {
            do { try await sender.deleteDraft(draftId: draftId) }
            catch { logger.error("deleteDraft failed (ignored): \(error.localizedDescription)") }
        }

        // 2. Archive replied-to inbox message (best-effort).
        if let archiveId = snapshot.archiveOnSuccessForMsgId,
           let archiveAccount = snapshot.archiveOnSuccessForAccountId,
           let archiveSender = sendersByAccount[archiveAccount] {
            do { _ = try await archiveSender.modifyMessage(id: archiveId, addLabels: nil, removeLabels: ["INBOX"]) }
            catch { logger.error("archive inbox failed (ignored): \(error.localizedDescription)") }
        }

        // 3. Strip INBOX label from self-sent messages so they don't clutter the user's inbox.
        if let sent = sentMessage, (sent.labelIds ?? []).contains("INBOX"), let sender {
            do { _ = try await sender.modifyMessage(id: sent.id, addLabels: nil, removeLabels: ["INBOX"]) }
            catch { logger.error("self-send INBOX strip failed (ignored): \(error.localizedDescription)") }
        }

        try? await store.delete(id: snapshot.id)
        await notifier.notifySuccess(snapshot: snapshot)
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
            case .httpError(let code, _):
                // 5xx is worth retrying; 4xx (malformed MIME, payload too large,
                // unprocessable) will fail identically on every retry — fail fast.
                return (500...599).contains(code) ? .transient : .permanent
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

// MARK: - Loop driver

extension OutboxService {
    func startLoop() {
        guard processTask == nil else { return }
        // Kick once so any items already in the store at boot get drained.
        signal()
        processTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stopLoop() {
        nextWakeTimer?.cancel()
        nextWakeTimer = nil
        processTask?.cancel()
        processTask = nil
    }

    private func runLoop() async {
        guard let stream = signalStream else { return }
        for await _ in stream {
            if Task.isCancelled { return }
            nextWakeTimer?.cancel()
            nextWakeTimer = nil
            await drainReady()
            await scheduleNextWake()
        }
    }

    private func drainReady() async {
        while !Task.isCancelled {
            let ready: [OutboxItem]
            do { ready = try await store.pendingReady(asOf: now()) }
            catch {
                logger.error("drainReady fetch failed: \(error.localizedDescription)")
                return
            }
            guard let item = ready.first else { return }
            await attemptSend(item)
            await reloadItems()
        }
    }

    private func scheduleNextWake() async {
        let next: Date?
        do { next = try await store.earliestPendingNext(after: now()) }
        catch {
            logger.error("scheduleNextWake fetch failed: \(error.localizedDescription)")
            return
        }
        guard let wake = next else { return }
        let delay = max(0, wake.timeIntervalSince(now()))
        let continuation = self.signalContinuation
        nextWakeTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            continuation?.yield()
        }
    }
}
