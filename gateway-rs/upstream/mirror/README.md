# Controlled public moq-rs derivative

## Current status

`https://github.com/Teremoq/moq-rs-teremoq` is a **public independent
derivative**, not a GitHub fork. The transition from the original private
bootstrap was a later user decision under Teremoq's open-source model and is
recorded in `public-transition-report-2026-08.md`. The original
`bootstrap-report-2026-08.md` remains immutable historical evidence of the state
when the baseline was first uploaded privately.

The derivative currently contains one branch and no tags:

```text
refs/heads/teremoq/baseline-draft16-bf87128
bf87128affd316463e5dcc7599a45001f222b6de
tree d76319009e815fb8923e21fc8319e17a0aaf8174
```

The branch and tree equal the official Cloudflare baseline. No Teremoq patch,
I1/I2/C1/C2 implementation, product source, secret, trust material or customer
configuration has been added. The derivative is not an active product
dependency; active Cargo pins still target the official Cloudflare commit.

## Ownership and licensing

- Task owner: `TP-RUST-DIST`.
- Required identity/privacy reviewer: `TP-SEC-PKI`.
- Open-source/supply-chain controls: accepted Task 06 work by `TP-OSS-SC`.
- Architecture: `../../ADR-0007-CONTROLLED-MOQ-MIRROR.md`.
- License and future derivative contributions: `MIT OR Apache-2.0`.
- Product deployments, PKI, identities, namespaces and operational data: out of
  scope and prohibited from this public repository.

## Files

- `baseline.env`: strict public immutable inputs for verification.
- `PATCH-SERIES.md`: future review units and gates; no implementation authority.
- `SYNC-RUNBOOK.md`: non-destructive public-derivative synchronization/rollback.
- `bootstrap-report-2026-08.md`: historical private bootstrap record; not
  rewritten.
- `public-transition-report-2026-08.md`: current public transition, controls and
  reproducible baseline evidence.
- `../../../infra/upstream-mirror/verify-public-moq-derivative.sh`: live
  read-only fail-closed verifier.
- `../../../infra/upstream-mirror/test-verify-public-moq-derivative.sh`: live
  positive plus read-only fixture negatives and remote before/after snapshot.

## Verification

Run from any workspace location:

```bash
infra/upstream-mirror/verify-public-moq-derivative.sh
infra/upstream-mirror/test-verify-public-moq-derivative.sh
```

The live verifier requires the exact repository to be public, independent and
active; verifies the single baseline ref/SHA/tree and zero tags; compares
official/derivative license and REUSE objects; and requires the GitHub controls
listed in ADR-0007. Configuration is parsed as strict data rather than sourced:
unknown keys, duplicates, whitespace syntax and shell-like injection fail.

That one-branch/zero-tag rule is intentionally valid only for the current
baseline-only phase. The current verifier cannot be reused unchanged after a
future branch is created. Before any authorized branch push, the same phase must
first version `baseline.env` and the verifier locally to require an exact list
of approved full ref names and their reviewed full commit SHAs. The future gate
must reject extra, missing or moved refs and all tags; it must never accept a
prefix wildcard or a relaxed branch count. This document approves no future
I1/I2/C1/C2 SHA.

Fixture mode is test-only and prints `mode=fixture`; it is never remote evidence.
Rulesets, CodeQL Rust and Dependency Graph/SBOM are reported as pending and are
not silently treated as enabled.

Every build or integration must consume a full approved commit, never a branch.
The baseline branch is only a provenance handle.

## Baseline gate and next phase

Rust/Cargo 1.93.0 in the pinned official Rust container demonstrated that
clippy and the focused native/relay tests pass, but the exact baseline does not
pass the full locked test or formatting gates. The detailed commands and
diagnostics are in the public transition report. No source was changed to mask
those upstream failures.

The next clean gate is Master review of this transition and the baseline
failures. Only a subsequent explicit authorization may begin I1/I2. C1/C2 and
product integration remain unauthorized. This governance work does not resolve
Zero-Trust or bounded concurrency and does not make the relay productive.
