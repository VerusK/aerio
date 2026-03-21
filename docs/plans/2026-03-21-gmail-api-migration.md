# Gmail API Migration: Web Scraping to REST API

## Overview

Migrate AgMail from WKWebView-based Gmail DOM scraping to Gmail REST API. Replace all JS injection/DOM parsing with direct HTTP calls via URLSession. Add OAuth 2.0 PKCE authentication via ASWebAuthenticationSession and Keychain token storage. Remove ~1600 lines of scraping code and ~1050 lines of scraping tests.

## Context

- Spec document: `docs/gmail-api-migration-plan.md`
- Files involved: 7 new source + 5 new test files; 8 modified files; 12 deleted files
- Related patterns: Published interface contract in GmailScraperManager must be preserved in GmailAPIManager for minimal view changes
- Dependencies: macOS Security.framework (Keychain), AuthenticationServices (ASWebAuthenticationSession), CryptoKit (PKCE SHA256). No external dependencies.
- Prerequisite: Google Cloud Console project with Gmail API enabled + OAuth Client ID (desktop app type)

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- Each task produces a buildable state (no half-wired code)
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: OAuth foundation — OAuthConfig, KeychainHelper, PKCE

Create the authentication infrastructure: constants, secure token storage, and PKCE generation.

**Files:**
- Create: `AgMail/Services/OAuthConfig.swift`
- Create: `AgMail/Services/KeychainHelper.swift`
- Create: `AgMail/Services/OAuthManager.swift`
- Create: `AgMailTests/KeychainHelperTests.swift`
- Create: `AgMailTests/OAuthManagerTests.swift`
- Modify: `AgMail.xcodeproj` (add files to target, add CFBundleURLTypes for `com.agmail` scheme)

- [x] Create `OAuthConfig.swift` with clientId (placeholder), redirectURI `com.agmail:/oauth/callback`, authURL, tokenURL, scopes (`gmail.modify`)
- [x] Create `KeychainHelper.swift` with `OAuthTokens` struct (accessToken, refreshToken, expiresAt, email, isExpired computed) and CRUD methods using Security.framework `kSecClassGenericPassword`
- [x] Create `OAuthManager.swift` with: `generatePKCE()` using CryptoKit SHA256, `authorize()` via ASWebAuthenticationSession, `exchangeCodeForTokens()` POST to tokenURL, `refreshAccessToken()`, `fetchUserEmail()` via userinfo endpoint
- [x] Add `CFBundleURLTypes` with scheme `com.agmail` to Info.plist / Xcode target for OAuth callback
- [x] Write `KeychainHelperTests`: save/load/delete/update tokens, load nonexistent returns nil
- [x] Write `OAuthManagerTests`: PKCE verifier length (43 chars base64url), challenge = base64url(SHA256(verifier)), base64url encoding correctness
- [x] Run project test suite - must pass before task 2

### Task 2: Gmail API models and HTTP client

Create Codable models for Gmail API responses and the HTTP client with auth, retry, and error handling.

**Files:**
- Create: `AgMail/Models/GmailAPIModels.swift`
- Create: `AgMail/Services/GmailAPIClient.swift`
- Create: `AgMail/Services/RFC2822Builder.swift`
- Create: `AgMailTests/GmailAPIClientTests.swift`
- Create: `AgMailTests/RFC2822BuilderTests.swift`
- Modify: `AgMail/Models/Folder.swift`

- [x] Create `GmailAPIModels.swift`: GmailMessageListResponse, GmailMessage, GmailPayload (recursive MIME), GmailHeader, GmailBody, GmailLabel, GmailModifyRequest, GmailSendRequest, GmailHistoryResponse, GmailLabelId constants
- [x] Create `GmailAPIClient.swift` with: `execute()` method handling auth header injection, auto-refresh on 401, retry on 429 (Retry-After) and 5xx (exponential backoff); public methods: listMessages, getMessage, getMessages (TaskGroup, max 10 concurrent), modifyMessage, trashMessage, sendMessage, listLabels, getLabel, listHistory; `@Published state: ClientState` (.idle/.syncing/.error)
- [x] Create `RFC2822Builder.swift`: buildRawMessage (From/To/Cc/Subject/Body with RFC 2047 Q-encoding for non-ASCII), base64URLEncode, base64URLDecode
- [x] Add `gmailQuery` and `gmailLabelIds` computed properties to `Folder.swift`
- [x] Write `GmailAPIClientTests` using URLProtocol mock: verify request construction (URL, headers, query params), 401 triggers refresh + retry, 429 respects Retry-After, 5xx retries with backoff, 200 decodes correctly
- [x] Write `RFC2822BuilderTests`: plain ASCII message, non-ASCII subject (Q-encoding), base64url encode/decode roundtrip, message with Cc and In-Reply-To headers
- [x] Run project test suite - must pass before task 3

### Task 3: GmailAPIManager — orchestrator replacing GmailScraperManager

Create the new orchestrator with the same Published interface contract so views require minimal changes.

**Files:**
- Create: `AgMail/Services/GmailAPIManager.swift`
- Create: `AgMailTests/GmailAPIManagerTests.swift`

- [x] Create `GmailAPIManager.swift` as `@MainActor ObservableObject` with matching Published properties: `clients` (was `scrapers`), `emailsByAccount`, `unreadCountsByAccount`, `isPolling`, `clientStates` (was `scraperStates`)
- [x] Implement 1:1 replacement methods: `addClient(for:)`, `removeClient(for:)` (+ Keychain cleanup), `startPollingAll(interval:)` (Task.sleep loop), `stopPollingAll()`, `navigateAllToFolder(_:)`, `refreshAll()`, `markAsRead(emailId:accountId:)`, `removeEmail(...)`
- [x] Implement new API methods: `fetchEmails(for:)` (list + batch get + convert), `fetchAllAccounts()` (TaskGroup), `fetchMessageContent(msgId:accountId:)`, `archiveEmail`, `deleteEmail`, `spamEmail`, `sendEmail` (via RFC2822Builder)
- [x] Implement `convertGmailMessageToEmail()`: extract From/Subject/Date from headers, internalDate to Date, isRead from labelIds, folder from labelIds, snippet from API response
- [x] Implement computed properties: `hasLoadedAny`, `clientErrors`, `allClientsErrored`, `allEmails`, `totalUnreadCount`
- [x] Implement unread count via `getLabel(id: "INBOX")` -> `messagesUnread`
- [x] Write `GmailAPIManagerTests` with mock GmailAPIClient: emailsByAccount updates after fetchEmails, markAsRead does optimistic update + API call, polling start/stop, removeClient cleans up state
- [x] Run project test suite - must pass before task 4

### Task 4: Wire AppState and account flow — OAuth replaces WKWebView login

Replace AppState wiring and rewrite AccountSetupView for OAuth login.

**Files:**
- Modify: `AgMail/AgMailApp.swift`
- Modify: `AgMail/Views/AccountSetupView.swift`
- Modify: `AgMail/Views/AccountSidebar.swift`
- Modify: `AgMail/Services/UnifiedMailbox.swift`

- [x] Rewrite `AppState` in `AgMailApp.swift`: replace `webViewPool` + `scraperManager` with `oauthManager` + `apiManager`; init chain: AccountManager -> OAuthManager + EmailCache -> GmailAPIManager -> UnifiedMailbox; add migration logic to remove old accounts without Keychain tokens on first launch
- [x] Rewrite `AccountSetupView.swift`: native SwiftUI view with "Sign in with Google" button -> `oauthManager.authorize()` -> save tokens -> `accountManager.addAccount()` -> dismiss; handle duplicate email check and error display
- [x] Update `AccountSidebar.swift`: remove `webViewPool` dependency, add `oauthManager`; pass oauthManager to AccountSetupView; remove `webViewPool.removeWebViews(for:)` calls (cleanup handled by apiManager.removeClient)
- [x] Update `UnifiedMailbox.swift`: observe `apiManager.$emailsByAccount` instead of `scraperManager.$emailsByAccount`; update init parameter type
- [x] Update existing tests that reference AppState or UnifiedMailbox to use new types
- [x] Run project test suite - must pass before task 5

### Task 5: Message content and actions via API

Replace message content loading (JS extraction) and email actions (JS DOM manipulation) with API calls.

**Files:**
- Modify: `AgMail/Views/MessageWebView.swift`
- Modify: `AgMail/Views/MainView.swift`

- [x] Rewrite `NativeMessageDetail` in `MessageWebView.swift`: replace webViewPool/scraper-based content loading with `apiManager.fetchMessageContent()` -> recursive MIME extraction (text/html preferred, text/plain fallback wrapped in `<pre>`) -> `BodyWebViewStore.loadHTML(wrapHTML(...))`; extract attachment names from MIME parts; remove webViewPool dependency
- [x] Update `MainView.swift`: replace `@ObservedObject scraperManager` with `apiManager: GmailAPIManager`; remove `webViewPool`; rewrite `executeActionOnSelected` to use `apiManager.archiveEmail/deleteEmail/spamEmail`; update `performRefresh()` to `apiManager.refreshAll()`; update state references (`scraperStates` -> `clientStates`, `hasLoadedAny`, `allScrapersErrored` -> `allClientsErrored`)
- [x] Pass `apiManager` instead of `webViewPool`/`scraperManager` to child views (NativeMessageDetail, FolderList, MessageList as needed)
- [x] Update any view tests in ViewTests.swift that reference scraperManager or webViewPool
- [x] Run project test suite - must pass before task 6

### Task 6: Compose via API — replace WKWebView send

Replace Gmail compose URL + JS click with direct API send.

**Files:**
- Modify: `AgMail/Views/ComposeWebView.swift` (rename to `ComposeView.swift`)

- [x] Rewrite `sendMessage()` in ComposeWebView: replace webViewPool compose path with `apiManager.sendEmail(from:to:cc:subject:body:accountId:inReplyTo:)`; remove webViewPool/scraperManager dependencies; keep existing native SwiftUI form (From picker, To/Cc/Subject TextFields, body TextEditor)
- [x] Rename file from `ComposeWebView.swift` to `ComposeView.swift`; update type names (NativeComposeView -> ComposeView or keep internal name)
- [x] Update MainView and any other callers to pass apiManager instead of webViewPool/scraperManager to compose view
- [x] Run project test suite - must pass before task 7

### Task 7: Delete scraping code

Remove all WKWebView scraping infrastructure now that everything runs on API.

**Files:**
- Delete: `AgMail/Services/GmailScraper.swift`
- Delete: `AgMail/Services/GmailScraperManager.swift`
- Delete: `AgMail/Services/WebViewPool.swift`
- Delete: `AgMail/Services/ComposeService.swift`
- Delete: `AgMail/Scripts/gmail_parser.js`
- Delete: `AgMail/Scripts/gmail_actions.js`
- Delete: `AgMail/Scripts/gmail_message_reader.js`
- Delete: `AgMailTests/GmailScraperTests.swift`
- Delete: `AgMailTests/GmailParserJSTests.swift`
- Delete: `AgMailTests/GmailActionsJSTests.swift`
- Delete: `AgMailTests/WebViewPoolTests.swift`
- Delete: `AgMailTests/ComposeServiceTests.swift`
- Delete: `AgMailTests/GmailScraperManagerTests.swift`
- Modify: `AgMail.xcodeproj` (remove from targets, remove Scripts folder group, remove JS from Copy Bundle Resources)

- [x] Delete all 7 source files listed above
- [x] Delete all 6 test files listed above
- [x] Remove deleted files from Xcode project (target membership, Scripts group, Copy Bundle Resources build phase)
- [x] Remove `import WebKit` from files where it is no longer needed (keep only in MessageWebView for BodyWebView HTML rendering)
- [x] Verify no remaining references to deleted types (GmailScraper, GmailScraperManager, WebViewPool, ComposeService)
- [x] Run project test suite - must pass before task 8

### Task 8: Incremental sync via History API

Optimize polling to use Gmail History API for delta updates instead of full re-fetch.

**Files:**
- Modify: `AgMail/Services/GmailAPIManager.swift`
- Modify: `AgMail/Services/GmailAPIClient.swift`

- [x] Add `historyIds: [String: String]` tracking to GmailAPIManager; save historyId from initial full fetch
- [x] Implement `incrementalSync(for accountId:)`: call `listHistory(startHistoryId:)`, process messagesAdded/messagesDeleted/labelsAdded/labelsRemoved, fetch only new/changed messages
- [x] Handle 410 Gone (expired historyId) with fallback to full fetch
- [x] Wire incrementalSync into polling loop: use incremental after first full fetch
- [x] Add tests for incremental sync: history processing, 410 fallback, delta application
- [x] Run project test suite - must pass before task 9

### Task 9: Verify acceptance criteria

- [x] Run full test suite: `xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS'`
- [x] Build release: `xcodebuild -project AgMail.xcodeproj -scheme AgMail -configuration Release build`
- [x] Verify no compiler warnings related to migration changes

### Task 10: Update documentation

- [x] Update `CLAUDE.md` project structure section: replace scraping references with API references (GmailAPIClient, GmailAPIManager, OAuthManager, KeychainHelper); update Key Patterns section; update file descriptions in Services
- [x] Move this plan to `docs/plans/completed/`
