import SwiftUI

struct ThreadDetailView: View {
    let email: Email
    let apiManager: GmailAPIManager
    let folder: Folder

    var onReply: ((ThreadMessage) -> Void)?
    var onReplyAll: ((ThreadMessage) -> Void)?
    var onForward: ((ThreadMessage) -> Void)?
    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSpam: (() -> Void)?
    var onMoveToInbox: (() -> Void)?
    var onRegisterScroll: ((@escaping (Int) -> Void) -> Void)?

    @State private var threadMessages: [ThreadMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            threadActionBar
            threadHeader
            Divider()

            if isLoading {
                ProgressView("Loading thread…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { loadThread() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(threadMessages) { message in
                                ThreadMessageView(
                                    message: message,
                                    apiManager: apiManager,
                                    onReply: { onReply?(message) },
                                    onReplyAll: { onReplyAll?(message) },
                                    onForward: { onForward?(message) }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .onAppear {
                        if let lastId = threadMessages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                        onRegisterScroll? { direction in
                            // Keyboard arrow scroll: find visible message and scroll to next/prev
                            guard !threadMessages.isEmpty else { return }
                            let step = direction > 0 ? 1 : -1
                            // Use scrollOffset to track approximate position
                            scrollOffset += CGFloat(step)
                            let index = max(0, min(threadMessages.count - 1, Int(scrollOffset)))
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(threadMessages[index].id, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { loadThread() }
        .onChange(of: email.threadId) { _, _ in loadThread() }
    }

    private var threadActionBar: some View {
        HStack(spacing: 4) {
            if folder == .inbox {
                actionButton(icon: "archivebox", tooltip: "Archive (\(ShortcutAction.archiveMessage.shortcutLabel))", action: onArchive)
            }
            if folder != .inbox {
                actionButton(icon: "tray.and.arrow.down", tooltip: "Move to Inbox (\(ShortcutAction.moveToInbox.shortcutLabel))", action: onMoveToInbox)
            }
            actionButton(icon: "exclamationmark.octagon", tooltip: "Spam (\(ShortcutAction.spamMessage.shortcutLabel))", action: onSpam)
            actionButton(icon: "trash", tooltip: "Delete (\(ShortcutAction.deleteMessage.shortcutLabel))", action: onDelete)

            Spacer()

            if !threadMessages.isEmpty {
                Text("\(threadMessages.count) messages")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var threadHeader: some View {
        Text(email.subject)
            .font(.system(size: 16, weight: .semibold))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func actionButton(icon: String, tooltip: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .disabled(action == nil)
    }

    private func loadThread() {
        isLoading = true
        loadError = nil
        Task {
            do {
                threadMessages = try await apiManager.fetchThread(
                    threadId: email.threadId,
                    accountId: email.accountId
                )
                isLoading = false
            } catch {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }
}
