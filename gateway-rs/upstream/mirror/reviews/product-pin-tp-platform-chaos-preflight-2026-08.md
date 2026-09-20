<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-PLATFORM-CHAOS preflight: gateway-rs local derivative pin

Date: 2026-08-28  
Scope: independent local compatibility preflight; no product edit, integration, commit, publication, or remote mutation  
Product lab: `/home/jimbomilk/teremoq-gateway-pin-platform-lab`

## Findings

### High — the candidate is source-compatible, but gateway-rs does not activate I1/I2/C1/C2

The direct path substitution compiles and all current product tests pass, but no product source, example, or test references the candidate's new peer-evidence, required-authorization, handshake-admission, or relay-session-admission APIs.

The private relay laboratory still uses the legacy builder and lifecycle:

- `examples/dev_mtls_moq_relay.rs` calls `build_with_cache_idle_timeout(...)` and then `relay.run()`;
- its emitted contract explicitly states `handshake_deadline_enforced=false`, `handshake_capacity_enforced=false`, and `session_capacity_enforced=false`;
- it still emits `federation_capacity_unenforced` with `upstream_api_missing`.

The candidate exposes the missing seams, including `HandshakeAdmission`, `ServerAdmissionConfig`, `Server::new_bounded_with_admission`, `Server::with_peer_evidence`, `RelaySessionLimits`, `RelayConfig::build_required_bounded`, session monitors, and `Relay::run_until`. Merely changing the three Cargo pins would retain the legacy behavior and would not close ADR-0005 or ADR-0006.

Required owner action for `TP-RUST-DIST` before a real pin can be accepted:

1. define validated fail-closed product configuration for independent C1 handshake and C2 inbound/outbound session limits;
2. construct bounded native server admission before accept and use a shared controller where multiple endpoints belong to one relay capacity domain;
3. select connection-bound peer evidence and required authorization before scope, Producer, Consumer, coordinator, namespace, or task state;
4. build the relay in required+bounded mode, propagate one absolute shutdown deadline through `run_until`, and expose low-cardinality monitors;
5. keep the 4433 browser laboratory and 4443 private laboratory roles explicit; do not infer SPIFFE authorization from path, IP, SNI, or certificate validity alone;
6. add product-level N/N+1, cancellation, recovery, zero-effect rejection, raw/WebTransport, shutdown, and gauge-zero tests before changing the existing warning fields.

This is a product integration gap, not an API incompatibility in the derivative.

### Medium — product tests exercise WebTransport but not the raw-QUIC product route

All current gateway transport integration URLs in `tests/mtls_quic.rs`, `tests/federation_concurrency.rs`, and `tests/moq_relay_interop.rs` use `https://`; they therefore exercise WebTransport. The product configuration accepts `moqt://`, but the gateway suite has no product-level raw-QUIC integration case.

Supplemental candidate tests passed for both raw QUIC and WebTransport, draft-16/raw ALPN, required+bounded positive setup, and exact N+1 rejection. Those tests ran under the derivative's own lock. They do not replace a product test under the gateway lock, whose effective transport graph is newer:

| Component | Gateway candidate lock | Derivative self-test lock |
|---|---:|---:|
| `quinn` | `0.11.11` | `0.11.9` |
| `quinn-proto` | `0.11.17` | `0.11.15` |
| `web-transport-quinn` | `0.11.12` | `0.11.8` |
| `web-transport` | `0.10.9` | `0.10.4` |
| `rustls` | `0.23.43` | `0.23.31` |

The candidate source compiled and the gateway WebTransport matrix passed with the gateway versions, so no type/API incompatibility is observed. `TP-RUST-DIST` must nevertheless add a product-owned `moqt://` case and exercise the new required/bounded paths under the effective gateway lock.

### Medium — the local path result is not a consumable published pin

The tested candidate is local commit `89cb1798644c32aef06cc625f097cd9acb203417`. This preflight neither verifies that an immutable remote ref currently exposes it nor authorizes publication. A real atomic Git pin remains contingent on the separate reviewed publication/governance gate. The local source was fully available, so this preflight itself was not blocked by unpublished source.

### Informational — existing compatibility gates are green

The path-resolved product passed full formatting, check, tests, Clippy, examples, mTLS, scheduler capacity, federation isolation, media/CMAF, Object draining, draft-16/WebTransport, lifecycle, and Zero-Transcoding topology checks. No current product API required adaptation merely to compile against the candidate.

## State

OWNER_CHANGES_REQUIRED

The state is driven by the missing product integration of the new required/bounded APIs and raw-QUIC product coverage. It is not a claim that the candidate source is incompatible.

## Frozen inputs

| Input | Observed binding |
|---|---|
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| product `Cargo.toml` SHA-256 | `1caa40574d12ebb4aa9cd03cc30d32f75edd8e9572e6d4876238f491c6e3f3de` |
| product `Cargo.lock` SHA-256 | `dd6ee5615630d788a351c4e3b395de0851fee41b34177823393d35d23a894316` |
| derivative commit | `89cb1798644c32aef06cc625f097cd9acb203417` |
| derivative tree | `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5` |
| derivative `Cargo.lock` SHA-256 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| derivative status | clean; empty status SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

The applicable ADRs were read completely: ADR-0001 through ADR-0007. Their constraints on external interoperability, Zero-Transcoding, mTLS versus authorization, bounded admission, controlled derivative provenance, and non-productive claims are retained.

## Lab construction and resolution

The lab did not exist and was created once by copying the `gateway-rs` snapshot with `target`, caches, and `.teremoq-dev` runtime state excluded. Before substitution, its manifest and lock hashes exactly matched product.

Only three direct declarations in the lab `Cargo.toml` were changed from the baseline Git revision to absolute local paths:

- `moq-native-ietf`;
- `moq-transport`;
- dev-dependency `moq-relay-ietf`.

The relay manifest selects sibling `moq-api` transitively. `cargo tree --locked --offline` confirmed all four packages originate from `/home/jimbomilk/moq-rs-teremoq-integration-work`; there is one selected `moq-native-ietf`, `moq-transport`, and `moq-relay-ietf` in the product graph.

The generated lab artifacts are:

| Artifact | SHA-256 |
|---|---|
| lab `Cargo.toml` | `f44fafb4d4c9101c67440af73780e07076c9a50bba4ea6ad0d9e7b4b5a759384` |
| lab `Cargo.lock` | `857889695a109c4315a3f1ea42ab530a3bd6b39e7d6920299c825579c60e4f9b` |

Relative to the product lock, the lab lock removes only the Git `source` fields for `moq-api`, `moq-native-ietf`, `moq-relay-ietf`, and `moq-transport`; it has zero insertions and four deletions. Two independent offline `cargo generate-lockfile` executions produced the same lab lock SHA, and a subsequent `cargo metadata --locked --offline` passed.

No copied product source differs from the original except the lab `Cargo.toml` and `Cargo.lock`. Two independent review reports appeared in the product review directory after the lab snapshot was taken; their absence from the earlier lab copy is not a source delta.

## Hermetic tooling

Build/test execution used:

```text
teremoq-step7-lab:rust-1.93-full
sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b
Rust/Cargo 1.93.0
GStreamer 1.22.0
```

Formatting/Clippy and candidate focal execution used:

```text
teremoq-local-rust193-components:c2-review-20260828
sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007
rustfmt 1.8.0
Clippy 0.1.93
```

Every container used `--network none`, an explicit installed toolchain via `RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu`, read-only lab/derivative source during gates, read-only pre-existing Cargo caches, and an external `CARGO_TARGET_DIR`. All long commands had an outer watchdog. No tool or dependency was downloaded or installed.

Setup-only failures were kept separate from product results:

- a rustup channel-sync attempt was denied by `--network none`; fixing `RUSTUP_TOOLCHAIN` selected the already installed toolchain;
- the first build attempted a default target inside the read-only lab and failed with `EROFS`; setting `CARGO_TARGET_DIR=/target` corrected the harness boundary;
- the first supplemental derivative focal used the gateway cache and lacked old `ahash`; selecting the pre-existing derivative cache resolved it offline.

None reached compilation of the candidate/product combination or modified product/derivative source.

## Commands and results

| Command | Result |
|---|---|
| `cargo metadata --offline --format-version 1` | PASS; generated the path-resolved lab lock |
| `cargo metadata --locked --offline --format-version 1 --no-deps` | PASS after two reproducibility runs |
| `cargo tree --locked --offline` | PASS; exact local MoQ paths confirmed |
| `cargo fmt --all -- --check` | PASS |
| `cargo check --locked --offline --all-targets --all-features` | PASS; examples included |
| `cargo test --locked --offline --all-targets --all-features` | PASS: 66 passed, 0 failed, 1 ignored |
| `cargo clippy --locked --offline --all-targets --all-features -- -D warnings` | PASS |
| derivative focal `c1_raw_and_webtransport_complete_and_release_before_session_lifetime` | PASS: 1/1 |
| derivative focal `draft_16_and_raw_quic_alpn_are_unchanged` | PASS: 1/1 |
| derivative focal `required_bounded_positive_` | PASS: 2/2, raw QUIC and WebTransport |
| derivative focal `c2_n_plus_one_real_moq_setup_observes_exact_raw_and_webtransport_close` | PASS: 1/1 |

Product test breakdown:

| Target | Result |
|---|---|
| library | 49 passed |
| `federation_concurrency` | 2 passed |
| `media_pipeline` | 4 passed |
| `moq_relay_interop` | 2 passed; hostile test ignored by design |
| `mtls_quic` | 8 passed |
| example `dev_moq_relay` | 1 passed |
| example `dev_mtls_moq_relay` | compiled; 0 tests |

The suite demonstrates current publisher isolation, delayed MoQT setup isolation, scheduler N+1/recovery, media demux/CMAF without encoder/decoder, all-Object Subgroup draining, WebTransport relay publication/subscription, mTLS fail-closed loading and invalid-peer isolation, and lifecycle cancellation/deadline behavior. It does not demonstrate that the product has enabled the candidate's new admission/authorization paths.

## Required post-pin platform matrix

After `TP-RUST-DIST` wires the candidate and an atomic real pin is authorized, the following are mandatory before changing ADR-0005/0006 status:

1. **Hermetic product gates:** repeat fmt, locked metadata, all-target/all-feature check/test/Clippy and exact path/source inventory using the real Git pin.
2. **Required/bounded integration:** product-owned raw QUIC and WebTransport tests for C1/I1/C2/I2 ordering, N/N+1 immediate rejection, zero waiter/task/state effects, capacity recovery, cancellation, panic/error paths, shared multi-endpoint controller, and one-deadline shutdown with terminal gauges zero.
3. **mTLS/authorization:** repeat anonymous, wrong-CA, wrong-EKU, expired, valid, identity-isolation, and Smallstep-real cases; add mTLS-valid but unauthorized SPIFFE/role/operation/namespace cases without logging identity material.
4. **Smoke race gate:** execute `./chaos/federation/run.sh --profile smoke` at least three consecutive times; every run must report coherently, preserve nonzero failures, and clean container/network state.
5. **Incremental hostile matrix:** run 60-second baseline, delay/jitter, loss, reorder, bandwidth, and combined cases with the pinned image and global timeout. Preserve exact requested/consumed settings and do not convert unobservable state to zero.
6. **Bounded soak:** only after the short matrix is green, run the explicit 1800-second hostile soak. Compare stable RSS/task/socket/admission-gauge windows and terminal equations; one sample cannot prove leak freedom.
7. **External interoperability:** repeat the draft-16 `moq-interop-runner`/moxygen matrix and browser/WebTransport playback checks. Self-tests against the same derivative are not external conformance.
8. **Multitrack gap:** retain scheduler priority evidence, but do not claim MoQT hostile multitrack Object Dropping until a real bounded integration carries video, audio, and telemetry and observes the intended policy.

Container/cgroup limits remain defense in depth, not a substitute for logical C1/C2 admission. No production, Tier-1, DoS-resistance, complete Zero-Trust, complete interoperability, or bounded-memory claim follows from this preflight.

## Cleanup, dependencies, and DCO

- Review containers: zero after execution.
- External target volume: removed.
- Lab-local `target/`: absent.
- Product and derivative hashes/status: unchanged.
- Product dependencies/licenses: unchanged; path substitution and regenerated lock exist only in the lab.
- Advisory/T batch evaluation: explicitly out of scope and not inferred from these results.
- DCO: not applicable; no commit or contribution was created.

