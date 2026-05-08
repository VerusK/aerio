import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "Aerio", category: "OutboxStore")

@MainActor
final class OutboxStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) {
        let schema = Schema([OutboxItem.self])
        // Same default location as EmailCache, but a separately-named store file ("Outbox").
        // SwiftData picks the per-app default URL; we just give the configuration a unique name
        // so it doesn't collide with EmailCache's default-named container.
        let config = ModelConfiguration("Outbox", schema: schema, isStoredInMemoryOnly: inMemory)
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
