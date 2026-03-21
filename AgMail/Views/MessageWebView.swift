import SwiftUI
import WebKit

struct MessageWebView: NSViewRepresentable {
    let webView: WKWebView
    var msgId: String?
    var folder: Folder = .inbox

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        let urlString = webView.url?.absoluteString ?? ""
        let isBasicHTML = urlString.contains("ui=html")
            || urlString.contains("/mail/u/0/h")
        let needsLoad = webView.url == nil || isBasicHTML
        if needsLoad {
            let gmailURL = URL(string: "https://mail.google.com/mail/u/0/")!
            webView.load(URLRequest(url: gmailURL))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let msgId else { return }
        context.coordinator.pendingFolder = folder
        if context.coordinator.lastMsgId != msgId {
            context.coordinator.lastMsgId = msgId
            let urlStr = nsView.url?.absoluteString ?? ""
            let isBasicHTML = urlStr.contains("ui=html") || urlStr.contains("/mail/u/0/h")
            let onFullGmail = urlStr.contains("mail.google.com") && !isBasicHTML
            if nsView.isLoading {
                context.coordinator.pendingNavigation = true
            } else if !onFullGmail {
                context.coordinator.pendingNavigation = true
                let gmailURL = URL(string: "https://mail.google.com/mail/u/0/")!
                nsView.load(URLRequest(url: gmailURL))
            } else {
                navigateToMessage(nsView, msgId: msgId)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastMsgId: String?
        var pendingNavigation = false
        var pendingFolder: Folder = .inbox

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard pendingNavigation, let msgId = lastMsgId else { return }
            guard let url = webView.url?.absoluteString, url.contains("mail.google.com"),
                  !url.contains("/mail/u/0/h"), !url.contains("ui=html") else {
                return // Don't navigate on non-Gmail or Basic HTML pages
            }
            pendingNavigation = false
            let sanitized = MessageWebView.sanitizeMsgId(msgId)
            let fragment = MessageWebView.gmailHashFragment(for: pendingFolder)
            let js = """
            (function() {
                window.location.hash = '#\(fragment)/' + '\(sanitized)';
                return true;
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    static func gmailHashFragment(for folder: Folder) -> String {
        folder.gmailParameter
    }

    static func sanitizeMsgId(_ msgId: String) -> String {
        msgId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func navigateToMessage(_ webView: WKWebView, msgId: String) {
        let sanitized = Self.sanitizeMsgId(msgId)
        let fragment = Self.gmailHashFragment(for: folder)
        let js = """
        (function() {
            var url = window.location.href;
            if (url.includes('mail.google.com')) {
                window.location.hash = '#\(fragment)/' + '\(sanitized)';
            }
            return true;
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
