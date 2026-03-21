import XCTest
import SwiftData
@testable import AgMail

@MainActor
final class EmailCacheTests: XCTestCase {

    private func makeStore() -> EmailCache {
        EmailCache(inMemory: true)
    }

    private func makeEmail(
        msgId: String = "msg1",
        from: String = "sender@test.com",
        subject: String = "Test Subject",
        accountId: String = "acc1",
        folder: Folder = .inbox,
        isRead: Bool = false
    ) -> Email {
        Email(
            msgId: msgId,
            from: from,
            subject: subject,
            date: Date(),
            snippet: "Preview text",
            isRead: isRead,
            accountId: accountId,
            folder: folder
        )
    }

    // MARK: - Save and Load

    func testSaveAndLoadEmails() {
        let store = makeStore()
        let emails = [
            makeEmail(msgId: "m1", accountId: "acc1"),
            makeEmail(msgId: "m2", accountId: "acc1"),
        ]

        store.saveEmails(emails)
        let loaded = store.loadEmails(for: "acc1")

        XCTAssertEqual(loaded.count, 2)
    }

    func testLoadEmailsFiltersByAccount() {
        let store = makeStore()
        store.saveEmails([
            makeEmail(msgId: "m1", accountId: "acc1"),
            makeEmail(msgId: "m2", accountId: "acc2"),
        ])

        let acc1Emails = store.loadEmails(for: "acc1")
        let acc2Emails = store.loadEmails(for: "acc2")
        let allEmails = store.loadEmails()

        XCTAssertEqual(acc1Emails.count, 1)
        XCTAssertEqual(acc2Emails.count, 1)
        XCTAssertEqual(allEmails.count, 2)
    }

    func testLoadEmailsPreservesFields() {
        let store = makeStore()
        let email = Email(
            msgId: "msg42",
            from: "alice@example.com",
            subject: "Important",
            date: Date(timeIntervalSince1970: 1000000),
            snippet: "Hello world",
            isRead: true,
            accountId: "acc1",
            folder: Folder.trash
        )

        store.saveEmails([email])
        let loaded = store.loadEmails(for: "acc1")

        XCTAssertEqual(loaded.count, 1)
        let result = loaded[0]
        XCTAssertEqual(result.msgId, "msg42")
        XCTAssertEqual(result.from, "alice@example.com")
        XCTAssertEqual(result.subject, "Important")
        XCTAssertEqual(result.snippet, "Hello world")
        XCTAssertTrue(result.isRead)
        XCTAssertEqual(result.folder, Folder.trash)
        XCTAssertEqual(result.accountId, "acc1")
    }

    // MARK: - Update existing

    func testSaveUpdatesExistingEmail() {
        let store = makeStore()
        let original = makeEmail(msgId: "m1", subject: "Original", accountId: "acc1", isRead: false)
        store.saveEmails([original])

        let updated = Email(
            msgId: "m1",
            from: "sender@test.com",
            subject: "Updated",
            date: Date(),
            snippet: "Preview text",
            isRead: true,
            accountId: "acc1",
            folder: Folder.inbox
        )
        store.saveEmails([updated])

        let loaded = store.loadEmails(for: "acc1")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].subject, "Updated")
        XCTAssertTrue(loaded[0].isRead)
    }

    // MARK: - Clear

    func testClearEmailsForAccount() {
        let store = makeStore()
        store.saveEmails([
            makeEmail(msgId: "m1", accountId: "acc1"),
            makeEmail(msgId: "m2", accountId: "acc2"),
        ])

        store.clearEmails(for: "acc1")

        XCTAssertEqual(store.loadEmails(for: "acc1").count, 0)
        XCTAssertEqual(store.loadEmails(for: "acc2").count, 1)
    }

    func testClearAllEmails() {
        let store = makeStore()
        store.saveEmails([
            makeEmail(msgId: "m1", accountId: "acc1"),
            makeEmail(msgId: "m2", accountId: "acc2"),
        ])

        store.clearEmails()

        XCTAssertEqual(store.emailCount, 0)
    }

    // MARK: - Email count

    func testEmailCount() {
        let store = makeStore()
        XCTAssertEqual(store.emailCount, 0)

        store.saveEmails([
            makeEmail(msgId: "m1", accountId: "acc1"),
            makeEmail(msgId: "m2", accountId: "acc1"),
            makeEmail(msgId: "m3", accountId: "acc2"),
        ])

        XCTAssertEqual(store.emailCount, 3)
    }

    // MARK: - Sort order

    func testLoadedEmailsSortedByDateDescending() {
        let store = makeStore()
        let older = Email(
            msgId: "old",
            from: "a@b.com",
            subject: "Old",
            date: Date(timeIntervalSince1970: 1000),
            snippet: "",
            accountId: "acc1",
            folder: Folder.inbox
        )
        let newer = Email(
            msgId: "new",
            from: "a@b.com",
            subject: "New",
            date: Date(timeIntervalSince1970: 2000),
            snippet: "",
            accountId: "acc1",
            folder: Folder.inbox
        )

        store.saveEmails([older, newer])
        let loaded = store.loadEmails(for: "acc1")

        XCTAssertEqual(loaded[0].msgId, "new")
        XCTAssertEqual(loaded[1].msgId, "old")
    }

    // MARK: - All folders

    func testAllFoldersRoundTrip() {
        let store = makeStore()
        let emails: [Email] = Folder.allCases.enumerated().map { index, folder in
            makeEmail(msgId: "m\(index)", accountId: "acc1", folder: folder)
        }

        store.saveEmails(emails)
        let loaded: [Email] = store.loadEmails(for: "acc1")

        let loadedFolders = Set(loaded.map { $0.folder })
        let expectedFolders = Set(Folder.allCases)
        XCTAssertEqual(loadedFolders, expectedFolders)
    }
}
