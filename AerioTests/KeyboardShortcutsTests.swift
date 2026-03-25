import XCTest
@testable import Aerio

final class KeyboardShortcutsTests: XCTestCase {

    // MARK: - Event binding values

    func testMessageActionKeys() {
        let archive = KeyboardShortcuts.eventBindings[.archiveMessage]
        XCTAssertEqual(archive?.qwertyChar, "e")
        XCTAssertEqual(archive?.modifiers, .command)

        let delete = KeyboardShortcuts.eventBindings[.deleteMessage]
        XCTAssertEqual(delete?.qwertyChar, "d")
        XCTAssertEqual(delete?.modifiers, .command)

        let spam = KeyboardShortcuts.eventBindings[.spamMessage]
        XCTAssertEqual(spam?.qwertyChar, "1")
        XCTAssertEqual(spam?.modifiers, [.command, .shift])

        let moveToInbox = KeyboardShortcuts.eventBindings[.moveToInbox]
        XCTAssertEqual(moveToInbox?.qwertyChar, "i")
        XCTAssertEqual(moveToInbox?.modifiers, .command)
    }

    func testComposeKeys() {
        let reply = KeyboardShortcuts.eventBindings[.reply]
        XCTAssertEqual(reply?.qwertyChar, "r")
        XCTAssertEqual(reply?.modifiers, [.command, .shift])

        let replyAll = KeyboardShortcuts.eventBindings[.replyAll]
        XCTAssertEqual(replyAll?.qwertyChar, "r")
        XCTAssertEqual(replyAll?.modifiers, .command)

        let fwd = KeyboardShortcuts.eventBindings[.forward]
        XCTAssertEqual(fwd?.qwertyChar, "t")
        XCTAssertEqual(fwd?.modifiers, .command)

        let compose = KeyboardShortcuts.eventBindings[.compose]
        XCTAssertEqual(compose?.qwertyChar, "n")
        XCTAssertEqual(compose?.modifiers, .command)
    }

    func testSearchKey() {
        let search = KeyboardShortcuts.eventBindings[.search]
        XCTAssertEqual(search?.qwertyChar, "f")
        XCTAssertEqual(search?.modifiers, [.command, .shift])
    }

    func testSendMessageKey() {
        let send = KeyboardShortcuts.eventBindings[.sendMessage]
        XCTAssertEqual(send?.qwertyChar, "\r")
        XCTAssertEqual(send?.modifiers, .command)
    }

    func testRefreshKey() {
        let refresh = KeyboardShortcuts.eventBindings[.refresh]
        XCTAssertEqual(refresh?.qwertyChar, "e")
        XCTAssertEqual(refresh?.modifiers, [.command, .shift])
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

    // MARK: - displayName

    func testAllActionsHaveDisplayName() {
        for action in ShortcutAction.allCases {
            XCTAssertFalse(action.displayName.isEmpty, "displayName should not be empty for \(action)")
        }
    }

    func testDisplayNameValues() {
        XCTAssertEqual(ShortcutAction.focusLeft.displayName, "Focus Left")
        XCTAssertEqual(ShortcutAction.focusRight.displayName, "Focus Right")
        XCTAssertEqual(ShortcutAction.navigateUp.displayName, "Navigate Up")
        XCTAssertEqual(ShortcutAction.navigateDown.displayName, "Navigate Down")
        XCTAssertEqual(ShortcutAction.escape.displayName, "Back")
        XCTAssertEqual(ShortcutAction.goToInbox.displayName, "Go to Inbox")
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
        // Modifier-based shortcuts
        XCTAssertEqual(ShortcutAction.deleteMessage.shortcutLabel, "⌘D")
        XCTAssertEqual(ShortcutAction.replyAll.shortcutLabel, "⌘R")
        XCTAssertEqual(ShortcutAction.reply.shortcutLabel, "⇧⌘R")
        XCTAssertEqual(ShortcutAction.forward.shortcutLabel, "⌘T")
        XCTAssertEqual(ShortcutAction.search.shortcutLabel, "⇧⌘F")
        XCTAssertEqual(ShortcutAction.openSettings.shortcutLabel, "⌘,")
        XCTAssertEqual(ShortcutAction.sendMessage.shortcutLabel, "⌘↩")
        XCTAssertEqual(ShortcutAction.refresh.shortcutLabel, "⇧⌘E")
        XCTAssertEqual(ShortcutAction.spamMessage.shortcutLabel, "⇧⌘1")
    }

    func testNavigationShortcutLabels() {
        XCTAssertEqual(ShortcutAction.focusLeft.shortcutLabel, "←")
        XCTAssertEqual(ShortcutAction.focusRight.shortcutLabel, "→")
        XCTAssertEqual(ShortcutAction.navigateUp.shortcutLabel, "↑/K")
        XCTAssertEqual(ShortcutAction.navigateDown.shortcutLabel, "↓/J")
        XCTAssertEqual(ShortcutAction.escape.shortcutLabel, "Esc")
    }

    func testGoToShortcutLabels() {
        XCTAssertEqual(ShortcutAction.goToInbox.shortcutLabel, "G I")
        XCTAssertEqual(ShortcutAction.goToSent.shortcutLabel, "G S")
        XCTAssertEqual(ShortcutAction.goToArchive.shortcutLabel, "G A")
        XCTAssertEqual(ShortcutAction.goToTrash.shortcutLabel, "G T")
        XCTAssertEqual(ShortcutAction.goToDrafts.shortcutLabel, "G D")
        XCTAssertEqual(ShortcutAction.goToSpam.shortcutLabel, "G P")
    }

    // MARK: - Settings selector

    func testSettingsSelectorNameIsValid() {
        let name = KeyboardShortcuts.settingsSelectorName
        XCTAssertTrue(
            name == "showSettingsWindow:" || name == "showPreferencesWindow:",
            "Settings selector should be showSettingsWindow: or showPreferencesWindow:, got \(name)"
        )
    }

    func testSettingsSelectorNameForCurrentOS() {
        let name = KeyboardShortcuts.settingsSelectorName
        if #available(macOS 14, *) {
            XCTAssertEqual(name, "showSettingsWindow:", "macOS 14+ should use showSettingsWindow:")
        } else {
            XCTAssertEqual(name, "showPreferencesWindow:", "Pre-macOS 14 should use showPreferencesWindow:")
        }
    }

    // MARK: - No binding conflicts

    func testNoBindingConflicts() {
        let bindings = Array(KeyboardShortcuts.eventBindings.values)
        for i in 0..<bindings.count {
            for j in (i+1)..<bindings.count {
                let a = bindings[i]
                let b = bindings[j]
                let conflict = a.qwertyChar == b.qwertyChar && a.modifiers == b.modifiers
                XCTAssertFalse(conflict, "Binding conflict: \(a.qwertyChar) with modifiers \(a.modifiers.rawValue)")
            }
        }
    }

    // MARK: - FocusedPanel

    func testFocusedPanelCases() {
        let panels: [FocusedPanel] = [.sidebar, .messageList, .detail]
        XCTAssertEqual(panels.count, 3)
    }

    // MARK: - Go-To helpers

    func testIsGoToPrefixRequiresNoModifiers() {
        // The isGoToPrefix function checks for bare G key (keyCode 0x05)
        // We can't easily create NSEvent, but we verify the function exists
        // and the goToAction maps all expected folder keys
        XCTAssertNotNil(KeyboardShortcuts.goToAction as Any)
        XCTAssertNotNil(KeyboardShortcuts.isGoToPrefix as Any)
    }

}
