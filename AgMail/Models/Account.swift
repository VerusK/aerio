import Foundation
import SwiftUI

struct Account: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let email: String
    var displayName: String
    var color: AccountColor
    var avatarLetter: String

    init(
        id: String = UUID().uuidString,
        email: String,
        displayName: String,
        color: AccountColor = .blue,
        avatarLetter: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.color = color
        self.avatarLetter = avatarLetter ?? String(displayName.prefix(1)).uppercased()
    }
}

enum AccountColor: String, CaseIterable, Codable, Sendable {
    case blue, red, green, orange, purple, teal, pink, indigo

    var swiftUIColor: Color {
        switch self {
        case .blue: return .blue
        case .red: return .red
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        case .teal: return .teal
        case .pink: return .pink
        case .indigo: return .indigo
        }
    }
}
