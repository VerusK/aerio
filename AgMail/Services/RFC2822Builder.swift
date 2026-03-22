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

    struct Attachment {
        let filename: String
        let mimeType: String
        let data: Data
    }

    struct InlineImage {
        let cid: String
        let mimeType: String
        let data: Data
    }

    static func buildRawHTMLMessageWithAttachments(
        from: String,
        to: String,
        cc: String? = nil,
        subject: String,
        htmlBody: String,
        plainBody: String,
        attachments: [Attachment] = [],
        inlineImages: [InlineImage] = [],
        inReplyTo: String? = nil,
        references: String? = nil
    ) -> String {
        let mixedBoundary = "mixed_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let relatedBoundary = "related_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let altBoundary = "alt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let hasInline = !inlineImages.isEmpty
        let hasAttachments = !attachments.isEmpty

        var lines: [String] = []
        let sanitize = { (s: String) in s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
        lines.append("From: \(sanitize(from))")
        lines.append("To: \(sanitize(to))")
        if let cc = cc, !cc.isEmpty {
            lines.append("Cc: \(sanitize(cc))")
        }
        lines.append("Subject: \(qEncode(subject))")
        lines.append("MIME-Version: 1.0")

        if hasAttachments {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"")
        } else if hasInline {
            lines.append("Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"")
        } else {
            lines.append("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"")
        }

        if let inReplyTo = inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if let references = references, !references.isEmpty {
            lines.append("References: \(references)")
        }
        lines.append("")

        // Structure:
        // With attachments + inline: mixed > [related > [alternative > [plain, html], inline images...], attachments...]
        // With inline only:          related > [alternative > [plain, html], inline images...]
        // With attachments only:     mixed > [alternative > [plain, html], attachments...]
        // Neither:                   alternative > [plain, html]

        if hasAttachments {
            lines.append("--\(mixedBoundary)")
            if hasInline {
                lines.append("Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"")
                lines.append("")
            }
        }

        if hasInline {
            if !hasAttachments {
                // related is top-level, already opened
            }
            lines.append("--\(relatedBoundary)")
            lines.append("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"")
            lines.append("")
        } else if hasAttachments {
            lines.append("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"")
            lines.append("")
        }

        // Plain text part
        lines.append("--\(altBoundary)")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(Data(plainBody.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
        lines.append("")

        // HTML part
        lines.append("--\(altBoundary)")
        lines.append("Content-Type: text/html; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(Data(htmlBody.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
        lines.append("")

        lines.append("--\(altBoundary)--")
        lines.append("")

        // Inline images (inside multipart/related)
        if hasInline {
            for img in inlineImages {
                lines.append("--\(relatedBoundary)")
                lines.append("Content-Type: \(img.mimeType)")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("Content-ID: <\(img.cid)>")
                lines.append("Content-Disposition: inline")
                lines.append("")
                lines.append(img.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
                lines.append("")
            }
            lines.append("--\(relatedBoundary)--")
            lines.append("")
        }

        // File attachments (inside multipart/mixed)
        if hasAttachments {
            for attachment in attachments {
                lines.append("--\(mixedBoundary)")
                lines.append("Content-Type: \(attachment.mimeType); name=\"\(qEncode(attachment.filename))\"")
                lines.append("Content-Disposition: attachment; filename=\"\(qEncode(attachment.filename))\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("")
                lines.append(attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
                lines.append("")
            }
            lines.append("--\(mixedBoundary)--")
        }

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
