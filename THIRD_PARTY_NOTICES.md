# Third-party notices

Reviewed technically on 2026-08-26. This inventory does not replace legal
review before commercial distribution. Third-party materials retain their
original licenses, copyrights, notices and trademarks.

| Component or material | Source | License | Relationship to Teremoq |
|---|---|---|---|
| Cloudflare `moq-rs` | https://github.com/cloudflare/moq-rs | MIT OR Apache-2.0 | Git-pinned Rust dependency; the `Teremoq/moq-rs-teremoq` mirror retains this license |
| GStreamer and plugins | https://gstreamer.freedesktop.org/ | Component-specific, including LGPL-2.1-or-later and MPL-2.0 | Native runtime/plugin dependencies; not relicensed by Teremoq |
| GStreamer Rust bindings | https://github.com/GStreamer/gstreamer-rs | MIT OR Apache-2.0 | Rust dependencies |
| Shiguredo SRT | https://github.com/shiguredo/srt-rs | Apache-2.0 | Rust SRT dependency |
| Smallstep `step-ca` and `step-cli` | https://github.com/smallstep | Apache-2.0 | Development PKI containers; exact images are in `infra/pki/THIRD_PARTY.md` |
| Next.js and React | https://github.com/vercel/next.js; https://github.com/facebook/react | MIT | Supervisor runtime and starter-generated material |
| MP4Box.js | https://github.com/gpac/mp4box.js | BSD-3-Clause | ISO BMFF/CMAF parsing in the supervisor |
| Synthetic MPEG-TS fixture | `gateway-rs/tests/fixtures/` | CC0-1.0 | Test media and metadata; see its local notice |
| n8n | https://github.com/n8n-io/n8n | Sustainable Use License | Internal development orchestration only; not redistributed or relicensed |
| Ollama runtime | https://github.com/ollama/ollama | MIT | Optional local development runtime; not redistributed here |
| Ollama models and weights | Model-specific source | Model-specific | Not included; each model retains its own license and usage terms |

Rust and JavaScript dependencies are enumerated by `gateway-rs/Cargo.lock` and
`supervisor-web/package-lock.json`. Direct inventories and distribution notes
are maintained in `gateway-rs/DEPENDENCIES.md`,
`supervisor-web/THIRD_PARTY_NOTICES.md` and `infra/pki/THIRD_PARTY.md`.

The repository does not redistribute n8n, Ollama, Ollama models, GStreamer,
Smallstep images, OCI base images or package-registry dependencies merely by
referencing or orchestrating them. Any future binary or image release must
produce an artifact-specific SBOM and notice bundle.
