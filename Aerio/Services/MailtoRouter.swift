import Foundation

/// Hands incoming `mailto:` links to whoever opens compose windows. On a cold launch the
/// link may arrive before MainView has set its handler, so links are queued until then.
@MainActor
final class MailtoRouter {
    static let shared = MailtoRouter()

    private var pending: [ComposeSeed] = []

    var handler: ((ComposeSeed) -> Void)? {
        didSet { flush() }
    }

    func open(_ url: URL) {
        guard let seed = MailtoURL.seed(from: url) else { return }
        pending.append(seed)
        flush()
    }

    private func flush() {
        guard let handler else { return }
        let seeds = pending
        pending.removeAll()
        seeds.forEach(handler)
    }
}
