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
