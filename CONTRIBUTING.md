# Contributing to Teremoq

Contributions are welcome when they preserve the architecture, security and
licensing boundaries documented in this repository.

## License of contributions

Inbound contributions use the same license as the component being modified:

- original code in `Teremoq/teremoq`: Apache-2.0;
- code in `Teremoq/moq-rs-teremoq`: MIT OR Apache-2.0;
- third-party, generated and fixture material: its existing license, without
  relicensing or removal of attribution.

Teremoq uses Developer Certificate of Origin 1.1 sign-off and does not require
a Contributor License Agreement. Sign every commit with:

```text
Signed-off-by: Your Name <your-address@example.invalid>
```

Using `git commit -s` adds the trailer. By signing off, you certify the DCO 1.1
for the contribution; review the current certificate at
https://developercertificate.org/ before contributing.

GitHub web commits require sign-off at repository level. Commits created with
Git or another local client are still checked manually during review: no DCO
App, third-party action or mandatory DCO status check is installed yet. Full
automated enforcement is therefore pending before external contributions are
accepted.

## Change requirements

1. Keep changes focused and explain the observable behavior and risks.
2. Preserve Zero-Transcoding, bounded per-session concurrency, mTLS identity
   boundaries and the pinned MoQT contract unless an accepted ADR changes them.
3. Reuse maintained upstream components and pin Git dependencies, OCI images
   and GitHub Actions immutably.
4. Add or update tests, dependency inventory, notices and documentation.
5. Run applicable formatting, lint, test, license and secret-scanning checks.
6. Do not include keys, certificates, `.env` files, customer configuration,
   production namespaces, personal data or operational evidence.

Security vulnerabilities must not be reported in a public issue. Follow
[SECURITY.md](SECURITY.md).

Acceptance of a contribution does not promise a release, support, production
compatibility or any service level.
