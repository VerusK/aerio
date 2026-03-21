import XCTest
import SwiftUI
@testable import AgMail

final class KeyboardShortcutsTests: XCTestCase {

    // MARK: - Binding lookup

    func testAllActionsHaveBindings() {
        for action in ShortcutAction.allCases {
            XCTAssertNotNil(
                KeyboardShortcuts.binding(for: action),
                "Missing binding for \(action)"
            )
        }
    }

    // MARK: - Key-to-action mapping

    func testNavigationKeys() {
        XCTAssertEqual(
            KeyboardShortcuts.action(for: "j", modifiers: []),
            .nextMessage
        )
        XCTAssertEqual(
            KeyboardShortcuts.action(for: "k", modifiers: []),
            .previousMessage
        )
    }

    func testMessageActionKeys() {
        XCTAssertEqual(
            KeyboardShortcuts.action(for: "e", modifiers: []),
            .archiveMessage
        )
        XCTAssertEqual(
            KeyboardShortcuts.action(for: "#", modifiers: []),
            .deleteMessage
        )
    }

    func testComposeKeys() {
        XCTAssertEqual(
            KeyboardShortcuts.action(for: "r", modifiers: []),
            .reply
        )
        XCTAssertEqual(
            KeyboardShortcuts.action(for: "R", modifiers: .shift),
            .replyAll
        )
        XCTAssertEqual(
            KeyboardShortcuts.action(for: "f", modifiers: []),
            .forward
        )
        XCTAssertEqual(
            KeyboardShortcuts.action(for: "c", modifiers: []),
            .compose
        )
    }

    func testSearchKey() {
        XCTAssertEqual(
            KeyboardShortcuts.action(for: "/", modifiers: []),
            .search
        )
    }

    func testSendMessageKey() {
        XCTAssertEqual(
            KeyboardShortcuts.action(for: .return, modifiers: .command),
            .sendMessage
        )
    }

    func testAccountSelectionKeys() {
        for i in 1...9 {
            let key = KeyEquivalent(Character("\(i)"))
            let action = KeyboardShortcuts.action(for: key, modifiers: .command)
            XCTAssertNotNil(action, "Cmd+\(i) should map to an action")
            XCTAssertTrue(
                KeyboardShortcuts.isAccountSelection(action!),
                "Cmd+\(i) should be account selection"
            )
        }

        let allAction = KeyboardShortcuts.action(for: "0", modifiers: .command)
        XCTAssertEqual(allAction, .selectAllAccounts)
    }

    // MARK: - Account index mapping

    func testAccountIndexMapping() {
        XCTAssertEqual(KeyboardShortcuts.accountIndex(for: .selectAccount1), 0)
        XCTAssertEqual(KeyboardShortcuts.accountIndex(for: .selectAccount5), 4)
        XCTAssertEqual(KeyboardShortcuts.accountIndex(for: .selectAccount9), 8)
        XCTAssertNil(KeyboardShortcuts.accountIndex(for: .selectAllAccounts))
        XCTAssertNil(KeyboardShortcuts.accountIndex(for: .reply))
    }

    // MARK: - Unknown key

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(KeyboardShortcuts.action(for: "z", modifiers: []))
        XCTAssertNil(KeyboardShortcuts.action(for: "j", modifiers: .command))
    }

    // MARK: - isAccountSelection

    func testIsAccountSelectionForNonAccountActions() {
        XCTAssertFalse(KeyboardShortcuts.isAccountSelection(.nextMessage))
        XCTAssertFalse(KeyboardShortcuts.isAccountSelection(.compose))
        XCTAssertFalse(KeyboardShortcuts.isAccountSelection(.search))
    }
}
