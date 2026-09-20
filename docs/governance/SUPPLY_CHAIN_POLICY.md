# Software supply-chain policy

## Provenance and dependency intake

Prefer maintained official upstream projects over local reimplementation. Pin
Git dependencies to full commits and OCI images to immutable digests. Package
manager lockfiles remain versioned. Every direct dependency records upstream,
version or commit, license, purpose, owner and update policy.

Third-party code, generated files, fixtures, GStreamer components, Smallstep,
n8n, OCI images, Ollama models, Rust crates and JavaScript packages keep their
own licenses and notices. Technical license review is not legal advice.

## GitHub Actions

Repository policy requires full-length commit SHA pins. Tags, branches and
abbreviated SHAs are prohibited. Before allowing an action, record:

- official repository;
- full commit SHA;
- license;
- narrowly defined purpose;
- review date and update owner.

Use a GitHub native feature instead of an action when it covers the requirement.
No workflow may approve pull requests. Default `GITHUB_TOKEN` permissions stay
read-only and workflow jobs request only the minimum additional permission.

Repository Actions policy allows GitHub-owned actions, requires full-length
commit SHAs, disables blanket access to verified creators by default and has no
third-party wildcard. A third-party repository is added only after its exact
commit, license, purpose and owner have been reviewed and recorded.

No Actions are introduced by this bootstrap, so there is currently no action
allowlist inventory beyond the repository-level policy.

## Builds and releases

Candidate artifacts require checks, SBOM, checksums and provenance as specified
in `RELEASE_POLICY.md`. Build tools run from a pinned project-local environment
or verified container and do not become part of Teremoq's runtime artifact.

## Secrets and private deployments

Secret Scanning, Push Protection and Private Vulnerability Reporting must remain
enabled. Dependabot alerts remain enabled; automatic security-update pull
requests remain disabled until their integration and review policy is approved.
Production secrets, PKI runtime state, customer configuration, identities,
namespaces and operational data are prohibited from the public repositories.

## Verification targets

Zero-Transcoding, mTLS identity, bounded concurrency and MoQT compatibility are
release gates only when the candidate has an explicit test method and evidence.
They must not be converted into unsupported production claims.
