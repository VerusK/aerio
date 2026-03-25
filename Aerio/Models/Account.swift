import Foundation
import SwiftUI

struct Account: Identifiable, Equatable, Hashable, Codable, Sendable {
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

    var initials: String {
        Self.computeInitials(from: displayName)
    }

    static func computeInitials(from name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }
}

enum AccountColor: String, CaseIterable, Codable, Sendable {
    case blue, red, green, orange, purple, teal, pink, indigo

    static func nextUniqueColor(existingAccounts: [Account]) -> AccountColor {
        let usedColors = existingAccounts.map { $0.color }
        if let unused = allCases.first(where: { !usedColors.contains($0) }) {
            return unused
        }
        let counts = Dictionary(usedColors.map { ($0, 1) }, uniquingKeysWith: +)
        return allCases.min(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) ?? .blue
    }

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
