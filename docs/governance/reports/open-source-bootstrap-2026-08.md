# Open-source bootstrap report — 2026-08

Date: 2026-08-26  
Profile: `TP-OSS-SC`  
Scope: `Teremoq/teremoq` and `Teremoq/moq-rs-teremoq`

This is a technical open-source and supply-chain review, not legal advice.

## Repository inventory

| Repository | Visibility | Fork | Default branch | Branches | Tags | Forks | Collaborators |
|---|---|---|---|---:|---:|---:|---|
| `Teremoq/teremoq` | public | no | `main` | 1 | 0 | 0 | 1 administrator |
| `Teremoq/moq-rs-teremoq` | public | no | `teremoq/baseline-draft16-bf87128` | 1 | 0 | 0 | 1 administrator |

The core had one published commit. The mirror had 802 reachable commits and
retains upstream's `MIT OR Apache-2.0` license and REUSE metadata. No remote
ruleset or branch protection was active before or after this task.

## GitHub controls: before and after

Only selected API fields were captured. Tokens and authorization headers were
not recorded.

| Control | Before bootstrap/correction | Final state |
|---|---|---|
| Secret Scanning | disabled | enabled in both; 0 alerts at final query |
| Push Protection | disabled | enabled in both |
| Private Vulnerability Reporting | disabled | enabled in both |
| Dependabot Alerts | enabled | enabled; 0 alerts |
| Dependabot Security Updates | disabled | remains disabled |
| Default `GITHUB_TOKEN` | read | read |
| Workflow PR approval | disabled | disabled |
| Action policy | initially all; then selected with wildcard `*/*@*` and verified creators | selected, GitHub-owned allowed, verified creators false, no third-party patterns, full-SHA pinning required |
| Web commit sign-off | false | true in both |
| CodeQL core | not configured | JavaScript/TypeScript default setup configured; setup run succeeded |
| CodeQL mirror | Rust detected, not configured | unchanged; official API retry rejected Rust |
| Remote rulesets | none | none |
| Branch protection | none | none |

The Actions wildcard was removed. Mutable third-party references inherited in
the mirror are now blocked, not allowlisted; see
`infra/github/ACTIONS_INVENTORY.md`.

Web sign-off covers commits authored through GitHub's web interface. Local/CLI
DCO trailers still require manual review. No DCO App, third-party DCO action or
required DCO status check is installed, so total DCO enforcement remains
pending before external contributions are accepted.

The CodeQL Rust retry used `X-GitHub-Api-Version: 2026-03-10`. GitHub returned
HTTP 422 because `rust` is not accepted by the endpoint's language enum, while
the subsequent GET still reported Rust detected and `not-configured`. This is
a platform blocker; no advanced-setup workflow was created.

Dependency Graph remained operationally unverified: an earlier GraphQL query
returned zero manifests for both default branches, and the final REST SBOM
query returned HTTP 404 for both repositories. Dependabot Alerts were
independently confirmed enabled. No SBOM availability claim is made.

## Generated artifacts

Both tracked bytecode files were removed from the Git index without rewriting
history:

- `gateway-rs/tests/preview/__pycache__/loopback_proxy.cpython-314.pyc`;
- `gateway-rs/tests/preview/__pycache__/verify-multitrack.cpython-314.pyc`.

`git rm --cached` left the local copies present and ignored. Neither path is
now returned by `git ls-files` or the publishable tracked/non-ignored file
inventory. The existing `__pycache__/` and `*.py[cod]` rules remain active.

The historical local path embedded in the first bytecode file remains in the
published commit because history was not rewritten. Local workspace paths in
Tasks 03, 04 and 05 remain findings pending their owners; those files were not
edited by this correction.

## Mirror history and blob coverage

Gitleaks 8.30.1 ran with `--redact=100` and:

```text
--log-opts="--all --full-history -m -p -U0"
```

The mirror has 802 reachable commits. Gitleaks reported 793 commits with
scannable fragments and the same three PEM-delimiter findings. Independent
parsing of the exact patch stream reconciled the other nine commits:

| Omission class | Count | Explanation |
|---|---:|---|
| Empty/no tree delta | 4 | No diff fragment exists |
| Whole-file deletion only | 4 | Gitleaks intentionally skips deleted files |
| Rename-only metadata | 1 | 100% rename with no text hunk |
| Binary-only omission | 0 | No commit was omitted solely for binary content |

The nine abbreviated commit identifiers and classifications were recorded in
the local redacted audit output. All 802 commit markers were present in the Git
log; 793 produced a fragment accepted by Gitleaks and the nine categories above
account exactly for the remainder.

A complementary object scan enumerated and materialized all 3,692 unique
reachable blobs, 30,595,811 bytes, with zero rejected paths. Gitleaks reported
12 private-key-rule matches across historical blob versions. They reduce to nine
file/line locations and all are comment-only PEM delimiters in TLS parser code;
no PEM body candidate exists in any matched blob. A raw-byte marker scan found
the corresponding 18 historical delimiter lines, likewise comments.

One 6,148-byte blob was binary or non-UTF-8. Its printable strings were scanned
separately with Gitleaks and produced zero findings. No reachable blob path used
a `.env`, PEM, DER, P12, PFX, key-store or private-key extension.

Patch-log findings:

| File | Line | Type | Classification |
|---|---:|---|---|
| `moq-native/src/tls.rs` | 148 | private-key rule | comment-only PEM delimiter |
| `moq-relay/src/tls.rs` | 98 | private-key rule | comment-only PEM delimiter |
| `moq-relay/src/server.rs` | 45 | private-key rule | comment-only PEM delimiter |

The combined patch, reachable-blob, raw-byte and binary-string checks cover all
reachable commits and blobs. No credible published secret was identified. This
is evidence about the audited Git object graph, not a mathematical guarantee
about credentials outside it.

The current publishable core snapshot contained 195 tracked or non-ignored
files (approximately 1.26 MB) and passed a redacted Gitleaks scan with zero
findings.
Runtime PKI and `.teremoq-dev` remain ignored; expected private runtime material
was not displayed or treated as publishable input.

## Licensing and dependency validation

- Root `LICENSE` and `LICENSES/Apache-2.0.txt` exactly match the complete
  Apache-2.0 reference text: 202 lines, SHA-256
  `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`.
- REUSE 5.1.1 passes REUSE Specification 3.3 with no bad, missing, deprecated or
  unused licenses.
- `cargo-deny 0.20.2 check licenses` passes against the locked Rust graph.
- npm inventory remains 505 installed name/version pairs overall and 59 with
  `--omit=dev` from the installed-tree run. Final lockfile parsing reconfirmed
  490 entries and zero entries missing license metadata.
- Generated material, fixtures and third-party components retain their separate
  annotations and licenses.

## Rulesets prepared, not active

Eight disabled JSON rulesets are versioned, four per repository:

1. immutable linear `teremoq/baseline-*` branches;
2. pull-request-only `main`, with conversation resolution and no guessed checks;
3. restricted `v*` creation with organization-administrator bypass;
4. independent `v*` update/deletion/non-fast-forward protection with no bypass.

Separating tag creation from tag immutability prevents the creation bypass from
also authorizing tag update or deletion. The activation order and lockout risk
for the mirror's current baseline default branch are documented in
`infra/github/README.md`.

## Tool record and limitations

| Tool | Version/pin | License | Use |
|---|---|---|---|
| GitHub CLI/API | gh 2.54.0; API 2026-03-10 where applicable | MIT | Selected-field state and authorized reversible controls |
| Gitleaks | 8.30.1; archive SHA-256 `551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb` | MIT | Redacted patch, tree, blob and binary-string scans |
| REUSE tool | 5.1.1; image digest `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | GPL-3.0-or-later | Read-only ephemeral license audit |
| cargo-deny | 0.20.2; archive SHA-256 `9f12ed4c49936e09b48bf862b595cde2fe64fcbd9d74dfacac6131ca824c8d5f` | MIT OR Apache-2.0 | License gate only |
| Rust container | 1.93.0; image digest `sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57` | Toolchain MIT OR Apache-2.0; Debian packages separate | Ephemeral cargo-deny environment |
| Python / PyYAML | 3.14.4 / 6.0.3 | Python-2.0 / MIT | Redacted reconciliation and syntax checks |
| npm | 10.9.3 | Artistic-2.0 | Installed-tree inventory |

## Scope confirmation

Final checks cover Apache text, REUSE, cargo-deny licenses, JSON/YAML/TOML,
redacted secret scanning, GitHub before/after state, runtime ignores, both
staged and unstaged `git diff --check`, and source/runtime diff boundaries.

No Rust or Next.js logic, protocol, runtime dependency, `Cargo.lock`, moq-rs
pin, productive Docker or PKI behavior was changed. Task 05 was not modified or
continued.

No email, message, issue, Discussion, pull request, release, Git commit or push
was created.
