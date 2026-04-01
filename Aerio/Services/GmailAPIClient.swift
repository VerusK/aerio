import Foundation
import os

enum ClientState: Equatable {
    case idle
    case syncing
    case error(String)
}

enum GmailAPIError: LocalizedError {
    case unauthorized
    case sessionExpired
    case forbidden(String)
    case notFound
    case rateLimited
    case serverError(Int)
    case decodingError(String)
    case historyExpired
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Unauthorized"
        case .sessionExpired: return "Session expired - please re-authenticate"
        case .forbidden(let msg): return "Forbidden: \(msg)"
        case .notFound: return "Resource not found"
        case .rateLimited: return "Rate limited"
        case .serverError(let code): return "Server error: \(code)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .historyExpired: return "History expired - full sync required"
        case .networkError(let msg): return "Network error: \(msg)"
        }
    }
}

final class GmailAPIClient: ObservableObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "Aerio", category: "GmailAPIClient")
    private static let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
    private static let maxConcurrentFetches = 10

    let accountId: String
    let oauthManager: OAuthManager
    let session: URLSession
    let keychainStore: KeychainStore

    @Published var state: ClientState = .idle

    /// Coalesces concurrent token refresh calls into a single in-flight request.
    private var refreshTask: Task<String, Error>?

    init(accountId: String, oauthManager: OAuthManager, session: URLSession = .shared, keychainStore: KeychainStore = KeychainHelper.shared) {
        self.accountId = accountId
        self.oauthManager = oauthManager
        self.session = session
        self.keychainStore = keychainStore
    }

    // MARK: - Public API

    func listMessages(query: String? = nil, labelIds: [String]? = nil, maxResults: Int = 50, pageToken: String? = nil) async throws -> GmailMessageListResponse {
        var queryItems = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let query = query {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        if let labelIds = labelIds {
            for labelId in labelIds {
                queryItems.append(URLQueryItem(name: "labelIds", value: labelId))
            }
        }
        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        let request = try buildRequest(path: "/messages", queryItems: queryItems)
        return try await execute(request: request)
    }

    func getMessage(id: String, format: String = "full", metadataHeaders: [String]? = nil) async throws -> GmailMessage {
        var queryItems = [URLQueryItem(name: "format", value: format)]
        if let headers = metadataHeaders {
            for header in headers {
                queryItems.append(URLQueryItem(name: "metadataHeaders", value: header))
            }
        }
        let request = try buildRequest(path: "/messages/\(id)", queryItems: queryItems)
        return try await execute(request: request)
    }

    func getMessages(ids: [String], format: String = "full", metadataHeaders: [String]? = nil) async throws -> [GmailMessage] {
        try await withThrowingTaskGroup(of: GmailMessage.self) { group in
            var results: [GmailMessage] = []
            var pending = 0

            for id in ids {
                if pending >= Self.maxConcurrentFetches {
                    if let message = try await group.next() {
                        results.append(message)
                        pending -= 1
                    }
                }
                group.addTask {
                    try await self.getMessage(id: id, format: format, metadataHeaders: metadataHeaders)
                }
                pending += 1
            }

            for try await message in group {
                results.append(message)
            }

            return results
        }
    }

    func getThread(id: String, format: String = "full") async throws -> GmailThread {
        let queryItems = [URLQueryItem(name: "format", value: format)]
        let request = try buildRequest(path: "/threads/\(id)", queryItems: queryItems)
        return try await execute(request: request)
    }

    func modifyMessage(id: String, addLabels: [String]? = nil, removeLabels: [String]? = nil) async throws -> GmailMessage {
        let body = GmailModifyRequest(addLabelIds: addLabels, removeLabelIds: removeLabels)
        var request = try buildRequest(path: "/messages/\(id)/modify", method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request: request)
    }

    func trashMessage(id: String) async throws -> GmailMessage {
        let request = try buildRequest(path: "/messages/\(id)/trash", method: "POST")
        return try await execute(request: request)
    }

    func untrashMessage(id: String) async throws -> GmailMessage {
        let request = try buildRequest(path: "/messages/\(id)/untrash", method: "POST")
        return try await execute(request: request)
    }

    func sendMessage(raw: String) async throws -> GmailMessage {
        let body = GmailSendRequest(raw: raw)
        var request = try buildRequest(path: "/messages/send", method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request: request)
    }

    func createDraft(raw: String) async throws -> GmailDraft {
        let body = GmailDraftRequest(message: GmailDraftMessage(raw: raw))
        var request = try buildRequest(path: "/drafts", method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request: request)
    }

    func getDraft(draftId: String) async throws -> GmailDraft {
        let request = try buildRequest(path: "/drafts/\(draftId)?format=full")
        return try await execute(request: request)
    }

    func listDrafts() async throws -> GmailDraftsListResponse {
        let request = try buildRequest(path: "/drafts?maxResults=500")
        return try await execute(request: request)
    }

    func sendDraft(draftId: String) async throws -> GmailMessage {
        let body = ["id": draftId]
        var request = try buildRequest(path: "/drafts/send", method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request: request)
    }

    func deleteDraft(draftId: String) async throws {
        var request = try buildRequest(path: "/drafts/\(draftId)", method: "DELETE")
        let token = try await getValidAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.networkError("Invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 { throw GmailAPIError.notFound }
            throw GmailAPIError.networkError("Delete draft failed: \(httpResponse.statusCode)")
        }
    }

    func listLabels() async throws -> [GmailLabel] {
        let request = try buildRequest(path: "/labels")
        let response: GmailLabelsResponse = try await execute(request: request)
        return response.labels ?? []
    }

    func getLabel(id: String) async throws -> GmailLabel {
        let request = try buildRequest(path: "/labels/\(id)")
        return try await execute(request: request)
    }

    func getAttachment(messageId: String, attachmentId: String) async throws -> GmailAttachment {
        let request = try buildRequest(path: "/messages/\(messageId)/attachments/\(attachmentId)")
        return try await execute(request: request)
    }

    func listHistory(startHistoryId: String, labelId: String? = nil, pageToken: String? = nil) async throws -> GmailHistoryResponse {
        var queryItems = [URLQueryItem(name: "startHistoryId", value: startHistoryId)]
        if let labelId = labelId {
            queryItems.append(URLQueryItem(name: "labelId", value: labelId))
        }
        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        let request = try buildRequest(path: "/history", queryItems: queryItems)
        return try await execute(request: request)
    }

    // MARK: - Request Building

    private func buildRequest(path: String, method: String = "GET", queryItems: [URLQueryItem]? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: Self.baseURL + path) else {
            throw GmailAPIError.networkError("Invalid URL components: \(Self.baseURL + path)")
        }
        if let queryItems = queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw GmailAPIError.networkError("Invalid URL: \(Self.baseURL + path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    // MARK: - Execution with Auth + Retry

    private func execute<T: Decodable>(request: URLRequest, retryCount: Int = 0, hasRefreshed: Bool = false) async throws -> T {
        var authedRequest = request
        let token = try await getValidAccessToken()
        authedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: authedRequest)
        } catch {
            throw GmailAPIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200...299:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw GmailAPIError.decodingError(error.localizedDescription)
            }

        case 401:
            if hasRefreshed {
                throw GmailAPIError.sessionExpired
            }
            logger.debug("Got 401, refreshing token for \(self.accountId)")
            _ = try await coalescedRefresh()
            return try await execute(request: request, retryCount: retryCount, hasRefreshed: true)

        case 429:
            if retryCount >= 3 {
                throw GmailAPIError.rateLimited
            }
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init) ?? Double(retryCount + 1)
            logger.debug("Rate limited, retrying after \(retryAfter)s")
            try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            return try await execute(request: request, retryCount: retryCount + 1, hasRefreshed: hasRefreshed)

        case 403:
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw GmailAPIError.forbidden(body)

        case 404:
            throw GmailAPIError.notFound

        case 410:
            throw GmailAPIError.historyExpired

        case 500...599:
            if retryCount >= 2 {
                throw GmailAPIError.serverError(httpResponse.statusCode)
            }
            let delay = pow(2.0, Double(retryCount))
            logger.debug("Server error \(httpResponse.statusCode), retrying after \(delay)s")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await execute(request: request, retryCount: retryCount + 1, hasRefreshed: hasRefreshed)

        default:
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw GmailAPIError.networkError("Unexpected status \(httpResponse.statusCode): \(body)")
        }
    }

    private func getValidAccessToken() async throws -> String {
        guard let tokens = try keychainStore.loadTokens(for: accountId) else {
            throw GmailAPIError.unauthorized
        }
        if tokens.isExpired {
            return try await coalescedRefresh()
        }
        return tokens.accessToken
    }

    /// Ensures only one refresh request is in-flight at a time per client.
    /// Concurrent callers await the same task.
    private func coalescedRefresh() async throws -> String {
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task { @MainActor in
            try await self.oauthManager.refreshAccessToken(for: self.accountId)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}
