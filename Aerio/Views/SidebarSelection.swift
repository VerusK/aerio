import Foundation

enum SidebarSelection: Hashable {
    case folder(Folder)
    case outbox

    var folder: Folder {
        if case .folder(let f) = self { return f }
        return .inbox
    }

    var isOutbox: Bool {
        if case .outbox = self { return true }
        return false
    }
}
