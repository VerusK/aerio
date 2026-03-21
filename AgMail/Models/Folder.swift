import Foundation

enum Folder: String, CaseIterable, Identifiable, Codable, Sendable {
    case inbox
    case archive
    case trash
    case spam
    case drafts

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .spam: return "Spam"
        case .drafts: return "Drafts"
        }
    }

    var gmailParameter: String {
        switch self {
        case .inbox: return "inbox"
        case .archive: return "all"
        case .trash: return "trash"
        case .spam: return "spam"
        case .drafts: return "drafts"
        }
    }

    var gmailQuery: String {
        switch self {
        case .inbox: return "in:inbox"
        case .archive: return "-in:inbox -in:sent -in:trash -in:spam -in:drafts"
        case .trash: return "in:trash"
        case .spam: return "in:spam"
        case .drafts: return "in:drafts"
        }
    }

    var gmailLabelIds: [String] {
        switch self {
        case .inbox: return [GmailLabelId.inbox]
        case .archive: return []
        case .trash: return [GmailLabelId.trash]
        case .spam: return [GmailLabelId.spam]
        case .drafts: return [GmailLabelId.draft]
        }
    }

    func matchesLabels(_ labelIds: [String]) -> Bool {
        switch self {
        case .archive:
            return !labelIds.contains(GmailLabelId.inbox)
                && !labelIds.contains(GmailLabelId.sent)
                && !labelIds.contains(GmailLabelId.trash)
                && !labelIds.contains(GmailLabelId.spam)
                && !labelIds.contains(GmailLabelId.draft)
        default:
            return gmailLabelIds.allSatisfy { labelIds.contains($0) }
        }
    }
}
