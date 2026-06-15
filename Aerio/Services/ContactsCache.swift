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
        guard let name = displayName, !name.isEmpty else { return email }
        return "\(Self.quotedDisplayName(name)) <\(email)>"
    }

    /// Quote a display name when it contains characters that the address-list parser
    /// would otherwise choke on — a comma especially (e.g. a "Last, First" corporate
    /// contact), which would be split into two bogus recipients. Embedded quotes and
    /// backslashes are escaped. Non-ASCII stays readable here; wire-level RFC 2047
    /// encoding happens later in RFC2822Builder.
    static func quotedDisplayName(_ name: String) -> String {
        let breaking = CharacterSet(charactersIn: ",<>\"")
        guard name.rangeOfCharacter(from: breaking) != nil else { return name }
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

@MainActor
final class ContactsCache {
    private let defaults: UserDefaults
    private let key = "aerio_contacts_cache"
    private var contacts: Set<CachedContact>

    private let countResetKey = "aerio_contacts_count_reset_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Set<CachedContact>.self, from: data) {
            self.contacts = decoded
        } else {
            self.contacts = []
        }
        // One-time migration: reset messageCount to 0 (was counting From headers, now counts To from Sent)
        if !defaults.bool(forKey: countResetKey) {
            let reset = contacts.map { CachedContact(email: $0.email, displayName: $0.displayName, messageCount: 0) }
            contacts = Set(reset)
            save()
            defaults.set(true, forKey: countResetKey)
            logger.info("ContactsCache: reset messageCount for \(reset.count) contacts")
        }
        // Purge entries whose "email" isn't actually an address (e.g. a bare name an
        // earlier failed send accidentally cached). These pollute autocomplete and
        // re-insert an invalid recipient when picked.
        let valid = contacts.filter { Self.isValidEmail($0.email) }
        if valid.count != contacts.count {
            logger.info("ContactsCache: purged \(self.contacts.count - valid.count) invalid contact(s)")
            contacts = valid
            save()
        }
    }

    var allContacts: Set<CachedContact> {
        contacts
    }

    func addContact(email: String, displayName: String?) {
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard Self.isValidEmail(normalized) else { return }
        let existingCount = contacts.first(where: { $0.email == normalized })?.messageCount ?? 0
        let contact = CachedContact(email: normalized, displayName: displayName, messageCount: existingCount + 1)
        contacts.remove(contact)
        contacts.insert(contact)
        save()
    }

    func addContacts(from emails: [Email]) {
        var changed = false
        for email in emails {
            if email.folder == .sent {
                // Sent emails: count To/Cc recipients (who I write to)
                let recipients = Self.parseAddressList(email.to) + Self.parseAddressList(email.cc)
                for parsed in recipients {
                    guard !parsed.email.isEmpty else { continue }
                    changed = upsertContact(email: parsed.email, displayName: parsed.displayName, incrementCount: true) || changed
                }
            } else {
                // Incoming emails: add sender for autocomplete but don't increment count
                let parsed = Self.parseFromHeader(email.from)
                guard !parsed.email.isEmpty else { continue }
                changed = upsertContact(email: parsed.email, displayName: parsed.displayName, incrementCount: false) || changed
            }
        }
        if changed {
            save()
            logger.debug("ContactsCache updated, total: \(self.contacts.count)")
        }
    }

    private func upsertContact(email: String, displayName: String?, incrementCount: Bool) -> Bool {
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard Self.isValidEmail(normalized) else { return false }
        let existing = contacts.first(where: { $0.email == normalized })
        let newCount = (existing?.messageCount ?? 0) + (incrementCount ? 1 : 0)
        let contact = CachedContact(email: normalized, displayName: displayName, messageCount: newCount)
        if let existing {
            if existing.displayName != contact.displayName || existing.messageCount != newCount {
                contacts.remove(contact)
                contacts.insert(contact)
                return true
            }
            return false
        } else {
            contacts.insert(contact)
            return true
        }
    }

    /// RFC 5322-aware split: only split on commas that fall OUTSIDE quoted
    /// strings, so a display name like `"Doe, Jane" <jane@x.com>` stays one
    /// address instead of being torn into two bogus entries.
    nonisolated static func splitAddressList(_ list: String) -> [String] {
        guard !list.isEmpty else { return [] }
        var results: [String] = []
        var current = ""
        var inQuotes = false
        for ch in list {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { results.append(trimmed) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { results.append(trimmed) }
        return results
    }

    /// Parse comma-separated address list like "Name <email>, other@email.com".
    /// Splits on commas outside quoted strings (see `splitAddressList`).
    nonisolated static func parseAddressList(_ list: String) -> [(email: String, displayName: String?)] {
        splitAddressList(list).map { parseFromHeader($0) }
    }

    /// Conservative email sanity check — catches obvious non-addresses (a bare name,
    /// missing @, missing domain dot). Not a full RFC validator. Shared by the compose
    /// recipient guard so the two stay consistent.
    nonisolated static func isValidEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains(" ") else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    func search(_ query: String) -> [CachedContact] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        // Never suggest a contact whose stored "email" isn't a real address.
        return contacts.filter { $0.matches(query) && Self.isValidEmail($0.email) }
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
