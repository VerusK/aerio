import XCTest
@testable import Aerio

@MainActor
final class ContactsCacheTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cache: ContactsCache!

    override func setUp() {
        super.setUp()
        suiteName = "ContactsCacheTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        cache = ContactsCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        cache = nil
        super.tearDown()
    }

    // MARK: - Add & Retrieve

    func testAddContact() {
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        XCTAssertEqual(cache.allContacts.count, 1)
        let contact = cache.allContacts.first!
        XCTAssertEqual(contact.email, "alice@example.com")
        XCTAssertEqual(contact.displayName, "Alice")
    }

    func testAddContactNormalizesEmail() {
        cache.addContact(email: "  Alice@Example.COM  ", displayName: "Alice")
        XCTAssertEqual(cache.allContacts.first?.email, "alice@example.com")
    }

    func testAddEmptyEmailIgnored() {
        cache.addContact(email: "", displayName: "Nobody")
        XCTAssertTrue(cache.allContacts.isEmpty)
    }

    func testAddWhitespaceOnlyEmailIgnored() {
        cache.addContact(email: "   ", displayName: "Nobody")
        XCTAssertTrue(cache.allContacts.isEmpty)
    }

    func testFormattedQuotesNameWithComma() {
        // "Last, First" corporate contacts must be quoted, or the address parser
        // splits them into two bogus recipients ("Stonebraker" + "Kelli ... <...>").
        let c = CachedContact(email: "kellistonebraker@synovus.com", displayName: "Stonebraker, Kelli Elizabeth")
        XCTAssertEqual(c.formatted, "\"Stonebraker, Kelli Elizabeth\" <kellistonebraker@synovus.com>")
    }

    func testFormattedPlainNameNotQuoted() {
        let c = CachedContact(email: "alice@example.com", displayName: "Alice Smith")
        XCTAssertEqual(c.formatted, "Alice Smith <alice@example.com>")
    }

    func testCommaNameRoundTripsToOneValidRecipient() {
        // The end-to-end fix: a comma-name contact, once inserted, parses back to a
        // single recipient with a valid email — not two broken ones.
        let c = CachedContact(email: "kellistonebraker@synovus.com", displayName: "Stonebraker, Kelli Elizabeth")
        let parsed = ContactsCache.parseAddressList(c.formatted)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.email, "kellistonebraker@synovus.com")
        XCTAssertTrue(ContactsCache.isValidEmail(parsed.first?.email ?? ""))
    }

    func testAddBareNameIgnored() {
        // The bug: a failed send to a bare name cached "Stonebraker" as a contact,
        // which then re-appeared in autocomplete and re-inserted an invalid recipient.
        cache.addContact(email: "Stonebraker", displayName: "Stonebraker")
        XCTAssertTrue(cache.allContacts.isEmpty)
    }

    func testSearchExcludesInvalidEmailContacts() {
        // Even if a bad entry somehow exists, it must never be suggested.
        let suite = "ContactsCacheTests-bad-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let bad = CachedContact(email: "Stonebraker", displayName: "Stonebraker")
        let good = CachedContact(email: "mike@db.com", displayName: "Mike Stonebraker")
        d.set(try! JSONEncoder().encode(Set([bad, good])), forKey: "aerio_contacts_cache")
        let c = ContactsCache(defaults: d)
        let results = c.search("stone")
        XCTAssertFalse(results.contains { $0.email == "Stonebraker" })
        XCTAssertTrue(results.contains { $0.email == "mike@db.com" })
        d.removePersistentDomain(forName: suite)
    }

    func testInvalidContactsPurgedOnLoad() {
        let suite = "ContactsCacheTests-purge-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let bad = CachedContact(email: "Stonebraker", displayName: "Stonebraker")
        let good = CachedContact(email: "alice@example.com", displayName: "Alice")
        d.set(try! JSONEncoder().encode(Set([bad, good])), forKey: "aerio_contacts_cache")
        let c = ContactsCache(defaults: d)
        XCTAssertEqual(c.allContacts.count, 1)
        XCTAssertEqual(c.allContacts.first?.email, "alice@example.com")
        d.removePersistentDomain(forName: suite)
    }

    func testDeduplication() {
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        XCTAssertEqual(cache.allContacts.count, 1)
    }

    func testDifferentDisplayNameUpdatesExistingEntry() {
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        cache.addContact(email: "alice@example.com", displayName: "Alice Smith")
        XCTAssertEqual(cache.allContacts.count, 1)
        let contact = cache.allContacts.first
        XCTAssertEqual(contact?.displayName, "Alice Smith")
    }

    // MARK: - Population from Emails

    func testAddContactsFromEmails() {
        let emails = [
            Email(msgId: "1", from: "Alice <alice@example.com>", subject: "Hi", date: Date(), snippet: "", accountId: "a1", folder: .inbox),
            Email(msgId: "2", from: "bob@example.com", subject: "Hello", date: Date(), snippet: "", accountId: "a1", folder: .inbox),
        ]
        cache.addContacts(from: emails)
        XCTAssertEqual(cache.allContacts.count, 2)
    }

    func testAddContactsFromEmailsDeduplicates() {
        let emails = [
            Email(msgId: "1", from: "Alice <alice@example.com>", subject: "Hi", date: Date(), snippet: "", accountId: "a1", folder: .inbox),
            Email(msgId: "2", from: "Alice <alice@example.com>", subject: "Hi2", date: Date(), snippet: "", accountId: "a1", folder: .inbox),
        ]
        cache.addContacts(from: emails)
        XCTAssertEqual(cache.allContacts.count, 1)
    }

    // MARK: - Search

    func testSearchByEmail() {
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        cache.addContact(email: "bob@example.com", displayName: "Bob")
        let results = cache.search("alice")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.email, "alice@example.com")
    }

    func testSearchByDisplayName() {
        cache.addContact(email: "alice@example.com", displayName: "Alice Wonder")
        let results = cache.search("wonder")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.displayName, "Alice Wonder")
    }

    func testSearchCaseInsensitive() {
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        XCTAssertEqual(cache.search("ALICE").count, 1)
        XCTAssertEqual(cache.search("alice").count, 1)
    }

    func testSearchEmptyQueryReturnsEmpty() {
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        XCTAssertTrue(cache.search("").isEmpty)
        XCTAssertTrue(cache.search("   ").isEmpty)
    }

    func testSearchNoResults() {
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        XCTAssertTrue(cache.search("charlie").isEmpty)
    }

    func testSearchResultsSorted() {
        cache.addContact(email: "zara@example.com", displayName: "Zara")
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        cache.addContact(email: "bob@example.com", displayName: "Bob")
        let results = cache.search("example")
        XCTAssertEqual(results.map(\.displayName), ["Alice", "Bob", "Zara"])
    }

    // MARK: - Persistence

    func testPersistenceAcrossInstances() {
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        let cache2 = ContactsCache(defaults: defaults)
        XCTAssertEqual(cache2.allContacts.count, 1)
        XCTAssertEqual(cache2.allContacts.first?.email, "alice@example.com")
    }

    // MARK: - Clear

    func testClear() {
        cache.addContact(email: "alice@example.com", displayName: "Alice")
        cache.clear()
        XCTAssertTrue(cache.allContacts.isEmpty)
    }

    // MARK: - From Header Parsing

    func testParseFromHeaderWithNameAndEmail() {
        let result = ContactsCache.parseFromHeader("Alice <alice@example.com>")
        XCTAssertEqual(result.email, "alice@example.com")
        XCTAssertEqual(result.displayName, "Alice")
    }

    func testParseFromHeaderEmailOnly() {
        let result = ContactsCache.parseFromHeader("alice@example.com")
        XCTAssertEqual(result.email, "alice@example.com")
        XCTAssertNil(result.displayName)
    }

    func testParseFromHeaderWithQuotedName() {
        let result = ContactsCache.parseFromHeader("\"Alice Smith\" <alice@example.com>")
        XCTAssertEqual(result.email, "alice@example.com")
        XCTAssertEqual(result.displayName, "Alice Smith")
    }

    func testParseFromHeaderEmptyAngleBrackets() {
        let result = ContactsCache.parseFromHeader("Alice <>")
        XCTAssertEqual(result.email, "")
        XCTAssertEqual(result.displayName, "Alice")
    }

    // MARK: - CachedContact

    func testFormattedWithName() {
        let contact = CachedContact(email: "alice@example.com", displayName: "Alice")
        XCTAssertEqual(contact.formatted, "Alice <alice@example.com>")
    }

    func testFormattedWithoutName() {
        let contact = CachedContact(email: "alice@example.com", displayName: nil)
        XCTAssertEqual(contact.formatted, "alice@example.com")
    }

    func testMatchesByEmail() {
        let contact = CachedContact(email: "alice@example.com", displayName: "Alice")
        XCTAssertTrue(contact.matches("alice"))
        XCTAssertTrue(contact.matches("example"))
        XCTAssertFalse(contact.matches("bob"))
    }

    func testMatchesByDisplayName() {
        let contact = CachedContact(email: "a@b.com", displayName: "Alice Wonder")
        XCTAssertTrue(contact.matches("wonder"))
        XCTAssertFalse(contact.matches("bob"))
    }

    // MARK: - Autocomplete token extraction

    func testExtractCurrentTokenSingleAddress() {
        XCTAssertEqual(ComposeView.extractCurrentToken(from: "alice"), "alice")
    }

    func testExtractCurrentTokenAfterComma() {
        XCTAssertEqual(ComposeView.extractCurrentToken(from: "alice@ex.com, bo"), "bo")
    }

    func testExtractCurrentTokenEmpty() {
        XCTAssertEqual(ComposeView.extractCurrentToken(from: ""), "")
    }

    func testExtractCurrentTokenTrailingComma() {
        XCTAssertEqual(ComposeView.extractCurrentToken(from: "alice@ex.com, "), "")
    }
}
