import SwiftUI
import os.log

private let logger = Logger(subsystem: "AgMail", category: "ComposeWindow")

/// Manages non-modal compose windows. Each compose action opens a separate
/// resizable window that doesn't block the main window and remembers its last size.
@MainActor
final class ComposeWindowManager {
    static let shared = ComposeWindowManager()

    private static let frameAutosaveName = "AgMailComposeWindow"
    private static let defaultSize = CGSize(width: 600, height: 500)
    private static let minSize = CGSize(width: 450, height: 350)

    /// All currently open compose windows.
    private var windows: [NSWindow] = []
    private var closeObservers: [NSWindow: Any] = [:]

    private init() {}

    func open(
        accountManager: AccountManager,
        apiManager: GmailAPIManager,
        contactsCache: ContactsCache?,
        composeType: ComposeType,
        replyToEmail: Email?,
        preselectedAccountId: String?
    ) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = Self.windowTitle(for: composeType)
        panel.minSize = Self.minSize
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .normal

        let weakPanel = Weak(panel)
        let composeView = ComposeView(
            accountManager: accountManager,
            apiManager: apiManager,
            contactsCache: contactsCache,
            composeType: composeType,
            replyToEmail: replyToEmail,
            preselectedAccountId: preselectedAccountId,
            onDismiss: { [weak self] in
                guard let window = weakPanel.value else { return }
                self?.closeWindow(window)
            }
        )

        let hostingController = NSHostingController(rootView: composeView)
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController

        // Restore frame AFTER hosting controller is set (it overrides size on attach)
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.setContentSize(Self.defaultSize)
            if let mainWindow = NSApp.mainWindow {
                let mainFrame = mainWindow.frame
                let x = mainFrame.midX - Self.defaultSize.width / 2
                let y = mainFrame.midY - Self.defaultSize.height / 2
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                panel.center()
            }
        }

        // Clean up on close (handles both programmatic close and titlebar X)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            window.saveFrame(usingName: Self.frameAutosaveName)
            Task { @MainActor in
                if let obs = self?.closeObservers.removeValue(forKey: window) {
                    NotificationCenter.default.removeObserver(obs)
                }
                self?.windows.removeAll { $0 === window }
            }
        }

        closeObservers[panel] = observer
        windows.append(panel)
        panel.makeKeyAndOrderFront(nil)
        logger.debug("Opened compose window: \(Self.windowTitle(for: composeType))")
    }

    func closeWindow(_ window: NSWindow) {
        window.saveFrame(usingName: Self.frameAutosaveName)
        window.close()
    }

    func closeAll() {
        for window in windows {
            window.saveFrame(usingName: Self.frameAutosaveName)
            window.close()
        }
    }

    private static func windowTitle(for type: ComposeType) -> String {
        switch type {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .draft: return "Draft"
        }
    }
}

/// Simple weak reference wrapper for use in closures.
private class Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
