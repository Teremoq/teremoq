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

`sbom/teremoq-local.cdx.json` is a local, reproducible inventory of the
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

Exact regeneration commands, the source commit, the resulting hashes, and
known catalog limitations are recorded below after SBOM generation.
