import Foundation
import os.log

private let logger = Logger(subsystem: "Aerio", category: "ContactsCache")

struct CachedContact: Codable, Hashable, Sendable {
    let email: String
    let displayName: String?
    var messageCount: Int

    init(email: String, displayName: String?, messageCount: Int = 0) {
        self.email = email
        self.displayName = displayName
        self.messageCount = messageCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
    }

    // Deduplicate by email only — a contact with a changed displayName should update, not duplicate
    static func == (lhs: CachedContact, rhs: CachedContact) -> Bool {
        lhs.email == rhs.email
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(email)
    }

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        if email.lowercased().contains(q) { return true }
        if let name = displayName?.lowercased(), name.contains(q) { return true }
        return false
    }

    var formatted: String {
        if let name = displayName, !name.isEmpty {
            return "\(name) <\(email)>"
        }
        return email
    }
}

@MainActor
final class ContactsCache {
    private let defaults: UserDefaults
    private let key = "aerio_contacts_cache"
    private var contacts: Set<CachedContact>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Set<CachedContact>.self, from: data) {
            self.contacts = decoded
        } else {
            self.contacts = []
        }
    }

    var allContacts: Set<CachedContact> {
        contacts
    }

    func addContact(email: String, displayName: String?) {
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return }
        let existingCount = contacts.first(where: { $0.email == normalized })?.messageCount ?? 0
        let contact = CachedContact(email: normalized, displayName: displayName, messageCount: existingCount + 1)
        contacts.remove(contact)
        contacts.insert(contact)
        save()
    }

    func addContacts(from emails: [Email]) {
        var changed = false
        for email in emails {
            let parsed = Self.parseFromHeader(email.from)
            guard !parsed.email.isEmpty else { continue }
            let normalizedEmail = parsed.email.lowercased()
            let existing = contacts.first(where: { $0.email == normalizedEmail })
            let newCount = (existing?.messageCount ?? 0) + 1
            let contact = CachedContact(email: normalizedEmail, displayName: parsed.displayName, messageCount: newCount)
            if existing != nil {
                if existing?.displayName != contact.displayName || existing?.messageCount != newCount {
                    contacts.remove(contact)
                    contacts.insert(contact)
                    changed = true
                }
            } else {
                contacts.insert(contact)
                changed = true
            }
        }
        if changed {
            save()
            logger.debug("ContactsCache updated, total: \(self.contacts.count)")
        }
    }

    func search(_ query: String) -> [CachedContact] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return contacts.filter { $0.matches(query) }
            .sorted {
                if $0.messageCount != $1.messageCount {
                    return $0.messageCount > $1.messageCount
                }
                return ($0.displayName ?? $0.email) < ($1.displayName ?? $1.email)
            }
    }

    func clear() {
        contacts.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(contacts) {
            defaults.set(data, forKey: key)
        }
    }

    nonisolated static func parseFromHeader(_ from: String) -> (email: String, displayName: String?) {
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        if let ltIndex = trimmed.lastIndex(of: "<"),
           let gtIndex = trimmed.lastIndex(of: ">"),
           ltIndex < gtIndex {
            let email = String(trimmed[trimmed.index(after: ltIndex)..<gtIndex])
                .trimmingCharacters(in: .whitespaces)
            var name = String(trimmed[trimmed.startIndex..<ltIndex])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if name.isEmpty { name = "" }
            return (email, name.isEmpty ? nil : name)
        }
        return (trimmed, nil)
    }
}
