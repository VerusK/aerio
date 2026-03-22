import SwiftUI
import AppKit

enum ShortcutAction: String, CaseIterable, Sendable {
    case nextMessage          // Cmd+J
    case previousMessage      // Cmd+K
    case archiveMessage       // Cmd+E
    case deleteMessage        // Cmd+D
    case spamMessage          // Cmd+Shift+1
    case reply                // Cmd+Shift+R
    case replyAll             // Cmd+R
    case forward              // Cmd+T
    case compose              // Cmd+N
    case search               // Cmd+Shift+F
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
    case refresh              // Cmd+Shift+E
    case openSettings         // Cmd+,
    case moveToInbox          // Cmd+I
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
        case .moveToInbox:       return "Move to Inbox"
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

    // MARK: - Hardware keyCode → QWERTY character mapping
    // These are macOS virtual key codes (kVK_*) which correspond to physical
    // key positions and are independent of the active keyboard layout.

    private static let keyCodeToQWERTY: [UInt16: Character] = [
        0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x04: "h",
        0x05: "g", 0x06: "z", 0x07: "x", 0x08: "c", 0x09: "v",
        0x0B: "b", 0x0C: "q", 0x0D: "w", 0x0E: "e", 0x0F: "r",
        0x10: "y", 0x11: "t", 0x12: "1", 0x13: "2", 0x14: "3",
        0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9",
        0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "o", 0x20: "u", 0x21: "[", 0x22: "i", 0x23: "p",
        0x25: "l", 0x26: "j", 0x27: "'", 0x28: "k", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "n", 0x2E: "m",
        0x2F: ".", 0x32: "`",
        // Special keys
        0x24: "\r",         // Return
        0x7E: "\u{F700}",  // Up arrow
        0x7D: "\u{F701}",  // Down arrow
        0x7B: "\u{F702}",  // Left arrow
        0x7C: "\u{F703}",  // Right arrow
    ]

    // MARK: - Primary bindings (NSEvent-based, layout-independent)

    static let eventBindings: [ShortcutAction: NSEventKeyBinding] = [
        .nextMessage:       NSEventKeyBinding("j", modifiers: .command),
        .previousMessage:   NSEventKeyBinding("k", modifiers: .command),
        .archiveMessage:    NSEventKeyBinding("e", modifiers: .command),
        .deleteMessage:     NSEventKeyBinding("d", modifiers: .command),
        .spamMessage:       NSEventKeyBinding("1", modifiers: [.command, .shift]),
        .reply:             NSEventKeyBinding("r", modifiers: [.command, .shift]),
        .replyAll:          NSEventKeyBinding("r", modifiers: .command),
        .forward:           NSEventKeyBinding("t", modifiers: .command),
        .compose:           NSEventKeyBinding("n", modifiers: .command),
        .search:            NSEventKeyBinding("f", modifiers: [.command, .shift]),
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
        .moveToInbox:       NSEventKeyBinding("i", modifiers: .command),
        .openSettings:      NSEventKeyBinding(",", modifiers: .command),
        .nextMessageAlt:    NSEventKeyBinding("\u{F701}", modifiers: .option),
        .previousMessageAlt: NSEventKeyBinding("\u{F700}", modifiers: .option),
    ]

    // MARK: - NSEvent matching (layout-independent via keyCode)

    /// Match an NSEvent against the registered bindings using `event.keyCode`
    /// (hardware scan code) mapped to QWERTY character. This is truly
    /// layout-independent — works on Russian, German, French, etc.
    static func action(for event: NSEvent) -> ShortcutAction? {
        guard let char = keyCodeToQWERTY[event.keyCode] else { return nil }

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

    /// Returns the correct selector name for opening the Settings window
    /// based on macOS version. macOS 14+ uses `showSettingsWindow:`,
    /// older versions use `showPreferencesWindow:`.
    static var settingsSelectorName: String {
        if #available(macOS 14, *) {
            return "showSettingsWindow:"
        } else {
            return "showPreferencesWindow:"
        }
    }

    /// Sends the appropriate Settings action to NSApp.
    @MainActor
    static func openSettings() {
        NSApp.sendAction(Selector((settingsSelectorName)), to: nil, from: nil)
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

// MARK: - KeyEventMonitor

/// Installs an `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` handler
/// that intercepts key events during `NSApplication.sendEvent(_:)` — BEFORE
/// they reach the window's responder chain or the main menu.
/// This guarantees layout-independent shortcuts work on any keyboard layout.
@MainActor
final class KeyEventMonitor {
    private var monitor: Any?
    private var handler: ((NSEvent) -> Bool)?

    func install(handler: @escaping (NSEvent) -> Bool) {
        self.handler = handler
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, let handler = self.handler, handler(event) {
                return nil // consume the event
            }
            return event // pass through
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        handler = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
