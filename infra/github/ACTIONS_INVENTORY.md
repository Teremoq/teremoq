# GitHub Actions inventory

Reviewed through the GitHub API on 2026-08-26. `Teremoq/teremoq` contains no
workflow `uses:` references. The baseline imported into
`Teremoq/moq-rs-teremoq` contains the mutable references below; none is approved
for Teremoq execution until it is replaced by a reviewed full commit SHA.

Repository policy currently permits GitHub-owned actions only, requires a full
commit SHA, sets `verified_allowed` to false and has no third-party wildcard.
Every non-GitHub repository below is therefore blocked until a narrow reviewed
pattern is deliberately added.

| Repository | Existing mutable references | Full commit | License | Upstream purpose | Status |
|---|---|---|---|---|---|
| `actions/checkout` | `v3`, `v4` | Not set | MIT | Check out source | Blocked by SHA policy; consolidate and pin |
| `superfly/flyctl-actions` | `master` | Not set | Apache-2.0 | Install Fly.io CLI for upstream deployment | Blocked; deployment workflow also requires explicit Teremoq authorization |
| `fsfe/reuse-action` | `v5` | Not set | GPL-3.0-or-later; CC0-1.0 documentation | Run REUSE lint | Blocked; prefer the verified REUSE tool in a pinned environment |
| `actions-rust-lang/setup-rust-toolchain` | `v1` | Not set | MIT | Install Rust toolchain | Blocked; review against native runner/toolchain options |
| `bnjbvr/cargo-machete` | `main` | Not set | MIT | Detect unused Rust dependencies | Blocked; pin only after owner and source review |
| `dtolnay/rust-toolchain` | `stable` | Not set | MIT | Install Rust toolchain | Blocked; consolidate duplicate toolchain setup |
| `MarcoIeni/release-plz-action` | `v0.5` | Not set | Apache-2.0 | Upstream release automation | Blocked; releases are outside this bootstrap's authorization |

Mutable tag and branch references are recorded only as findings, not as allowed
pins. Before enabling any of these workflows, the maintainer must select the
official repository, review the exact source revision, record its 40-character
commit and license here, update the workflow, and verify the resulting run.

GitHub-native CodeQL default setup does not add an external `uses:` reference
and is therefore preferred over a hand-written CodeQL workflow.
