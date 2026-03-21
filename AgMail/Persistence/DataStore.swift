import Foundation
import os.log
import SwiftData

private let logger = Logger(subsystem: "AgMail", category: "DataStore")

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
            folder: folder
        )
    }
}

@MainActor
final class EmailCache: ObservableObject {
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext

    init(inMemory: Bool = false) {
        let schema = Schema([CachedEmail.self])
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
}
