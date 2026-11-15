import XCTest
import AppKit
@testable import Aerio

/// The Dock-click (reopen) path. On 2026-11-14 a login-time launch restored no main
/// window, and the old reopen handler brought forward an invisible helper window and
/// returned false, so SwiftUI never created one: the app sat windowless (and not polling)
/// until killed.
@MainActor
final class MainWindowTrackerTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    func testReopenWithoutMainWindowLetsSwiftUICreateOne() {
        let tracker = MainWindowTracker()

        XCTAssertTrue(tracker.handleReopen())
    }

    func testReopenShowsRegisteredMainWindow() {
        let tracker = MainWindowTracker()
        let window = makeWindow()
        tracker.register(window)

        XCTAssertFalse(tracker.handleReopen())
        XCTAssertTrue(window.isVisible)
        window.close()
    }

    func testReopenAfterMainWindowClosedLetsSwiftUICreateOne() {
        let tracker = MainWindowTracker()
        let window = makeWindow()
        tracker.register(window)
        window.close()

        XCTAssertTrue(tracker.handleReopen())
        XCTAssertFalse(window.isVisible)
    }

    /// AppKit state restoration is what left the login-time launch windowless.
    func testRegisteredMainWindowIsNotRestorable() {
        let tracker = MainWindowTracker()
        let window = makeWindow()
        tracker.register(window)

        XCTAssertFalse(window.isRestorable)
    }
}
