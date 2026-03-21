import SwiftUI
import WebKit

struct AccountSetupView: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var webViewPool: WebViewPool
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var accountId = UUID().uuidString

    private let gmailLoginURL = URL(string: "https://mail.google.com/mail/?ui=html&zy=h")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            webViewContainer
        }
        .frame(width: 500, height: 600)
        .onDisappear {
            // Clean up pool entry if account was never added (e.g., dismissed via Escape)
            if !accountManager.accounts.contains(where: { $0.id == accountId }) {
                webViewPool.removeWebViews(for: accountId)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Sign in to Gmail")
                .font(.headline)
            Spacer()
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            }
            Button("Cancel") {
                webViewPool.removeWebViews(for: accountId)
                dismiss()
            }
        }
        .padding()
    }

    private var webViewContainer: some View {
        AccountSetupWebView(
            webViewPool: webViewPool,
            accountId: accountId,
            url: gmailLoginURL,
            isLoading: $isLoading,
            onLoginDetected: { email in
                let colorIndex = accountManager.accounts.count % AccountColor.allCases.count
                let account = Account(
                    id: accountId,
                    email: email,
                    displayName: email.components(separatedBy: "@").first ?? email,
                    color: AccountColor.allCases[colorIndex]
                )
                accountManager.addAccount(account)
                dismiss()
            }
        )
    }
}

struct AccountSetupWebView: NSViewRepresentable {
    let webViewPool: WebViewPool
    let accountId: String
    let url: URL
    @Binding var isLoading: Bool
    var onLoginDetected: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let entry = webViewPool.createWebViews(for: accountId)
        let webView = entry.visibleWebView
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, onLoginDetected: onLoginDetected)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        var onLoginDetected: ((String) -> Void)?
        private var loginHandled = false

        init(isLoading: Binding<Bool>, onLoginDetected: ((String) -> Void)?) {
            _isLoading = isLoading
            self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            if !loginHandled {
                detectLogin(in: webView)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        private func detectLogin(in webView: WKWebView) {
            guard let url = webView.url?.absoluteString,
                  url.contains("mail.google.com/mail") else { return }

            let js = """
            (function() {
                var emailEl = document.querySelector('[data-email]');
                if (emailEl) return emailEl.getAttribute('data-email');
                var titleMatch = document.title.match(/([\\w.+-]+@[\\w-]+\\.[\\w.]+)/);
                if (titleMatch) return titleMatch[1];
                return null;
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let email = result as? String, !email.isEmpty {
                        self.loginHandled = true
                        self.onLoginDetected?(email)
                    }
                }
            }
        }
    }
}
