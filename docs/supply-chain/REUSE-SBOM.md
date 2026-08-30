# REUSE and local SBOM

This repository uses Apache-2.0 for Teremoq-owned files. The central
`REUSE.toml` metadata is authoritative so that generated and binary files are
covered without modifying their contents. It also overrides older project
headers that used the generic `Teremoq contributors` label with the legal
copyright holder requested for this repository.

This metadata does not relicense dependencies. Dependency licenses and package
provenance are recorded by their package managers and in the local SBOM.

## Provenance exceptions

- `gateway-rs/tests/fixtures/**` is synthetic test material generated from
  FFmpeg filters, with no third-party audiovisual content. Its existing fixture
  notice dedicates the fixture and metadata under CC0-1.0. REUSE records no
  copyright holder (`NONE`).
- `supervisor-web/public/{file,globe,next,vercel,window}.svg`,
  `supervisor-web/src/app/favicon.ico`, `supervisor-web/AGENTS.md`, and
  `supervisor-web/CLAUDE.md` are byte-identical to, or generated verbatim by,
  the Next.js 16.3.2 `create-next-app` templates. They retain the upstream
  copyright `2025 Vercel, Inc.` and MIT license.
- Tracked Python bytecode under `gateway-rs/tests/preview/__pycache__/` is a
  generated derivative of the adjacent Teremoq test helpers. The operations
  screenshots under `supervisor-web/evidence/` are evidence generated from the
  Teremoq UI. Both remain covered as Teremoq-owned Apache-2.0 files.
- Lockfiles are generated dependency-resolution metadata for this project.
  Their Apache-2.0 file annotation does not change the licenses of packages
  named inside them.
- Untracked or ignored build outputs (`node_modules`, `target`, `.next`, caches,
  and local logs) are outside the REUSE inventory and the committed SBOM.

## REUSE verification

Run the upstream REUSE tool fixed to version 5.1.1 and image digest:

```sh
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD:/data" -w /data \
  fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da \
  lint
```

The same image can restore the SPDX license texts referenced by `REUSE.toml`:

```sh
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD:/data" -w /data \
  fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da \
  download --all
```

## Local SBOM scope

`sbom/teremoq-local.syft.json` is a local, reproducible inventory of the
integrated source tree. It is not a release attestation, evidence of a clean
consumer build, a production deployment inventory, or evidence of live MoQT or
video sessions. It catalogs package-manager manifests and lockfiles, including
the Rust graph, the npm graph, and the three MoQ crates fixed to Git revision
`4b50958c121edfa2d6778c0586b30a78ee3e6f83`.

The inventory is generated with upstream Syft 1.51.0 (Apache-2.0), fixed to
image digest
`sha256:678bfa565b60f747aac0f8e964fe5588a24445b8d0a480e91f6efd70020dfbb0`.
It is validated with the official CycloneDX CLI 0.33.1 (Apache-2.0), fixed to
image digest
`sha256:252c2e26f468c25fea1e63ecde1bc3198ad6e9dbb57f5ed3236bddcb2281b3a7`.

The SBOM describes source commit
`df769b3df973665183bc27ad5d33af6c4c99944b`. Relative to the previous SBOM
source, this release-candidate state updates `chacha20` from 0.10.1 to 0.10.2
and adds approved platform/two-host artifacts. The later commit that stores the
refreshed SBOM does not change manifests, dependencies, locks, or product code.

The result contains 857 components: 375 Rust crates and 482 npm packages,
including npm development dependencies. The three MoQ components each record
the complete Git source and revision, and `web-transport` records version
`0.10.9` and its crates.io checksum. The Rust inventory contains `chacha20`
0.10.2 and no `chacha20` 0.10.1 component.

### Reproduce from the clean source commit

Run from a checkout that contains this guide. The output is written by Syft,
outside the temporary source checkout, and no network is available to the
generator:

```sh
teremoq_source_commit=df769b3df973665183bc27ad5d33af6c4c99944b
teremoq_clean_root="$(mktemp -d)"
mkdir -p "$teremoq_clean_root/output"
git worktree add --detach "$teremoq_clean_root/source" "$teremoq_source_commit"

docker run --rm --network none --user "$(id -u):$(id -g)" \
  -e SYFT_CHECK_FOR_APP_UPDATE=false \
  -e SYFT_JAVASCRIPT_INCLUDE_DEV_DEPENDENCIES=true \
  -v "$teremoq_clean_root/source:/src:ro" \
  -v "$teremoq_clean_root/output:/out" \
  anchore/syft@sha256:678bfa565b60f747aac0f8e964fe5588a24445b8d0a480e91f6efd70020dfbb0 \
  scan dir:/src --source-name teremoq \
  --source-version "$teremoq_source_commit" \
  --output syft-json=/out/teremoq-local.syft.json

cmp sbom/teremoq-local.syft.json \
  "$teremoq_clean_root/output/teremoq-local.syft.json"
(cd sbom && sha256sum -c SHA256SUMS)
git worktree remove "$teremoq_clean_root/source"
```

Two independent clean-checkout generations produced the same SHA-256:

```text
6365310f51ea1741500f80f364facbd82a8f77476bee03af2b287e2be210fc6e  teremoq-local.syft.json
```

### Validate the committed SBOM

Syft first parses its native schema 16.1.10 and converts it to a temporary
CycloneDX 1.7 document. The official CycloneDX CLI then validates that document:

```sh
teremoq_validation_root="$(mktemp -d)"
docker run --rm --network none --user "$(id -u):$(id -g)" \
  -e SYFT_CHECK_FOR_APP_UPDATE=false \
  -v "$PWD/sbom:/input:ro" -v "$teremoq_validation_root:/out" \
  anchore/syft@sha256:678bfa565b60f747aac0f8e964fe5588a24445b8d0a480e91f6efd70020dfbb0 \
  convert /input/teremoq-local.syft.json \
  --output cyclonedx-json=/out/teremoq-local.cdx.json

docker run --rm --network none \
  -v "$teremoq_validation_root/teremoq-local.cdx.json:/data/sbom.json:ro" \
  cyclonedx/cyclonedx-cli@sha256:252c2e26f468c25fea1e63ecde1bc3198ad6e9dbb57f5ed3236bddcb2281b3a7 \
  validate --input-file /data/sbom.json --input-format json \
  --input-version v1_7 --fail-on-errors
```

### Known limits

- This is a source/lockfile inventory, not a catalog of compiled binaries,
  container base images, host packages, or deployment-time services.
- The control plane declares no Python packages, so the SBOM has no PyPI
  components. Build tools themselves are not project runtime dependencies.
- Syft's native JSON is retained because it is byte-reproducible for this scan.
  Direct CycloneDX output contains a volatile timestamp and random UUID; the
  converted CycloneDX document is therefore validation-only and is not stored.
- Format conversion is marked experimental by Syft and may omit
  format-specific details. The authoritative inventory is the committed Syft
  JSON and its SHA-256.
- An SBOM is an inventory, not a vulnerability decision or a license grant.
  `cargo audit`, `cargo deny`, and `npm audit` remain separate validation gates.
