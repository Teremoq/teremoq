# Controlled public derivative synchronization runbook

## Purpose and authorization

This manual runbook synchronizes the independent public derivative without
rewriting consumed refs. Each execution requires an authorized continuation of
Task 05, `TP-RUST-DIST` ownership, the ADR-0007 reviewers, and a publication
boundary review because every pushed object becomes public.

It never changes product dependency pins, uses a branch as a build pin, vendors
source into Teremoq, uses `git push --mirror`, force-pushes, or publishes
unreviewed code. Public visibility is not standing authority to push.

## Preconditions

1. Run `infra/upstream-mirror/verify-public-moq-derivative.sh` against the
   currently approved baseline. The current version accepts exactly one
   baseline branch and zero tags; it is not a post-push verifier for future
   branches.
2. Confirm GitHub authentication without recording credentials or identities.
3. Confirm the destination is exactly `Teremoq/moq-rs-teremoq`, public,
   independent, not archived and under the required repository controls.
4. Confirm no secret, PKI, customer configuration, production namespace,
   operational data, private path/log or unsupported product claim is present.
5. Work in a clean temporary checkout outside the Teremoq workspace with
   credential-free remotes:

```text
upstream https://github.com/cloudflare/moq-rs.git
origin   https://github.com/Teremoq/moq-rs-teremoq.git
```

6. Record Git, GitHub CLI, Rust/Cargo and test-tool versions, immutable pins and
   licenses. Install nothing globally.
7. Before creating any new remote branch, produce and review the intended commit
   locally so its full SHA is known. In the same authorized phase, evolve
   `baseline.env`, the verifier and its tests to an exact inventory binding each
   approved full ref name to its full SHA. Run that revised verifier against the
   pre-push state with an explicit expected-absence transition for only the new
   ref. Do not use prefix wildcards, `branch_count >= 1` or an open count.

## 1. Obtain and identify official refs

Fetch without deleting audit refs, then record complete commit and tree IDs:

```bash
git fetch upstream main draft-18-dev --tags
git rev-parse refs/remotes/upstream/main^{commit}
git rev-parse refs/remotes/upstream/main^{tree}
```

Never select a candidate by short SHA, branch, mutable tag or date alone.

## 2. Inspect candidate delta and publication boundary

- compare the approved baseline to the candidate with log/stat and focused
  source review;
- search identity, authorization, admission, lifecycle, wire, draft and ALPN
  changes;
- inspect manifests, lockfile, MSRV/toolchain, features, build scripts,
  workflows and third-party sources;
- inspect every SPDX expression, `LICENSES/`, REUSE metadata and notice delta;
- review official releases, issues, pull requests, advisories and I1/I2/C1/C2;
- scan every new object for secrets/private deployment material before push;
- stop if official upstream now supplies the complete contracts and prepare an
  official adoption decision instead of extending the derivative.

Wire/draft/ALPN change, incompatible license, new dependency/feature, `unsafe`,
second transport, copied relay, unclear provenance or private material returns
to the Master before any public action.

## 3. Create a new immutable baseline

Create a new branch from a complete official commit:

```text
teremoq/baseline-<draft>-<short-display-sha>
```

Verify full commit, tree, clean worktree and upstream license objects. A later
authorized push uses one explicit non-force branch refspec only: no tags, notes,
remote-tracking refs or hidden refs. Verify public independence, ref inventory,
SHA/tree/license and repository controls immediately afterward. Never move an
existing `teremoq/baseline-*` branch.

The post-push check uses the revised exact inventory prepared before the push:
every approved ref must exist at its declared full SHA, and any extra, missing or
moved ref or any tag fails closed. Do not run the current baseline-only verifier
unchanged after creating a new branch and do not weaken it to make the push pass.

## 4. Replay approved derivative commits

Create new phase branches from the new baseline and use immutable approved
commit IDs. Prefer reviewed `git cherry-pick -x` only when the API remains
compatible. Reimplement under fresh review when ownership or structure changed;
never mechanically resolve trust, admission, lifecycle or wire conflicts.

Keep I1, I2, C1 and C2 as separate review units. Do not rebase/force-push a
reviewed or consumed branch. Record old/new commits, reason, source paths,
reviewers, license and test evidence without personal identities, credentials,
certificates, local paths or raw logs.

## 5. Execute gates

Use one exact locked toolchain and test the exact commit proposed for use:

- upstream locked workspace test, clippy and format requirements;
- focused I1/I2 identity, object-safety, ordering and redaction tests;
- focused C1/C2 real-QUINN N/N+1, release, cancellation, deadline,
  multi-endpoint, shutdown and metric tests;
- draft-16, WebTransport/raw QUIC, ALPN, setup and Object regressions;
- license, REUSE, advisories, provenance, MSRV, features and dependency delta;
- secret/private-material and sensitive-output absence scans.

A moving branch tip invalidates evidence. A failed baseline gate is recorded and
returned to the Master; source is never edited under a synchronization run merely
to make it pass.

## 6. Product pin gate

Only a separately authorized integration continuation may update Teremoq. It
pins a full integration commit and updates `moq-native-ietf`, `moq-transport`
and `moq-relay-ietf` atomically. Before the pin, repeat remote/provenance/control
verification and prove reachability from the documented baseline plus only
approved patch commits. Run complete SPIFFE, Chaos, wire and rollback gates.

## 7. Rollback and unavailable derivative

Rollback is an authorized atomic pin change to the previous full commit; remote
branches never move. If the derivative is unavailable, fail new builds closed
unless the exact commit already exists in a trusted cache.

A disaster-recovery source archive may be retained outside the source workspace
only with commit, tree, archive digest, licenses and notices. Verify it against
the official/derivative commit. Do not unpack it into Teremoq or activate
`[patch]`, `path` or vendored dependencies without another ADR decision.

## Exit review

At every synchronization, test whether an official Cloudflare release or commit
covers I1/I2/C1/C2. Exit through one atomic official pin, complete regressions,
removal of derivative adaptation and rollback proof. Two active implementations
are prohibited.
