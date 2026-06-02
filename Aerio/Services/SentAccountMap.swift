import Foundation
import os.log

private let logger = Logger(subsystem: "Aerio", category: "SentAccountMap")

/// Remembers which account you last sent mail to a given recipient from, so a
/// new compose can auto-select the matching "From" account.
///
/// The map is written at send time (the real signal — it also captures manual
/// From overrides) and read synchronously when composing. Persisted in
/// `UserDefaults`, mirroring `ContactsCache`.
///
///   record(recipient, accountId)         on every send, per To/Cc address
///   accountId(forRecipient:) -> String?  O(1) lookup, newest write wins
///
/// Bounded to `cap` entries; the oldest (by `updatedAt`) are evicted first.
@MainActor
final class SentAccountMap {
    static let shared = SentAccountMap()

    private struct Entry: Codable {
        let accountId: String
        let updatedAt: Date
    }

    private let defaults: UserDefaults
    private let key = "aerio_sent_account_map"
    private let cap: Int
    private var map: [String: Entry]

    init(defaults: UserDefaults = .standard, cap: Int = 2000) {
        self.defaults = defaults
        self.cap = max(1, cap)
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            self.map = decoded
        } else {
            self.map = [:]
        }
    }

    /// The account most recently used to send mail to `recipient`, or nil.
    func accountId(forRecipient recipient: String) -> String? {
        let k = Self.normalize(recipient)
        guard !k.isEmpty else { return nil }
        return map[k]?.accountId
    }

    /// Record that `recipient` was last written from `accountId`. Newest wins.
    func record(recipient: String, accountId: String, at date: Date = Date()) {
        let k = Self.normalize(recipient)
        guard !k.isEmpty, !accountId.isEmpty else { return }
        map[k] = Entry(accountId: accountId, updatedAt: date)
        evictIfNeeded()
        save()
    }

    /// Record every To/Cc recipient of a sent message against the sending
    /// account. Uses the quote-aware splitter so `"Doe, Jane" <j@x>` stays one
    /// address. Safe to call with empty `cc`.
    func recordRecipients(to: String, cc: String, accountId: String, at date: Date = Date()) {
        guard !accountId.isEmpty else { return }
        let tokens = ContactsCache.splitAddressList(to) + ContactsCache.splitAddressList(cc)
        var changed = false
        for token in tokens {
            let email = ContactsCache.parseFromHeader(token).email
            let k = Self.normalize(email)
            guard !k.isEmpty else { continue }
            map[k] = Entry(accountId: accountId, updatedAt: date)
            changed = true
        }
        if changed {
            evictIfNeeded()
            save()
        }
    }

    func clear() {
        map.removeAll()
        save()
    }

    // MARK: - Internals

    private static func normalize(_ recipient: String) -> String {
        recipient.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private func evictIfNeeded() {
        guard map.count > cap else { return }
        let overflow = map.count - cap
        let oldestKeys = map.sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(overflow)
            .map(\.key)
        for k in oldestKeys { map.removeValue(forKey: k) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }
}
