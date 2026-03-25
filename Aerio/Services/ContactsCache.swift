import Foundation
import os.log

private let logger = Logger(subsystem: "Aerio", category: "ContactsCache")

struct CachedContact: Codable, Hashable, Sendable {
    let email: String
    let displayName: String?

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
        let contact = CachedContact(email: normalized, displayName: displayName)
        // Remove existing entry for same email (may have different displayName), then insert updated
        contacts.remove(contact)
        contacts.insert(contact)
        save()
    }

    func addContacts(from emails: [Email]) {
        var changed = false
        for email in emails {
            let parsed = Self.parseFromHeader(email.from)
            guard !parsed.email.isEmpty else { continue }
            let contact = CachedContact(email: parsed.email.lowercased(), displayName: parsed.displayName)
            // Update existing entry if displayName changed
            if let existing = contacts.first(where: { $0.email == contact.email }) {
                if existing.displayName != contact.displayName {
                    contacts.remove(existing)
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
            .sorted { ($0.displayName ?? $0.email) < ($1.displayName ?? $1.email) }
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
