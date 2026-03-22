import SwiftUI
import AppKit

// MARK: - Focused Panel

enum FocusedPanel: Sendable {
    case sidebar, messageList, detail
}

enum ShortcutAction: String, CaseIterable, Sendable {
    // Panel focus
    case focusLeft            // ← arrow
    case focusRight           // → arrow
    // In-panel navigation
    case navigateUp           // ↑ arrow / K
    case navigateDown         // ↓ arrow / J
    // Go-to folders (triggered via G+X state machine)
    case goToInbox
    case goToSent
    case goToArchive
    case goToTrash
    case goToDrafts
    case goToSpam
    // Sidebar expand/collapse
    case toggleExpand           // Space
    // Escape
    case escape
    // Message actions
    case archiveMessage       // Cmd+E
    case deleteMessage        // Cmd+D
    case spamMessage          // Cmd+Shift+1
    case moveToInbox          // Cmd+I
    // Compose
    case reply                // Cmd+Shift+R
    case replyAll             // Cmd+R
    case forward              // Cmd+T
    case compose              // Cmd+N
    case sendMessage          // Cmd+Enter
    // Other
    case search               // Cmd+Shift+F
    case refresh              // Cmd+Shift+E
    case openSettings         // Cmd+,
    case nextMessageAlt       // Alt+Down
    case previousMessageAlt   // Alt+Up

    var displayName: String {
        switch self {
        case .focusLeft:         return "Focus Left"
        case .focusRight:        return "Focus Right"
        case .navigateUp:        return "Navigate Up"
        case .navigateDown:      return "Navigate Down"
        case .goToInbox:         return "Go to Inbox"
        case .goToSent:          return "Go to Sent"
        case .goToArchive:       return "Go to Archive"
        case .goToTrash:         return "Go to Trash"
        case .goToDrafts:        return "Go to Drafts"
        case .goToSpam:          return "Go to Spam"
        case .toggleExpand:      return "Expand/Collapse"
        case .escape:            return "Back"
        case .archiveMessage:    return "Archive"
        case .deleteMessage:     return "Delete"
        case .spamMessage:       return "Report Spam"
        case .moveToInbox:       return "Move to Inbox"
        case .reply:             return "Reply"
        case .replyAll:          return "Reply All"
        case .forward:           return "Forward"
        case .compose:           return "Compose"
        case .sendMessage:       return "Send Message"
        case .search:            return "Search"
        case .refresh:           return "Refresh"
        case .openSettings:      return "Settings"
        case .nextMessageAlt:    return "Next Message"
        case .previousMessageAlt: return "Previous Message"
        }
    }

    var shortcutLabel: String {
        // Special labels for navigation shortcuts not in eventBindings
        switch self {
        case .focusLeft:     return "←"
        case .focusRight:    return "→"
        case .navigateUp:    return "↑/K"
        case .navigateDown:  return "↓/J"
        case .toggleExpand:  return "Space"
        case .escape:        return "Esc"
        case .goToInbox:     return "G I"
        case .goToSent:      return "G S"
        case .goToArchive:   return "G A"
        case .goToTrash:     return "G T"
        case .goToDrafts:    return "G D"
        case .goToSpam:      return "G P"
        default: break
        }
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
        0x2F: ".", 0x31: " ", 0x32: "`",
        // Special keys
        0x24: "\r",         // Return
        0x7E: "\u{F700}",  // Up arrow
        0x7D: "\u{F701}",  // Down arrow
        0x7B: "\u{F702}",  // Left arrow
        0x7C: "\u{F703}",  // Right arrow
    ]

    // MARK: - Primary bindings (NSEvent-based, layout-independent)

    static let eventBindings: [ShortcutAction: NSEventKeyBinding] = [
        .archiveMessage:    NSEventKeyBinding("e", modifiers: .command),
        .deleteMessage:     NSEventKeyBinding("d", modifiers: .command),
        .spamMessage:       NSEventKeyBinding("1", modifiers: [.command, .shift]),
        .reply:             NSEventKeyBinding("r", modifiers: [.command, .shift]),
        .replyAll:          NSEventKeyBinding("r", modifiers: .command),
        .forward:           NSEventKeyBinding("t", modifiers: .command),
        .compose:           NSEventKeyBinding("n", modifiers: .command),
        .search:            NSEventKeyBinding("f", modifiers: [.command, .shift]),
        .sendMessage:       NSEventKeyBinding("\r", modifiers: .command),
        .refresh:           NSEventKeyBinding("e", modifiers: [.command, .shift]),
        .moveToInbox:       NSEventKeyBinding("i", modifiers: .command),
        .openSettings:      NSEventKeyBinding(",", modifiers: .command),
        .nextMessageAlt:    NSEventKeyBinding("\u{F701}", modifiers: .option),
        .previousMessageAlt: NSEventKeyBinding("\u{F700}", modifiers: .option),
    ]

    // MARK: - NSEvent matching (layout-independent via keyCode)

    // Escape keyCode
    private static let escapeKeyCode: UInt16 = 0x35

    /// Match an NSEvent against the registered bindings using `event.keyCode`
    /// (hardware scan code) mapped to QWERTY character. This is truly
    /// layout-independent — works on Russian, German, French, etc.
    static func action(for event: NSEvent) -> ShortcutAction? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Escape — no modifiers
        if event.keyCode == escapeKeyCode && flags.isEmpty {
            return .escape
        }

        guard let char = keyCodeToQWERTY[event.keyCode] else { return nil }

        // Bare keys (no modifiers): arrows and J/K for navigation
        if flags.isEmpty {
            switch char {
            case "\u{F702}": return .focusLeft      // ← arrow
            case "\u{F703}": return .focusRight     // → arrow
            case "\u{F700}": return .navigateUp     // ↑ arrow
            case "\u{F701}": return .navigateDown   // ↓ arrow
            case "j":        return .navigateDown
            case "k":        return .navigateUp
            case " ":        return .toggleExpand
            default: break
            }
        }

        // Modifier-based bindings: more-specific (more modifiers) match first
        // to avoid e.g. Cmd+Shift+R matching plain Cmd+R.
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

    /// Check if a bare key (no modifiers) is a Go-To second key.
    /// Returns the corresponding folder shortcut action, or nil.
    static func goToAction(for event: NSEvent) -> ShortcutAction? {
        guard let char = keyCodeToQWERTY[event.keyCode] else { return nil }
        switch char {
        case "i": return .goToInbox
        case "s": return .goToSent
        case "a": return .goToArchive
        case "t": return .goToTrash
        case "d": return .goToDrafts
        case "p": return .goToSpam
        default: return nil
        }
    }

    /// Check if a bare key is the Go-To prefix "G".
    static func isGoToPrefix(for event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.isEmpty, let char = keyCodeToQWERTY[event.keyCode] else { return false }
        return char == "g"
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
    /// Go-To state machine: true after pressing G, waiting for second key
    private(set) var pendingGoTo = false
    private var goToTimer: DispatchWorkItem?

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

    /// Begin Go-To sequence: set pending flag with 1s timeout.
    func beginGoTo() {
        pendingGoTo = true
        goToTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            self?.cancelGoTo()
        }
        goToTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timer)
    }

    /// Cancel Go-To sequence.
    func cancelGoTo() {
        pendingGoTo = false
        goToTimer?.cancel()
        goToTimer = nil
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        handler = nil
        cancelGoTo()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
