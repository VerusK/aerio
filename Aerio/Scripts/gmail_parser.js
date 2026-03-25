// gmail_parser.js
// Parses Gmail Basic HTML view email table into structured data.
// Injected into WKWebView via evaluateJavaScript.

(function() {
    "use strict";

    function parseEmailRows() {
        var emails = [];
        // Gmail Basic HTML uses a table-based layout for the inbox.
        // Each email row is a <tr> inside the main message table.
        // The table typically has class or is nested inside a specific structure.

        var rows = document.querySelectorAll("table > tbody > tr");

        for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            var cells = row.querySelectorAll("td");

            // Gmail Basic HTML email rows typically have 3+ cells:
            // Cell 0: checkbox + star
            // Cell 1: sender
            // Cell 2: subject + snippet
            // Cell 3: date/time (sometimes attached or a separate cell)
            if (cells.length < 3) continue;

            var email = parseRow(row, cells);
            if (email) {
                emails.push(email);
            }
        }

        return emails;
    }

    function parseRow(row, cells) {
        // Determine read status from row styling
        // Unread emails have <b> tags around sender/subject in Gmail Basic HTML
        var isRead = !row.querySelector("b");

        // Extract message ID from the checkbox or link
        var msgId = extractMsgId(row);
        if (!msgId) return null;

        // Parse sender from cell index 1
        var fromCell = cells.length >= 4 ? cells[1] : cells[0];
        var from = extractText(fromCell);

        // Parse subject + snippet from the next cell
        var subjectCell = cells.length >= 4 ? cells[2] : cells[1];
        var subjectData = parseSubjectCell(subjectCell);

        // Parse date from the last cell
        var dateCell = cells[cells.length - 1];
        var date = extractText(dateCell).trim();

        if (!from && !subjectData.subject) return null;

        return {
            msgId: msgId,
            from: from,
            subject: subjectData.subject,
            snippet: subjectData.snippet,
            date: date,
            isRead: isRead
        };
    }

    function extractMsgId(row) {
        // Gmail Basic HTML links contain message IDs in href
        // e.g., ?th=18abc123def or /mail/u/0/?th=18abc123def
        var links = row.querySelectorAll("a[href]");
        for (var i = 0; i < links.length; i++) {
            var href = links[i].getAttribute("href") || "";

            // Pattern: th=<hex_id>
            var thMatch = href.match(/[?&]th=([a-fA-F0-9]+)/);
            if (thMatch) return thMatch[1];

            // Pattern: /message/
            var msgMatch = href.match(/\/message\/([a-fA-F0-9]+)/);
            if (msgMatch) return msgMatch[1];
        }

        // Fallback: check input checkboxes
        var checkbox = row.querySelector("input[type='checkbox']");
        if (checkbox) {
            var val = checkbox.getAttribute("value") || checkbox.getAttribute("name");
            if (val && /^[a-fA-F0-9]+$/.test(val)) return val;
        }

        return null;
    }

    function parseSubjectCell(cell) {
        if (!cell) return { subject: "", snippet: "" };

        // In Gmail Basic HTML, subject is typically in a link <a>,
        // and snippet follows as text or in a <span> with lighter color
        var subjectLink = cell.querySelector("a");
        var subject = subjectLink ? extractText(subjectLink) : "";

        // Snippet is often the remaining text after the link,
        // or inside a <font color="#7777"> or <span> element
        var snippet = "";
        var fontEl = cell.querySelector("font[color]");
        if (fontEl) {
            snippet = extractText(fontEl);
        } else {
            // Get text content minus the subject
            var fullText = extractText(cell);
            if (subject && fullText.indexOf(subject) !== -1) {
                snippet = fullText.substring(fullText.indexOf(subject) + subject.length);
            }
        }

        // Clean up snippet: remove leading " - " or similar
        snippet = snippet.replace(/^\s*[-–—]\s*/, "").trim();

        return { subject: subject.trim(), snippet: snippet };
    }

    function extractText(el) {
        if (!el) return "";
        return (el.textContent || el.innerText || "").trim();
    }

    function parseUnreadCount() {
        // Gmail Basic HTML shows unread count in title or header
        // e.g., "Inbox (3)" or "Gmail - Inbox (3)"
        var title = document.title || "";
        var match = title.match(/\((\d+)\)/);
        if (match) return parseInt(match[1], 10);

        // Also check for explicit unread indicators in the page
        var inboxLinks = document.querySelectorAll("a[href*='inbox']");
        for (var i = 0; i < inboxLinks.length; i++) {
            var text = extractText(inboxLinks[i]);
            var countMatch = text.match(/\((\d+)\)/);
            if (countMatch) return parseInt(countMatch[1], 10);
        }

        return 0;
    }

    function detectCurrentFolder() {
        var url = window.location.href || "";
        try {
            var params = new URL(url).searchParams;
            var s = params.get("s");
            if (s === "s") return "spam";
            if (s === "t") return "trash";
            if (s === "d") return "drafts";
            if (s === "a") return "all";
        } catch (e) {
            // URL parsing failed, default to inbox
        }
        return "inbox";
    }

    // Main execution: return parsed result as JSON
    var result = {
        emails: parseEmailRows(),
        unreadCount: parseUnreadCount(),
        folder: detectCurrentFolder(),
        timestamp: new Date().toISOString()
    };

    return JSON.stringify(result);
})();
