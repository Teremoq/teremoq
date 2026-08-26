# Third-party inventory — Teremoq development PKI

Checked on: 2026-08-25

| Name | Official repository | Version | OCI digest | SPDX license | Purpose | Owner | Update policy | Distribution obligations |
|---|---|---:|---|---|---|---|---|---|
| Smallstep `step-ca` | https://github.com/smallstep/certificates | v0.30.2 | `sha256:a2b17872915c193259b75a5474c398326f41bd199f0842093e52cf4182bc8270` | Apache-2.0 | Standalone development CA and revocation database | Teremoq Infrastructure & PKI | Review upstream security releases monthly; update tag and multi-platform digest together after smoke tests and license review | Preserve license and NOTICE material when distributing the image or derivative; state changes; do not use trademarks as endorsement. Legal review remains required. |
| Smallstep `step-cli` | https://github.com/smallstep/cli | v0.30.6 | `sha256:474768dd54700088e9480210eaf2c25e3041ed1e8302c7cf211725381cec9f5e` | Apache-2.0 | CA bootstrap, issuance, renewal, revocation and primary X.509 validation | Teremoq Infrastructure & PKI | Review upstream security releases monthly; update tag and multi-platform digest together after smoke tests and license review | Preserve license and NOTICE material when distributing the image or derivative; state changes; do not use trademarks as endorsement. Legal review remains required. |

The technical license review was confirmed against the `LICENSE` files at the exact release tags. It does not replace legal approval before commercial distribution. Container transitive packages must be included in the future release SBOM and legal review.
