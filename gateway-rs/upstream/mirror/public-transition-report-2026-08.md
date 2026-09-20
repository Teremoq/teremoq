# Controlled public moq-rs derivative transition — 2026-08-26

- Owner: `TP-RUST-DIST`
- Required identity/privacy reviewer: `TP-SEC-PKI`
- Accepted governance/supply-chain predecessor: `TP-OSS-SC`
- Scope: governance transition and exact baseline closure only
- I1/I2/C1/C2: **not started**

## Result and historical boundary

`Teremoq/moq-rs-teremoq` is now a public independent derivative, not a GitHub
fork. This is a later user decision under the open-source model recorded by
Task 06. The initial private creation and upload remain factual; their original
before/after states are preserved without alteration in
`bootstrap-report-2026-08.md`.

No issue, Discussion, pull request, release, commit, branch, tag, push, email or
maintainer message was created during this transition work. No derivative patch
or Teremoq code was published. The active product dependency graph and pins were
not changed.

## Official revision and repository state

Checked through official Git/GitHub surfaces on 2026-08-26:

| Field | Verified value |
|---|---|
| Official `cloudflare/moq-rs` `main` | `bf87128affd316463e5dcc7599a45001f222b6de` |
| Official `draft-18-dev` | `5a3e5ffe833f00df6e39277b7b1258dd907fc036` |
| Derivative | `Teremoq/moq-rs-teremoq` |
| Visibility / relationship | `public`; `fork=false`; parent absent; not archived |
| Default and only branch | `teremoq/baseline-draft16-bf87128` |
| Branch SHA | `bf87128affd316463e5dcc7599a45001f222b6de` |
| Official and derivative tree | `d76319009e815fb8923e21fc8319e17a0aaf8174` |
| Tags | zero |
| Issues / wiki | disabled / disabled |

The fixed baseline remains deliberate even though it is also current `main` at
the time of this check. A future `main` move does not move this baseline.

## License and provenance

The official and derivative objects are identical:

| Object | Git blob | SHA-256 where materialized |
|---|---|---|
| `LICENSES/Apache-2.0.txt` | `55b366195e45a27ba1681037db12a9efe3cb3e6f` | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| `LICENSES/MIT.txt` | `a6443463f9756ac500af0f4b62ae276a096429b8` | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| `REUSE.toml` | `39f45dc398c58993c3eab21d62c89d39b8b6fcd6` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |

`moq-native-ietf 0.10.0`, `moq-relay-ietf 0.7.25` and `moq-transport
0.16.1` each declare `MIT OR Apache-2.0`. Their manifest blobs also match
official upstream. All future contributions made inside the derivative use that
same dual license. Original Teremoq code remains Apache-2.0; no license or REUSE
material was degraded by this Task 05 transition.

## GitHub controls

The live API and fail-closed verifier demonstrated:

- Secret Scanning enabled;
- Push Protection enabled;
- Private Vulnerability Reporting enabled;
- Dependabot Alerts endpoint enabled;
- Actions enabled with `allowed_actions=selected`;
- `sha_pinning_required=true`;
- GitHub-owned actions allowed, verified creators not blanket-allowed, and no
  third-party patterns;
- default workflow permission `read`;
- workflows cannot approve pull requests; and
- web commit sign-off enabled.

The following are explicitly pending and are not acceptance claims:

- repository rulesets: prepared locally, remote list empty;
- CodeQL Rust default setup: `not-configured`; Task 06's official API attempt
  returned HTTP 422;
- Dependency Graph/SBOM: not assumed; REST SBOM remained unavailable (404).

## Read-only verifier

`verify-public-moq-derivative.sh` parses a fixed data file without `source`,
`eval` or environment value overrides. Unknown/duplicate keys, malformed lines,
unsafe values and shell-like injection fail before remote access. Live mode
requires GitHub authentication but suppresses credential output. It never
clones, pushes, creates refs or changes repository configuration.

Exit classes are distinct: prerequisite/config `10`, authentication `11`,
repository identity/visibility/independence `20`, missing ref `30`, SHA mismatch
`40`, tree mismatch `41`, provenance/ref inventory `50`, license/REUSE `51`, and
mandatory controls `60`.

This verifier version is scoped to the baseline-only state: exactly one branch
and zero tags. Before a future authorized branch creation, that phase must first
replace the count-only baseline contract with an exact approved mapping of full
ref names to reviewed full commit SHAs in `baseline.env` and verifier logic. The
post-push verifier must reject extra, absent or moved refs and all tags. No
future phase SHA is known or approved in this report.

Validation results:

| Case | Result |
|---|---|
| Bash syntax, verifier and test driver | pass |
| Live positive | pass; exact repository/SHA/tree/license and controls |
| Wrong/non-independent repository fixture | expected exit `20` |
| Missing ref fixture | expected exit `30` |
| Wrong SHA fixture | expected exit `40` |
| Wrong tree/provenance fixture | expected exit `41` |
| Second branch in baseline-only fixture | expected exit `50` |
| Mandatory control absent fixture | expected exit `60` |
| Required tool absent | expected exit `10` |
| Unknown configuration key | expected exit `10` |
| Duplicate configuration key | expected exit `10` |
| Injection-shaped configuration | expected exit `10` |
| Canonical remote snapshot before/after test matrix | identical |

Fixture success always prints `mode=fixture` and is never evidence of remote
state.

## Exact baseline build gate

The clean temporary checkout was detached at the approved commit. Commit, tree,
license hashes and empty `git status --porcelain --untracked-files=all` were
verified before tests. After the tests, commit/tree/license remained exact and,
after deleting only ignored build output, status was empty. No baseline source
was edited.

Environment:

- official `rust:1.93.0` image digest
  `sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`;
- `rustc 1.93.0`, commit
  `254b59607d4417e9dffbc307138ae5c86280fe4c`;
- Cargo 1.93.0, commit
  `083ac5135f967fd9dc906ab057a2315861c7a80d`;
- clippy and rustfmt installed only in the ephemeral container for that exact
  toolchain;
- Rust toolchain components are MIT OR Apache-2.0; the official image includes
  Debian packages under their respective licenses and is a test tool, not a
  runtime dependency.

Exact results:

| Command | Result | Classification |
|---|---|---|
| `cargo test --verbose --locked` | fail, exit `101` | Reproducible upstream source/test incompatibility: `moq-transport/src/serve/tracks.rs:501` compares `TrackName` with `&str` (E0308). |
| `cargo clippy --locked --no-deps -- -D warnings` | pass | Upstream invocation accepted; workspace dev targets checked. |
| `cargo fmt --all -- --check` | fail, exit `1` | Two existing format diffs in `moq-transport/src/serve/subgroup.rs:934` and `serve/tracks.rs:304`. |
| `cargo test --verbose --locked -p moq-native-ietf` | pass | 1 unit test passed; zero failed; doctests zero. |
| `cargo test --verbose --locked -p moq-relay-ietf` | pass | 16 unit tests passed; doctests 1 passed, 1 ignored. |
| Specific `moq-transport` test repeat | environment failure, exit `101` | A later repeat exhausted the 3.9 GiB temporary filesystem; the earlier workspace command had already reached and demonstrated the crate's E0308 source failure. |

Because the required locked workspace test and formatting checks fail, the
baseline is exact and reproducibly characterized but **not a fully passing
reproducible baseline**. No source correction is part of this transition.

## Tool record

| Tool | Pin/version | License | Purpose |
|---|---|---|---|
| Git | 2.53.0 | GPL-2.0-only | exact checkout/ref/tree/status |
| GitHub CLI/API | gh 2.54.0; official REST | MIT | selected-field read-only repository evidence |
| Docker | 28.3.3 | Apache-2.0 | ephemeral pinned Rust environment |
| Rust image/toolchain | digest and commits above | toolchain MIT OR Apache-2.0; image packages vary | baseline compilation gates |
| ShellCheck | 0.11.0, tag commit `aac0823e6b58f8a499e856e93738082691cbf212`, official asset SHA-256 `8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198` | GPL-3.0 | ephemeral static analysis; not installed globally |
| curl | 8.18.0 | curl license | download official ShellCheck asset only |
| ripgrep | 15.2.0 | MIT OR Unlicense | local scope/placeholder/reference validation |

ShellCheck 0.11.0 passed both verifier scripts after one test-literal cleanup.
The binary came from the official GitHub release; GitHub's asset digest was
verified before execution and the temporary files were removed.

## Primary official sources

All were consulted on 2026-08-26:

- `https://github.com/cloudflare/moq-rs/commit/bf87128affd316463e5dcc7599a45001f222b6de`
  — approved official baseline, MIT OR Apache-2.0;
- `https://github.com/cloudflare/moq-rs/tree/draft-18-dev` — separate development
  branch at the exact commit above; not adopted;
- `https://github.com/Teremoq/moq-rs-teremoq` — public independent derivative;
- `https://docs.github.com/en/repositories/creating-and-managing-repositories/duplicating-a-repository`
  — official independent duplication/mirroring model;
- `https://docs.github.com/en/pull-requests/reference/forks` — official fork
  network/visibility model;
- `https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility`
  — visibility transition consequences;
- `https://docs.github.com/en/rest/actions/permissions` — Actions selection,
  SHA pinning and workflow permission API;
- `https://docs.github.com/en/rest/secret-scanning/secret-scanning` — Secret
  Scanning/Push Protection API surfaces;
- `https://github.com/koalaman/shellcheck/releases/tag/v0.11.0` and
  `https://github.com/koalaman/shellcheck/blob/v0.11.0/LICENSE` — official tool
  release and GPL-3.0 license.

## Residual blockers and next gate

- baseline workspace tests and formatting do not pass under the selected exact
  toolchain;
- rulesets are inactive;
- CodeQL Rust remains blocked by the documented GitHub API limitation;
- Dependency Graph/SBOM remains unverified;
- I1/I2/C1/C2 and all product integration are unstarted.

The next Master gate is to review and accept this public-governance transition
and decide whether the baseline test/format failures must be resolved in a
separate authorized baseline-maintenance phase before authorizing I1/I2. No
identity implementation begins automatically.
