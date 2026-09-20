# Controlled moq-rs mirror bootstrap report — 2026-08-26

## Result

Bootstrap completed for the independent repository
`https://github.com/Teremoq/moq-rs-teremoq`.

- Visibility before baseline upload: `private` (`private=true`).
- Visibility after baseline upload: `private` (`private=true`).
- Fork status: `fork=false`, no parent.
- Issues/wiki: disabled.
- Created: `2026-08-26T18:51:25Z`.
- Baseline pushed: `2026-08-26T18:53:45Z`.
- Published branch count: one.
- Published tag count: zero.
- Product patches: zero.
- External communications during bootstrap: zero.

The first HTTPS push attempt was rejected before creating a ref because the
OAuth credential did not include workflow permission and the official baseline
contains an upstream workflow. The source was not altered to bypass this guard,
and the push was not retried with broader OAuth scope. Existing authenticated
SSH access was then used without persistent configuration or a credential in the
remote URL. One explicit non-force branch refspec succeeded.

## Exact baseline

| Field | Value |
|---|---|
| Official upstream | `https://github.com/cloudflare/moq-rs.git` |
| Approved commit | `bf87128affd316463e5dcc7599a45001f222b6de` |
| Commit date | 2026-08-18 |
| Approved tree | `d76319009e815fb8923e21fc8319e17a0aaf8174` |
| Mirror branch | `teremoq/baseline-draft16-bf87128` |
| Remote branch SHA | `bf87128affd316463e5dcc7599a45001f222b6de` |
| Remote commit tree | `d76319009e815fb8923e21fc8319e17a0aaf8174` |
| Current official `main` at bootstrap | `bf87128affd316463e5dcc7599a45001f222b6de` |
| Current official `draft-18-dev` | `5a3e5ffe833f00df6e39277b7b1258dd907fc036` |

The baseline branch became GitHub's default branch automatically because it was
the first and only pushed branch. No command changed the default branch. The
bootstrap recommendation is to leave it unchanged until an authorized
implementation continuation defines a dedicated integration branch and an
approved protection model; builds must continue to use full commits rather than
either default branch.

Remote ref inventory immediately after the push:

```text
bf87128affd316463e5dcc7599a45001f222b6de refs/heads/teremoq/baseline-draft16-bf87128
```

The explicit push published no tags, notes, remote-tracking refs, or other
branch. It did not use force or `git push --mirror`.

## License and provenance

The official repository uses SPDX `MIT OR Apache-2.0` for
`moq-native-ietf 0.10.0`, `moq-relay-ietf 0.7.25`, and
`moq-transport 0.16.1`. The baseline preserves:

| Official file | Git blob | SHA-256 |
|---|---|---|
| `LICENSES/Apache-2.0.txt` | `55b366195e45a27ba1681037db12a9efe3cb3e6f` | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| `LICENSES/MIT.txt` | `a6443463f9756ac500af0f4b62ae276a096429b8` | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| `REUSE.toml` | `39f45dc398c58993c3eab21d62c89d39b8b6fcd6` | preserved in baseline tree |

No notice or upstream workflow was removed. No code was copied into the Teremoq
workspace.

## Official source register

All sources were consulted on 2026-08-26.

| Primary official source | Exact revision | License | Conclusion |
|---|---|---|---|
| `https://github.com/cloudflare/moq-rs/commit/bf87128affd316463e5dcc7599a45001f222b6de` | full commit and tree above | MIT OR Apache-2.0 | Approved unchanged draft-16 baseline and current `main`. |
| `https://github.com/cloudflare/moq-rs/tree/draft-18-dev` | `5a3e5ffe833f00df6e39277b7b1258dd907fc036` | MIT OR Apache-2.0 | Separate early draft-18 development; not adopted. |
| `https://github.com/cloudflare/moq-rs/tree/bf87128affd316463e5dcc7599a45001f222b6de/LICENSES` and `REUSE.toml` | exact blobs above | MIT OR Apache-2.0 | License texts, SPDX ownership, and notices preserved. |
| `https://docs.github.com/en/pull-requests/reference/forks` | consulted 2026-08-26 | documentation; not a software dependency | Public forks are public and remain in the repository network; unsuitable for this boundary. |
| `https://docs.github.com/en/repositories/creating-and-managing-repositories/duplicating-a-repository` | consulted 2026-08-26 | documentation; not a software dependency | GitHub documents an independent duplicate without a fork. Task 05 deliberately uses one scoped branch push instead of mirror-push. |
| `https://docs.github.com/en/rest/repos/repos` | REST API current on 2026-08-26 | documentation; not a software dependency | API evidence for private visibility, fork state, refs, commits, trees, and settings. |
| `https://docs.github.com/en/organizations/managing-organization-settings/restricting-repository-creation-in-your-organization` | consulted 2026-08-26 | documentation; not a software dependency | Organization policy controls who may create private repositories. |

## Access and repository controls

Demonstrated:

- authenticated GitHub CLI session without token output;
- organization membership and permission to create repositories;
- private visibility before and after upload;
- independent repository with no fork parent;
- issues and wiki disabled;
- effective administrative/read/write access for the bootstrap session;
- no direct collaborator grant and no team grant at bootstrap;
- organization base repository permission reported as `read`;
- one exact branch, no tags, correct commit, and matching tree.

Not demonstrated or not active:

- MFA enforcement: API evidence was unavailable; recommend organization-enforced
  MFA and human MFA without claiming either is active;
- branch protection/rulesets: the branch reports `protected=false`, and GitHub
  returned that repository rulesets require a plan upgrade or a public
  repository. Making the repository public is prohibited;
- a dedicated read-only build identity/deploy key: not created in this phase;
- availability SLO, backup retention, or a verified disaster-recovery archive:
  policy is documented but no archive was created.

Organization policy allowed members to create both private and public
repositories at bootstrap. This is an exposure risk outside the mirror itself;
least-privilege repository-creation policy and periodic access review are
recommended to organization owners.

## Baseline checks

The official PR workflow calls `cargo test --verbose`, `cargo clippy --no-deps`,
and `cargo fmt --check`, but it installs the current stable Rust toolchain and
uses unpinned Actions. The repository contains no fixed Rust toolchain file.

The local baseline checkout was exact and clean before checks. Execution stopped
before Cargo because `rustc` was not installed in the environment. No toolchain
was installed globally or implicitly. Therefore:

- source/tree identity: verified;
- licenses/SPDX/notices: verified;
- baseline compiled: **not demonstrated**;
- upstream tests/clippy/fmt under a reproducible toolchain: **not demonstrated**.

A future implementation continuation must select and record an explicitly
approved immutable toolchain before treating compilation as reproducible.

## Verifier validation

`infra/upstream-mirror/verify-private-moq-mirror.sh` passed `bash -n` and the
live positive case. Its reported commit and tree match the values above. The
following read-only negative cases returned their distinct expected codes:

| Case | Expected/result |
|---|---|
| nonexistent baseline ref override | exit `30`, ref absent |
| incorrect expected full SHA override | exit `40`, SHA mismatch |
| public-repository privacy guard | exit `20`, privacy/independence failure |
| simulated missing required tool | exit `10`, prerequisite failure |

ShellCheck was not installed. No workspace-approved ShellCheck image pinned by
digest was found, so no global install or floating container image was used.
ShellCheck validation remains an explicit tooling limitation; Bash syntax and
functional paths were still exercised.

Discovery and bootstrap used Git 2.53.0 (GPL-2.0-only), GitHub CLI 2.54.0
(MIT), curl 8.18.0 (curl license), and ripgrep 15.2.0 (MIT OR Unlicense).
Nothing was installed or added to the product toolchain.

## Product and security boundary review

`TP-SEC-PKI` review confirms that the mirror and documentation contain no
production secret, PKI key, certificate, principal, role assignment, private
namespace, local absolute path, token, cookie, credential-bearing URL, or raw
authenticated-tool output. The baseline is public official source stored behind
a private access boundary for future unpublished changes.

The active Teremoq dependency remains the official Cloudflare URL at the same
full commit. No I1/I2/C1/C2 implementation exists. Zero-Trust, bounded
admission, bounded shutdown, soak stability, and commercial readiness remain
unresolved.

## Rollback and next gate

The rollback anchor is the official full commit and tree recorded above. Since
the mirror is not an active dependency, bootstrap rollback currently means no
product action: do not adopt it. Once a future integration is authorized,
rollback must atomically restore the prior approved full commit for all three
crates.

The next Master decision is whether to authorize the identity continuation
(I1/I2) or request governance changes first, especially a supported immutable
branch control and a reproducible Rust toolchain. Admission and integration do
not begin under this bootstrap.
