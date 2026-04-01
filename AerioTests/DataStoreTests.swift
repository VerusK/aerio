import XCTest
import SwiftData
@testable import Aerio

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
            folder: Folder.inbox,
            messageId: "<updated@example.com>"
        )
        store.saveEmails([updated])

        let loaded = store.loadEmails(for: "acc1")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].subject, "Updated")
        XCTAssertTrue(loaded[0].isRead)
        XCTAssertEqual(loaded[0].messageId, "<updated@example.com>")
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

    // MARK: - Replace Emails

    func testReplaceEmailsReplacesForAccountAndFolder() {
        let store = makeStore()
        let old1 = makeEmail(msgId: "old1", accountId: "acc1", folder: .inbox)
        let old2 = makeEmail(msgId: "old2", accountId: "acc1", folder: .inbox)
        let other = makeEmail(msgId: "other1", accountId: "acc2", folder: .inbox)
        store.saveEmails([old1, old2, other])

        let fresh = makeEmail(msgId: "fresh1", accountId: "acc1", folder: .inbox)
        store.replaceEmails(for: "acc1", folder: .inbox, with: [fresh])

        let acc1Emails = store.loadEmails(for: "acc1")
        XCTAssertEqual(acc1Emails.count, 1)
        XCTAssertEqual(acc1Emails[0].msgId, "fresh1")

        // Other account untouched
        let acc2Emails = store.loadEmails(for: "acc2")
        XCTAssertEqual(acc2Emails.count, 1)
        XCTAssertEqual(acc2Emails[0].msgId, "other1")
    }

    func testReplaceEmailsPreservesOtherFolders() {
        let store = makeStore()
        let inboxEmail = makeEmail(msgId: "m1", accountId: "acc1", folder: .inbox)
        let sentEmail = makeEmail(msgId: "m2", accountId: "acc1", folder: .sent)
        store.saveEmails([inboxEmail, sentEmail])

        let freshInbox = makeEmail(msgId: "m3", accountId: "acc1", folder: .inbox)
        store.replaceEmails(for: "acc1", folder: .inbox, with: [freshInbox])

        let all = store.loadEmails(for: "acc1")
        XCTAssertEqual(all.count, 2)
        let msgIds = Set(all.map(\.msgId))
        XCTAssertTrue(msgIds.contains("m3"))
        XCTAssertTrue(msgIds.contains("m2"))
    }

    // MARK: - Delete Email

    func testDeleteEmailById() {
        let store = makeStore()
        let email1 = makeEmail(msgId: "m1", accountId: "acc1")
        let email2 = makeEmail(msgId: "m2", accountId: "acc1")
        store.saveEmails([email1, email2])

        store.deleteEmail(id: email1.id)

        let loaded = store.loadEmails(for: "acc1")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].msgId, "m2")
    }

    func testDeleteEmailsByMsgIdAndAccountId() {
        let store = makeStore()
        // Same msgId in two folders
        let inboxEmail = makeEmail(msgId: "m1", accountId: "acc1", folder: .inbox)
        let sentEmail = makeEmail(msgId: "m1", accountId: "acc1", folder: .sent)
        let otherEmail = makeEmail(msgId: "m1", accountId: "acc2", folder: .inbox)
        store.saveEmails([inboxEmail, sentEmail, otherEmail])

        store.deleteEmails(msgId: "m1", accountId: "acc1")

        let acc1 = store.loadEmails(for: "acc1")
        XCTAssertEqual(acc1.count, 0)

        // Other account untouched
        let acc2 = store.loadEmails(for: "acc2")
        XCTAssertEqual(acc2.count, 1)
    }

    // MARK: - Content Cache

    func testSaveAndLoadContentRoundTrip() {
        let store = makeStore()
        let headers = ["from": "alice@test.com", "subject": "Hello"]
        let attachments: [[String: String]] = [["filename": "doc.pdf", "mimeType": "application/pdf"]]

        store.saveContent(accountId: "acc1", msgId: "msg1", bodyHTML: "<p>Hello</p>", headers: headers, attachments: attachments)

        let result = store.loadContent(accountId: "acc1", msgId: "msg1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.bodyHTML, "<p>Hello</p>")
        XCTAssertEqual(result?.headers["from"], "alice@test.com")
        XCTAssertEqual(result?.headers["subject"], "Hello")
        XCTAssertEqual(result?.attachments.count, 1)
        XCTAssertEqual(result?.attachments[0]["filename"], "doc.pdf")
    }

    func testLoadContentReturnsNilForNonExistentId() {
        let store = makeStore()
        let result = store.loadContent(accountId: "acc1", msgId: "nonexistent")
        XCTAssertNil(result)
    }

    func testPurgeOldContentLargeThresholdKeepsAll() {
        let store = makeStore()

        store.saveContent(accountId: "acc1", msgId: "msg1", bodyHTML: "<p>One</p>", headers: [:], attachments: [])
        store.saveContent(accountId: "acc1", msgId: "msg2", bodyHTML: "<p>Two</p>", headers: [:], attachments: [])

        XCTAssertEqual(store.contentCacheCount, 2)

        // Purge with large threshold — nothing removed (all items are recent)
        store.purgeOldContent(olderThanDays: 365)
        XCTAssertEqual(store.contentCacheCount, 2)
    }

    func testPurgeOldContentNegativeDaysRemovesAll() {
        let store = makeStore()

        store.saveContent(accountId: "acc1", msgId: "msg1", bodyHTML: "<p>One</p>", headers: [:], attachments: [])
        store.saveContent(accountId: "acc1", msgId: "msg2", bodyHTML: "<p>Two</p>", headers: [:], attachments: [])

        XCTAssertEqual(store.contentCacheCount, 2)

        // Use -1 days (cutoff = tomorrow) so all entries are strictly older
        store.purgeOldContent(olderThanDays: -1)
        XCTAssertEqual(store.contentCacheCount, 0)
    }

    func testDeleteContentRemovesSpecificEntry() {
        let store = makeStore()
        store.saveContent(accountId: "acc1", msgId: "msg1", bodyHTML: "<p>1</p>", headers: [:], attachments: [])
        store.saveContent(accountId: "acc1", msgId: "msg2", bodyHTML: "<p>2</p>", headers: [:], attachments: [])

        store.deleteContent(accountId: "acc1", msgId: "msg1")

        XCTAssertNil(store.loadContent(accountId: "acc1", msgId: "msg1"))
        XCTAssertNotNil(store.loadContent(accountId: "acc1", msgId: "msg2"))
    }

    func testClearContentRemovesAllEntries() {
        let store = makeStore()
        store.saveContent(accountId: "acc1", msgId: "msg1", bodyHTML: "<p>1</p>", headers: [:], attachments: [])
        store.saveContent(accountId: "acc2", msgId: "msg2", bodyHTML: "<p>2</p>", headers: [:], attachments: [])

        XCTAssertEqual(store.contentCacheCount, 2)

        store.clearContent()

        XCTAssertEqual(store.contentCacheCount, 0)
    }

    func testContentCacheCountReturnsCorrectCount() {
        let store = makeStore()
        XCTAssertEqual(store.contentCacheCount, 0)

        store.saveContent(accountId: "acc1", msgId: "msg1", bodyHTML: "", headers: [:], attachments: [])
        XCTAssertEqual(store.contentCacheCount, 1)

        store.saveContent(accountId: "acc1", msgId: "msg2", bodyHTML: "", headers: [:], attachments: [])
        XCTAssertEqual(store.contentCacheCount, 2)

        // Overwriting same key doesn't increase count
        store.saveContent(accountId: "acc1", msgId: "msg1", bodyHTML: "<p>updated</p>", headers: [:], attachments: [])
        XCTAssertEqual(store.contentCacheCount, 2)
    }

    // MARK: - ThreadId persistence

    func testSaveAndLoadPreservesThreadId() {
        let store = makeStore()
        let email = Email(
            msgId: "msg1",
            from: "test@test.com",
            subject: "Test",
            date: Date(),
            snippet: "preview",
            accountId: "acc1",
            folder: .inbox,
            threadId: "thread456"
        )
        store.saveEmails([email])
        let loaded = store.loadEmails(for: "acc1")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].threadId, "thread456")
    }

    // MARK: - To/Cc persistence

    func testSaveAndLoadPreservesToCc() {
        let store = makeStore()
        let email = Email(
            msgId: "msg1",
            from: "me@test.com",
            subject: "Test",
            date: Date(),
            snippet: "preview",
            accountId: "acc1",
            folder: .sent,
            to: "recipient@test.com",
            cc: "cc@test.com"
        )
        store.saveEmails([email])
        let loaded = store.loadEmails(for: "acc1")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].to, "recipient@test.com")
        XCTAssertEqual(loaded[0].cc, "cc@test.com")
    }

    func testLoadEmailsScopedByFolderWithLimit() {
        let store = makeStore()
        var emails: [Email] = []
        for i in 0..<10 {
            emails.append(Email(
                msgId: "msg\(i)",
                from: "sender@test.com",
                subject: "Subject \(i)",
                date: Date().addingTimeInterval(Double(-i * 60)),
                snippet: "snippet",
                accountId: "acc1",
                folder: .inbox
            ))
        }
        emails.append(Email(
            msgId: "sent1",
            from: "me@test.com",
            subject: "Sent",
            date: Date(),
            snippet: "snippet",
            accountId: "acc1",
            folder: .sent
        ))
        store.saveEmails(emails)

        let loaded = store.loadEmails(for: "acc1", folder: .inbox, limit: 5)
        XCTAssertEqual(loaded.count, 5)
        XCTAssertEqual(loaded[0].msgId, "msg0")
    }

    func testPurgeOldEmails() {
        let store = makeStore()
        var emails: [Email] = []
        for i in 0..<5 {
            emails.append(Email(
                msgId: "msg\(i)",
                from: "sender@test.com",
                subject: "Subject \(i)",
                date: Date().addingTimeInterval(Double(-i * 3600)),
                snippet: "snippet",
                accountId: "acc1",
                folder: .inbox
            ))
        }
        store.saveEmails(emails)
        XCTAssertEqual(store.emailCount, 5)

        store.purgeOldEmails(keepLast: 3)
        XCTAssertEqual(store.emailCount, 3)

        let loaded = store.loadEmails(for: "acc1")
        XCTAssertEqual(loaded[0].msgId, "msg0")
        XCTAssertEqual(loaded[2].msgId, "msg2")
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
