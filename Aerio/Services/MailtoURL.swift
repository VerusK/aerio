import Foundation
import os.log

private let logger = Logger(subsystem: "Aerio", category: "MailtoURL")

/// Parses `mailto:` links (RFC 6068) into compose pre-fill content.
enum MailtoURL {
    /// Returns nil for any URL that isn't `mailto:`. `bcc` is dropped: compose has no
    /// Bcc field, and moving those addresses into To/Cc would expose them.
    static func seed(from url: URL) -> ComposeSeed? {
        guard url.scheme?.lowercased() == "mailto",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // `percentEncodedPath`, then decode: `path` would also be decoded, but this keeps
        // "+" literal (RFC 6068) exactly like the query values below.
        var to = ContactsCache.splitAddressList(components.percentEncodedPath.removingPercentEncoding ?? "")
        var cc: [String] = []
        var subject = ""
        var body = ""

        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "to": to += ContactsCache.splitAddressList(value)
            case "cc": cc += ContactsCache.splitAddressList(value)
            // Single-line field: collapse CR/LF runs so they can't reach the headers.
            case "subject": subject = value.replacingOccurrences(
                of: "[\\r\\n]+", with: " ", options: .regularExpression)
            case "body": body = value.replacingOccurrences(of: "\r\n", with: "\n")
            case "bcc": logger.info("Ignoring bcc in mailto link: compose has no Bcc field")
            default: break
            }
        }

        return ComposeSeed(
            to: to.joined(separator: ", "),
            cc: cc.joined(separator: ", "),
            subject: subject,
            body: body,
            marksDirty: false
        )
    }
}
