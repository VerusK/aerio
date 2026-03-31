import Foundation
import os.log
import SwiftData

private let logger = Logger(subsystem: "Aerio", category: "DataStore")

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
            cc: cc ?? ""
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

    init(inMemory: Bool = false) {
        let schema = Schema([CachedEmail.self, CachedEmailContent.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
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
            } else {
                modelContext.insert(CachedEmail(from: email))
            }
        }
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save emails: \(error.localizedDescription)")
        }
    }

    func replaceEmails(for accountId: String, folder: Folder, with emails: [Email]) {
        let folderRaw = folder.rawValue
        let freshIds = Set(emails.map(\.id))
        let descriptor = FetchDescriptor<CachedEmail>(
            predicate: #Predicate { $0.accountId == accountId && $0.folderRaw == folderRaw }
        )
        let cached = (try? modelContext.fetch(descriptor)) ?? []
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
        do {
            try modelContext.save()
            logger.info("Purged \(toDelete.count) old cached emails, keeping \(keepLast)")
        } catch {
            logger.error("Failed to purge old emails: \(error.localizedDescription)")
        }
    }

    func deleteEmail(id: String) {
        let descriptor = FetchDescriptor<CachedEmail>(
            predicate: #Predicate { $0.id == id }
        )
        do {
            let cached = try modelContext.fetch(descriptor)
            for item in cached {
                modelContext.delete(item)
            }
            try modelContext.save()
        } catch {
            logger.error("Failed to delete email \(id): \(error.localizedDescription)")
        }
    }

    func deleteEmails(msgId: String, accountId: String) {
        let descriptor = FetchDescriptor<CachedEmail>(
            predicate: #Predicate { $0.msgId == msgId && $0.accountId == accountId }
        )
        do {
            let cached = try modelContext.fetch(descriptor)
            for item in cached {
                modelContext.delete(item)
            }
            try modelContext.save()
        } catch {
            logger.error("Failed to delete emails for msgId \(msgId): \(error.localizedDescription)")
        }
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
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to clear emails: \(error.localizedDescription)")
        }
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
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save content cache: \(error.localizedDescription)")
        }
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
        do {
            try modelContext.save()
            logger.info("Purged \(old.count) old content cache entries")
        } catch {
            logger.error("Failed to purge old content: \(error.localizedDescription)")
        }
    }

    func deleteContent(accountId: String, msgId: String) {
        let key = "\(accountId)_\(msgId)"
        let descriptor = FetchDescriptor<CachedEmailContent>(
            predicate: #Predicate { $0.contentKey == key }
        )
        do {
            let cached = try modelContext.fetch(descriptor)
            for item in cached {
                modelContext.delete(item)
            }
            try modelContext.save()
        } catch {
            logger.error("Failed to delete content for \(key): \(error.localizedDescription)")
        }
    }

    func clearContent() {
        let descriptor = FetchDescriptor<CachedEmailContent>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        for item in all {
            modelContext.delete(item)
        }
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to clear content cache: \(error.localizedDescription)")
        }
    }

    var contentCacheCount: Int {
        let descriptor = FetchDescriptor<CachedEmailContent>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}
