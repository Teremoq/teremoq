# Teremoq

## Current priority: complete the PoC

The user-approved [PoC acceptance and delegation contract](tasks/poc/ACCEPTANCE-AND-DELEGATION.md)
defines the immediate milestone: real video between two computers, automatic
updates and a resilient test coordination channel. The Master delegates the
campaign to the existing Platform/Chaos owner and retains integration and final
acceptance. This is a requirements document, not evidence of completed tests.

Teremoq is an open-source edge gateway research and engineering project for
low-latency media delivery over Media over QUIC (MoQ). The original code in
this repository is available under Apache-2.0. Deployments, customer
configuration, trust material and operational data remain private.

The repository contains the Rust gateway (`gateway-rs`), an isolated Next.js
supervisor (`supervisor-web`), development PKI automation, resilience labs and
design documentation. It does not contain production certificates, keys,
credentials, customer namespaces or production deployment configuration.

## Engineering invariants

Zero-Transcoding, mTLS, identity-bound authorization, bounded concurrency and
MoQT compatibility are architecture invariants and verification targets. They
are not claims that every environment, codec, upstream peer or production load
has already been qualified. Results must identify the tested revision, network,
hardware, load, duration and limitations.

## Development

The detailed architecture and pinned dependencies are documented in
`.cursorrules`, `gateway-rs/DEPENDENCIES.md` and the component ADRs. Typical
component checks are:

```sh
cd gateway-rs
cargo check --locked --all-targets --all-features
cargo test --locked --all-targets --all-features

cd ../supervisor-web
npm ci
npm test
npm run lint
```

Tool availability and native GStreamer requirements vary by environment. A
failed or unavailable check must be reported, not treated as passing.

## Licensing and third parties

Original Teremoq code is Apache-2.0. Fixtures, generated material, dependencies,
containers and other third-party material keep their own licenses. In
particular, `Teremoq/moq-rs-teremoq` remains `MIT OR Apache-2.0`, matching
upstream; contributions made in that repository use the same dual license.

The `aiops` development area does not redistribute or relicense n8n, Ollama or
Ollama models. n8n remains governed by its upstream Sustainable Use License,
the Ollama runtime by its upstream license, and each model or set of weights by
its own license and usage terms. Model name, version, digest and license must be
reviewed before use or distribution.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and component inventories.
This technical license review is not legal advice.

## Contributing and security

Contributions require DCO 1.1 sign-off and use the license of the component
modified; no CLA is used. See [CONTRIBUTING.md](CONTRIBUTING.md).

Do not report vulnerabilities in public issues. Use GitHub Private
Vulnerability Reporting as described in [SECURITY.md](SECURITY.md).

Publication of the source code does not imply commercial support, a service
level agreement, production compatibility or a product warranty.
