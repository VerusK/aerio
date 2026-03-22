---
name: Project migration history
description: AgMail evolved from WKWebView Gmail scraping to Gmail REST API — all scraping code deleted, no legacy remains
type: project
---

AgMail was originally built on WKWebView-based Gmail DOM scraping (JS injection, gmail_parser.js, gmail_actions.js). On 2026-03-21 it was fully migrated to Gmail REST API.

**What was removed:** GmailScraper, GmailScraperManager, WebViewPool, ComposeService, all JS scripts (~1600 lines scraping code, ~1050 lines scraping tests). 12 files deleted total.

**What replaced it:** OAuthManager (PKCE via ASWebAuthenticationSession), GmailAPIClient (URLSession HTTP client with auth/retry), GmailAPIManager (orchestrator), RFC2822Builder (email composition).

**Why:** Web scraping was fragile and limited. REST API provides reliable data access, incremental sync via History API, and proper email actions.

**How to apply:** There is NO legacy scraping code. Don't reference GmailScraper, WebViewPool, or JS scripts — they don't exist. All email operations go through GmailAPIClient → GmailAPIManager.
