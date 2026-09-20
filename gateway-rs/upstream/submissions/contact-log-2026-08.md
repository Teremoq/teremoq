# moq-rs maintainer contact log — DESIGN NOT SUBMITTED

## Status

- Contact status: **CONTACTED**
- Design status: **NOT SUBMITTED**
- Response status: pending; no response had been received when this record was
  written.
- Sent at: `2026-08-26T15:48:19Z` (UTC)
- Verified `main` commit before contact:
  [`bf87128affd316463e5dcc7599a45001f222b6de`](https://github.com/cloudflare/moq-rs/commit/bf87128affd316463e5dcc7599a45001f222b6de)

This was one bounded channel-discovery contact. It did not submit either design
for technical review and does not resolve authenticated identity/authorization
or bounded admission.

## Official channel discovery

The following official project or organization surfaces were checked immediately
before contact:

- [`cloudflare/moq-rs` main](https://github.com/cloudflare/moq-rs) remained at the
  exact commit above and documented draft-16 behavior.
- [`draft-18-dev`](https://github.com/cloudflare/moq-rs/tree/draft-18-dev)
  remained a separate early-development branch at
  `5a3e5ffe833f00df6e39277b7b1258dd907fc036`.
- [Repository issues](https://github.com/cloudflare/moq-rs/issues) were an
  official feature-discussion surface, but issue creation was restricted and
  creating an issue was outside the authorization.
- GitHub Discussions was not enabled for the repository. Creating a Discussion,
  pull request, fork, or branch was also outside the authorization.
- The repository contained no local `CONTRIBUTING.md`, `SECURITY.md`,
  `CODEOWNERS`, issue template, or pull-request template at the verified commit.
- Cloudflare's inherited official
  [`CONTRIBUTING.md`](https://github.com/cloudflare/.github/blob/master/CONTRIBUTING.md)
  directs questions to `opensource@cloudflare.com`. This published, direct
  Open Source contact allowed the authorized channel-and-review-shape question
  without creating a public GitHub resource, so it was selected.
- Cloudflare's official security-reporting channel was excluded because this is
  a functionality/design inquiry, not a vulnerability report. No personal
  maintainer account or address was used.

## Contact made

- Medium: direct email to the officially published Cloudflare Open Source
  contact, `opensource@cloudflare.com`.
- Subject: `moq-rs embedder API design: verified peer context and bounded admission`
- Attachments: none.
- Links or paths to private/local material: none.

The send operation returned an ambiguous connector decoding error, so it was not
retried. A read-only check of the sent mailbox then confirmed exactly one message
with the intended recipient, subject, and body at the recorded time, with no
attachment. No mailbox message identifier or credential data is retained here.

Exact text sent:

```text
Hello moq-rs maintainers,

We are evaluating two independent generic embedder gaps against the current moq-rs main revision bf87128affd316463e5dcc7599a45001f222b6de:

1. making connection-bound QUINN/rustls verified peer evidence available to relay authorization before scope or namespace state is created; and
2. immediate, separate admission bounds for pending native handshakes and established relay sessions, including bounded shutdown.

We have prepared design drafts and test matrices, but have not opened an issue, prepared a pull request, or published code. Issue creation appears to be restricted. Which official channel would you prefer for discussing these two designs? Would you prefer two independent design threads with small crate-scoped PRs, or two focused cross-crate PRs?

The proposals preserve the existing MoQT draft, ALPNs, WebTransport/raw QUIC wire behavior, and keep deployment-specific identity and authorization policy outside moq-rs. At this stage we only need guidance on the discussion channel and review shape.

Thank you.
```

Before sending, `TP-SEC-PKI` reviewed the exact body for disclosure and trust
boundary concerns. It contains no certificate material, principal or role,
local path, log, IP address, secret, private repository link, product narrative,
attachment, or unsupported production claim. It keeps deployment-specific
identity interpretation and authorization policy outside `moq-rs`.

## Scope still not authorized

The contact did not authorize, request, or perform any of the following:

- a second message or reply;
- opening an issue, Discussion, pull request, fork, or branch;
- pushing or publishing code, drafts, test matrices, or repository content;
- sharing a private repository, local file, credential, log, or deployment data;
- negotiating a wire, draft, ALPN, trust-model, dependency, or breaking-API
  change;
- changing dependencies or product files; or
- treating silence, a reaction, or informal guidance as technical approval.

## Response and next decision

No response is recorded yet. Task 05 stops after this one contact. If a response
arrives, the Master must review it and explicitly choose whether to authorize a
specific next action in the named official channel, request revisions, or keep
the designs unsubmitted. No follow-up communication or technical contribution
is authorized by this record.
