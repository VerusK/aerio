import AppKit

/// Knows which NSWindow hosts `MainView`, so a Dock click (reopen) can bring that window
/// back — or, when there is none, let SwiftUI's WindowGroup create a new one.
///
/// Picking "the first window that isn't the status bar" is not enough: SwiftUI keeps
/// invisible helper windows around, and ordering one of those front while refusing the
/// reopen left the app windowless (and not polling, since polling lives in MainView)
/// until it was killed.
@MainActor
final class MainWindowTracker {
    static let shared = MainWindowTracker()

    private(set) weak var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func register(_ window: NSWindow) {
        // AppKit state restoration at login re-created no main window and suppressed
        // the WindowGroup's default one. The frame is persisted separately
        // (`mainWindowFrame`), so restoration buys nothing here.
        window.isRestorable = false
        self.window = window

        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, self.window === window else { return }
                self.window = nil
            }
        }
    }

    /// The return value of `applicationShouldHandleReopen`: false when the existing main
    /// window was shown, true to let SwiftUI open a new one.
    func handleReopen() -> Bool {
        guard let window else { return true }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return false
    }
}
