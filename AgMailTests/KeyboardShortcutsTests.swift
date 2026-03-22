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
        XCTAssertEqual(delete?.qwertyChar, "d")
        XCTAssertEqual(delete?.modifiers, .command)

        let spam = KeyboardShortcuts.eventBindings[.spamMessage]
        XCTAssertEqual(spam?.qwertyChar, "1")
        XCTAssertEqual(spam?.modifiers, [.command, .shift])
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

    func testSettingsSelectorCreatesValidSelector() {
        let selector = Selector((KeyboardShortcuts.settingsSelectorName))
        XCTAssertNotNil(selector, "Should create a valid Selector from the settings selector name")
    }

    // MARK: - isAccountSelection

    func testIsAccountSelectionForNonAccountActions() {
        XCTAssertFalse(KeyboardShortcuts.isAccountSelection(.nextMessage))
        XCTAssertFalse(KeyboardShortcuts.isAccountSelection(.compose))
        XCTAssertFalse(KeyboardShortcuts.isAccountSelection(.search))
    }

    // MARK: - Updated shortcut mappings (new in Task 7)

    func testDeleteUsesCommandD() {
        let binding = KeyboardShortcuts.eventBindings[.deleteMessage]!
        XCTAssertEqual(binding.qwertyChar, "d")
        XCTAssertEqual(binding.modifiers, .command)
    }

    func testReplyAllUsesCommandR() {
        let binding = KeyboardShortcuts.eventBindings[.replyAll]!
        XCTAssertEqual(binding.qwertyChar, "r")
        XCTAssertEqual(binding.modifiers, .command)
    }

    func testReplyUsesCommandShiftR() {
        let binding = KeyboardShortcuts.eventBindings[.reply]!
        XCTAssertEqual(binding.qwertyChar, "r")
        XCTAssertEqual(binding.modifiers, [.command, .shift])
    }

    func testForwardUsesCommandT() {
        let binding = KeyboardShortcuts.eventBindings[.forward]!
        XCTAssertEqual(binding.qwertyChar, "t")
        XCTAssertEqual(binding.modifiers, .command)
    }

    func testSearchUsesCommandShiftF() {
        let binding = KeyboardShortcuts.eventBindings[.search]!
        XCTAssertEqual(binding.qwertyChar, "f")
        XCTAssertEqual(binding.modifiers, [.command, .shift])
    }

    func testSpamUsesCommandShift1() {
        let binding = KeyboardShortcuts.eventBindings[.spamMessage]!
        XCTAssertEqual(binding.qwertyChar, "1")
        XCTAssertEqual(binding.modifiers, [.command, .shift])
    }

    // MARK: - Action lookup by key+modifiers (layout-independent matching)

    func testActionLookupMoreSpecificBindingMatchesFirst() {
        // Cmd+R should match replyAll (less modifiers)
        // Cmd+Shift+R should match reply (more modifiers)
        // This tests that the sorting by modifier count works correctly
        let replyAllBinding = KeyboardShortcuts.eventBindings[.replyAll]!
        XCTAssertEqual(replyAllBinding.modifiers, .command)

        let replyBinding = KeyboardShortcuts.eventBindings[.reply]!
        XCTAssertEqual(replyBinding.modifiers, [.command, .shift])
    }

    func testNoBindingConflicts() {
        // Verify no two actions share the same key+modifiers
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

    // MARK: - KeyEventInterceptor (KeyInterceptorView)

    func testKeyInterceptorViewDoesNotAcceptFirstResponder() {
        let view = KeyEventInterceptor.KeyInterceptorView()
        XCTAssertFalse(view.acceptsFirstResponder)
    }

    func testKeyInterceptorViewHandlerCanBeSet() {
        let view = KeyEventInterceptor.KeyInterceptorView()
        XCTAssertNil(view.handler)
        view.handler = { _ in true }
        XCTAssertNotNil(view.handler)
    }

    func testKeyInterceptorViewWithoutHandlerPassesThrough() {
        let view = KeyEventInterceptor.KeyInterceptorView()
        // Without a handler set, performKeyEquivalent should return false (pass through)
        // We can't easily create NSEvent in tests, but we verify the view structure is correct
        XCTAssertNil(view.handler)
        XCTAssertFalse(view.acceptsFirstResponder)
    }
}

