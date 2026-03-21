import SwiftUI

enum ShortcutAction: String, CaseIterable, Sendable {
    case nextMessage          // j
    case previousMessage      // k
    case archiveMessage       // e
    case deleteMessage        // #
    case spamMessage          // !
    case reply                // r
    case replyAll             // Shift+R
    case forward              // f
    case compose              // c
    case search               // /
    case sendMessage          // Cmd+Enter
    case selectAccount1       // Cmd+1
    case selectAccount2       // Cmd+2
    case selectAccount3       // Cmd+3
    case selectAccount4       // Cmd+4
    case selectAccount5       // Cmd+5
    case selectAccount6       // Cmd+6
    case selectAccount7       // Cmd+7
    case selectAccount8       // Cmd+8
    case selectAccount9       // Cmd+9
    case selectAllAccounts    // Cmd+0
}

struct KeyBinding: Equatable, Sendable {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    init(_ key: KeyEquivalent, modifiers: EventModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

struct KeyboardShortcuts: Sendable {
    static let bindings: [ShortcutAction: KeyBinding] = [
        .nextMessage:       KeyBinding("j"),
        .previousMessage:   KeyBinding("k"),
        .archiveMessage:    KeyBinding("e"),
        .deleteMessage:     KeyBinding("#"),
        .spamMessage:       KeyBinding("!"),
        .reply:             KeyBinding("r"),
        .replyAll:          KeyBinding("R", modifiers: .shift),
        .forward:           KeyBinding("f"),
        .compose:           KeyBinding("c"),
        .search:            KeyBinding("/"),
        .sendMessage:       KeyBinding(.return, modifiers: .command),
        .selectAccount1:    KeyBinding("1", modifiers: .command),
        .selectAccount2:    KeyBinding("2", modifiers: .command),
        .selectAccount3:    KeyBinding("3", modifiers: .command),
        .selectAccount4:    KeyBinding("4", modifiers: .command),
        .selectAccount5:    KeyBinding("5", modifiers: .command),
        .selectAccount6:    KeyBinding("6", modifiers: .command),
        .selectAccount7:    KeyBinding("7", modifiers: .command),
        .selectAccount8:    KeyBinding("8", modifiers: .command),
        .selectAccount9:    KeyBinding("9", modifiers: .command),
        .selectAllAccounts: KeyBinding("0", modifiers: .command),
    ]

    /// Characters that require Shift to type on a standard US keyboard.
    /// When matching, we strip `.shift` from the incoming modifiers for these keys
    /// so that e.g. pressing Shift+3 to produce "#" matches `KeyBinding("#")`.
    private static let shiftedCharacters: Set<Character> = [
        "~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")",
        "_", "+", "{", "}", "|", ":", "\"", "<", ">", "?"
    ]

    static func action(for key: KeyEquivalent, modifiers: EventModifiers) -> ShortcutAction? {
        // For characters produced via Shift (e.g. "#" = Shift+3), strip .shift
        // so the binding doesn't need to redundantly declare .shift.
        let effectiveModifiers: EventModifiers
        if shiftedCharacters.contains(key.character) {
            effectiveModifiers = modifiers.subtracting(.shift)
        } else {
            effectiveModifiers = modifiers
        }
        return bindings.first { _, binding in
            binding.key == key && binding.modifiers == effectiveModifiers
        }?.key
    }

    static func binding(for action: ShortcutAction) -> KeyBinding? {
        bindings[action]
    }

    static func accountIndex(for action: ShortcutAction) -> Int? {
        switch action {
        case .selectAccount1: return 0
        case .selectAccount2: return 1
        case .selectAccount3: return 2
        case .selectAccount4: return 3
        case .selectAccount5: return 4
        case .selectAccount6: return 5
        case .selectAccount7: return 6
        case .selectAccount8: return 7
        case .selectAccount9: return 8
        case .selectAllAccounts: return nil
        default: return nil
        }
    }

    static let isAccountSelection: (ShortcutAction) -> Bool = { action in
        switch action {
        case .selectAccount1, .selectAccount2, .selectAccount3,
             .selectAccount4, .selectAccount5, .selectAccount6,
             .selectAccount7, .selectAccount8, .selectAccount9,
             .selectAllAccounts:
            return true
        default:
            return false
        }
    }
}
