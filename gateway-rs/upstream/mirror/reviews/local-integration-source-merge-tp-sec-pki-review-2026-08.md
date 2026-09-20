<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# TP-SEC-PKI review of the staged I1/I2 + C1/C2 source merge

Date: 2026-08-28

Role: TP-SEC-PKI

Review mode: independent, read-only security composition review

Source: /home/jimbomilk/moq-rs-teremoq-integration-work

Authorization boundary: NO COMMIT / NO MERGE COMPLETION / NO ABORT / NO FETCH /
NO PUSH / NO PUBLICATION / NO REMOTE MUTATION

## Findings

### HIGH — IC-12 fails: required sessions disclose exact resource names in tracing and mlog

The composed required path is not fully redacted. Authentication and
authorization denial messages are constant, but a successfully authorized
session reaches shared Producer, Consumer and RemoteManager code that writes
the exact namespace, prefix, track and remote URL to tracing:

- moq-relay-ietf/src/consumer.rs:172-187 logs the exact namespace after the
  PUBLISH_NAMESPACE gate; lines 192, 205, 208, 226 and 239 repeat it around
  local/coordinator registration and the positive response.
- moq-relay-ietf/src/consumer.rs:412-423 logs the exact namespace and track
  after the PUBLISH gate.
- moq-relay-ietf/src/producer.rs:222-233 logs the exact namespace and track
  after the SUBSCRIBE gate.
- moq-relay-ietf/src/producer.rs:371-384 logs the exact namespace prefix after
  the SUBSCRIBE_NAMESPACE gate.
- moq-relay-ietf/src/producer.rs:769-783 logs the exact namespace, track and
  complete request Debug representation after the TRACK_STATUS gate.
- moq-relay-ietf/src/remote.rs:1949-2023 logs the exact remote URL, namespace
  and track through the C2-owned Remote lifecycle; lines 2073 and 2098 log an
  exact prefix or namespace during relay forwarding.

These paths are reachable from required mode: relay.rs:2078-2158 constructs
the required Producer/Consumer with the authenticated RequiredAuthorization,
and the authorized forwarding path uses the same RemoteManager. Therefore this
is not confined to legacy observability.

The configured mlog path has the same problem. Required bounded mode derives a
path at relay.rs:1944 and passes it to PendingSession::finish at
relay.rs:1985. The protected transport implementation deliberately omits
CLIENT_SETUP from required-mode mlog, but retains the writer for the session
(moq-transport/src/session/mod.rs:173-248). It serializes subsequent
SUBSCRIBE and PUBLISH_NAMESPACE messages at session/mod.rs:839-870.
mlog/events.rs:239-257 stores track_namespace and track_name;
events.rs:291-327 stores track_namespace; events.rs:330-367 stores the
namespace prefix; and events.rs:369-410 stores NAMESPACE/NAMESPACE_DONE
suffixes. A successful required session can consequently persist the tenant
resource canary even if tracing is corrected.

This contradicts the binding readiness invariant IC-12 and the present
instruction to reject DER/identity/namespace disclosure in logs, errors and
metrics. Namespace and prefix values are authorization resources and may carry
business-sensitive tenant/topology names. Authorization makes the operation
permissible; it does not grant permission to copy the resource identifier into
diagnostics.

Required, independently testable correction for Task 05:

1. Remove raw namespace, prefix, track, connection path and full remote URL
   fields from tracing reachable by required sessions. Use only fixed,
   low-cardinality operation/stage/source classifications. Do not include
   request Debug or peer-derived error formatting.
2. Until a separately reviewed redacted mlog mode exists, required mode must
   pass no mlog writer for post-authentication traffic, or otherwise prove that
   every emitted event omits resource fields. Legacy observability may remain
   explicitly separate.
3. Add raw-QUIC and WebTransport tests with unique canaries in authenticated
   context, path, namespace and prefix. Capture tracing and inspect the
   isolated mlog directory; none of those canaries, type names or certificate
   material may occur. Metrics must retain only fixed labels.

No DER, PEM, certificate chain, principal or role was observed in the four
resolved files, and capacity labels remain low-cardinality. Those narrower
properties do not close this finding.

### HIGH — the mandatory positive raw/WT composition proof is absent, and the combined N+1 oracle is incomplete

The new tests prove two useful negative orderings but do not prove the complete
composed success chain required by the readiness gate:

- bounded_required_composition_orders_c1_i1_c2_before_i2_denial at
  moq-relay-ietf/src/i2_tests.rs:788-856 uses
  RecordingAuthorizer::new. That constructor sets authentication_rejected to
  true at lines 327-340, so the test ends at authenticate. It cannot prove
  canonical path, resolve_scope, SERVER_SETUP, SessionContext or any exact
  operation gate under C1+C2.
- bounded_required_capacity_rejects_n_plus_one_before_authentication at
  i2_tests.rs:903-1003 admits the first connection and deliberately blocks it
  in resolve_scope. The N+1 assertion at lines 960-979 proves only that setup
  returned an error and that authenticate remained at one call. It does not
  assert the public close code 0x3 and constant reason, does not attach the
  RequiredEffectProbe or an isolated mlog directory, and never proves a
  successful composed SERVER_SETUP or operation.
- authenticated_context_and_exact_path_gate_raw_quic_and_webtransport starts
  at i2_tests.rs:1007, but it uses Relay::new_required rather than
  Relay::new_required_bounded.
- The operation tests use start_required_session at i2_tests.rs:583-671,
  which constructs RequiredAuthorization directly after a separate legacy
  Session::accept_with_config. They are strong I2 unit-composition tests, but
  they do not traverse C1 admission, I1 evidence or C2 admission.

The owner reports all of these tests passing. Their pass result is credible but
does not establish the missing proposition. Split I1/I2/C1/C2 suites cannot
detect a merge-resolution bypass between the four gates.

Required, independently testable correction for Task 05:

1. Add one real raw-QUIC test and one real WebTransport test through
   Relay::new_required_bounded using the synthetic client certificate.
2. In each, prove one C1 admission, connection-bound I1 evidence, exactly one
   successful authenticate, the exact canonical requested path, successful
   resolve_scope, SERVER_SETUP completion, and one exact namespace operation
   authorization before an independent state/effect probe. Prove zero
   ConnectionTagger and legacy Coordinator scope calls.
3. Add a relay-peer variant or an equally discriminating composed assertion
   that the base operation and RelayPeer second gate both precede the first
   effect.
4. Strengthen the combined N+1 test to assert public code 0x3 and the constant
   reason, zero second authenticate, zero required effect probes, zero mlog and
   zero relay application state. Keep raw and WebTransport as separate
   discriminating cases under one absolute watchdog.
5. Capture the redaction canaries from the first finding in the same composed
   harness. Do not use sleeps or counters from the admission code as the only
   effect oracle.

## Snapshot binding and merge isolation

All binding values were recomputed before and after the static review with
GIT_OPTIONAL_LOCKS=0:

| Binding | Independently reproduced value |
| --- | --- |
| Branch | teremoq/integration-draft16-bf87128-local; no upstream |
| HEAD | 59d9a8601885ef934cae29d89876abb7c7f73e89 |
| MERGE_HEAD | b4ee3b68df58bbb6e7b865c2898d3f46ffbb7fd1 |
| Merge base | bf87128affd316463e5dcc7599a45001f222b6de |
| HEAD tree | d108208bfb5792767881a932480da01769844148 |
| Expected staged tree | 985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b |
| Index versus expected tree | exact; git diff-index --cached --quiet passed |
| Staged paths | exactly 26 |
| Newline path-set SHA-256 | c16063d311bc42b1baf16f314d11e3604cecc640be6542af826b09be20023470 |
| Porcelain-v1 status-z SHA-256 | 085eec09a457ee974eb9a7260c278516631ca4d7941262f197e675b87506933a |
| Unmerged entries | zero |
| Unstaged changes | zero |
| Cached whitespace check | PASS |

The expected staged tree already existed as a Git object. I compared the index
to it without invoking write-tree or any operation that could create or
replace an object.

I1 commit 05b41127ecbd48de4c59fe1626c43b1e423c33a9 is an ancestor of
HEAD/I2. C1 commit ee22a1079783e374371e0705775978790ddd6471 is an
ancestor of MERGE_HEAD/C2. The 22 non-resolution paths are byte-identical to
MERGE_HEAD. Index and worktree blob IDs are identical for all four resolutions.

### Requested input/review hashes

| Input | SHA-256 |
| --- | --- |
| .cursorrules | 88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2 |
| TP-SEC-PKI readiness | e6807e5a64267fc01b7f5b9ceeee2d6f18bc922ed9ecdd100d740131aa5a06c6 |
| TP-PLATFORM-CHAOS readiness | 2bc3b73be58c01eb1831ea583c4fe6043c0bc0c6a30ace46fa9f3e842c816083 |
| TP-OSS-SC readiness | 7abcd8739c599aef8e2559cb0fd3375d93a6f5cea4102f30128a436e7785a92f |
| Source-merge owner report | 9c4c4c5bee4debaffda8aea10ef5653db9d29f6987119d83c83a02f9b22c21a7 |
| Final I1 TP-SEC-PKI review | 142860f7cdc408095e806acbf41bd2e32b2137307f44425d6e25e6ab8b1583ee |
| Final I2 TP-SEC-PKI review | 73170aa2a26d048067acdd189e09fec590e226e7e5c1432569d9439873ac0a61 |
| Final C1 TP-SEC-PKI review | d613817d9ea2da9b7698caf8b934512515c3a6ca0ca76d77d8d2faa223d12d1e |
| Final C2 TP-SEC-PKI review | d4a27e0333528b4f238875aed0e8423fa06c5dd425eef9f1944b8674cdcf96f9 |

### Exact staged path hashes

| Path | SHA-256 |
| --- | --- |
| moq-native-ietf/src/quic.rs | 92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d |
| moq-native-ietf/src/quic_c1_tests.rs | 610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9 |
| moq-native-ietf/tests/data/c1/README.md | 717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10 |
| moq-native-ietf/tests/data/c1/SHA256SUMS | ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64 |
| moq-native-ietf/tests/data/c1/ca.cert.der | ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b |
| moq-native-ietf/tests/data/c1/ca.cert.der.license | 5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0 |
| moq-native-ietf/tests/data/c1/server.cert.der | 053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc |
| moq-native-ietf/tests/data/c1/server.cert.der.license | 5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0 |
| moq-native-ietf/tests/data/c1/server.key.der | 1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436 |
| moq-native-ietf/tests/data/c1/server.key.der.license | 5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0 |
| moq-relay-ietf/src/i2_tests.rs | 0917f6715ffba69c4b681679f17eeadffb46453b215fcff33e4e64c4d953e571 |
| moq-relay-ietf/src/lib.rs | 833b732c738650c0ed6297c7094bdb8309da5953b9c51f950f58f1079f68b03c |
| moq-relay-ietf/src/relay.rs | 062bc828c7494e672cf8dbcd850e6b2a045792c2cf24256f702fccfdcf47d733 |
| moq-relay-ietf/src/relay_c2_tests.rs | 5ebccdf289a5b4183b28e78ee56dfad7f991a2c4c58eda27327c5e88f8033237 |
| moq-relay-ietf/src/remote.rs | 5a5a30536280fe946db0df969b1ae81099186838ec69904128a15e0ff15cf8a4 |
| moq-relay-ietf/src/session_admission.rs | cc5c56db172f7fb13e1f5a1a8bea3957c096d869dd97ac3f9d9f753820f0c7ef |
| moq-relay-ietf/src/upstream_namespaces.rs | 7033823b66d5e3e82c0e6afdf2e4062080b908ed11c0aedb4550bd2f7cd775b9 |
| moq-relay-ietf/tests/c2_session_admission.rs | 1b528da9ccd852d81085bad190e01ae9a5a84ca6724574ed6a7cd2904e7e0a0a |
| moq-relay-ietf/tests/data/c2/README.md | 285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72 |
| moq-relay-ietf/tests/data/c2/SHA256SUMS | ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd |
| moq-relay-ietf/tests/data/c2/ca.cert.pem | c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb |
| moq-relay-ietf/tests/data/c2/ca.cert.pem.license | 5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0 |
| moq-relay-ietf/tests/data/c2/server.cert.pem | 76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09 |
| moq-relay-ietf/tests/data/c2/server.cert.pem.license | 5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0 |
| moq-relay-ietf/tests/data/c2/server.key.pem | 607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35 |
| moq-relay-ietf/tests/data/c2/server.key.pem.license | 5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0 |

### Protected, unchanged inputs

| Path | SHA-256 |
| --- | --- |
| Cargo.toml | 6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f |
| Cargo.lock | 13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80 |
| moq-native-ietf/Cargo.toml | 3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e |
| moq-relay-ietf/Cargo.toml | 83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11 |
| moq-transport/Cargo.toml | 78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743 |
| moq-transport/src/session/mod.rs | 5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00 |
| moq-transport/src/setup/mod.rs | c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750 |
| moq-transport/src/setup/version.rs | 384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad |
| moq-transport/src/message/mod.rs | e5760f5ce2927b2437511b3e616fea2615d82e916d4b6036b7f5450ae0973352 |
| moq-transport/src/serve/tracks.rs | a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7 |
| REUSE.toml | afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc |
| LICENSES/Apache-2.0.txt | 1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e |
| LICENSES/MIT.txt | c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057 |

## Audit of the four resolutions

### moq-native-ietf/src/quic.rs

PASS for composition ordering. HandshakeAdmission::try_admit uses one immediate
try_acquire_owned at quic.rs:245-253. PeerEvidenceServer obtains Incoming,
acquires C1 and only then starts accept_session_bounded_mode at
quic.rs:1430-1467. Saturation uses Refuse/Retry without a waiter or crypto.

EstablishedConnection completes QUIC/TLS and WebTransport CONNECT first
(quic.rs:1023-1150). accept_session then calls peer_identity on a clone of that
same established quinn::Connection at lines 1154-1179. No IP, SNI, CID, map,
task-local or tagger supplies evidence. LegacyEvidenceMode never invokes the
extractor. Evidence conversion failure yields no AcceptedSession.

The C1 guard releases its permit before publishing terminal Release counters
at quic.rs:284-320. It contains no callback/logging. The final resolution adds
only the read-only shares_capacity_with and handshake_admission handles needed
to prove shared relay-global C1 capacity.

### moq-relay-ietf/src/relay.rs

PASS for admission/auth ordering. new_required_bounded validates explicit
C1-bounded endpoints and pointer-identical shared HandshakeAdmission at
relay.rs:478-531. It rejects implicit bind, missing/unbounded endpoints and
per-endpoint controllers.

The bounded accept loop receives the I1 result, then performs immediate C2
admission at relay.rs:1469-1526 before metrics, root/task construction,
authenticate, MoQT setup, Coordinator, tagger or namespace state. A slot never
becomes identity. Required session execution consumes only the evidence from
the AcceptedSession, borrows it for authenticate, drops it, and stores only the
opaque context at relay.rs:1877-1933.

Required order is:

1. C1 bounded native acceptance and I1 evidence;
2. C2 try_admit and owned session root;
3. authenticate and evidence drop;
4. PendingSession decode and canonical path;
5. required resolve_scope;
6. PendingSession::finish and SERVER_SETUP;
7. SessionContext and required Producer/Consumer.

The exact implementation is relay.rs:1506-1553 and 1877-2158. Missing,
unexpected, authenticate-denied, missing-path and scope-denied paths return
fixed closes before finish and never call connection_tagger or legacy
Coordinator scope resolution.

Required SessionContext comes only from AuthenticatedSession. IP, SNI,
ConnInfo, ConnectionMeta, connection path and ConnectionTagger are confined to
the explicit legacy branch at relay.rs:2061-2075. Required RelayPeer
classification and its second operation gate remain in authorization.rs, whose
approved hashes are unchanged:

- authorization.rs:
  101fc1a0a8c1fc8d61453f43617cbfef1913a7db91767f29c9e59b9970d148c2;
- consumer.rs:
  06f601e1f4efdb3c7f4bca99114d275db0abcdca436fece01c352f3fb13a256d;
- producer.rs:
  8b9c723341ad93c77f94a57fc833323c695d45078edd541c0a42a80ea51e966e.

C2 inbound/outbound semaphores close at relay.rs:1591-1597 before cancellation
and drain. Dropping accepts at line 1595 drops the C1 Server accept roots and
any handshake guards before cancellation. One timeout_at over one absolute
deadline covers the owned drain at relay.rs:1579-1695. Return checks require
zero active/inflight gauges and full capacity.

### moq-relay-ietf/src/i2_tests.rs

The resolution preserves all prior I2 tests and adds exactly three combined
tests at lines 788-1003. The negative authentication and N+1 tests use real
raw QUIC and WebTransport and the constructor test distinguishes shared from
split C1 controllers. Their limits are stated in the second finding; no test
was mistaken for a stronger oracle than it is.

### moq-relay-ietf/src/lib.rs

The resolution exports both the existing authorization surface and the C2
session-admission surface. It adds no dependency, feature, wire type, provider
or implicit default. Legacy constructors remain explicit and
new_required_bounded has no fallback to them.

## IC-01 through IC-14 matrix

| Invariant | Result | Security conclusion |
| --- | --- | --- |
| IC-01 same-connection evidence | PASS | peer_identity is queried only after handshake/CONNECT from the same EstablishedConnection clone; failure exposes no session. |
| IC-02 C1 before expensive work, never identity | PASS | One immediate try_acquire_owned precedes QUIC/TLS/WT; guard RAII and constant Refuse/Retry remain independent of auth. |
| IC-03 C2 before auth/state | PASS | C2 admission is after I1 acceptance and before authenticate, setup, metrics and session root effects. |
| IC-04 borrowed evidence/minimal context | PASS | authenticate receives a borrow; evidence is dropped before RequiredAuthorization; upstream retains only opaque context. |
| IC-05 path is resource, not identity | PASS | PendingSession supplies canonical raw/CONNECT path only to required resolve_scope; no transport metadata contributes to principal. |
| IC-06 required fail-closed before SERVER_SETUP | PASS | Absent/type/auth/path/scope failure returns before finish, mlog creation and application state; no legacy fallback. |
| IC-07 exact operation gates before effects | PASS | Approved I2 source hashes preserve gates for publish, subscribe, namespace discovery/status and forwarding before their first effect. |
| IC-08 RelayPeer only from auth context | PASS | AuthenticatedSession marks RelayPeer explicitly and RequiredAuthorization applies the base and second gate. |
| IC-09 capacity/auth/authz separation | PASS | C1/C2 inputs and labels contain no identity; capacity does not call policy and auth errors do not increment capacity rejection. |
| IC-10 close before cancel/drain | PASS | Both C2 controllers close, C1 accept roots are dropped, then cancellation/drain uses one deadline and verifies zero gauges. |
| IC-11 concurrency/lifetimes | PASS | Per-session owned evidence/context/permit flow has no global or task-local identity; reviewed C1/C2 RAII generations remain exact. |
| IC-12 complete redaction | FAIL | Exact namespace/prefix/track/URL are emitted by required tracing and mlog; see HIGH finding 1. |
| IC-13 explicit legacy/no required fallback | PASS | Legacy APIs remain source-compatible; required bounded validates prerequisites and every mismatch fails closed. |
| IC-14 same raw/WT trust contract | FAIL | Static routing is shared, but the mandatory positive composed raw/WT proof and discriminating N+1 close oracle are absent; see HIGH finding 2. |

No capacity limit, permit, IP, SNI, path, ConnectionTagger or endpoint tag is
used as authentication or authorization. T, an X.509 parser, SPIFFE policy,
Teremoq ACLs and custom cryptography remain outside this source merge.

## Test and validation matrix

No large build was started. The owner explicitly removed its external target,
and the current instruction permits only focal offline work with local
artifacts. Therefore owner cargo results below are supporting evidence, not
represented as independent executions.

| Gate | Result | Evidence |
| --- | --- | --- |
| Git binding, staged tree, path-set/status hashes | PASS independent | Exact values above; zero unmerged/unstaged. |
| Parent preservation | PASS independent | 22 non-resolution paths exact to MERGE_HEAD; four index/worktree blobs exact. |
| git diff --check and cached check | PASS independent | No whitespace errors. |
| Rust 1.93 focal rustfmt on four resolutions | PASS independent | Local immutable image ID sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007; read-only source, no network. |
| Gitleaks 8.30.1 on four resolutions | PASS independent | Zero findings; image ID sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f. |
| Broad relay source Gitleaks | PASS with documented scanner false positive | One unchanged match at tls.rs:115 is the literal PKCS#8 PEM parser delimiter, not key material; tls.rs is byte-identical to both parents. No suppression was used. |
| C1/C2 fixture hashes and provenance | PASS independent | PEM decode hashes reproduce the C1 DER hashes; README/sidecars mark the key public synthetic test-only material. No PEM/key content was printed. |
| Owner full moq-native-ietf suite | PASS supporting | 32 library + 6 I1 integration tests, zero failures. |
| Owner full moq-relay-ietf suite | PASS supporting | 173 library + 16 binary + 10 C2 integration + doctest; 200 executed, zero failures. |
| Owner C1 focal suite | PASS supporting | 25 tests. |
| Owner I1 peer_evidence suite | PASS supporting | 6 tests. |
| Owner I2 focal suite | PASS supporting | 23 tests. |
| Owner C2 focal suites | PASS supporting | 28 library + 10 public integration tests. |
| Owner Clippy and complete rustfmt | PASS supporting | Rust/Cargo 1.93.0, offline, locked, no-deps Clippy with -D warnings. |
| Combined authentication denial, raw and WT | PASS for its stated negative proposition | One authenticate; zero scope/coordinator/app effects; C1/C2 recovery. |
| Combined N+1, raw and WT | FAIL formal composition criterion | Test passes but does not assert exact public close reason/code, required effect/mlog zero, or a successful composed session. |
| Positive cert-to-operation composition, raw and WT | FAIL / ABSENT | Existing success tests bypass either C1/C2 or I1 evidence. |
| Dynamic tracing/mlog canary redaction | FAIL / ABSENT | Static inspection proves exact namespace/prefix persistence. |
| REUSE and staged fixture licensing | PASS supporting/independent hashes | Owner reports 223/223 compliant; staged sidecars and license hashes reproduced. |

## Inherited baseline blocker and scope boundaries

WR-03 remains exactly BLOCKED_BY_BASELINE_E0308 at the unchanged
moq-transport/src/serve/tracks.rs:501
(SHA-256 a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7).
It is neither corrected nor hidden by this review. It remains a separate
blocker for full product integration/Objects validation even after the two
source-merge findings above are corrected.

This review covers only the staged I1/I2 + C1/C2 source merge. It does not
approve Q/U1 application, product pinning, package/release, advisories,
deployment or publication. T remains an unapproved and separate cryptographic
decision. Revocation, CRL/OCSP, SPIRE, production PKI and Teremoq principal/
role/policy parsing remain outside upstream and outside this verdict.

## Commands and evidence boundary

Independent read-only commands included:

- git rev-parse HEAD, MERGE_HEAD and tree objects;
- git merge-base and ancestry checks;
- git diff-index --cached --quiet against the expected staged tree;
- git status --porcelain=v1 -z, git diff --cached --name-only, git ls-files -u,
  git diff --quiet and both diff checks;
- sha256sum over all 26 staged paths, protected inputs and review inputs;
- full static read of the staged diff and all composition/security call sites;
- read-only Rust 1.93 rustfmt --check for the four resolutions;
- read-only, no-network Gitleaks 8.30.1 focal scans;
- OpenSSL certificate DER conversion and non-printing key-container decode
  hashes for public synthetic fixture provenance.

No cargo build/test, dependency resolution, install, network access, source or
index write, Git object creation, merge mutation, commit, abort, fetch, push or
remote operation was performed. The only filesystem mutation made by this
review is this new report outside the reviewed worktree.

The SHA-256 of this report is supplied in the handoff after the file is closed;
embedding its own digest would make the digest circular.

## Verdict

CHANGES REQUIRED
