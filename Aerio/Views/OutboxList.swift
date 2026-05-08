import SwiftUI

struct OutboxList: View {
    @EnvironmentObject var outboxService: OutboxService

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
                    OutboxRow(item: item)
                }
            }
        }
    }
}

private struct OutboxRow: View {
    let item: OutboxItem
    @EnvironmentObject var outboxService: OutboxService
    @State private var nowTick = Date()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 22)
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
                if let err = item.lastError, item.status == .failed {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 4)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Drives the pending countdown text. Only fires while this row is on screen.
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
            if item.status == .failed {
                Button("Retry") {
                    Task { try? await outboxService.retry(itemId: item.id) }
                }
                .buttonStyle(.bordered)
            }
            Button("Cancel") {
                Task { try? await outboxService.cancel(itemId: item.id) }
            }
            .buttonStyle(.bordered)
        }
    }
}
