# Comprehensive Test Coverage for AgMail

## Overview
Add meaningful tests covering critical untested logic — email composition (MIME building), data persistence (content cache), API client (token refresh, missing endpoints), API manager (history sync, polling), and API model decoding. Focus on code paths where bugs cause real user-facing problems: broken emails, data loss, auth failures, stale data.

## Context
- Files involved: `RFC2822Builder.swift`, `DataStore.swift`, `GmailAPIClient.swift`, `GmailAPIManager.swift`, `GmailAPIModels.swift`
- Test files: `RFC2822BuilderTests.swift`, `DataStoreTests.swift`, `GmailAPIClientTests.swift`, `GmailAPIManagerTests.swift`, new `GmailAPIModelsTests.swift`
- Existing test infrastructure: `MockKeychainStore`, `MockURLProtocol` (in GmailAPIClientTests)
- Related patterns: tests use `XCTestCase`, async/await, `MockURLProtocol` for HTTP stubbing, in-memory SwiftData for persistence

## Development Approach
- **Testing approach**: TDD where practical — write the test, verify it exercises real logic
- Complete each task fully before moving to the next
- **CRITICAL: all tests must pass before starting next task**
- Prioritized by impact: bugs in task 1 = garbled emails sent to users; bugs in task 5 = minor decode issues

## Implementation Steps

### Task 1: RFC2822Builder — HTML messages and attachments

The multipart MIME nesting logic (mixed > related > alternative) is the most complex untested algorithm. Bugs here mean users send broken emails.

**Files:**
- Modify: `AgMailTests/RFC2822BuilderTests.swift`
- Read: `AgMail/Services/RFC2822Builder.swift`

- [x] Test `buildRawHTMLMessage()` — plain + HTML multipart/alternative structure, correct boundaries, Content-Type headers
- [x] Test `buildRawHTMLMessage()` with non-ASCII subject and body (Q-encoding in HTML path)
- [x] Test `buildRawHTMLMessageWithAttachments()` with inline images — multipart/related wrapping, CID references, base64 image data
- [x] Test `buildRawHTMLMessageWithAttachments()` with file attachments — multipart/mixed outer layer, correct Content-Disposition
- [x] Test `buildRawHTMLMessageWithAttachments()` with both inline images AND file attachments — full 3-level nesting (mixed > related > alternative)
- [x] Test edge case: empty HTML body, empty attachments array
- [x] Run test suite — must pass before task 2

### Task 2: EmailCache — content cache and missing CRUD operations

Content caching was recently added (commit 0d0310b) with zero test coverage. `replaceEmails` and delete operations are also untested.

**Files:**
- Modify: `AgMailTests/DataStoreTests.swift`
- Read: `AgMail/Persistence/DataStore.swift`

- [x] Test `saveContent` and `loadContent` round-trip (store HTML content by email ID)
- [x] Test `loadContent` returns nil for non-existent ID
- [x] Test `purgeOldContent` removes entries older than threshold, keeps recent ones
- [x] Test `deleteContent` removes specific entry
- [x] Test `clearContent` removes all content entries
- [x] Test `contentCacheCount` returns correct count
- [x] Test `replaceEmails(for:folder:with:)` — replaces existing emails for account+folder, preserves other accounts
- [x] Test `deleteEmail(id:)` and `deleteEmails(msgId:accountId:)`
- [x] Run test suite — must pass before task 3

### Task 3: GmailAPIClient — token refresh and missing endpoints

The 401 -> refresh -> retry flow is security-critical. Missing endpoint tests cover user-facing features (trash, attachments, drafts, search, history).

**Files:**
- Modify: `AgMailTests/GmailAPIClientTests.swift`
- Read: `AgMail/Services/GmailAPIClient.swift`

- [x] Test 401 response triggers token refresh and retries the original request
- [x] Test 401 with failed refresh propagates the error (no infinite loop)
- [x] Test concurrent 401s coalesce into single refresh (refreshTask dedup)
- [x] Test `trashMessage` — request URL and method
- [x] Test `getAttachment` — request shape and base64 response decoding
- [x] Test `listHistory` — request with startHistoryId, response parsing
- [x] Test `listDrafts`, `getDraft`, `updateDraft`, `sendDraft` — request shapes and response parsing
- [x] Test `searchEmailsWithTokens` — query encoding, pageToken handling, response with nextPageToken
- [x] Test 429 rate limit response handling (if distinct from retry logic)
- [x] Run test suite — must pass before task 4

### Task 4: GmailAPIManager — history sync, polling, and infinite scroll

Core data freshness mechanisms — incremental sync, 410 fallback, polling timer, and pagination.

**Files:**
- Modify: `AgMailTests/GmailAPIManagerTests.swift`
- Read: `AgMail/Services/GmailAPIManager.swift`

- [x] Test incremental sync via History API — processes history records, updates email state
- [x] Test History API 410 Gone triggers full re-fetch fallback
- [x] Test `fetchMoreEmails` (infinite scroll) — loads next page, appends results
- [x] Test `fetchMoreEmails` when no more pages — returns without action
- [x] Test polling start/stop — verify timer fires and stops correctly
- [x] Test cache integration — `loadCachedEmails` populates emails from `EmailCache` at startup
- [x] Run test suite — must pass before task 5

### Task 5: GmailAPIModels — response decoding

Validate that all API response models correctly decode from JSON. These are the contract with Gmail's API.

**Files:**
- Create: `AgMailTests/GmailAPIModelsTests.swift`
- Read: `AgMail/Models/GmailAPIModels.swift`

- [x] Test `GmailHistoryResponse` decoding (historyId, history records array)
- [x] Test `GmailHistoryRecord` decoding (messagesAdded, messagesDeleted, labelsAdded, labelsRemoved)
- [x] Test `GmailDraftsListResponse` decoding (drafts array, nextPageToken)
- [x] Test `GmailAttachment` decoding (attachmentId, size, data)
- [x] Test decoding with missing optional fields (graceful defaults)
- [x] Run test suite — must pass before task 6

### Task 6: Verify acceptance criteria

- [x] Run full test suite: `xcodebuild test -project AgMail.xcodeproj -scheme AgMail -destination 'platform=macOS'`
- [x] Verify all new tests pass and no existing tests broken
