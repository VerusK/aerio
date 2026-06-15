import SwiftUI
import AppKit

struct OutboxList: View {
    @EnvironmentObject var outboxService: OutboxService
    /// Re-open a message in the compose editor to fix and resend it.
    var onEdit: (OutboxItemSnapshot) -> Void = { _ in }

    var body: some View {
        if outboxService.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Outbox is empty")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(outboxService.items, id: \.id) { item in
                    OutboxRow(item: item, onEdit: onEdit)
                }
            }
        }
    }
}

/// One stable timer publisher per view tree, hoisted out of view body to avoid
/// republishing on every re-render (which can cause SwiftUI subscription churn
/// and rare layout crashes when the parent updates rapidly).
private let outboxRowTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

private struct OutboxRow: View {
    let item: OutboxItemSnapshot
    let onEdit: (OutboxItemSnapshot) -> Void
    @EnvironmentObject var outboxService: OutboxService
    @State private var nowTick = Date()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 22)
            // Click the message body to open it in the editor (fix & resend).
            VStack(alignment: .leading, spacing: 2) {
                Text(item.subject.isEmpty ? "(no subject)" : item.subject)
                    .font(.body)
                Text("To: \(item.recipientsPreview)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let countdown = pendingCountdownText {
                    Text(countdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // A short status only — the full error is one click away via
                // "Copy error" rather than dumped inline (it can be a long JSON blob).
                if item.status == .failed {
                    Text("Couldn’t send — click to edit & resend")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onEdit(item) }
            .help("Click to open this message in the editor")
            actions
        }
        .padding(.vertical, 4)
        .onReceive(outboxRowTimer) { _ in
            // Drives the pending countdown text. Cheap when the row is off-screen
            // (SwiftUI gates onReceive on visibility for List rows).
            nowTick = Date()
        }
    }

    /// "Sending in 12s" text for a pending item with a future nextAttemptAt (Undo Send window
    /// or backoff). Returns nil for items that should fire immediately or have already moved on.
    private var pendingCountdownText: String? {
        guard item.status == .pending else { return nil }
        let secondsLeft = Int(item.nextAttemptAt.timeIntervalSince(nowTick).rounded(.up))
        guard secondsLeft > 0 else { return nil }
        if item.attemptCount > 0 {
            return "Retrying in \(secondsLeft)s"
        }
        return "Sending in \(secondsLeft)s"
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "hourglass")
                .foregroundStyle(.secondary)
        case .sending:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            // Open in the editor to fix recipients/body and resend.
            Button("Edit") {
                onEdit(item)
            }
            .buttonStyle(.bordered)
            .help("Open this message in the editor to fix and resend it")

            if item.lastError != nil {
                Button("Copy error") {
                    copyToPasteboard(item.lastError ?? "")
                }
                .buttonStyle(.bordered)
                .help("Copy the full send error to the clipboard")
            }

            if item.status == .failed {
                Button("Retry") {
                    Task { try? await outboxService.retry(itemId: item.id) }
                }
                .buttonStyle(.bordered)
                .help("Send again as-is (use Edit instead if the recipient was wrong)")
            }

            Button("Cancel") {
                Task { try? await outboxService.cancel(itemId: item.id) }
            }
            .buttonStyle(.bordered)
            .help("Remove this message from the Outbox")
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
