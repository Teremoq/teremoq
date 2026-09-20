<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-PLATFORM-CHAOS review: local Q + U1 integration

Date: 2026-08-28  
Scope: read-only review of the staged Q + U1 merge in `/home/jimbomilk/moq-rs-teremoq-integration-work`  
Reviewer role: `TP-PLATFORM-CHAOS`

## Findings

No Critical, High, Medium, or Low finding is attributable to the staged Q + U1 change.

### Informational — the staged change is exactly the reviewed lock-only composition

Relative to the first parent, the index changes only `Cargo.lock`. The complete semantic delta is:

| Package | First parent | Staged Q + U1 | Other record fields |
|---|---:|---:|---|
| `quinn-proto` | `0.11.13` | `0.11.15` | Dependency list unchanged; checksum updated for the selected release |
| `bytes` | `1.6.0` | `1.11.1` | Dependency list unchanged; checksum updated for the selected release |

There are no other package record changes. In particular, `rustls 0.23.31` and its record remain unchanged. The graph resolved offline to one `quinn-proto 0.11.15` shared through `quinn 0.11.9`, `moq-native-ietf`, and `web-transport-quinn 0.11.8`, and to one `bytes 1.11.1` used by the existing QUIC, HTTP, transport, and relay graph.

The parentage is coherent: U1 commit `4547800088881cb4782c544ebfec0a1904ed1fab` has Q commit `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` as its sole parent. Q changes only the `quinn-proto` lock record from its baseline; U1 changes only the `bytes` lock record from Q.

### Informational — focal runtime compatibility passed for both existing transports

The unchanged native and relay sources compiled and passed their complete package suites with the staged lock. Real raw QUIC and WebTransport paths passed, including the two positive required/bounded composition cases and the combined N+1 case. The N+1 test retained the first admitted session and exercised both transport variants while checking rejection before authentication.

The source blobs that implement C1 handshake admission, I1 peer evidence, C2 session admission, I2 authorization, and relay lifecycle are byte-identical to the first parent. The manifests are also byte-identical. Therefore Q + U1 introduce no new admission queue, task ownership, timeout, cancellation, shutdown, ALPN, draft-16, Object, or transcoding logic.

### Informational — inherited transport compile defect remains separately blocked

`cargo test --locked --offline -p moq-transport --lib` reaches the protected pre-existing error at `moq-transport/src/serve/tracks.rs:501`: Rust E0308, expected `TrackName`, found `&str`. This is `BLOCKED_BY_BASELINE_E0308`. It is neither caused nor repaired by the lock-only Q + U1 merge and is not used as evidence for approval.

## Verdict

APPROVE

This verdict applies only to the frozen, local, staged Q + U1 lock composition identified below. It is not approval to publish, not external interoperability certification, and not a claim of production, capacity, memory, or denial-of-service readiness.

## Frozen identity and scope

The binding was checked before runtime work and again after cleanup:

| Item | Observed value |
|---|---|
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `HEAD` / first parent | `1fc0d5b7d145863c96c25560190669a4c13d026b` |
| `MERGE_HEAD` / U1 | `4547800088881cb4782c544ebfec0a1904ed1fab` |
| Q ancestor | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` |
| staged tree | `4696ae59a07ec1b3930a654e03e412221f9a8a5d` |
| staged paths | exactly one: `Cargo.lock` |
| staged path count | `1` |
| newline pathset SHA-256 | `3e503ffd2d2f0c135bc5d8c97cba5aff82676478d90cb002333ed9583b92c5a0` |
| `git status --short -z` SHA-256 | `ce44e624498f3a799669efe577d41fb1e715ff857867d6f87cc84c94cfaf54da` |
| staged/working `Cargo.lock` SHA-256 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| unmerged paths | `0` |
| unstaged paths | `0` |
| upstream tracking | none |

The staged diff has four insertions and four deletions, all in the two version/checksum records above. A direct cached diff check found no non-lock path.

Representative binding commands:

```bash
sha256sum /home/jimbomilk/teremoq/.cursorrules
git rev-parse HEAD MERGE_HEAD
git write-tree
git diff --cached --name-only
git diff --cached --name-only | sha256sum
git status --short -z | sha256sum
sha256sum Cargo.lock
git diff --name-only --diff-filter=U
git diff --name-only
git merge-base --is-ancestor \
  1e9d1ee62bde97145a0914e5992ab7f54fc909c4 \
  4547800088881cb4782c544ebfec0a1904ed1fab
git show -s --format='%P' MERGE_HEAD
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
```

All observed values matched the frozen binding. The upstream query had no configured result, as required.

## Static compatibility audit

The staged and first-parent blob IDs match for the relevant implementation surfaces:

| Surface | Blob ID in both trees |
|---|---|
| `moq-native-ietf/src/quic.rs` | `53d15423e0cea877377caf0ae589841845419823` |
| `moq-relay-ietf/src/relay.rs` | `9edd2f01ae974d703899bcf5cf9b690e21dcd960` |
| `moq-relay-ietf/src/session_admission.rs` | `ffee7e615c4ee30d8bb5660832815665845934cb` |
| `moq-relay-ietf/src/i2_tests.rs` | `5335a27792f01f2419d0d162679cd9789453e4e1` |

The root, native, relay, and transport manifests are unchanged, with SHA-256 values `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f`, `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e`, `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11`, and `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743`, respectively. Inspection also confirmed that the native endpoint still advertises/configures the existing WebTransport ALPN and MoQT `moqt-16` ALPN. No draft-16 message, session, setup, Object, namespace, identity, authorization, or media byte path changed.

Consequently:

- C1 and C2 remain separate admission layers with their existing immediate, non-waiting capacity decisions and RAII ownership.
- I1 connection-bound evidence and I2 authorization/lifecycle ordering remain source-identical.
- Existing cancellation, deadline, recovery, and shutdown behavior is not rewritten by Q + U1.
- Encoded Objects are neither decoded nor transformed by this delta; Zero-Transcoding compatibility here means absence of a changed byte path, not a new end-to-end media proof.

## Tooling and execution isolation

All Cargo execution used the pre-existing local image:

```text
teremoq-local-rust193-components:c2-review-20260828
sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007
```

Observed tools were Rust `1.93.0`, Cargo `1.93.0`, rustfmt `1.8.0`, and Clippy `0.1.93`. Containers ran with `--network none`, the source mounted read-only at `/src`, registry/git caches mounted read-only, and the build target on the dedicated external Docker volume `teremoq-integration-q-u1-platform-review-target-20260828`. Commands used `--locked --offline`; no download or installation occurred. Relevant test groups ran under a 600-second outer watchdog.

## Commands and results

The following Cargo commands were executed inside that isolated environment:

| Command | Result |
|---|---|
| `cargo metadata --locked --offline --format-version 1 --no-deps` | PASS; staged lock resolves offline |
| `cargo tree --locked --offline -i quinn-proto@0.11.15` | PASS; one selected version on native/WebTransport paths |
| `cargo tree --locked --offline -i bytes@1.11.1` | PASS; one selected version across the existing graph |
| `cargo tree --locked --offline -i rustls@0.23.31` | PASS; retained selection confirmed |
| `cargo check --locked --offline -p moq-native-ietf --tests` | PASS |
| `cargo check --locked --offline -p moq-relay-ietf --tests` | PASS |
| `cargo clippy --locked --offline --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 38 passed, 0 failed (`32` library + `6` integration) |
| `cargo test --locked --offline -p moq-relay-ietf` | PASS: 202 passed, 0 failed, 1 ignored (`175` library + `16` binary + `10` integration + `1` executed doctest) |
| `cargo test --locked --offline -p moq-native-ietf --test peer_evidence` | PASS: 6/6 I1 integration tests |
| `cargo test --locked --offline -p moq-native-ietf c1_` | PASS: 25/25 C1 tests |
| `cargo test --locked --offline -p moq-relay-ietf i2_` | PASS: 25/25 I2-filtered tests |
| `cargo test --locked --offline -p moq-relay-ietf c2_` | PASS: 38/38 C2 tests across library and integration targets |
| `cargo test --locked --offline -p moq-relay-ietf required_bounded_positive_` | PASS: 2/2 composed positive cases, raw QUIC and WebTransport |
| `cargo test --locked --offline -p moq-relay-ietf bounded_required_capacity_rejects_n_plus_one_before_authentication` | PASS: 1/1 combined N+1 test; both transports exercised internally |
| `cargo test --locked --offline -p moq-transport --lib` | `BLOCKED_BY_BASELINE_E0308` at `src/serve/tracks.rs:501`; no Q/U1-attributable diagnostic |

The complete package suites subsume the focal runs; their counts must not be added together as unique-test totals.

## Runtime and lifecycle assessment

- **QUIC and WebTransport:** both real upstream-backed paths completed with the upgraded lock graph. No arbitrary UDP stand-in was used.
- **ALPN and draft-16:** the unchanged `moqt-16` and WebTransport ALPN configuration compiled and its composed tests passed.
- **Objects and Zero-Transcoding:** wire constants/Object-type regression coverage passed through the I2 group; the lock-only delta cannot add transcoding. This is not a media payload certification.
- **C1/I1/C2/I2:** focal groups passed with unchanged implementation blobs. The combined N+1 regression retained the admitted connection and observed overload on raw QUIC and WebTransport before authentication.
- **Lifecycle:** existing bounded admission recovery, cancellation, shutdown, and ownership tests passed in the C1/C2 groups. No source or test was added that could detach a new task or reset a deadline.
- **Determinism and residue:** the relevant existing tests use their established deterministic barriers/watchdogs; the outer run was also time-bounded. No host port was published, no source-tree `target` directory was created, and no test source/file residue was found.

## Cleanup

All review containers used `--rm` and were absent after execution. The dedicated target volume existed before cleanup and was removed successfully. Final checks found:

- zero review containers;
- zero `teremoq-integration-q-u1-platform-review-target-20260828` volumes;
- no `/home/jimbomilk/moq-rs-teremoq-integration-work/target` path;
- unchanged staged tree, pathset, status hash, parents, lock hash, unmerged count, unstaged count, and tracking state.

## Limitations

- Offline local tests do not establish interoperability with external implementations, browsers, networks, or deployment environments.
- A lock-only merge plus package regressions does not establish production capacity, sustained-memory bounds, flood/DoS resistance, or service SLOs.
- The protected E0308 prevents treating a full `moq-transport --lib` run as green; it remains a separately owned baseline blocker.
- The review did not run Chaos, load, soak, packet-loss, or cross-host testing because this frozen task authorizes a read-only Q + U1 compatibility review and forbids network access.
- Passing unchanged Object/wire regressions and proving no transcoding source delta do not replace an end-to-end encoded-media Zero-Transcoding audit.
