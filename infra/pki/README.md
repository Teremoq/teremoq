# Teremoq development PKI

This directory provides persistent mTLS identities for development, integration and CI. It deliberately reuses Smallstep `step-ca` and `step-cli`; Teremoq does not implement a CA, X.509 parser or cryptographic protocol. This is not the final production PKI.

## Trust model and profiles

The bootstrap creates an ECDSA P-256 root and intermediate, then three independent JWK provisioners with sanitized Smallstep X.509 templates:

- `gateway-client`: digital signature plus `clientAuth`; never `serverAuth`; URI `spiffe://teremoq.local/gateway/<node-id>`.
- `relay-server`: digital signature plus `serverAuth`; never `clientAuth`; configurable DNS/IP SANs and URI `spiffe://teremoq.local/relay/<node-id>`.
- `relay-peer`: digital signature plus both `serverAuth` and `clientAuth`. This dual role is reserved for a relay that may accept and initiate authenticated relay-to-relay connections. It must not be issued to gateways.

The CN is informational. Future authorization uses the URI SAN. These are SPIFFE-shaped URIs only: this task does not deploy SPIRE, the SPIFFE Workload API, workload attestation or automatic SVID rotation.

`config/identity-policy.json` is the approved development/integration authorization contract, not a private key or a production policy engine. It is fail-closed and grants only:

- `gateway-dev-1` on the exact connection path `/publish`;
- operations `Publish` and `PublishNamespace`;
- the exact namespace `teremoq/live`.

Every other gateway identity, operation, path or namespace is denied. Relay identities are default-deny until a separately reviewed relay-to-relay mapping exists; the presence of a valid relay certificate never grants a relay permission by itself. Capacity limits, certificate validity, IP, DNS SAN, SNI and the requested path are not principals.

Before parsing an already rustls-verified leaf from the same connection, the runtime contract caps the presented chain at 8 certificates, the leaf DER at 16 KiB and the complete DER chain at 64 KiB. Those are defensive product input bounds, not CA issuance settings. The runtime owner must enforce them before its maintained X.509 parser and reduce every failure to a fixed, redacted authentication denial. PKI tests validate this declarative contract; enforcement inside the Rust relay remains the responsibility of the product integration.

Development defaults are root 10 years, intermediate 1 year and leaf 30 days. They are configurable in `versions.env` or by environment override. They are not production recommendations: production should use short-lived leaf certificates, automated renewal, audited policy, and protected HSM/KMS-backed CA keys.

## Layout and operation

Static policy, templates, scripts and tests are versionable. `runtime/` is ignored except for its sentinel `.gitignore`. Bootstrap creates `runtime/ca`, `runtime/trust`, `runtime/identities` and `runtime/env` with restrictive permissions.

Run:

```bash
make pki-bootstrap
make pki-verify
make pki-test
```

Start and stop without deleting state:

```bash
make pki-up
make pki-down
```

Issue, renew and revoke:

```bash
infra/pki/scripts/issue-identity.sh --profile relay-server --id relay-dev-2 \
  --dns relay-dev-2 --ip 127.0.0.1
infra/pki/scripts/renew-identity.sh --id relay-dev-2
infra/pki/scripts/revoke-identity.sh --id relay-dev-2 --reason 'Node retired'
```

Every profile automatically receives its required URI SAN. IDs are strictly allowlisted and existing identity directories are never overwritten. Mutations are serialized with `flock`, built in private temporary paths and published with atomic renames.

## Task 02 environment contract

Bootstrap writes `runtime/env/gateway-dev-1.env` and `runtime/env/relay-dev-1.env`. Load one in Bash with:

```bash
set -a
source infra/pki/runtime/env/gateway-dev-1.env
set +a
```

The public browser/WebTransport MoQ listener remains UDP/4433. The private mTLS federation development endpoint is TCP/4443. The CA management endpoint is TCP/9443 and Compose publishes it only on `127.0.0.1`.

The versioned identity policy lives at `infra/pki/config/identity-policy.json`. It contains no secrets and must remain independently reviewable. The current PKI scripts validate and publish the contract but do not make the Rust relay enforce it; the runtime owner must implement the same fail-closed decisions at the required authorization gates. Do not infer authorization from the `.env` files: they provide paths and bind settings only.

## Revocation limitation

`revoke-identity.sh` records revocation in the Smallstep database using the official authenticated revocation API. This prevents subsequent renewal. It does not by itself make an arbitrary TLS runtime reject an otherwise time-valid certificate: the verifier must enforce CRL/OCSP or another active status mechanism. No evidence in Task 01 shows that the Rust relay runtime does so, therefore active revocation enforcement is explicitly pending Task 02/runtime integration.

## Backup and restore

Stop the CA, take an encrypted, access-controlled backup of the entire `runtime/ca` tree plus `runtime/trust`, and restart it. The backup must preserve ownership and modes and include database, configuration, certificates, encrypted CA keys and password files. Restore only into an empty `runtime`; bootstrap intentionally rejects partial state and never replaces existing keys. Test restoration and key access periodically. Never place the archive in Git or an unencrypted shared filesystem.

## WSL2 and Docker Desktop

WSL2 file permissions are reliable on the Linux filesystem used by this workspace, but may be emulated or weakened under `/mnt/c`. Keep runtime material in the Linux filesystem. Docker Desktop must be running, clock synchronization must be healthy, and port 9443 must be free. `flock` semantics on Windows-mounted filesystems can differ; do not move the runtime there.

The upstream `step-ca` executable carries the image's low-port execution capability metadata. Docker rejects execution when its entire capability bounding set is dropped, even though this deployment binds only port 9443. Compose therefore keeps Docker's default bounding set, while still running as UID/GID 1000 (or the invoking Linux UID/GID), setting `no-new-privileges`, using a read-only container filesystem, and avoiding privileged mode. This should be revisited when Smallstep publishes an image variant without that file capability.

## Production gaps

Production requires offline/protected root ceremonies, HSM/KMS custody for CA signing keys, HA and disaster recovery, short-lived automated renewal, status enforcement, audit export, RBAC/approval workflows, monitoring, rotation drills, SBOM/provenance verification and legal approval. The Apache-2.0 inventory here is a technical review only. Upstream examples were consulted for command and template syntax but were not copied as a production application.
