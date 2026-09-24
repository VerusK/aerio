import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "Aerio", category: "OutboxStore")

@MainActor
final class OutboxStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Persistent stores live in `Application Support/<bundle id>/Outbox.store` (see `StoreLocation`);
    /// the release app moves a pre-existing root-level `Outbox.store` there so queued mail survives.
    convenience init(inMemory: Bool = false) {
        if !inMemory, let url = try? StoreLocation.storeURL(named: "Outbox", migratingLegacyStore: true) {
            self.init(configuration: ModelConfiguration("Outbox", schema: Self.schema, url: url))
        } else {
            if !inMemory {
                logger.error("Failed to create the outbox store directory. Falling back to in-memory.")
            }
            self.init(configuration: ModelConfiguration("Outbox", schema: Self.schema, isStoredInMemoryOnly: true))
        }
    }

    convenience init(url: URL) {
        self.init(configuration: ModelConfiguration("Outbox", schema: Self.schema, url: url))
    }

    private static let schema = Schema([OutboxItem.self])

    private init(configuration config: ModelConfiguration) {
        let schema = Self.schema
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            logger.error("Failed to create outbox ModelContainer: \(error.localizedDescription). Falling back to in-memory.")
            let fallback = ModelConfiguration("Outbox", schema: schema, isStoredInMemoryOnly: true)
            self.container = try! ModelContainer(for: schema, configurations: [fallback])
        }
    }

    func insert(_ item: OutboxItem) async throws {
        context.insert(item)
        try context.save()
    }

    func delete(id: UUID) async throws {
        let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.id == id })
        let matches = try context.fetch(descriptor)
        for m in matches { context.delete(m) }
        try context.save()
    }

    func allItems() async throws -> [OutboxItem] {
        let descriptor = FetchDescriptor<OutboxItem>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Pending items whose nextAttemptAt is at or before `asOf`, ordered by createdAt.
    func pendingReady(asOf date: Date) async throws -> [OutboxItem] {
        let pendingRaw = OutboxStatus.pending.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.statusRaw == pendingRaw && $0.nextAttemptAt <= date },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    /// Earliest future nextAttemptAt across pending items, or nil if none in future.
    func earliestPendingNext(after date: Date) async throws -> Date? {
        let pendingRaw = OutboxStatus.pending.rawValue
        var descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.statusRaw == pendingRaw && $0.nextAttemptAt > date },
            sortBy: [SortDescriptor(\.nextAttemptAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.nextAttemptAt
    }

    @discardableResult
    func resetSendingToPending() async throws -> Int {
        let sendingRaw = OutboxStatus.sending.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.statusRaw == sendingRaw })
        let stuck = try context.fetch(descriptor)
        for item in stuck {
            item.status = .pending
            // The app died mid-send, so Gmail may already have this message. Counting
            // the interrupted attempt makes OutboxService look it up in SENT before
            // sending again — attemptCount alone only grows on a *reported* failure.
            item.attemptCount = max(item.attemptCount, 1)
        }
        try context.save()
        return stuck.count
    }

    func save() throws {
        try context.save()
    }

    func item(byId id: UUID) async throws -> OutboxItem? {
        let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }
}
