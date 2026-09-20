# Open-source governance

## Scope

Original source in `Teremoq/teremoq` is published under Apache-2.0. The
`Teremoq/moq-rs-teremoq` repository preserves upstream's MIT OR Apache-2.0
license and provenance. Customer deployments, trust material, credentials,
production namespaces and operational data remain private and are not part of
the open-source project.

Publication grants the rights in the applicable license. It does not create a
commercial support obligation, SLA, warranty, product roadmap commitment or
presumption of compatibility with a private deployment.

## Contributions and decisions

Inbound contributions use the existing license of the component modified.
Every commit requires DCO 1.1 `Signed-off-by`; no CLA is used. Third-party and
generated material must keep its original license and attribution.

Repository settings require sign-off for commits authored in GitHub's web
interface. Local/CLI commits remain subject to manual trailer review because no
DCO App or required DCO status check is installed. The policy must not be
described as fully automated until that separate gate exists.

Maintainers accept changes based on technical merit, security, maintainability,
test evidence, provenance and license compatibility. Architecture changes to
protocol boundaries, the data plane or security model require an ADR and review
by the responsible technical profiles. A merged change is not a promise that it
will ship in a release or receive commercial support.

## Security and private material

Vulnerabilities are accepted only through GitHub Private Vulnerability
Reporting. Public issues, pull requests and Discussions must not contain
vulnerability details. No email intake address is published.

Repository history and proposed changes are screened for secrets and private
deployment data. A credible secret finding halts publication work until the
owner revokes the credential and explicitly authorizes any history rewrite.

## Architecture invariants

Zero-Transcoding, mTLS, identity-bound authorization, bounded concurrency and
MoQT compatibility are invariants and verification targets. They are not
unqualified product claims. Evidence must record the exact revision, peer,
network, load, hardware, duration and known limitations.

## Responsibility boundaries

- `TP-OSS-SC` owns open-source governance, repository controls, provenance,
  license/SBOM policy and release supply-chain gates.
- `TP-RUST-DIST` owns Rust behavior, upstream API integration and technical
  contributions to `moq-rs`; its changes in the mirror remain dual-licensed.
- `TP-SEC-PKI` owns private trust material, identities, rotation and revocation;
  `TP-OSS-SC` verifies that those materials are excluded from publication.
- `TP-PLATFORM-CHAOS` owns reproducible labs and container/network harnesses;
  `TP-OSS-SC` reviews their third-party inputs and release provenance.

The Master Tech Lead integrates work across these boundaries and approves any
external, irreversible or public action outside the repository controls already
authorized by policy.
