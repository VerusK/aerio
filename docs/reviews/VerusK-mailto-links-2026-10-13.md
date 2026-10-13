# Review: VerusK/mailto-links vs b5e2e2f7ad537eba3bf430283424ffe96a7c92aa
## Verdict
NOT READY — a mailto subject can inject raw email headers, quoted recipient addresses are corrupted, and the test suite could not complete in this sandbox.
## Findings (confidence 7+)
[P1] (confidence: 8/10) Aerio/Services/MailtoURL.swift:26 — A link such as `mailto:victim@example.com?subject=Hello%0D%0ABcc:%20attacker@example.com` puts CRLF in the subject; `RFC2822Builder.qEncode` passes ASCII through unchanged, so sending builds an unintended `Bcc:` header despite the deliberate bcc omission — reject or normalize header control characters before compose, and sanitize subject values in the MIME builder.
[P2] (confidence: 9/10) Aerio/Services/MailtoURL.swift:42 — Splitting after percent decoding treats an encoded comma inside a quoted local part as an address separator: `mailto:%22a%2Cb%22@example.com` becomes `"a, b"@example.com`, which the send validator rejects — split only on commas outside quoted strings, preserving encoded address characters.
## Appendix (confidence below 7)
None
## Plan alignment notes
No plan given
## Ledger triage
None
<!-- end of review -->
