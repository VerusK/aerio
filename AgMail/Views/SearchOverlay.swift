import SwiftUI
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [Email] = []
    @Published private(set) var isSearching = false

    private let apiManager: GmailAPIManager
    private var searchTask: Task<Void, Never>?
    private var debounceCancellable: AnyCancellable?

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
            return
        }

        isSearching = true
        searchTask = Task {
            let found = await apiManager.searchEmails(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }

    func clear() {
        query = ""
        results = []
        isSearching = false
        searchTask?.cancel()
    }
}

struct SearchOverlay: View {
    @Binding var isPresented: Bool
    @ObservedObject var searchViewModel: SearchViewModel
    let accountManager: AccountManager
    let onSelectEmail: (Email) -> Void

    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                searchField
                resultsList
            }
            .frame(width: 600)
            .frame(maxHeight: 450)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
        .onAppear {
            isSearchFieldFocused = true
        }
        .onExitCommand {
            dismiss()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))

            TextField("Search emails...", text: $searchViewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isSearchFieldFocused)
                .onSubmit {
                    if let first = searchViewModel.results.first {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultsList: some View {
        if !searchViewModel.results.isEmpty {
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(searchViewModel.results) { email in
                        SearchResultRow(
                            email: email,
                            account: accountManager.account(for: email.accountId)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectEmail(email)
                        }

                        if email.id != searchViewModel.results.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } else if !searchViewModel.query.isEmpty && !searchViewModel.isSearching {
            Divider()
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No results found")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
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
        searchViewModel.clear()
        isPresented = false
    }
}

struct SearchResultRow: View {
    let email: Email
    let account: Account?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(account?.color.swiftUIColor ?? .gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(email.from)
                        .font(.system(size: 13, weight: email.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(email.date.shortRelative)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(email.subject)
                    .font(.system(size: 12, weight: email.isRead ? .regular : .medium))
                    .lineLimit(1)

                Text(email.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.clear)
    }
}
