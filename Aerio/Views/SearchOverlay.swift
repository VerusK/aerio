import SwiftUI
import WebKit
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [Email] = []
    @Published private(set) var isSearching = false
    @Published var selectedIndex: Int? = nil
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var previewEmail: Email? = nil
    @Published private(set) var previewHTML: String? = nil
    @Published private(set) var isLoadingPreview = false

    private let apiManager: GmailAPIManager
    private var searchTask: Task<Void, Never>?
    private var debounceCancellable: AnyCancellable?
    private var pageTokens: [String: String] = [:] // accountId -> nextPageToken
    private var lastQuery: String = ""

    static let debounceInterval: TimeInterval = 0.3

    init(apiManager: GmailAPIManager) {
        self.apiManager = apiManager
        setupDebounce()
    }

    private func setupDebounce() {
        debounceCancellable = $query
            .debounce(for: .seconds(Self.debounceInterval), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] newQuery in
                self?.performSearch(query: newQuery)
            }
    }

    func performSearch(query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            selectedIndex = nil
            pageTokens = [:]
            hasMore = false
            return
        }

        lastQuery = trimmed
        isSearching = true
        selectedIndex = nil
        pageTokens = [:]
        searchTask = Task {
            let (found, tokens) = await apiManager.searchEmailsWithTokens(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            pageTokens = tokens
            hasMore = !tokens.isEmpty
            isSearching = false
        }
    }

    func loadMore() {
        guard hasMore, !isLoadingMore, !lastQuery.isEmpty else { return }
        isLoadingMore = true
        searchTask = Task {
            let (moreEmails, tokens) = await apiManager.searchEmailsWithTokens(query: lastQuery, pageTokens: pageTokens)
            guard !Task.isCancelled else { return }
            let existingIds = Set(results.map(\.id))
            let uniqueNew = moreEmails.filter { !existingIds.contains($0.id) }
            results.append(contentsOf: Email.sortedByDate(uniqueNew))
            pageTokens = tokens
            hasMore = !tokens.isEmpty
            isLoadingMore = false
        }
    }

    func moveSelection(down: Bool) {
        guard !results.isEmpty else { return }
        if let current = selectedIndex {
            let next = down ? current + 1 : current - 1
            selectedIndex = max(0, min(next, results.count - 1))
        } else {
            selectedIndex = down ? 0 : results.count - 1
        }
    }

    var selectedEmail: Email? {
        guard let idx = selectedIndex, results.indices.contains(idx) else { return nil }
        return results[idx]
    }

    private var previewTask: Task<Void, Never>?

    func showPreview() {
        guard let email = selectedEmail, email.id != previewEmail?.id else { return }
        previewTask?.cancel()
        previewEmail = email
        previewHTML = nil
        isLoadingPreview = true
        previewTask = Task {
            do {
                let message = try await apiManager.fetchMessageContent(msgId: email.msgId, accountId: email.accountId)
                guard !Task.isCancelled else { return }
                if let payload = message.payload {
                    let body = extractBodyFromPayload(payload)
                    previewHTML = body.isEmpty ? "<p style=\"color:#888;\">No message body</p>" : body
                } else {
                    previewHTML = "<p style=\"color:#888;\">No message body</p>"
                }
            } catch {
                guard !Task.isCancelled else { return }
                previewHTML = "<p style=\"color:#c00;\">Failed to load preview</p>"
            }
            isLoadingPreview = false
        }
    }

    func hidePreview() {
        previewTask?.cancel()
        previewEmail = nil
        previewHTML = nil
        isLoadingPreview = false
    }

    func clear() {
        query = ""
        results = []
        isSearching = false
        selectedIndex = nil
        searchTask?.cancel()
        previewTask?.cancel()
        pageTokens = [:]
        hasMore = false
        lastQuery = ""
        previewEmail = nil
        previewHTML = nil
        isLoadingPreview = false
    }
}

struct SearchOverlay: View {
    @Binding var isPresented: Bool
    @ObservedObject var searchViewModel: SearchViewModel
    let accountManager: AccountManager
    let onSelectEmail: (Email) -> Void

    @FocusState private var isSearchFieldFocused: Bool
    @State private var previewHasFocus = false

    private var hasResults: Bool { !searchViewModel.results.isEmpty }
    private var showingPreview: Bool { searchViewModel.previewEmail != nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 0) {
                    searchField
                    resultsList
                }
                .frame(width: 680)
                .frame(maxHeight: hasResults ? 400 : nil)
                .fixedSize(horizontal: false, vertical: !hasResults)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

                if showingPreview {
                    SearchPreviewPanel(
                        email: searchViewModel.previewEmail,
                        html: searchViewModel.previewHTML,
                        isLoading: searchViewModel.isLoadingPreview,
                        hasFocus: previewHasFocus,
                        onLeftArrow: {
                            searchViewModel.hidePreview()
                            previewHasFocus = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isSearchFieldFocused = true
                            }
                        },
                        onEscape: { dismiss() }
                    )
                    .frame(width: 500, height: 400)
                    .background(.ultraThickMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 100)
            .animation(.easeOut(duration: 0.2), value: showingPreview)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFieldFocused = true
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 17))

            TextField("Search emails...", text: $searchViewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($isSearchFieldFocused)
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    searchViewModel.moveSelection(down: false)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    searchViewModel.moveSelection(down: true)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard searchViewModel.selectedEmail != nil else { return .ignored }
                    searchViewModel.showPreview()
                    previewHasFocus = true
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    guard showingPreview else { return .ignored }
                    searchViewModel.hidePreview()
                    previewHasFocus = false
                    return .handled
                }
                .onSubmit {
                    if let email = searchViewModel.selectedEmail {
                        selectEmail(email)
                    } else if let first = searchViewModel.results.first {
                        selectEmail(first)
                    }
                }

            if searchViewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if !searchViewModel.query.isEmpty {
                Button {
                    searchViewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                NSWorkspace.shared.open(URL(string: "https://support.google.com/mail/answer/7190")!)
            } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .help("Gmail search operators")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultsList: some View {
        if !searchViewModel.results.isEmpty {
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(searchViewModel.results.enumerated()), id: \.element.id) { index, email in
                            SearchResultRow(
                                email: email,
                                account: accountManager.account(for: email.accountId),
                                isSelected: searchViewModel.selectedIndex == index,
                                onPreview: {
                                    searchViewModel.selectedIndex = index
                                    searchViewModel.showPreview()
                                    previewHasFocus = true
                                }
                            )
                            .id(email.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectEmail(email)
                            }
                            .onAppear {
                                if index == searchViewModel.results.count - 3 && searchViewModel.hasMore {
                                    searchViewModel.loadMore()
                                }
                            }

                            if email.id != searchViewModel.results.last?.id {
                                Divider().padding(.leading, 40)
                            }
                        }

                        if searchViewModel.isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: searchViewModel.selectedIndex) { _, newIndex in
                    if let newIndex, searchViewModel.results.indices.contains(newIndex) {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(searchViewModel.results[newIndex].id)
                        }
                    }
                }
            }
        } else if !searchViewModel.query.isEmpty && !searchViewModel.isSearching {
            Divider()
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No results found")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private func selectEmail(_ email: Email) {
        onSelectEmail(email)
        dismiss()
    }

    private func dismiss() {
        previewHasFocus = false
        searchViewModel.clear()
        isPresented = false
    }
}

struct SearchResultRow: View {
    let email: Email
    let account: Account?
    var isSelected: Bool = false
    var onPreview: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(account?.color.swiftUIColor ?? .gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(email.from)
                        .font(.system(size: 14, weight: email.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(email.date.shortRelative)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Text(email.subject)
                    .font(.system(size: 13, weight: email.isRead ? .regular : .medium))
                    .lineLimit(1)

                Text(email.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    onPreview?()
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - Preview Panel

struct SearchPreviewPanel: View {
    let email: Email?
    let html: String?
    let isLoading: Bool
    var hasFocus: Bool = false
    var onLeftArrow: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let email {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(email.subject)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    HStack {
                        Text(email.from)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(email.date.shortRelative)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // Body
                if isLoading {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                } else if let html {
                    SearchPreviewWebView(
                        html: html,
                        hasFocus: hasFocus,
                        onLeftArrow: onLeftArrow,
                        onEscape: onEscape
                    )
                } else {
                    Spacer()
                }
            }
        }
    }
}

struct SearchPreviewWebView: NSViewRepresentable {
    let html: String
    let hasFocus: Bool
    var onLeftArrow: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.appearance = NSAppearance(named: .aqua)
        context.coordinator.webView = webView

        context.coordinator.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard context.coordinator.hasFocus else { return event }
            switch event.keyCode {
            case 123: // left arrow
                context.coordinator.onLeftArrow?()
                return nil
            case 53: // escape
                context.coordinator.onEscape?()
                return nil
            case 125: // down arrow
                context.coordinator.webView?.evaluateJavaScript("window.scrollBy(0, 40)", completionHandler: nil)
                return nil
            case 126: // up arrow
                context.coordinator.webView?.evaluateJavaScript("window.scrollBy(0, -40)", completionHandler: nil)
                return nil
            case 49: // space
                let amount = event.modifierFlags.contains(.shift) ? -200 : 200
                context.coordinator.webView?.evaluateJavaScript("window.scrollBy(0, \(amount))", completionHandler: nil)
                return nil
            default:
                return event
            }
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLeftArrow = onLeftArrow
        context.coordinator.onEscape = onEscape
        context.coordinator.hasFocus = hasFocus
        let wrapped = wrapEmailHTML(html, subject: "")
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        if let monitor = coordinator.keyMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.keyMonitor = nil
        }
    }

    class Coordinator {
        var keyMonitor: Any?
        weak var webView: WKWebView?
        var onLeftArrow: (() -> Void)?
        var onEscape: (() -> Void)?
        var hasFocus = false
    }
}
