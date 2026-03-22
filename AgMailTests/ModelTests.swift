import XCTest
@testable import AgMail

final class FolderTests: XCTestCase {
    func testAllCases() {
        let allCases = Folder.allCases
        XCTAssertEqual(allCases.count, 6)
        XCTAssertTrue(allCases.contains(.inbox))
        XCTAssertTrue(allCases.contains(.sent))
        XCTAssertTrue(allCases.contains(.archive))
        XCTAssertTrue(allCases.contains(.trash))
        XCTAssertTrue(allCases.contains(.spam))
        XCTAssertTrue(allCases.contains(.drafts))
    }

    func testDisplayName() {
        XCTAssertEqual(Folder.inbox.displayName, "Inbox")
        XCTAssertEqual(Folder.sent.displayName, "Sent")
        XCTAssertEqual(Folder.archive.displayName, "Archive")
        XCTAssertEqual(Folder.trash.displayName, "Trash")
        XCTAssertEqual(Folder.spam.displayName, "Spam")
        XCTAssertEqual(Folder.drafts.displayName, "Drafts")
    }

    func testGmailParameter() {
        XCTAssertEqual(Folder.inbox.gmailParameter, "inbox")
        XCTAssertEqual(Folder.sent.gmailParameter, "sent")
        XCTAssertEqual(Folder.archive.gmailParameter, "all")
        XCTAssertEqual(Folder.trash.gmailParameter, "trash")
    }

    func testSentFolderProperties() {
        let sent = Folder.sent
        XCTAssertEqual(sent.displayName, "Sent")
        XCTAssertEqual(sent.gmailQuery, "in:sent")
        XCTAssertEqual(sent.gmailLabelIds, ["SENT"])
        XCTAssertEqual(sent.iconName, "paperplane.fill")
        XCTAssertEqual(sent.id, "sent")
    }

    func testMatchesLabelsInbox() {
        XCTAssertTrue(Folder.inbox.matchesLabels(["INBOX", "UNREAD"]))
        XCTAssertFalse(Folder.inbox.matchesLabels(["SENT"]))
    }

    func testMatchesLabelsSent() {
        XCTAssertTrue(Folder.sent.matchesLabels(["SENT"]))
        XCTAssertTrue(Folder.sent.matchesLabels(["SENT", "UNREAD"]))
        XCTAssertFalse(Folder.sent.matchesLabels(["INBOX"]))
        XCTAssertFalse(Folder.sent.matchesLabels([]))
    }

    func testMatchesLabelsArchive() {
        XCTAssertTrue(Folder.archive.matchesLabels(["CATEGORY_PRIMARY"]))
        XCTAssertFalse(Folder.archive.matchesLabels(["INBOX"]))
        XCTAssertFalse(Folder.archive.matchesLabels(["SENT"]))
        XCTAssertFalse(Folder.archive.matchesLabels(["TRASH"]))
        XCTAssertFalse(Folder.archive.matchesLabels(["SPAM"]))
        XCTAssertFalse(Folder.archive.matchesLabels(["DRAFT"]))
    }

    func testMatchesLabelsTrashSpamDrafts() {
        XCTAssertTrue(Folder.trash.matchesLabels(["TRASH"]))
        XCTAssertTrue(Folder.spam.matchesLabels(["SPAM"]))
        XCTAssertTrue(Folder.drafts.matchesLabels(["DRAFT"]))
    }

    func testIdentifiable() {
        XCTAssertEqual(Folder.inbox.id, "inbox")
        XCTAssertEqual(Folder.spam.id, "spam")
    }

    func testCodable() throws {
        let folder = Folder.inbox
        let data = try JSONEncoder().encode(folder)
        let decoded = try JSONDecoder().decode(Folder.self, from: data)
        XCTAssertEqual(folder, decoded)
    }
}

final class EmailTests: XCTestCase {
    private func makeDate(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1700000000 + offset)
    }

    private func makeEmail(
        msgId: String = "msg1",
        from: String = "sender@test.com",
        subject: String = "Test Subject",
        date: Date? = nil,
        snippet: String = "Preview text",
        isRead: Bool = false,
        accountId: String = "acc1",
        folder: Folder = .inbox
    ) -> Email {
        Email(
            msgId: msgId,
            from: from,
            subject: subject,
            date: date ?? makeDate(),
            snippet: snippet,
            isRead: isRead,
            accountId: accountId,
            folder: folder
        )
    }

    func testInitialization() {
        let email = makeEmail()
        XCTAssertEqual(email.msgId, "msg1")
        XCTAssertEqual(email.from, "sender@test.com")
        XCTAssertEqual(email.subject, "Test Subject")
        XCTAssertEqual(email.snippet, "Preview text")
        XCTAssertFalse(email.isRead)
        XCTAssertEqual(email.accountId, "acc1")
        XCTAssertEqual(email.folder, .inbox)
    }

    func testIdCombinesAccountAndMsg() {
        let email = makeEmail(msgId: "xyz", accountId: "acc2")
        XCTAssertEqual(email.id, "acc2_inbox_xyz")
    }

    func testEquatable() {
        let email1 = makeEmail(msgId: "msg1", accountId: "acc1")
        let email2 = makeEmail(msgId: "msg1", accountId: "acc1")
        let email3 = makeEmail(msgId: "msg2", accountId: "acc1")
        XCTAssertEqual(email1, email2)
        XCTAssertNotEqual(email1, email3)
    }

    func testSortedByDateDescending() {
        let older = makeEmail(msgId: "old", date: makeDate(0))
        let newer = makeEmail(msgId: "new", date: makeDate(3600))
        let sorted = Email.sortedByDate([older, newer])
        XCTAssertEqual(sorted.first?.msgId, "new")
        XCTAssertEqual(sorted.last?.msgId, "old")
    }

    func testSortedByDateAscending() {
        let older = makeEmail(msgId: "old", date: makeDate(0))
        let newer = makeEmail(msgId: "new", date: makeDate(3600))
        let sorted = Email.sortedByDate([older, newer], ascending: true)
        XCTAssertEqual(sorted.first?.msgId, "old")
        XCTAssertEqual(sorted.last?.msgId, "new")
    }

    func testIsReadMutable() {
        var email = makeEmail(isRead: false)
        XCTAssertFalse(email.isRead)
        email.isRead = true
        XCTAssertTrue(email.isRead)
    }

    func testCodable() throws {
        let email = makeEmail()
        let data = try JSONEncoder().encode(email)
        let decoded = try JSONDecoder().decode(Email.self, from: data)
        XCTAssertEqual(email, decoded)
    }
}

final class AccountTests: XCTestCase {
    func testInitialization() {
        let account = Account(id: "a1", email: "user@gmail.com", displayName: "User One", color: .blue)
        XCTAssertEqual(account.id, "a1")
        XCTAssertEqual(account.email, "user@gmail.com")
        XCTAssertEqual(account.displayName, "User One")
        XCTAssertEqual(account.color, .blue)
        XCTAssertEqual(account.avatarLetter, "U")
    }

    func testAvatarLetterDefault() {
        let account = Account(email: "test@gmail.com", displayName: "Alice")
        XCTAssertEqual(account.avatarLetter, "A")
    }

    func testAvatarLetterCustom() {
        let account = Account(email: "test@gmail.com", displayName: "Alice", avatarLetter: "X")
        XCTAssertEqual(account.avatarLetter, "X")
    }

    func testEquatable() {
        let a1 = Account(id: "same", email: "a@b.com", displayName: "A")
        let a2 = Account(id: "same", email: "a@b.com", displayName: "A")
        let a3 = Account(id: "diff", email: "a@b.com", displayName: "A")
        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, a3)
    }

    func testCodable() throws {
        let account = Account(id: "a1", email: "u@g.com", displayName: "U", color: .red)
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(account, decoded)
    }

    func testAllColors() {
        XCTAssertEqual(AccountColor.allCases.count, 8)
    }

    func testNextUniqueColorNoAccounts() {
        let color = AccountColor.nextUniqueColor(existingAccounts: [])
        XCTAssertEqual(color, .blue, "First account should get blue (first in allCases)")
    }

    func testNextUniqueColorSkipsUsed() {
        let existing = [
            Account(email: "a@b.com", displayName: "A", color: .blue),
            Account(email: "b@b.com", displayName: "B", color: .red),
        ]
        let color = AccountColor.nextUniqueColor(existingAccounts: existing)
        XCTAssertEqual(color, .green, "Should pick first unused color")
    }

    func testNextUniqueColorAllUsedPicksLeastUsed() {
        var existing: [Account] = AccountColor.allCases.map {
            Account(email: "\($0.rawValue)@b.com", displayName: $0.rawValue, color: $0)
        }
        // Add extra blue account so blue has count 2
        existing.append(Account(email: "extra@b.com", displayName: "E", color: .blue))
        let color = AccountColor.nextUniqueColor(existingAccounts: existing)
        // All colors used once except blue (twice), so any with count 1 is valid
        XCTAssertNotEqual(color, .blue, "Should not pick the most-used color")
    }

    func testNextUniqueColorOneAccount() {
        let existing = [Account(email: "a@b.com", displayName: "A", color: .blue)]
        let color = AccountColor.nextUniqueColor(existingAccounts: existing)
        XCTAssertEqual(color, .red, "Second account should get red (second in allCases)")
    }

    func testAccountColorSwiftUIColors() {
        // Exercise every case of the swiftUIColor computed property
        for accountColor in AccountColor.allCases {
            let color = accountColor.swiftUIColor
            XCTAssertNotNil(color, "swiftUIColor should not be nil for \(accountColor.rawValue)")
        }
        // Spot-check specific mappings
        XCTAssertEqual(AccountColor.blue.swiftUIColor, .blue)
        XCTAssertEqual(AccountColor.red.swiftUIColor, .red)
        XCTAssertEqual(AccountColor.green.swiftUIColor, .green)
        XCTAssertEqual(AccountColor.orange.swiftUIColor, .orange)
        XCTAssertEqual(AccountColor.purple.swiftUIColor, .purple)
        XCTAssertEqual(AccountColor.teal.swiftUIColor, .teal)
        XCTAssertEqual(AccountColor.pink.swiftUIColor, .pink)
        XCTAssertEqual(AccountColor.indigo.swiftUIColor, .indigo)
    }
}
