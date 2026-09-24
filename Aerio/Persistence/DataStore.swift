import Foundation
import os.log
import SwiftData

private let logger = Logger(subsystem: "Aerio", category: "DataStore")

/// Where Aerio's SwiftData stores live: `Application Support/<bundle id>/<name>.store`.
///
/// SwiftData's default URL is `Application Support/default.store`, and Aerio isn't sandboxed,
/// so that file is shared with every other unsandboxed SwiftData app. On 2026-09-23 one of them
/// migrated it to its own schema, dropping Aerio's tables; every cache save failed from then on.
/// The bundle id also keeps Debug builds (`com.aerio.Aerio.dev`) off the release app's stores.
enum StoreLocation {
    static let releaseBundleId = "com.aerio.Aerio"
    private static let storeFileSuffixes = ["", "-wal", "-shm"]

    /// Creates the per-bundle directory and returns the store URL inside it.
    /// With `migratingLegacyStore`, the release app moves `Application Support/<name>.store`
    /// (written before stores had their own directory) into place. If that copy fails, the
    /// legacy URL is returned so nothing already in the store goes missing.
    static func storeURL(
        named name: String,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        bundleId: String = Bundle.main.bundleIdentifier ?? releaseBundleId,
        migratingLegacyStore: Bool = false
    ) throws -> URL {
        let directory = applicationSupport.appendingPathComponent(bundleId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).store")

        let legacyURL = applicationSupport.appendingPathComponent("\(name).store")
        let fm = FileManager.default
        guard migratingLegacyStore, bundleId == releaseBundleId,
              !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacyURL.path) else {
            return url
        }

        // Copy all three SQLite files before deleting any: a store moved without its WAL
        // loses every transaction not yet checkpointed.
        var copied: [URL] = []
        do {
            for suffix in storeFileSuffixes {
                let source = URL(fileURLWithPath: legacyURL.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: url.path + suffix)
                try fm.copyItem(at: source, to: destination)
                copied.append(destination)
            }
        } catch {
            logger.error("Failed to migrate \(name).store into \(bundleId): \(error.localizedDescription). Keeping the legacy location.")
            for file in copied { try? fm.removeItem(at: file) }
            return legacyURL
        }
        for suffix in storeFileSuffixes {
            try? fm.removeItem(at: URL(fileURLWithPath: legacyURL.path + suffix))
        }
        logger.info("Migrated \(name).store into \(bundleId)")
        return url
    }
}

@Model
final class CachedEmail {
    @Attribute(.unique) var id: String
    var msgId: String
    var from: String
    var subject: String
    var date: Date
    var snippet: String
    var isRead: Bool
    var accountId: String
    var folderRaw: String
    var messageId: String?
    var to: String?
    var cc: String?
    var threadId: String?

    init(from email: Email) {
        self.id = email.id
        self.msgId = email.msgId
        self.from = email.from
        self.subject = email.subject
        self.date = email.date
        self.snippet = email.snippet
        self.isRead = email.isRead
        self.accountId = email.accountId
        self.folderRaw = email.folder.rawValue
        self.messageId = email.messageId
        self.to = email.to
        self.cc = email.cc
        self.threadId = email.threadId
    }

    func toEmail() -> Email? {
        guard let folder = Folder(rawValue: folderRaw) else { return nil }
        return Email(
            msgId: msgId,
            from: from,
            subject: subject,
            date: date,
            snippet: snippet,
            isRead: isRead,
            accountId: accountId,
            folder: folder,
            messageId: messageId,
            to: to ?? "",
            cc: cc ?? "",
            threadId: threadId ?? ""
        )
    }
}

@Model
final class CachedEmailContent {
    @Attribute(.unique) var contentKey: String  // "accountId_msgId"
    var accountId: String
    var msgId: String
    var bodyHTML: String
    var headersJSON: String  // JSON: {from, to, cc, subject, date}
    var attachmentsJSON: String  // JSON array of attachment info
    var cachedAt: Date

    init(contentKey: String, accountId: String, msgId: String, bodyHTML: String, headersJSON: String, attachmentsJSON: String, cachedAt: Date = Date()) {
        self.contentKey = contentKey
        self.accountId = accountId
        self.msgId = msgId
        self.bodyHTML = bodyHTML
        self.headersJSON = headersJSON
        self.attachmentsJSON = attachmentsJSON
        self.cachedAt = cachedAt
    }
}

@MainActor
final class EmailCache: ObservableObject {
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext

    static func defaultStoreURL() throws -> URL {
        try StoreLocation.storeURL(named: "EmailCache")
    }

    init(inMemory: Bool = false) {
        let schema = Schema([CachedEmail.self, CachedEmailContent.self])
        let config: ModelConfiguration
        if !inMemory, let url = try? Self.defaultStoreURL() {
            config = ModelConfiguration(schema: schema, url: url)
        } else {
            if !inMemory {
                logger.error("Failed to create the cache store directory. Falling back to in-memory store.")
            }
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            logger.error("Failed to create ModelContainer: \(error.localizedDescription). Falling back to in-memory store.")
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // If even in-memory fails, there's nothing we can do
            self.modelContainer = try! ModelContainer(for: schema, configurations: [fallbackConfig])
        }
        self.modelContext = modelContainer.mainContext
    }

    init(container: ModelContainer) {
        self.modelContainer = container
        self.modelContext = container.mainContext
    }

    func saveEmails(_ emails: [Email]) {
        for email in emails {
            let emailId = email.id
            let descriptor = FetchDescriptor<CachedEmail>(
                predicate: #Predicate { $0.id == emailId }
            )
            let existing = (try? modelContext.fetch(descriptor))?.first

            if let existing {
                existing.from = email.from
                existing.subject = email.subject
                existing.date = email.date
                existing.snippet = email.snippet
                existing.isRead = email.isRead
                existing.folderRaw = email.folder.rawValue
                existing.messageId = email.messageId
                existing.to = email.to
                existing.cc = email.cc
                existing.threadId = email.threadId
            } else {
                modelContext.insert(CachedEmail(from: email))
            }
        }
        save("Failed to save emails")
    }

    func replaceEmails(for accountId: String, folder: Folder, with emails: [Email]) {
        let folderRaw = folder.rawValue
        let freshIds = Set(emails.map(\.id))
        let descriptor = FetchDescriptor<CachedEmail>(
            predicate: #Predicate { $0.accountId == accountId && $0.folderRaw == folderRaw }
        )
        let cached = (try? modelContext.fetch(descriptor)) ?? []
        // Safety: never wipe a populated folder with an empty fresh set — almost always a sync glitch.
        if emails.isEmpty && !cached.isEmpty {
            logger.warning("replaceEmails: refused to wipe \(cached.count) cached emails for \(accountId)/\(folderRaw) with empty set")
            return
        }
        for item in cached where !freshIds.contains(item.id) {
            modelContext.delete(item)
        }
        saveEmails(emails)
    }

    func loadEmails(for accountId: String? = nil) -> [Email] {
        var descriptor: FetchDescriptor<CachedEmail>
        if let accountId {
            descriptor = FetchDescriptor<CachedEmail>(
                predicate: #Predicate { $0.accountId == accountId },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<CachedEmail>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
        }

        let cached = (try? modelContext.fetch(descriptor)) ?? []
        return cached.compactMap { $0.toEmail() }
    }

    func loadEmails(for accountId: String, folder: Folder, limit: Int = 200) -> [Email] {
        let folderRaw = folder.rawValue
        var descriptor = FetchDescriptor<CachedEmail>(
            predicate: #Predicate { $0.accountId == accountId && $0.folderRaw == folderRaw },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let cached = (try? modelContext.fetch(descriptor)) ?? []
        return cached.compactMap { $0.toEmail() }
    }

    func purgeOldEmails(keepLast: Int) {
        let descriptor = FetchDescriptor<CachedEmail>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        guard all.count > keepLast else { return }
        let toDelete = all.dropFirst(keepLast)
        for item in toDelete {
            modelContext.delete(item)
        }
        if save("Failed to purge old emails") {
            logger.info("Purged \(toDelete.count) old cached emails, keeping \(keepLast)")
        }
    }

    func deleteEmail(id: String) {
        let descriptor = FetchDescriptor<CachedEmail>(
            predicate: #Predicate { $0.id == id }
        )
        let cached = (try? modelContext.fetch(descriptor)) ?? []
        for item in cached {
            modelContext.delete(item)
        }
        save("Failed to delete email \(id)")
    }

    func deleteEmails(msgId: String, accountId: String) {
        let descriptor = FetchDescriptor<CachedEmail>(
            predicate: #Predicate { $0.msgId == msgId && $0.accountId == accountId }
        )
        let cached = (try? modelContext.fetch(descriptor)) ?? []
        for item in cached {
            modelContext.delete(item)
        }
        save("Failed to delete emails for msgId \(msgId)")
    }

    func clearEmails(for accountId: String? = nil) {
        let descriptor: FetchDescriptor<CachedEmail>
        if let accountId {
            descriptor = FetchDescriptor<CachedEmail>(
                predicate: #Predicate { $0.accountId == accountId }
            )
        } else {
            descriptor = FetchDescriptor<CachedEmail>()
        }

        let cached = (try? modelContext.fetch(descriptor)) ?? []
        for item in cached {
            modelContext.delete(item)
        }
        save("Failed to clear emails")
    }

    var emailCount: Int {
        let descriptor = FetchDescriptor<CachedEmail>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Content Cache

    func saveContent(accountId: String, msgId: String, bodyHTML: String, headers: [String: String], attachments: [[String: String]]) {
        let key = "\(accountId)_\(msgId)"
        let headersJSON = (try? JSONSerialization.data(withJSONObject: headers)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let attachmentsJSON = (try? JSONSerialization.data(withJSONObject: attachments)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let descriptor = FetchDescriptor<CachedEmailContent>(
            predicate: #Predicate { $0.contentKey == key }
        )
        let existing = (try? modelContext.fetch(descriptor))?.first

        if let existing {
            existing.bodyHTML = bodyHTML
            existing.headersJSON = headersJSON
            existing.attachmentsJSON = attachmentsJSON
            existing.cachedAt = Date()
        } else {
            modelContext.insert(CachedEmailContent(
                contentKey: key, accountId: accountId, msgId: msgId,
                bodyHTML: bodyHTML, headersJSON: headersJSON, attachmentsJSON: attachmentsJSON
            ))
        }
        save("Failed to save content cache")
    }

    func loadContent(accountId: String, msgId: String) -> (bodyHTML: String, headers: [String: String], attachments: [[String: String]])? {
        let key = "\(accountId)_\(msgId)"
        let descriptor = FetchDescriptor<CachedEmailContent>(
            predicate: #Predicate { $0.contentKey == key }
        )
        guard let cached = (try? modelContext.fetch(descriptor))?.first else { return nil }
        let headers = (try? JSONSerialization.jsonObject(with: Data(cached.headersJSON.utf8))) as? [String: String] ?? [:]
        let attachments = (try? JSONSerialization.jsonObject(with: Data(cached.attachmentsJSON.utf8))) as? [[String: String]] ?? []
        return (cached.bodyHTML, headers, attachments)
    }

    func purgeOldContent(olderThanDays days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<CachedEmailContent>(
            predicate: #Predicate { $0.cachedAt < cutoff }
        )
        let old = (try? modelContext.fetch(descriptor)) ?? []
        guard !old.isEmpty else { return }
        for item in old {
            modelContext.delete(item)
        }
        if save("Failed to purge old content") {
            logger.info("Purged \(old.count) old content cache entries")
        }
    }

    func deleteContent(accountId: String, msgId: String) {
        let key = "\(accountId)_\(msgId)"
        let descriptor = FetchDescriptor<CachedEmailContent>(
            predicate: #Predicate { $0.contentKey == key }
        )
        let cached = (try? modelContext.fetch(descriptor)) ?? []
        for item in cached {
            modelContext.delete(item)
        }
        save("Failed to delete content for \(key)")
    }

    func clearContent() {
        let descriptor = FetchDescriptor<CachedEmailContent>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        for item in all {
            modelContext.delete(item)
        }
        save("Failed to clear content cache")
    }

    /// Saves pending changes, and on failure logs and rolls the context back. Without the
    /// rollback a failed save leaves its inserts and deletes pending, every later save retries
    /// the whole growing pile, and a long-running app gets slower by the hour.
    @discardableResult
    private func save(_ failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            logger.error("\(failureMessage): \(error.localizedDescription)")
            modelContext.rollback()
            return false
        }
    }

    var contentCacheCount: Int {
        let descriptor = FetchDescriptor<CachedEmailContent>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}
