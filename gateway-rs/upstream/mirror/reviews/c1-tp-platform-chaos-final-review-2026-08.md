<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C1 TP-PLATFORM-CHAOS final review

Verdict: **APPROVE FOR LOCAL COMMIT**

Review date: `2026-08-28`.

Scope: final read-only, focal rereview of the local C1 snapshot in
`/home/jimbomilk/moq-rs-teremoq-c1-work`. This approval is limited to a local
commit of the exact ten paths and hashes recorded below. It does not approve
C2, integration, publication, push, issue, pull request, tag, release, product
capacity, or any remote mutation.

## Findings

No open C1 implementation or C1 test-gate finding remains in this exact
snapshot.

### Inherited baseline blocker — C1-WR-03 remains unpassed

C1-WR-03 remains correctly classified `BLOCKED_BY_BASELINE_E0308`. The exact
baseline and current tree retain byte-identical
`moq-transport/src/serve/tracks.rs` with SHA-256
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
Its library test still compares `TrackName` with `&str` at line 501 and fails to
build before the Objects assertion can execute. C1 changes neither that crate
nor that test.

This inherited blocker is not waived or converted into a pass. It does not
prevent a local commit of the isolated C1 delta, but it continues to prevent a
claim that the full workspace/Objects regression gate passes and remains a
publication/integration blocker until its owning baseline change lands.

### Public-seam limitations remain conservative

The four previously documented cases remain outside the pinned public/test
seams: exact mid-TLS pause, exact same-poll deadline/success, exact same-poll
cancellation/QUINN error, and live QUINN 0.11.x incoming-queue occupancy. None
is labelled a pass. Their status is unchanged and introduces no new C1 finding.

## C1-R04 closure

C1-R04 is closed.

At `moq-native-ietf/src/quic_c1_tests.rs:1132-1143`, the complete paired
draft-16 setup wait now has this ownership and timeout shape:

```rust
tokio::time::timeout_at(watchdog_deadline(), async {
    tokio::join!(
        moq_transport::session::Session::accept(...),
        moq_transport::session::Session::connect(...),
    )
})
.await
.expect("draft-16 setup watchdog elapsed");
```

The review confirms all required properties:

- `watchdog_deadline()` is evaluated once for the paired logical wait;
- the absolute deadline is not reset per side, setup message, or poll;
- `tokio::join!` remains inside the timed future, so accept and connect continue
  to be polled simultaneously;
- no sleep, relative success threshold, event-count heuristic, or nested timeout
  was introduced;
- the server and client draft-16 success assertions remain after the watchdog;
- the pending-handshake and completed-terminal assertions before setup remain
  unchanged; and
- each Raw QUIC and WebTransport iteration receives its own single watchdog for
  its independent setup operation.

The prior direct, unbounded `tokio::join!` was the sole open
TP-PLATFORM-CHAOS finding. The new test-module hash is
`610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9`.

## Prior binding findings

| ID | Final state | Evidence |
| --- | --- | --- |
| C1-R01 | CLOSED | No admission observer, public admission event, synchronous emission callback, or blocking replacement exists in production. Observability remains atomic and low-cardinality; the deterministic stage hook is `cfg(test)` only. |
| C1-R02 | CLOSED | Every public route to semaphore construction validates `MAX_PERMITS`; MAX succeeds and MAX+1 returns the typed fallible error without panic. |
| C1-R03 | CLOSED | RAII releases the owned permit before publishing a terminal counter, with release/acquire ordering and exactly-once terminal ownership. |
| C1-R04 | CLOSED | The last unbounded paired draft-16 setup wait now has one absolute monotonic watchdog around the complete simultaneous join. |
| C1-R05 | CLOSED | WR-03 is correctly `BLOCKED_BY_BASELINE_E0308`, explicitly unpassed, and separated from C1. |

## Production invariance and C1 behavior

Production `moq-native-ietf/src/quic.rs` remains byte-identical to the snapshot
reviewed previously, SHA-256
`b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723`.
The R04 correction changes only the test module. Therefore the prior formal
review of production ordering, ownership, and metrics remains binding:

- `quinn::Endpoint::accept().await` first yields one owned `Incoming`;
- admission then uses only non-blocking `try_acquire_owned`;
- saturation immediately consumes that `Incoming` with configured Refuse or
  legal Retry, with no permit waiter, task, or hidden future;
- an admitted connection creates exactly one server-owned future;
- one absolute production deadline covers QUIC/TLS, ALPN, H3 SETTINGS, and
  WebTransport CONNECT;
- permit ownership is RAII across success, error, timeout, cancellation, future
  drop, and server drop;
- capacity is released before MoQT setup and established session lifetime;
- endpoint capacity is local by default and shared only through the explicit
  shared-controller constructor;
- raw QUIC, WebTransport, `accept_with`, draft-16, and legacy behavior retain the
  reviewed compatibility; and
- metrics remain schema-versioned, low-cardinality, free of peer identity/IP
  labels, underflow-safe, and terminally exactly once.

No relay session limit or C2 behavior is implied by C1.

## Immutable base and exact ten-path scope

- Branch: `teremoq/c1-bounded-handshakes-bf87128`.
- Base and HEAD: `bf87128affd316463e5dcc7599a45001f222b6de`.
- Base and HEAD tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`.
- Status-path inventory SHA-256:
  `fc674e7161c60e0aae278ea478f6570a9606d706aa81dad0c60e2384d5e8d3f9`.
- Index: empty.
- Owner correction report SHA-256:
  `a7cca70bc0d926739ca109cacdef1648e200255ad9c82cb33e2b521e0d2b7626`.
- Prior TP-PLATFORM-CHAOS rereview SHA-256:
  `4ea32c55223e4e9d9f1aa697ca9f63e37fd2561b3fb568e66298bdcf858392c2`.

The exact inventory is one modified production file, one new test module, and
eight unchanged test-fixture/provenance files:

| State | Path | SHA-256 |
| --- | --- | --- |
| modified | `moq-native-ietf/src/quic.rs` | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| new | `moq-native-ietf/src/quic_c1_tests.rs` | `610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9` |
| new, unchanged | `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| new, unchanged | `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| new, unchanged | `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| new, unchanged | `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

All manifests, `Cargo.lock`, `moq-transport`, `moq-relay-ietf`, setup/wire
constants, Objects source, licenses, and dependencies remain byte-identical to
the base. No eleventh path, staged change, or production change after the prior
review was found.

## Validation evidence

This focal final review deliberately did not repeat a large build. It verified
the exact branch, base/HEAD/tree, status inventory, stage, ten paths, focal and
protected hashes, source lines, watchdog ownership, and whitespace checks
directly.

The binding owner report, at its verified SHA-256 above, records Rust 1.93.0,
`--locked --offline`, and these post-correction results:

| Gate | Result |
| --- | --- |
| focal rustfmt on `quic.rs` and `quic_c1_tests.rs` | PASS |
| `cargo test -p moq-native-ietf c1_` under external watchdog | PASS: 25 passed, 0 failed, 1 filtered |
| `cargo test -p moq-native-ietf` under external watchdog | PASS: 26 passed, 0 failed; doctests 0/0 |
| `git diff --check` and cached diff check | PASS; index empty |
| no-index whitespace checks for all new files | PASS |
| exact inventory, fixture hashes, and protected-file comparison | PASS |
| `cargo test -p moq-transport` | `BLOCKED_BY_BASELINE_E0308`; not passed |

No result interrupted by resources is promoted to evidence in this final
review. The earlier interrupted WR-03 reproduction remains documented only in
the historical rereview; it was not repeated and is not needed to verify the
focal R04 test-only correction.

## Final gate

The exact ten-path C1 snapshot above is approved for a **local commit only**.
The commit must preserve every listed hash. Any source, test, fixture, manifest,
lockfile, dependency, path-inventory, or base change invalidates this approval
and requires a new review.

**APPROVE FOR LOCAL COMMIT**

**LOCAL REVIEW ONLY / NO COMMIT PERFORMED / NO PUSH / NO PUBLICATION / NO C2 / NO REMOTE MUTATION**
