# Review: VerusK/mailto-links vs b5e2e2f7ad537eba3bf430283424ffe96a7c92aa
## Verdict
READY WITH FIXES — the prior header-injection finding is resolved and basic quoted commas work, but escaped quoted local parts still break; Xcode tests could not complete in this sandbox.
## Findings (confidence 7+)
[P2] (confidence: 9/10) Aerio/Services/MailtoURL.swift:16 — `ContactsCache.splitAddressList` toggles quote state on every `"`, including an escaped quote, so `mailto:%22a%5C%22b%2Cc%22@example.com` is split at the encoded comma and its valid quoted recipient is corrupted — make the address splitter recognize quoted-pair escapes before treating a quote as a delimiter.
## Appendix (confidence below 7)
[P2] (confidence: 6/10) AerioTests/MailtoURLTests.swift:88 — The no-draft test checks only `ComposeSeed.marksDirty`, while actual saving depends on `ComposeView` initialization, `.onChange`, and `.onDisappear`; a deferred state update could mark an untouched mailto compose dirty without failing this test — mount and close a seeded compose view with a fake draft API and assert that no save occurs.
## Plan alignment notes
No plan given
## Ledger triage
None
<!-- end of review -->
