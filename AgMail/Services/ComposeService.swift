import Foundation

enum ComposeType: Sendable {
    case new
    case reply
    case replyAll
    case forward
}

struct ComposeService: Sendable {
    static func composeURL(
        type: ComposeType,
        accountIndex: Int = 0,
        to: String? = nil,
        subject: String? = nil,
        body: String? = nil,
        msgId: String? = nil
    ) -> URL? {
        var components = URLComponents(string: "https://mail.google.com/mail/u/\(accountIndex)/")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "tf", value: "1"),
        ]

        switch type {
        case .new:
            if let to { queryItems.append(URLQueryItem(name: "to", value: to)) }
            if let subject { queryItems.append(URLQueryItem(name: "su", value: subject)) }
            if let body { queryItems.append(URLQueryItem(name: "body", value: body)) }

        case .reply:
            guard let msgId else { return nil }
            queryItems.append(URLQueryItem(name: "rm", value: msgId))
            queryItems.append(URLQueryItem(name: "rmt", value: "reply"))
            if let body { queryItems.append(URLQueryItem(name: "body", value: body)) }

        case .replyAll:
            guard let msgId else { return nil }
            queryItems.append(URLQueryItem(name: "rm", value: msgId))
            queryItems.append(URLQueryItem(name: "rmt", value: "replyall"))
            if let body { queryItems.append(URLQueryItem(name: "body", value: body)) }

        case .forward:
            guard let msgId else { return nil }
            queryItems.append(URLQueryItem(name: "rm", value: msgId))
            queryItems.append(URLQueryItem(name: "rmt", value: "forward"))
            if let to { queryItems.append(URLQueryItem(name: "to", value: to)) }
            if let body { queryItems.append(URLQueryItem(name: "body", value: body)) }
        }

        components?.queryItems = queryItems
        return components?.url
    }
}
