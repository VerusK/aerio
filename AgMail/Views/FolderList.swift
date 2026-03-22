import SwiftUI

struct FolderList: View {
    @ObservedObject var unifiedMailbox: UnifiedMailbox
    @Binding var selectedFolder: Folder
    var selectedAccountId: String?

    var body: some View {
        List(Folder.allCases) { folder in
            folderRow(folder)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedFolder = folder
                }
                .listRowBackground(
                    selectedFolder == folder
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear
                )
        }
        .listStyle(.sidebar)
        .frame(minWidth: 140)
    }

    private func folderRow(_ folder: Folder) -> some View {
        HStack {
            Image(systemName: folder.iconName)
                .frame(width: 20)
            Text(folder.displayName)
                .lineLimit(1)
            Spacer()
            let count = unifiedMailbox.unreadCount(for: folder, accountId: selectedAccountId)
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .accessibilityIdentifier("folder-\(folder.rawValue)")
    }
}

// iconName extension moved to Folder.swift
