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
}
