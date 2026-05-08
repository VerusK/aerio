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
