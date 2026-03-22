import Foundation

struct RFC2822Builder {
    static func buildRawMessage(
        from: String,
        to: String,
        cc: String? = nil,
        subject: String,
        body: String,
        inReplyTo: String? = nil,
        references: String? = nil
    ) -> String {
        var lines: [String] = []
        let sanitize = { (s: String) in s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
        lines.append("From: \(sanitize(from))")
        lines.append("To: \(sanitize(to))")
        if let cc = cc, !cc.isEmpty {
            lines.append("Cc: \(sanitize(cc))")
        }
        lines.append("Subject: \(qEncode(subject))")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        if let inReplyTo = inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if let references = references, !references.isEmpty {
            lines.append("References: \(references)")
        }
        lines.append("")
        let bodyBase64 = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        lines.append(bodyBase64)

        let raw = lines.joined(separator: "\r\n")
        return base64URLEncode(Data(raw.utf8))
    }

    static func buildRawHTMLMessage(
        from: String,
        to: String,
        cc: String? = nil,
        subject: String,
        htmlBody: String,
        plainBody: String,
        inReplyTo: String? = nil,
        references: String? = nil
    ) -> String {
        let boundary = "boundary_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var lines: [String] = []
        let sanitize = { (s: String) in s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
        lines.append("From: \(sanitize(from))")
        lines.append("To: \(sanitize(to))")
        if let cc = cc, !cc.isEmpty {
            lines.append("Cc: \(sanitize(cc))")
        }
        lines.append("Subject: \(qEncode(subject))")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
        if let inReplyTo = inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if let references = references, !references.isEmpty {
            lines.append("References: \(references)")
        }
        lines.append("")

        // Plain text part
        lines.append("--\(boundary)")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(Data(plainBody.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
        lines.append("")

        // HTML part
        lines.append("--\(boundary)")
        lines.append("Content-Type: text/html; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(Data(htmlBody.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
        lines.append("")

        lines.append("--\(boundary)--")

        let raw = lines.joined(separator: "\r\n")
        return base64URLEncode(Data(raw.utf8))
    }

    static func qEncode(_ string: String) -> String {
        let ascii = string.unicodeScalars.allSatisfy { $0.value < 128 }
        if ascii { return string }

        let encoded = string.utf8.map { byte -> String in
            if byte == 0x20 {
                return "_"
            } else if (byte >= 0x21 && byte <= 0x3C) || (byte >= 0x3E && byte <= 0x7E) {
                // Printable ASCII except = and ?
                if byte == 0x3D || byte == 0x3F || byte == 0x5F {
                    return String(format: "=%02X", byte)
                }
                return String(UnicodeScalar(byte))
            } else {
                return String(format: "=%02X", byte)
            }
        }.joined()

        return "=?UTF-8?Q?\(encoded)?="
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64URLEncoded()
    }

    static func base64URLDecode(_ string: String) -> Data? {
        Data.fromBase64URL(string)
    }
}
