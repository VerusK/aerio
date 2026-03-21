import SwiftUI

enum ShortcutAction: String, CaseIterable, Sendable {
    case nextMessage          // Cmd+J
    case previousMessage      // Cmd+K
    case archiveMessage       // Cmd+E
    case deleteMessage        // # (Shift+3)
    case spamMessage          // ! (Shift+1)
    case reply                // Cmd+R
    case replyAll             // Cmd+Shift+R
    case forward              // Cmd+F
    case compose              // Cmd+N
    case search               // Cmd+/
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
    case refresh              // Cmd+Shift+E (was Cmd+R, moved to avoid conflict with reply)
    case openSettings         // Cmd+,
    case nextMessageAlt       // Alt+Down
    case previousMessageAlt   // Alt+Up

    var displayName: String {
        switch self {
        case .nextMessage:       return "Next Message"
        case .previousMessage:   return "Previous Message"
        case .archiveMessage:    return "Archive"
        case .deleteMessage:     return "Delete"
        case .spamMessage:       return "Report Spam"
        case .reply:             return "Reply"
        case .replyAll:          return "Reply All"
        case .forward:           return "Forward"
        case .compose:           return "Compose"
        case .search:            return "Search"
        case .sendMessage:       return "Send Message"
        case .selectAccount1:    return "Account 1"
        case .selectAccount2:    return "Account 2"
        case .selectAccount3:    return "Account 3"
        case .selectAccount4:    return "Account 4"
        case .selectAccount5:    return "Account 5"
        case .selectAccount6:    return "Account 6"
        case .selectAccount7:    return "Account 7"
        case .selectAccount8:    return "Account 8"
        case .selectAccount9:    return "Account 9"
        case .selectAllAccounts: return "All Accounts"
        case .refresh:           return "Refresh"
        case .openSettings:      return "Settings"
        case .nextMessageAlt:    return "Next Message"
        case .previousMessageAlt: return "Previous Message"
        }
    }

    var shortcutLabel: String {
        guard let binding = KeyboardShortcuts.eventBindings[self] else { return "" }
        var parts: [String] = []
        if binding.modifiers.contains(.control) { parts.append("⌃") }
        if binding.modifiers.contains(.option)  { parts.append("⌥") }
        if binding.modifiers.contains(.shift)   { parts.append("⇧") }
        if binding.modifiers.contains(.command) { parts.append("⌘") }
        let keyLabel: String
        let scalar = binding.qwertyChar.unicodeScalars.first?.value ?? 0
        switch scalar {
        case 0x0D:    keyLabel = "↩"
        case 0xF700:  keyLabel = "↑"
        case 0xF701:  keyLabel = "↓"
        case 0xF702:  keyLabel = "←"
        case 0xF703:  keyLabel = "→"
        default:      keyLabel = String(binding.qwertyChar).uppercased()
        }
        parts.append(keyLabel)
        return parts.joined()
    }
}

// MARK: - NSEvent-based shortcut binding

/// A shortcut binding that matches against the QWERTY character produced by the
/// physical key position (`charactersIgnoringModifiers`), making it work on any
/// keyboard layout.
struct NSEventKeyBinding: Equatable, Sendable {
    /// The lowercase QWERTY character for the physical key (e.g. "j", "r", "/", "3").
    let qwertyChar: Character
    /// Required modifier flags (only .command, .shift, .option, .control are compared).
    let modifiers: NSEvent.ModifierFlags

    init(_ char: Character, modifiers: NSEvent.ModifierFlags = []) {
        self.qwertyChar = char
        self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
    }
}

struct KeyboardShortcuts: Sendable {

    // MARK: - Primary bindings (NSEvent-based, layout-independent)

    static let eventBindings: [ShortcutAction: NSEventKeyBinding] = [
        .nextMessage:       NSEventKeyBinding("j", modifiers: .command),
        .previousMessage:   NSEventKeyBinding("k", modifiers: .command),
        .archiveMessage:    NSEventKeyBinding("e", modifiers: .command),
        .deleteMessage:     NSEventKeyBinding("3", modifiers: [.command, .shift]),   // Cmd+# (Shift+3)
        .spamMessage:       NSEventKeyBinding("1", modifiers: [.command, .shift]),   // Cmd+! (Shift+1)
        .reply:             NSEventKeyBinding("r", modifiers: .command),
        .replyAll:          NSEventKeyBinding("r", modifiers: [.command, .shift]),
        .forward:           NSEventKeyBinding("f", modifiers: [.command, .shift]),
        .compose:           NSEventKeyBinding("n", modifiers: .command),
        .search:            NSEventKeyBinding("/", modifiers: .command),
        .sendMessage:       NSEventKeyBinding("\r", modifiers: .command),
        .selectAccount1:    NSEventKeyBinding("1", modifiers: .command),
        .selectAccount2:    NSEventKeyBinding("2", modifiers: .command),
        .selectAccount3:    NSEventKeyBinding("3", modifiers: .command),
        .selectAccount4:    NSEventKeyBinding("4", modifiers: .command),
        .selectAccount5:    NSEventKeyBinding("5", modifiers: .command),
        .selectAccount6:    NSEventKeyBinding("6", modifiers: .command),
        .selectAccount7:    NSEventKeyBinding("7", modifiers: .command),
        .selectAccount8:    NSEventKeyBinding("8", modifiers: .command),
        .selectAccount9:    NSEventKeyBinding("9", modifiers: .command),
        .selectAllAccounts: NSEventKeyBinding("0", modifiers: .command),
        .refresh:           NSEventKeyBinding("e", modifiers: [.command, .shift]),
        .openSettings:      NSEventKeyBinding(",", modifiers: .command),
        .nextMessageAlt:    NSEventKeyBinding("\u{F701}", modifiers: .option),
        .previousMessageAlt: NSEventKeyBinding("\u{F700}", modifiers: .option),
    ]

    // MARK: - NSEvent matching (layout-independent)

    /// Match an NSEvent against the registered bindings using `charactersIgnoringModifiers`
    /// which always returns the QWERTY character for the physical key, regardless of the
    /// active input method / keyboard layout.
    static func action(for event: NSEvent) -> ShortcutAction? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let char = chars.first else { return nil }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // More-specific bindings (more modifiers) should match first to avoid
        // e.g. Cmd+Shift+R matching plain Cmd+R.
        // Sort by descending modifier count.
        let sorted = eventBindings.sorted { lhs, rhs in
            lhs.value.modifiers.rawValue.nonzeroBitCount > rhs.value.modifiers.rawValue.nonzeroBitCount
        }

        for (action, binding) in sorted {
            if binding.qwertyChar == char && binding.modifiers == flags {
                return action
            }
        }
        return nil
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

    static func isAccountSelection(_ action: ShortcutAction) -> Bool {
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
