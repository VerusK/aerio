import XCTest
@testable import AgMail

final class KeyboardShortcutsTests: XCTestCase {

    // MARK: - Binding lookup

    func testAllActionsHaveEventBindings() {
        for action in ShortcutAction.allCases {
            XCTAssertNotNil(
                KeyboardShortcuts.eventBindings[action],
                "Missing event binding for \(action)"
            )
        }
    }

    // MARK: - Event binding values

    func testNavigationKeys() {
        let next = KeyboardShortcuts.eventBindings[.nextMessage]
        XCTAssertEqual(next?.qwertyChar, "j")
        XCTAssertEqual(next?.modifiers, .command)

        let prev = KeyboardShortcuts.eventBindings[.previousMessage]
        XCTAssertEqual(prev?.qwertyChar, "k")
        XCTAssertEqual(prev?.modifiers, .command)
    }

    func testMessageActionKeys() {
        let archive = KeyboardShortcuts.eventBindings[.archiveMessage]
        XCTAssertEqual(archive?.qwertyChar, "e")
        XCTAssertEqual(archive?.modifiers, .command)

        let delete = KeyboardShortcuts.eventBindings[.deleteMessage]
        XCTAssertEqual(delete?.qwertyChar, "3")
        XCTAssertEqual(delete?.modifiers, [.command, .shift])
    }

    func testComposeKeys() {
        let reply = KeyboardShortcuts.eventBindings[.reply]
        XCTAssertEqual(reply?.qwertyChar, "r")
        XCTAssertEqual(reply?.modifiers, .command)

        let replyAll = KeyboardShortcuts.eventBindings[.replyAll]
        XCTAssertEqual(replyAll?.qwertyChar, "r")
        XCTAssertEqual(replyAll?.modifiers, [.command, .shift])

        let fwd = KeyboardShortcuts.eventBindings[.forward]
        XCTAssertEqual(fwd?.qwertyChar, "f")
        XCTAssertEqual(fwd?.modifiers, [.command, .shift])

        let compose = KeyboardShortcuts.eventBindings[.compose]
        XCTAssertEqual(compose?.qwertyChar, "n")
        XCTAssertEqual(compose?.modifiers, .command)
    }

    func testSearchKey() {
        let search = KeyboardShortcuts.eventBindings[.search]
        XCTAssertEqual(search?.qwertyChar, "/")
        XCTAssertEqual(search?.modifiers, .command)
    }

    func testSendMessageKey() {
        let send = KeyboardShortcuts.eventBindings[.sendMessage]
        XCTAssertEqual(send?.qwertyChar, "\r")
        XCTAssertEqual(send?.modifiers, .command)
    }

    func testAccountSelectionKeys() {
        for i in 1...9 {
            let char = Character("\(i)")
            let matching = KeyboardShortcuts.eventBindings.first { _, binding in
                binding.qwertyChar == char && binding.modifiers == .command
            }
            XCTAssertNotNil(matching, "Cmd+\(i) should map to an action")
            XCTAssertTrue(
                KeyboardShortcuts.isAccountSelection(matching!.key),
                "Cmd+\(i) should be account selection"
            )
        }

        let allBinding = KeyboardShortcuts.eventBindings[.selectAllAccounts]
        XCTAssertEqual(allBinding?.qwertyChar, "0")
        XCTAssertEqual(allBinding?.modifiers, .command)
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
        // "z" with no modifiers should not match anything
        let matching = KeyboardShortcuts.eventBindings.first { _, binding in
            binding.qwertyChar == "z" && binding.modifiers == NSEvent.ModifierFlags()
        }
        XCTAssertNil(matching)
    }

    // MARK: - displayName

    func testAllActionsHaveDisplayName() {
        for action in ShortcutAction.allCases {
            XCTAssertFalse(action.displayName.isEmpty, "displayName should not be empty for \(action)")
        }
    }

    func testDisplayNameValues() {
        XCTAssertEqual(ShortcutAction.nextMessage.displayName, "Next Message")
        XCTAssertEqual(ShortcutAction.previousMessage.displayName, "Previous Message")
        XCTAssertEqual(ShortcutAction.archiveMessage.displayName, "Archive")
        XCTAssertEqual(ShortcutAction.compose.displayName, "Compose")
        XCTAssertEqual(ShortcutAction.reply.displayName, "Reply")
        XCTAssertEqual(ShortcutAction.replyAll.displayName, "Reply All")
        XCTAssertEqual(ShortcutAction.forward.displayName, "Forward")
        XCTAssertEqual(ShortcutAction.openSettings.displayName, "Settings")
        XCTAssertEqual(ShortcutAction.refresh.displayName, "Refresh")
    }

    // MARK: - shortcutLabel

    func testAllActionsHaveShortcutLabel() {
        for action in ShortcutAction.allCases {
            XCTAssertFalse(action.shortcutLabel.isEmpty, "shortcutLabel should not be empty for \(action)")
        }
    }

    func testShortcutLabelFormat() {
        XCTAssertEqual(ShortcutAction.nextMessage.shortcutLabel, "⌘J")
        XCTAssertEqual(ShortcutAction.previousMessage.shortcutLabel, "⌘K")
        XCTAssertEqual(ShortcutAction.replyAll.shortcutLabel, "⇧⌘R")
        XCTAssertEqual(ShortcutAction.deleteMessage.shortcutLabel, "⇧⌘3")
        XCTAssertEqual(ShortcutAction.openSettings.shortcutLabel, "⌘,")
        XCTAssertEqual(ShortcutAction.sendMessage.shortcutLabel, "⌘↩")
        XCTAssertEqual(ShortcutAction.refresh.shortcutLabel, "⇧⌘E")
    }

    // MARK: - openSettings binding

    func testOpenSettingsBinding() {
        XCTAssertNotNil(KeyboardShortcuts.eventBindings[.openSettings])
    }

    // MARK: - Alt navigation bindings

    func testAltNavigationBindings() {
        XCTAssertNotNil(KeyboardShortcuts.eventBindings[.nextMessageAlt])
        XCTAssertNotNil(KeyboardShortcuts.eventBindings[.previousMessageAlt])
    }

    func testAltNavigationShortcutLabels() {
        XCTAssertEqual(ShortcutAction.nextMessageAlt.shortcutLabel, "⌥↓")
        XCTAssertEqual(ShortcutAction.previousMessageAlt.shortcutLabel, "⌥↑")
    }

    func testAltNavigationDisplayNames() {
        XCTAssertEqual(ShortcutAction.nextMessageAlt.displayName, "Next Message")
        XCTAssertEqual(ShortcutAction.previousMessageAlt.displayName, "Previous Message")
    }

    // MARK: - isAccountSelection

    func testIsAccountSelectionForNonAccountActions() {
        XCTAssertFalse(KeyboardShortcuts.isAccountSelection(.nextMessage))
        XCTAssertFalse(KeyboardShortcuts.isAccountSelection(.compose))
        XCTAssertFalse(KeyboardShortcuts.isAccountSelection(.search))
    }
}
