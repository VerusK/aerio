import Foundation

struct RFC2822Builder {
    static func buildRawMessage(
        from: String,
        to: String,
        cc: String? = nil,
        subject: String,
        body: String,
        inReplyTo: String? = nil,
        references: String? = nil,
        messageId: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("From: \(encodeAddressList(from))")
        lines.append("To: \(encodeAddressList(to))")
        if let cc = cc, !cc.isEmpty {
            lines.append("Cc: \(encodeAddressList(cc))")
        }
        lines.append("Subject: \(qEncode(subject))")
        if let messageId, !messageId.isEmpty {
            lines.append("Message-ID: \(messageId)")
        }
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
        references: String? = nil,
        messageId: String? = nil
    ) -> String {
        let boundary = "boundary_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var lines: [String] = []
        lines.append("From: \(encodeAddressList(from))")
        lines.append("To: \(encodeAddressList(to))")
        if let cc = cc, !cc.isEmpty {
            lines.append("Cc: \(encodeAddressList(cc))")
        }
        lines.append("Subject: \(qEncode(subject))")
        if let messageId, !messageId.isEmpty {
            lines.append("Message-ID: \(messageId)")
        }
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
        references: String? = nil,
        messageId: String? = nil
    ) -> String {
        let mixedBoundary = "mixed_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let relatedBoundary = "related_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let altBoundary = "alt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let hasInline = !inlineImages.isEmpty
        let hasAttachments = !attachments.isEmpty

        var lines: [String] = []
        lines.append("From: \(encodeAddressList(from))")
        lines.append("To: \(encodeAddressList(to))")
        if let cc = cc, !cc.isEmpty {
            lines.append("Cc: \(encodeAddressList(cc))")
        }
        lines.append("Subject: \(qEncode(subject))")
        if let messageId, !messageId.isEmpty {
            lines.append("Message-ID: \(messageId)")
        }
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

    /// Build a valid RFC 5322 address-list header value ("To"/"Cc"/"From") from a
    /// user-entered string like `Name <email>, other@x.com`.
    ///
    /// Crucially, this RFC 2047-encodes any non-ASCII display name and quotes ASCII
    /// names containing specials. Without it, a non-ASCII display name (e.g. a
    /// Cyrillic contact name pulled in by autocomplete) lands in the header as raw
    /// UTF-8 and Gmail rejects the send with `HTTP 400: Invalid To header`.
    /// Reuses `ContactsCache.parseAddressList`, which is quote-aware and drops empty
    /// entries (so stray trailing commas are normalized away too).
    static func encodeAddressList(_ raw: String) -> String {
        let parsed = ContactsCache.parseAddressList(raw)
        guard !parsed.isEmpty else { return stripCRLF(raw) }
        let encoded: [String] = parsed.compactMap { addr in
            let email = stripCRLF(addr.email)
            guard !email.isEmpty else { return nil }
            guard let name = addr.displayName, !name.isEmpty else { return email }
            return "\(encodeDisplayName(stripCRLF(name))) <\(email)>"
        }
        return encoded.isEmpty ? stripCRLF(raw) : encoded.joined(separator: ", ")
    }

    /// Encode a display name for use in an address header: RFC 2047 encoded-word for
    /// non-ASCII, quoted-string for ASCII names containing RFC 5322 specials,
    /// otherwise verbatim.
    private static func encodeDisplayName(_ name: String) -> String {
        let isASCII = name.unicodeScalars.allSatisfy { $0.value < 128 }
        if !isASCII {
            return qEncode(name) // =?UTF-8?Q?…?= — encoded-words need no quoting
        }
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        guard name.rangeOfCharacter(from: specials) != nil else { return name }
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func stripCRLF(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
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

extension RFC2822Builder {
    /// Single entry point — picks the right MIME structure based on the payload.
    static func build(_ payload: ComposePayload) -> String {
        if !payload.attachments.isEmpty || !payload.inlineImages.isEmpty {
            return buildRawHTMLMessageWithAttachments(
                from: payload.from, to: payload.to, cc: payload.cc, subject: payload.subject,
                htmlBody: payload.htmlBody ?? payload.body, plainBody: payload.body,
                attachments: payload.attachments, inlineImages: payload.inlineImages,
                inReplyTo: payload.inReplyTo, references: payload.references,
                messageId: payload.messageId
            )
        }
        if let html = payload.htmlBody, !html.isEmpty {
            return buildRawHTMLMessage(
                from: payload.from, to: payload.to, cc: payload.cc, subject: payload.subject,
                htmlBody: html, plainBody: payload.body,
                inReplyTo: payload.inReplyTo, references: payload.references,
                messageId: payload.messageId
            )
        }
        return buildRawMessage(
            from: payload.from, to: payload.to, cc: payload.cc, subject: payload.subject,
            body: payload.body,
            inReplyTo: payload.inReplyTo, references: payload.references,
            messageId: payload.messageId
        )
    }
}
