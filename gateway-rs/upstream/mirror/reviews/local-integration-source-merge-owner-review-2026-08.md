<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Local I1/I2 + C1/C2 source merge owner rereview

Date: 2026-08-28 09:23:58 UTC

Owner: `TP-RUST-DIST`

Required reviewers: `TP-SEC-PKI`, `TP-PLATFORM-CHAOS`, `TP-OSS-SC`

State: **READY FOR FORMAL REREVIEW / NOT COMMITTED**

LOCAL ONLY / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION

## Findings first

### Closed for owner rereview — HIGH IC-12: required-mode diagnostics disclosed resources

The formal `TP-SEC-PKI` review identified exact namespace, prefix, track and
remote URL values in tracing reachable after successful required-mode
authorization, and post-authentication mlog retained the same resource-bearing
MoQT messages. The owner correction is conservative and global within the
shared relay library paths:

- `consumer.rs`, `producer.rs`, `remote.rs` and the relay wiring now emit only
  fixed, low-cardinality `operation`, `stage`, `source` and enumerable
  disposition fields. Peer-derived errors and request `Debug` values are not
  formatted.
- The dynamically reached `api.rs`, `local.rs`, `session.rs` and
  `upstream_namespaces.rs` helpers apply the same redaction. This was necessary
  because the positive composed test proved that local registration teardown
  was also reachable from required mode.
- Both required relay paths finish the pending MoQT setup with no mlog writer.
  Legacy mlog remains explicitly separate; no transport serializer or wire
  behavior was changed.
- Raw QUIC and WebTransport tests place independent synthetic canaries in the
  certificate label, authenticated context, connection path, namespace,
  prefix, track and relay URL. Captured relay tracing and an isolated mlog
  directory contain none of the canaries or protected type names. The test
  observes a fixed required-mode authorization event and fixed metrics labels.

No certificate bytes, DER/PEM, subject, SAN, serial, fingerprint, principal,
role, path, namespace, prefix, track or full remote URL is added to tracing,
errors, mlog or metric labels by the corrected required path.

### Closed for owner rereview — HIGH IC-14: positive composition and N+1 oracle were absent

Two distinct positive tests now traverse `Relay::new_required_bounded`, one over
raw QUIC and one over WebTransport. Each proves, with independent probes:

1. exactly one C1 admission completes and releases;
2. non-empty I1 rustls evidence from that connection reaches I2;
3. exactly one authentication succeeds;
4. only policy observes the exact canonical requested path;
5. required scope resolution succeeds while legacy `Coordinator::resolve_scope`
   and `ConnectionTagger` remain at zero calls;
6. `SERVER_SETUP` completes;
7. exact-namespace `Publish` and the second `RelayPeer(Publish)` gate both
   complete before reader extraction or registration;
8. the positive response and independent application-state probes occur only
   after both gates; and
9. tracing and mlog remain redacted/empty.

The combined N+1 test retains the first authorized root at the scope boundary
and runs both transports. The second client observes public application close
code `0x3` with the fixed reason `relay session capacity reached`. It proves no
second authentication, required effect, coordinator/tagger call, mlog file or
application state, while C1 still accounts for both completed handshakes and C2
accounts for one immediate capacity rejection.

### Residual inherited blocker — not changed

`moq-transport` library tests remain
`BLOCKED_BY_BASELINE_E0308` at
`moq-transport/src/serve/tracks.rs:501` (`TrackName` compared with `&str`). The
protected crate was not edited. Complete workspace rustfmt also continues to
report only the two inherited protected diffs at
`moq-transport/src/serve/subgroup.rs:934` and
`moq-transport/src/serve/tracks.rs:304`.

No unresolved owner finding remains in this correction snapshot. Formal
approval is deliberately not claimed.

## Frozen merge identity

| Item | Value |
| --- | --- |
| Branch | `teremoq/integration-draft16-bf87128-local` |
| `HEAD` / first parent candidate | `59d9a8601885ef934cae29d89876abb7c7f73e89` (I2) |
| `MERGE_HEAD` / second parent candidate | `b4ee3b68df58bbb6e7b865c2898d3f46ffbb7fd1` (C2) |
| Previous reviewed staged tree | `985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b` |
| Corrected staged tree | `d7f0c67f4c134adc4250885f6bc031aa2efcead6` |
| Corrected pathset SHA-256 (`git diff --cached --name-only`) | `5ca569098581750132c29f1e9b50d5bfefd52eee2f7d347811f27697109a7388` |
| Corrected status-z SHA-256 | `b35e9c4f2ce80d4abd8b08e72fa8fa31b3370ad1517001ddf26cf11fc15fe426` |
| Staged paths | 31 |
| Unmerged entries | 0 |
| Unstaged paths | 0 |
| Tracking branch | none |

The merge remains in progress. No commit, merge abort, fetch, push, tag,
release, issue, PR or remote mutation occurred. Locally cached remote refs still
contain only
`origin/teremoq/baseline-draft16-bf87128 -> bf87128affd316463e5dcc7599a45001f222b6de`.

The correction started only after reproducing the required preflight values:
previous tree `985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b`, 26 paths, pathset
`c16063d311bc42b1baf16f314d11e3604cecc640be6542af826b09be20023470`
and status-z
`085eec09a457ee974eb9a7260c278516631ca4d7941262f197e675b87506933a`.

## Review inputs

| Review | SHA-256 / result on previous snapshot |
| --- | --- |
| Owner report | `9c4c4c5bee4debaffda8aea10ef5653db9d29f6987119d83c83a02f9b22c21a7` |
| `TP-PLATFORM-CHAOS` | `05a523c98db61e993ed6edc2fd23ec5c8878b61769837123df84668ef781e4b2`; `APPROVE` |
| `TP-SEC-PKI` | `e0225d5dcb8684c84a60de5ecf126bfab9e939e1eb632188a8e7aa79510e14a0`; `CHANGES REQUIRED` |
| `TP-OSS-SC` | `541bedd92605a261b5b938c32df4a980c8e931e183f0881100b40c079a795826`; supply-chain `APPROVE` |

The platform and OSS results describe the previous tree; the expanded
redaction pathset therefore requires a fresh independent formal rereview.

## Integrated ordering and invariants

The corrected staged source preserves:

`C1 Incoming admission -> I1 verified evidence -> C2 immediate session admission -> I2 authenticate -> pending CLIENT_SETUP and canonical path -> exact path/scope authorization -> finish/SERVER_SETUP -> exact operation authorization -> state/tasks`

C1/C2 capacity does not grant identity or authorization. Required identity is
derived only from the connection-bound verified evidence. Path and namespace
remain authorization resources, not identity. IP, SNI, CID, `ConnInfo` and
`ConnectionTagger` do not contribute to the required principal. Legacy APIs
remain explicitly separate. Draft-16, ALPN, Objects, Zero-Transcoding, QUIC,
rustls and WebTransport wire behavior remain unchanged.

## Validation matrix

All Rust commands used Rust/Cargo 1.93.0 in the local image
`teremoq-local-rust193-components:c2-review-20260828`, image ID
`sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`,
with `--network none`, read-only Cargo caches and an external target directory.

| Gate | Result |
| --- | --- |
| Frozen preflight, parent identities and prior index hashes | PASS |
| `git ls-files -u`; conflict-marker scan | PASS; zero unmerged entries and zero conflict markers |
| `git diff --check`; `git diff --cached --check` | PASS |
| Focal `rustfmt --edition 2021 --check` on all nine corrected Rust paths | PASS |
| `cargo clippy --locked --offline --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS after final snapshot |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 32 library + 6 I1 integration tests |
| `cargo test --locked --offline -p moq-relay-ietf` | PASS: 175 library + 16 binary + 10 C2 integration + 1 doctest; 202 passed, 1 doctest ignored |
| Positive `required_bounded_positive_*` filter | PASS: distinct raw QUIC and WebTransport tests |
| Combined `bounded_required_capacity_rejects_n_plus_one_before_authentication` | PASS for raw QUIC and WebTransport with public code/reason oracle |
| Existing I1/I2/C1/C2 focal coverage | PASS within the complete native and relay suites |
| `cargo fmt --all -- --check` | Expected inherited failure only: protected `subgroup.rs:934` and `tracks.rs:304` diffs |
| `cargo test --locked --offline -p moq-transport --lib` | `BLOCKED_BY_BASELINE_E0308` only at protected `tracks.rs:501` |
| REUSE 5.1.1, image ID `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | PASS: 223/223; MIT and Apache-2.0; zero errors |
| Gitleaks 8.30.1/MIT, image ID `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` | PASS: nine corrected source paths, 449,967 bytes, redacted output, zero findings |
| `cargo package --locked --offline -p moq-relay-ietf --list --allow-dirty` | PASS: 48 entries |
| Fixture provenance | C1 DER entries PASS; C2 PEM entries PASS; the three C2 DER provenance hashes independently match the immutable C1 files |
| Protected artifact SHA-256 comparison | PASS; all values unchanged from I2 `HEAD` |
| Final index | PASS: tree `d7f0c67f4c134adc4250885f6bc031aa2efcead6`, 31 staged, zero unstaged/unmerged |
| Cleanup | PASS: external target and focal scan directory removed; no source-side target or temporary container remains |

A direct all-entry `sha256sum -c` inside the C2 fixture directory reports its
three DER provenance names as absent because those entries document the C1 DER
source rather than duplicate it. The PEM entries pass in place, and the DER
hashes were checked against the immutable C1 directory. No fixture was changed.

## Staged inventory and SHA-256

| Path | SHA-256 |
| --- | --- |
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` |
| `moq-native-ietf/src/quic_c1_tests.rs` | `610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9` |
| `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/src/api.rs` | `aca75de5ecdc7e6eebca0064c72389afaa6020e24bf0e355f2c5fcdf2a1cfbda` |
| `moq-relay-ietf/src/consumer.rs` | `311807c1b982ab9f72420e6c7fb5e4f4ce0b9bf7f1a8593626d92a1438dd7916` |
| `moq-relay-ietf/src/i2_tests.rs` | `c69ffa190430cd8662f249c461be94fd74e10d9ceabe188b028c91e1f37413ec` |
| `moq-relay-ietf/src/lib.rs` | `833b732c738650c0ed6297c7094bdb8309da5953b9c51f950f58f1079f68b03c` |
| `moq-relay-ietf/src/local.rs` | `ecacbe786afa98fbc75afbdf8cde57571a43b818662b946ee43db5c593ac2395` |
| `moq-relay-ietf/src/producer.rs` | `23b8ac2ea42987414aebc1f4b21c9eaf5dae182335fba00c3a2aadfd75238960` |
| `moq-relay-ietf/src/relay.rs` | `8c0df50c59ca86c132272b573604e6a10657cd6781bb70f9ed384e1262c1b3e4` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `5ebccdf289a5b4183b28e78ee56dfad7f991a2c4c58eda27327c5e88f8033237` |
| `moq-relay-ietf/src/remote.rs` | `ed2c2c1759dff247ecac4582021938026572a301db29a44059459b6308b7f614` |
| `moq-relay-ietf/src/session.rs` | `9be32af612ae4cf7a3e3868432141adf17796eb07405d9bdb7d618570a36c60e` |
| `moq-relay-ietf/src/session_admission.rs` | `cc5c56db172f7fb13e1f5a1a8bea3957c096d869dd97ac3f9d9f753820f0c7ef` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `39dd2e657e511465e89fee2d24a53452ab30a9a4bb3b588d9888e98bd89f05f3` |
| `moq-relay-ietf/tests/c2_session_admission.rs` | `1b528da9ccd852d81085bad190e01ae9a5a84ca6724574ed6a7cd2904e7e0a0a` |
| `moq-relay-ietf/tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `moq-relay-ietf/tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `moq-relay-ietf/tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

## Protected artifacts

All protected values remain byte-identical to I2 `HEAD`:

| Path | SHA-256 |
| --- | --- |
| `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `moq-native-ietf/Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |
| `moq-transport/Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| `Cargo.lock` | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` |
| `moq-transport/src/setup/mod.rs` | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| `moq-transport/src/setup/version.rs` | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| `moq-transport/src/message/mod.rs` | `e5760f5ce2927b2437511b3e616fea2615d82e916d4b6036b7f5450ae0973352` |
| `moq-transport/src/session/mod.rs` | `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00` |
| `moq-transport/src/serve/tracks.rs` | `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| `LICENSES/MIT.txt` | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| `LICENSES/Apache-2.0.txt` | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |

## Residual limits and next gate

This snapshot is a local, reversible, staged source-merge candidate. It does
not establish Zero-Trust readiness, DoS resistance, bounded production
capacity, commercial readiness, publication readiness or authorization to
change product pins.

The exact next gate is independent formal rereview by `TP-SEC-PKI` for IC-12
and IC-14, plus confirmation by `TP-PLATFORM-CHAOS` and `TP-OSS-SC` over staged
tree `d7f0c67f4c134adc4250885f6bc031aa2efcead6`. The merge must remain
uncommitted. The inherited E0308 repair requires its own separately authorized
package.
