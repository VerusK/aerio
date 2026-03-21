import SwiftUI
import WebKit

struct ComposeWebView: View {
    let webView: WKWebView
    let composeURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ComposeWebViewRepresentable(
                webView: webView,
                url: composeURL,
                isLoading: $isLoading
            )
        }
        .frame(width: 600, height: 500)
    }

    private var header: some View {
        HStack {
            Text("Compose")
                .font(.headline)
            Spacer()
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            }
            Button("Close") {
                dismiss()
            }
        }
        .padding()
    }
}

struct ComposeWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    let url: URL
    @Binding var isLoading: Bool

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool

        init(isLoading: Binding<Bool>) {
            _isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }
    }
}
