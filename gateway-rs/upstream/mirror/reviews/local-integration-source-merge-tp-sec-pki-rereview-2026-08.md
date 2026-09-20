<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-SEC-PKI formal rereview — staged local I1/I2 + C1/C2 source merge

Date: 2026-08-28 09:50:04 UTC

Role: `TP-SEC-PKI` (independent security reviewer; not implementer)

Scope: `/home/jimbomilk/moq-rs-teremoq-integration-work`

READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION

## Findings first

No open security finding was identified in the frozen snapshot. The two HIGH
findings from the preceding TP-SEC-PKI review are closed by the staged
correction. No source, manifest, lockfile, index, merge metadata, ADR, PKI
artifact or prior report was edited during this rereview.

### CLOSED — prior HIGH IC-12: required-mode observability disclosed resources

The correction removes the disclosure rather than moving it to another shared
helper:

- Required unbounded mode decodes pending setup, authorizes the canonical path
  and calls `pending.finish(None)` at
  `moq-relay-ietf/src/relay.rs:919-970`, specifically line 961. Required bounded
  mode does the same at `relay.rs:1960-2015`, specifically line 2006. The legacy
  branches alone retain `mlog_path` at `relay.rs:972-1011` and
  `relay.rs:2017-2050`. Supplying `RelayConfig.mlog_dir` therefore creates no
  required-mode mlog writer or file.
- Required setup and run failures no longer format peer-derived errors:
  `relay.rs:929-968`, `relay.rs:1153-1159`, `relay.rs:1969-2013` and
  `relay.rs:2195-2200` use fixed stages/messages. The `%err`, path, scope and
  permission formatting that remains at `relay.rs:982-1007`,
  `relay.rs:1041-1046`, `relay.rs:2028-2047` and `relay.rs:2198-2200` is reachable
  only from the explicit legacy branch.
- The required Producer/Consumer paths authorize before their first metric or
  effect (`consumer.rs:170-176`, `consumer.rs:442-448`,
  `producer.rs:212-218`, `producer.rs:379-387`, `producer.rs:533-539`,
  `producer.rs:571-574`, `producer.rs:611-628`, `producer.rs:725-728` and
  `producer.rs:785-788`). Their catch paths at `consumer.rs:128-166` and
  `producer.rs:148-205` emit only fixed operation/stage messages; request
  `Debug`, exact namespace/prefix/track and underlying errors are not
  formatted.
- Shared reachable diagnostics are fixed and low-cardinality throughout the
  eight requested files: `api.rs:62-66,88-92`;
  `local.rs:195-199,661-666,888-893,977-982`;
  `session.rs:391-436`; `remote.rs:1283-1389,1516-1598,1841-1869,1980-2154`;
  and `upstream_namespaces.rs:529-674,871-955`. `Remote`'s own Debug redacts the
  URL at `remote.rs:2162-2169`. `Api` has no call edge from the required inbound
  relay; its exported helper logging is nevertheless redacted. Every
  peer-derived error reached through Consumer, Producer, RemoteManager or the
  upstream namespace runner is either converted to a fixed wire error or
  discarded before the required session's fixed diagnostic boundary.
- Metric labels in these paths are enumerable constants only: connection error
  `stage`, announce/publish `phase`, subscription `source`, change `channel`,
  and cache `source`. No certificate, context, path, scope, namespace, prefix,
  track, URL, request or peer error supplies a label value. The subscription
  timing labels at `producer.rs:226,254,278,290,321,339` are also fixed.
- The positive raw and WebTransport harness places independent synthetic
  canaries in the client certificate label, authenticated context, canonical
  path, namespace, prefix, track and authenticated relay URL
  (`i2_tests.rs:43-57,911-935,981-985`). The context canary is genuinely stored
  and downcast by the authorizer (`i2_tests.rs:445-460,502-555,571-587`). The
  current-thread tracing capture follows spawned tasks, observes a fixed
  required-mode event, rejects all seven canaries plus protected type names,
  and independently requires the isolated mlog directory to remain empty
  (`i2_tests.rs:898-909,1042-1087`). The certificate canary was independently
  confirmed present in the synthetic DER fixture without emitting its bytes.

Static extraction of every `tracing::*` and `metrics::*` invocation in the
eight requested files found no dynamic resource, identity or error field in a
required-reachable invocation. A differential scan against previously reviewed
tree `985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b` independently confirms removal
of the former namespace, prefix, track, remote URL, request Debug and `%err`
fields. No DER, PEM, subject, SAN, serial, fingerprint, principal, role,
authenticated context, path, namespace, prefix, track, full remote URL or
protected type name is emitted by the corrected required path.

IC-12: **PASS / CLOSED**.

### CLOSED — prior HIGH IC-14: positive raw/WebTransport composition and N+1 oracle were absent

The production ordering is explicit and common to both transports:

1. C1 uses one immediate `try_acquire_owned` at
   `moq-native-ietf/src/quic.rs:245-253` and acquires it before calling any
   bounded handshake/CONNECT path at `quic.rs:1442-1466`.
2. I1 derives the application session and preserves a clone of that same
   established `quinn::Connection` for evidence at `quic.rs:1101-1134`; the
   evidence capture from that connection occurs before the accepted session is
   exposed at `quic.rs:1163-1179`.
3. The relay receives that `AcceptedSession` and performs immediate C2
   admission at `moq-relay-ietf/src/relay.rs:1487-1547`. A capacity disposition
   closes with the fixed public constants at `relay.rs:1520-1539`; no session
   root is pushed until admission owns the permit at `relay.rs:1553-1567`.
4. I2 authenticates only inside the admitted root and only from the borrowed I1
   evidence at `relay.rs:1894-1946`; the evidence value is dropped at line 1944.
5. Pending setup decodes the canonical path, sends it only to the required
   policy and fails closed on absence/denial at `relay.rs:1960-1998`. It neither
   calls `Coordinator::resolve_scope` nor `ConnectionTagger`; those are confined
   to the legacy branch at `relay.rs:2035-2047,2082-2097`.
6. `pending.finish(None)` and therefore `SERVER_SETUP` occurs only after scope
   authorization at `relay.rs:1999-2015`. SessionContext, Producer and Consumer
   creation occur later at `relay.rs:2053-2179`.
7. `RequiredAuthorization::authorize` executes the exact base operation and,
   only for an authenticated relay peer, the exact `RelayPeer` second gate
   before returning (`authorization.rs:332-345`). `Consumer::serve_track` does
   not increment its operation metric, extract a reader, register a track or
   respond until that combined call has succeeded (`consumer.rs:442-535`).

The new tests are real composition tests, not direct unit construction:

- `required_bounded_positive_raw_quic_is_ordered_and_redacted` and
  `required_bounded_positive_webtransport_is_ordered_and_redacted` call
  `Relay::new_required_bounded` through the common helper at
  `i2_tests.rs:898-1097`. They establish TLS 1.3 with the synthetic client
  certificate, complete the public MoQT `SERVER_SETUP`, and send an actual
  PUBLISH (`i2_tests.rs:911-985`).
- C1 completion is observed through the native admission snapshot
  (`i2_tests.rs:965-979`); non-empty I1 evidence, exactly one authenticate and
  one required scope resolution are checked independently. Legacy coordinator
  scope and tagger calls remain zero (`i2_tests.rs:965-975`).
- The authorizer blocks the base `Publish` and `RelayPeer(Publish)` calls
  separately. Before each release, reader extraction and coordinator track
  registration remain zero (`i2_tests.rs:987-1024`). Only after both releases
  does the client observe PUBLISH_OK and the independent coordinator and local
  effect probes become one (`i2_tests.rs:1026-1045`). This distinguishes gate
  ordering from counters maintained by admission itself.
- The N+1 case retains the first real authenticated root at `resolve_scope` and
  drives a second real raw or WebTransport connection through C1 and I1 to C2
  (`i2_tests.rs:1269-1327`). The client must observe exactly code `0x3` and
  `relay session capacity reached` through the public transport-specific error
  variants (`i2_tests.rs:865-887,1328-1331`). It then requires exactly one total
  authenticate/scope, zero coordinator/tagger calls, zero required application
  effects, an empty mlog directory, C1 completion for both handshakes and one
  immediate C2 capacity rejection (`i2_tests.rs:1332-1344`). Shutdown proves one
  terminal and zero active inbound sessions (`i2_tests.rs:1346-1363`).

All waits use a single monotonic absolute watchdog per case; there are no
`sleep`-based success oracles. The operation semaphores are observations made
before release, and success is corroborated by the public protocol response,
real coordinator state and controller snapshots. Capacity never produces an
authenticated context or an authorization result. Raw QUIC and WebTransport
share the same evidence/authentication/authorization code after their existing
transport-specific path acquisition.

IC-14: **PASS / CLOSED**.

## Frozen snapshot and independent reproduction

| Binding | Reproduced value |
| --- | --- |
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` — complete 488-line read |
| Owner report SHA-256 | `531aa1e13a34a9999327c0708dbf7eab15b8597a14b9d5f0d57bb6b1fca318a7` — complete read |
| HEAD / first parent | `59d9a8601885ef934cae29d89876abb7c7f73e89` |
| MERGE_HEAD / second parent | `b4ee3b68df58bbb6e7b865c2898d3f46ffbb7fd1` |
| Staged tree | `d7f0c67f4c134adc4250885f6bc031aa2efcead6`; index compared byte-for-byte with `git diff-index --cached --quiet` |
| Staged paths | `31` |
| Pathset SHA-256 | `5ca569098581750132c29f1e9b50d5bfefd52eee2f7d347811f27697109a7388` |
| Status-z SHA-256 | `b35e9c4f2ce80d4abd8b08e72fa8fa31b3370ad1517001ddf26cf11fc15fe426` |
| Unmerged / unstaged | `0 / 0` |
| Branch / tracking | `teremoq/integration-draft16-bf87128-local` / none |

All 31 staged object hashes were independently reproduced:

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

The nine-path correction from prior tree
`985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b` is exactly 782 insertions and 265
deletions in `api.rs`, `consumer.rs`, `i2_tests.rs`, `local.rs`, `producer.rs`,
`relay.rs`, `remote.rs`, `session.rs` and `upstream_namespaces.rs`. Manifests,
the lockfile and protected wire/setup files remain byte-identical; independently
reproduced anchors include:

| Protected path | SHA-256 |
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

## Validation evidence

Independent commands were read-only, offline and used local immutable images.

| Command / gate | Result |
| --- | --- |
| Preflight and final `git rev-parse`, `git diff-index --cached --quiet d7f0c67...`, path/status hashing, `git ls-files -u`, `git diff --quiet`, upstream lookup | PASS at both checkpoints: exact parents/tree/pathset/status; 31 paths; zero unmerged/unstaged; no tracking |
| `git diff --check`; `git diff --cached --check`; conflict-marker scan of staged Rust paths | PASS; no whitespace error or merge marker |
| Rust/Cargo image identity | `teremoq-local-rust193-components:c2-review-20260828`, image ID `sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`; `rustc 1.93.0`, `cargo 1.93.0` |
| `rustfmt --edition 2021 --check` on all nine corrected Rust paths in the fixed image, `--network none`, source mounted read-only | PASS |
| Full `cargo fmt --all -- --check` | `BLOCKED_BY_BASELINE_E0308`: only the two protected inherited formatting diffs at `moq-transport/src/serve/subgroup.rs:934` and `moq-transport/src/serve/tracks.rs:304`; neither path changed |
| Static extraction of all tracing/metrics calls in the eight required-reachable modules; differential sensitive-field scan against prior tree | PASS; fixed low-cardinality fields only in required reachability; no request Debug or peer error formatting |
| Gitleaks 8.30.1/MIT, exact local image `zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`, nine corrected paths, `--network none`, read-only mounts, `--redact=100` | PASS; 449,967 bytes scanned; zero findings |
| REUSE 5.1.1, exact local image `fsfe/reuse:5.1.1@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`, `--network none`, read-only source | PASS; 223/223 files; MIT and Apache-2.0; zero errors |
| C1 `sha256sum -c SHA256SUMS` | PASS for all three DER fixtures |
| I2 `sha256sum -c SHA256SUMS`; certificate-label canary presence check | PASS for all five DER fixtures; canary present without printing fixture bytes |
| C2 PEM entries plus decoded DER provenance | PASS: three PEM hashes exact; base64-decoded bytes match C1 DER hashes `ea33add...`, `053a80b...`, `1d02d7e...` |

The first direct all-entry `sha256sum -c` in the C2 directory predictably
reported the three provenance-only `.der` names absent. This is not hidden: the
file documents source hashes without duplicating DER files. The PEM entries and
their decoded bytes were then checked separately and all matched the immutable
C1 fixtures.

An independent focal Cargo execution was attempted in the fixed Rust 1.93.0
image with `--network none`, source mounted read-only and an ephemeral container
target. Cargo stopped before compilation because the remaining local read-only
registry cache lacks locked package `ahash`; network/download was prohibited.
No retry with network, installation or dependency mutation was made. Therefore
the dynamic test results below are supporting evidence from the owner report,
not misrepresented as an independent rerun:

- owner exact-snapshot complete `moq-native-ietf`: 32 library + 6 integration,
  PASS;
- owner exact-snapshot complete `moq-relay-ietf`: 175 library + 16 binary + 10
  integration + 1 doctest, 202 passed and 1 doctest ignored;
- owner exact-snapshot `required_bounded_positive_*`: both raw QUIC and
  WebTransport PASS;
- owner exact-snapshot
  `bounded_required_capacity_rejects_n_plus_one_before_authentication`: raw
  QUIC and WebTransport PASS with exact public close oracle;
- owner exact-snapshot Clippy for native and relay tests with `-D warnings`:
  PASS.

Those owner results bind to the independently reproduced staged object hashes.
This rereview did not rely on the results alone: it audited the complete
corrective diff, production call graph, test setup, synchronization, public
wire assertions and independent effect oracles line by line.

`cargo test --locked --offline -p moq-transport --lib` remains
`BLOCKED_BY_BASELINE_E0308` at the protected inherited
`moq-transport/src/serve/tracks.rs:501`. It is neither counted against this
merge nor used to approve it. The two protected rustfmt diffs have the same
classification. Their repair remains a separately authorized package.

## Residual boundaries

- This review establishes only the security acceptability of the frozen local
  source merge candidate. It does not establish production, commercial,
  publication, release, performance or full DoS readiness.
- C1 bounds pending native handshake/CONNECT work and C2 bounds admitted relay
  session roots. Neither is authentication or authorization, and neither is a
  total DoS defense.
- The upstream library still deliberately does not parse X.509/SPIFFE identity
  or implement Teremoq principal, roles or namespace policy. Those remain an
  embedder responsibility under the reviewed `SessionAuthorizer` contract.
- Fixture keys are public synthetic test material only. No operational key,
  certificate, token, principal or tenant value was printed by this review.
- No dependency/advisory/publication conclusion is added here. The inherited
  E0308/rustfmt blocker and any OSS release gate remain separate.
- The SHA-256 of this report is supplied with the handoff after the immutable
  file bytes exist; embedding its own digest would change those bytes.

## Verdict

APPROVE

This verdict is limited to considering a local merge commit of the exact frozen
snapshot above. It authorizes no push, fetch, issue, PR, tag, release,
publication, deployment, C2 follow-on change or remote mutation.

READ-ONLY SECURITY REVIEW CONFIRMED / NO COMMIT / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION
