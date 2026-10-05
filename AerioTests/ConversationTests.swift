import XCTest
@testable import Aerio

final class ConversationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func email(
        _ msgId: String,
        thread: String = "",
        account: String = "acc1",
        folder: Folder = .inbox,
        minutes: Double = 0,
        isRead: Bool = true
    ) -> Email {
        Email(
            msgId: msgId,
            from: "sender@test.com",
            subject: "Subject \(msgId)",
            date: t0.addingTimeInterval(minutes * 60),
            snippet: "",
            isRead: isRead,
            accountId: account,
            folder: folder,
            threadId: thread
        )
    }

    // MARK: - Grouping

    func testMessagesOfOneThreadInOneFolderFormOneConversation() {
        let fw = email("m1", thread: "t1", minutes: 0)
        let re = email("m2", thread: "t1", minutes: 60)
        let other = email("m3", thread: "t2", minutes: 30)

        let conversations = Conversation.group([fw, other, re])

        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations[0].messages.map(\.msgId), ["m2", "m1"], "newest first inside")
        XCTAssertEqual(conversations[0].newest.msgId, "m2")
        XCTAssertEqual(conversations[0].count, 2)
        XCTAssertEqual(conversations[1].messages.map(\.msgId), ["m3"])
    }

    func testSameThreadIdInTwoAccountsStaysSeparate() {
        let a = email("m1", thread: "t1", account: "acc1")
        let b = email("m2", thread: "t1", account: "acc2", minutes: 1)

        XCTAssertEqual(Conversation.group([a, b]).count, 2)
    }

    func testSameThreadInInboxAndSentStaysSeparate() {
        let inbox = email("m1", thread: "t1", folder: .inbox)
        let sent = email("m2", thread: "t1", folder: .sent, minutes: 1)

        XCTAssertEqual(Conversation.group([inbox, sent]).count, 2)
    }

    func testEmptyThreadIdNeverGroups() {
        let a = email("m1", thread: "")
        let b = email("m2", thread: "", minutes: 1)

        XCTAssertEqual(Conversation.group([a, b]).count, 2)
    }

    func testDraftsNeverGroup() {
        let a = email("d1", thread: "t1", folder: .drafts)
        let b = email("d2", thread: "t1", folder: .drafts, minutes: 1)

        XCTAssertEqual(Conversation.group([a, b]).count, 2)
    }

    func testConversationIdFormat() {
        let grouped = Conversation.group([email("m1", thread: "t1"), email("m2", thread: "t1", minutes: 1)])
        XCTAssertEqual(grouped.first?.id, "acc1_inbox_t_t1")

        let lone = email("m9")
        XCTAssertEqual(Conversation.group([lone]).first?.id, lone.id)
    }

    func testIsUnreadWhenOnlyAnOlderMemberIsUnread() {
        let older = email("m1", thread: "t1", minutes: 0, isRead: false)
        let newer = email("m2", thread: "t1", minutes: 1, isRead: true)

        let conversation = Conversation.group([older, newer])[0]

        XCTAssertTrue(conversation.newest.isRead)
        XCTAssertTrue(conversation.isUnread)
    }

    func testEqualDatesGiveTheSameOrderWhateverTheInputOrder() {
        let input = [
            email("m1", thread: "t1", account: "acc1"),
            email("m2", thread: "t1", account: "acc1"),
            email("m3", thread: "t2", account: "acc2"),
            email("m4", thread: "", account: "acc1"),
        ]

        let forward = Conversation.group(input)
        let backward = Conversation.group(Array(input.reversed()))

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.first { $0.count == 2 }?.messages.map(\.msgId), ["m1", "m2"], "equal dates ordered by msgId")
    }

    // MARK: - Selection helpers

    /// Three rows, newest first: c1 = [a2, a1], c2 = [b1], c3 = [c2, c1].
    private func threeRows() -> [Conversation] {
        Conversation.group([
            email("a1", thread: "ta", minutes: 50), email("a2", thread: "ta", minutes: 60),
            email("b1", thread: "tb", minutes: 40),
            email("c1", thread: "tc", minutes: 10), email("c2", thread: "tc", minutes: 20),
        ])
    }

    private func id(_ msgId: String) -> String { email(msgId).id }

    func testAdjacentSelectionMovesByRowsAndSelectsTheNewestMember() {
        let rows = threeRows()
        XCTAssertEqual(rows.adjacentSelection(from: id("a2"), offset: 1), id("b1"))
        XCTAssertEqual(rows.adjacentSelection(from: id("b1"), offset: 1), id("c2"))
        XCTAssertEqual(rows.adjacentSelection(from: id("b1"), offset: -1), id("a2"))
    }

    func testAdjacentSelectionClampsAtBothEnds() {
        let rows = threeRows()
        XCTAssertEqual(rows.adjacentSelection(from: id("a2"), offset: -1), id("a2"))
        XCTAssertEqual(rows.adjacentSelection(from: id("c2"), offset: 1), id("c2"))
    }

    func testAdjacentSelectionFromAnOlderMember() {
        let rows = threeRows()
        XCTAssertEqual(rows.adjacentSelection(from: id("a1"), offset: 1), id("b1"))
        XCTAssertEqual(rows.adjacentSelection(from: id("c1"), offset: -1), id("b1"))
    }

    func testAdjacentSelectionWithoutSelectionOrWithAVanishedOnePicksTheFirstRow() {
        let rows = threeRows()
        XCTAssertEqual(rows.adjacentSelection(from: nil, offset: 1), id("a2"))
        XCTAssertEqual(rows.adjacentSelection(from: "acc1_inbox_gone", offset: 1), id("a2"))
        XCTAssertNil(rows.conversation(containing: "acc1_inbox_gone"))
        XCTAssertNil([Conversation]().adjacentSelection(from: nil, offset: 1))
    }

    func testSelectionAfterRemoving() {
        let rows = threeRows()
        XCTAssertEqual(rows.selectionAfterRemoving(conversationId: rows[1].id), id("c2"), "middle → next")
        XCTAssertEqual(rows.selectionAfterRemoving(conversationId: rows[2].id), id("b1"), "last → previous")
        XCTAssertNil([rows[0]].selectionAfterRemoving(conversationId: rows[0].id), "only row → nil")
    }

    func testConversationContainingAnOlderMemberHasTheNewestAsReplyTarget() {
        let rows = threeRows()
        XCTAssertEqual(rows.conversation(containing: id("a1"))?.newest.msgId, "a2")
    }

    func testActionTargetsAreAllFolderLocalMembers() {
        let rows = threeRows()
        let older = email("a1", thread: "ta", minutes: 50)
        let newer = email("a2", thread: "ta", minutes: 60)

        XCTAssertEqual(rows.actionTargets(for: older).map(\.msgId), ["a2", "a1"])
        XCTAssertEqual(rows.actionTargets(for: newer).map(\.msgId), ["a2", "a1"])

        let stranger = email("zz")
        XCTAssertEqual(rows.actionTargets(for: stranger), [stranger])
    }
}
