<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Minimal opt-in LAN E2E laboratory

This is a local, reversible preparation for one Windows 11 server and one
Windows 10 client on the same private 5 GHz Wi-Fi. It does not alter normal
loopback defaults, expose the root Compose stack, configure Windows by itself,
run a load or claim production readiness.

## Fixed boundary

```text
Windows 10 Chrome/Edge (outbound only)
  -> exact client IPv4 -> exact server IPv4, WebTransport/QUIC UDP/14433
  -> one run-owned Defender rule + one run-owned WSL Hyper-V rule
  -> WSL mirrored, bounded infra/lan/udp_proxy.py
  -> fixed backend 127.0.0.1:4433, dev_moq_relay

test source -> SRT 127.0.0.1:19000 -> Gateway -> relay
Gateway -> private run-scoped capability -> relay `/publish/<capability>`
Gateway health/supervisor -> 127.0.0.1:9080 only
```

UDP/14433 is the only LAN exposure. SRT/19000, the source, relay, Gateway and
supervisor remain server/loopback-only. There is no LAN rule for 19000 or
4433, no dashboard LAN bind, and no Redis/Valkey, n8n, Ollama, Docker socket,
router forwarding, UPnP or `netsh portproxy` exposure.

The proxy never terminates or inspects QUIC. It binds the exact assigned
server RFC1918 address, accepts only the exact client RFC1918 address, forwards
only to `127.0.0.1:4433`, caps real clients at 25 plus exactly two technical
QUIC tuple associations, rejects datagrams of 65535 bytes or more and expires
idle tuples in 5--120 seconds. Inputs and logs are bounded; logs contain no
payload or full client/server IP.

## Current real blockers

The observed host is Windows build 22621, WSL 2.7.12/kernel 6.18 in NAT,
without `.wslconfig`, Wi-Fi 802.11ac/5 GHz, profile `Public`, non-elevated
PowerShell 5.1 and default-deny Hyper-V inbound. Inherited containers currently
publish wildcard TCP/4433, 5678, 6379, 11434 and UDP/4433, 9000. They are not
owned here and must not be stopped or changed by these scripts.

Activation remains blocked until all of the following are true:

1. exact integrated Rust LAN capability commit
   `6dadfbd8695bd1d0037568d879563eb83b7567b5` and the reviewed Web LAN player
   bypass are ancestors of the clean integration HEAD;
2. the TP-WEB-REALTIME lightweight 1/5/10/25 launcher contract is integrated;
3. an authorized owner isolates the inherited publications and both preflights
   record no reserved/wildcard conflict;
4. mirrored WSL is approved, applied and verified after `wsl --shutdown`;
5. both exact firewall rules are applied and verified from an elevated session;
6. certificate, fingerprint, capacity, clock, MTU, package and authorization
   evidence pass.

No script turns those prerequisites into success by substituting simulation.

## 1. Private configuration and preflight

Copy the template outside Git and replace every placeholder with current exact
values. Versioned files contain no real addresses.

```bash
cp infra/lan/config/lan.example.tsv /ABSOLUTE/PRIVATE/PATH/lan.tsv
infra/lan/validate-config.sh --config /ABSOLUTE/PRIVATE/PATH/lan.tsv
infra/lan/preflight-wsl.sh --role server --config /ABSOLUTE/PRIVATE/PATH/lan.tsv \
  > /ABSOLUTE/PRIVATE/PATH/server-wsl-preflight.tsv
```

Windows 11 server, read-only, from a native elevated-or-non-elevated Windows
PowerShell console on the server itself:

```powershell
& .\infra\lan\windows\Preflight-Lan.ps1 `
  -Role Server -RunId RUN_ID -SourceCommit FULL_INTEGRATED_COMMIT `
  -ServerIPv4 SERVER_EXACT_IP -ClientIPv4 CLIENT_EXACT_IP `
  -PrefixLength PREFIX -NetworkProfile Public -ExpectedWslMode mirrored `
  -MaximumClockOffsetMs MAX_CLOCK_MS -MinimumMtu MINIMUM_MTU `
  -MinimumCpuCores SERVER_MIN_CPU -MinimumMemoryMiB SERVER_MIN_MEMORY_MIB `
  -MinimumDiskMiB SERVER_MIN_DISK_MIB `
  | Set-Content -Encoding UTF8 C:\ABSOLUTE\PRIVATE\server-preflight.json
```

Windows 10 client, read-only and outbound-only, from a native Windows
PowerShell console on the client itself:

```powershell
& .\infra\lan\windows\Preflight-Client.ps1 `
  -RunId RUN_ID -SourceCommit FULL_INTEGRATED_COMMIT `
  -ServerIPv4 SERVER_EXACT_IP -ClientIPv4 CLIENT_EXACT_IP -PrefixLength PREFIX `
  -NetworkProfile Public -ExpectedWslMode nat `
  -MaximumClockOffsetMs MAX_CLOCK_MS -MinimumMtu MINIMUM_MTU `
  -MinimumCpuCores CLIENT_MIN_CPU -MinimumMemoryMiB CLIENT_MIN_MEMORY_MIB `
  -MinimumDiskMiB CLIENT_MIN_DISK_MIB `
  | Set-Content -Encoding UTF8 C:\ABSOLUTE\PRIVATE\client-preflight.json
```

The checks cover exact private IP/subnet/profile, Wi-Fi 5 GHz when observable,
clock, Chrome/Edge, WSL mode, Docker/tools where applicable, MTU and capacity.
Missing data is `unavailable`, never zero. Client ping fields are explicitly
`icmp_echo_*_approximation`; they are not QUIC loss, jitter or reachability.
QUIC stays `not_measured` until the real browser handshake. Docker conflicts
report only service/protocol/port, never PID.
Client loopback TCP/3000 is an additional fail-closed reservation for the
standalone Node process and must be free in preflight and immediately before
start; it is never exposed through the LAN firewall.
Run both Windows preflights in native PowerShell. On this host, `powershell.exe`
launched from WSL interop does not provide trustworthy nested native stdout for
evidence capture, so WSL-driven captures are documentation-only and are not
accepted as real preflight evidence. Copy/import the resulting JSON files only
after the native PowerShell run completes. The JSON now carries a closed
`capture_context` block with PowerShell process ancestry and WSL environment
indicators plus a derived traversal outcome. The file hash binds exact bytes,
but trust still comes from native PowerShell execution plus CIM-derived process
ancestry, not from any external CLI-supplied context. Activation rejects WSL
interop, truncated CIM ancestry, PID cycles/reuse, depth-limit captures or any
other ambiguous capture path even if the JSON/hash pair is otherwise well
formed. Wi-Fi band acceptance is equally strict: only the exact canonical
`5 GHz` value passes when the band field is present. Internally, every queried
PID is re-read and must keep the same `ProcessId`, `ParentProcessId`, basename
and `CreationDate` before the ancestry walk advances; a parent whose
`CreationDate` is later than the observed child is rejected. Equality is
conservatively accepted because DMTF/host timestamp resolution can collapse
closely created native processes.

## 2. Mirrored WSL plan

These commands print exact changes and rollback but execute neither:

```powershell
.\infra\lan\windows\Wsl-Mirrored-Plan.ps1 -Action Plan -RunId RUN_ID
.\infra\lan\windows\Wsl-Mirrored-Plan.ps1 -Action RollbackPlan -RunId RUN_ID
```

The plan refuses to overwrite an existing `.wslconfig`. Actual application,
`wsl --shutdown` and rollback require the separately authorized maintenance
window. Windows 10 stays WSL NAT.

## 3. Relay certificate

`prepare-pki-plan.sh` requires the recorded Rust owner integration to be ready.
It does not misuse the 30-day Smallstep identity profile. Activation separately
requires the exact integrated Rust commit above to be an ancestor of HEAD. Its
source provenance is `2f8fb1b3219483050bc997bee25a052c2db5f463`; both commits
have stable patch-id `5729506f85cb640b0026e4db80e402d496cd8fd8`, but provenance
is never accepted as an operational ancestry override. The integrated
loopback relay creates its private runtime identity; then verify it exactly:

```bash
infra/lan/prepare-pki-plan.sh --config /ABSOLUTE/PRIVATE/PATH/lan.tsv
infra/lan/verify-runtime-pki.sh --config /ABSOLUTE/PRIVATE/PATH/lan.tsv \
  --cert /ABSOLUTE/RUNTIME/relay/cert.pem \
  --root /ABSOLUTE/RUNTIME/relay/cert.pem \
  --fingerprint /ABSOLUTE/RUNTIME/relay/fingerprint.sha256
```

The leaf must be currently valid, have positive total validity strictly below
14 days, DNS SAN exactly `localhost`, ordered IP SANs exactly `127.0.0.1` then
the configured server IP, and the exact SHA-256 pin. Extra/duplicate SANs,
expired/future/14-day certificates and mismatched pins fail. The profile marker
must be exactly `webtransport-hash-v2-lan-ip-sha256:<sha256(canonical-server-ip)>`;
the raw IP is not stored in the marker. Keys and real identities stay outside
Git and logs; TLS verification is never disabled.

## 4. Two exact firewall rules

`Plan` is read-only and safely copyable. `Apply` and `Rollback` require both
elevation and `-ConfirmApply`; this delivery executes neither.

```powershell
.\infra\lan\windows\Firewall-Lan.ps1 -Action Plan -RunId RUN_ID `
  -SourceCommit FULL_INTEGRATED_COMMIT `
  -ServerIPv4 SERVER_EXACT_IP -ClientIPv4 CLIENT_EXACT_IP `
  -RouterIPv4 ROUTER_EXACT_IP -PrefixLength PREFIX -NetworkProfile Public
```

The script validates network/broadcast for server, client and router, requires
the configured profile to match the interface, and creates exactly UDP/14433
from client to server in Defender and Hyper-V. Hyper-V uses creator ID
`{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}` and plural parameters. Rollback
removes only both exact run Names and separately proves zero residue. It never
changes the profile or Hyper-V `DefaultInboundAction`.
After a separately authorized `Apply`, capture the read-only, closed
attestation used by activation with the same exact arguments and commit:

```powershell
.\infra\lan\windows\Firewall-Lan.ps1 -Action Verify -RunId RUN_ID `
  -SourceCommit FULL_INTEGRATED_COMMIT `
  -ServerIPv4 SERVER_EXACT_IP -ClientIPv4 CLIENT_EXACT_IP `
  -RouterIPv4 ROUTER_EXACT_IP -PrefixLength PREFIX -NetworkProfile Public `
  | Set-Content -Encoding UTF8 C:\ABSOLUTE\PRIVATE\firewall-verify.json
```

`Verify` requires exactly one Defender and one Hyper-V rule and checks all
planned identities, filters and cardinalities, including Defender
`EdgeTraversalPolicy=Block`, before emitting `firewall_verified=true`.

## 5. Executable activation and stop

Prepare run-owned state and private copies of the command/authorization
templates. The command manifest is an argv array, never a shell string. The
authorization binds the independent server WSL preflight, both Windows
preflights and firewall attestation by SHA-256,
the command-manifest SHA-256, the publish-capability metadata SHA-256, the
commit, conflict cleanup, owner integrations and explicit operator approval.
Every executable has its own SHA-256 and must
reside in the exact clean worktree or a run-owned artifact directory with no
write bits; generic shells, `cargo`, Python, Node and similar runners are denied.

```bash
infra/lan/prepare-runtime.sh --config /ABSOLUTE/PRIVATE/PATH/lan.tsv \
  --state-dir /tmp/teremoq-lan-RUN_ID
cp infra/lan/config/lab-commands.example.json /ABSOLUTE/PRIVATE/PATH/lab-commands.json
cp infra/lan/config/activation-authorization.example.tsv /ABSOLUTE/PRIVATE/PATH/activation.tsv
sha256sum /tmp/teremoq-lan-RUN_ID/publish-capability.metadata.tsv
```

For a `ready` exact Rust contract, preparation obtains 256 bits from Python's
system-backed CSPRNG and creates `publish-capability` as a new run-owned regular
file with exact mode `0600`. Its closed sidecar records only run/commit,
filename, mode, UID, device/inode, byte count and SHA-256; it never contains the
capability value. Record the sidecar digest in
`publish_capability_metadata_sha256` inside the private authorization. Never
print, copy, package or inspect the capability value.

Before freezing the private artifact directory, copy only the already-built
reviewed `dev_moq_relay` and `gateway-rs` binaries from the exact commit, add
`run-id` and `source-commit` marker files, record both executable SHA-256 values
in `lab-commands.json`, then remove every write bit from the binaries, markers
and artifact directory. Record `sha256sum lab-commands.json` in
`activation.tsv`. The source command is the existing reviewed
`gateway-rs/tests/preview/run-source.sh` from the same clean worktree; no viewer
or media generator is added here.

Once every gate is genuinely satisfied, activation is executable:

```bash
infra/lan/start-lab.sh \
  --config /ABSOLUTE/PRIVATE/PATH/lan.tsv \
  --commands /ABSOLUTE/PRIVATE/PATH/lab-commands.json \
  --authorization /ABSOLUTE/PRIVATE/PATH/activation.tsv \
  --wsl-preflight /ABSOLUTE/PRIVATE/PATH/server-wsl-preflight.tsv \
  --server-preflight /ABSOLUTE/PRIVATE/PATH/server-preflight.json \
  --client-preflight /ABSOLUTE/PRIVATE/PATH/client-preflight.json \
  --firewall-attestation /ABSOLUTE/PRIVATE/PATH/firewall-verify.json \
  --certificate /ABSOLUTE/RUNTIME/relay/cert.pem \
  --key /ABSOLUTE/RUNTIME/relay/key.pem \
  --fingerprint /ABSOLUTE/RUNTIME/relay/fingerprint.sha256 \
  --identity-profile /ABSOLUTE/RUNTIME/relay/relay-webtransport-v1 \
  --proxy-attestation /ABSOLUTE/PRIVATE/PATH/proxy-attestation.tsv \
  --artifact-root /ABSOLUTE/PRIVATE/IMMUTABLE-ARTIFACTS \
  --state-dir /tmp/teremoq-lan-RUN_ID
```

The orchestrator sets `TEREMOQ_DEV_RELAY_LAN_IP_SAN` only in this opt-in run,
passes the same derived `TEREMOQ_DEV_RELAY_PUBLISH_CAPABILITY_FILE` path only to
relay and Gateway, and forces relay 127.0.0.1:4433, Gateway SRT
127.0.0.1:19000, supervisor 127.0.0.1:9080, source output loopback and the
exact UDP/14433 proxy. It never runs the root Compose file. Relay UDP, Gateway
health/SRT, source liveness and proxy readiness must each pass; otherwise the
run is not declared ready and its own child processes are stopped in reverse
order. Runtime metrics contain timestamps and per-component RSS only.
Activation also rechecks exact HEAD, full tracked/untracked cleanliness,
owner-commit ancestry, manifest digest and every executable digest immediately
before launch. The capability sidecar is authorization-bound; its exact private
file, inode, mode and digest are revalidated before relay, before Gateway and
during the run. Missing, replaced, permissive or partial state terminates the
run without revealing the value. Each bound preflight/attestation is read once through one
non-symlink descriptor, size/cardinality bounded and parsed as a closed schema.
Authorization cannot replace its result: any `blocked`, `pending`,
`unavailable`, `unknown`, inherited Docker publication, legacy listener,
server WSL NAT or firewall-property contradiction blocks activation.
The operational owner field in config, authorization, proxy attestation and
capability metadata is closed to `6dadfbd8695bd1d0037568d879563eb83b7567b5`.
Neither the origin hash, another ancestor nor an environment/manual override is
accepted. Patch-id is audit evidence only and is not an activation credential.

Stop only the matching run-id lifecycle:

```bash
infra/lan/stop-lab.sh --config /ABSOLUTE/PRIVATE/PATH/lan.tsv \
  --state-dir /tmp/teremoq-lan-RUN_ID
```

Then execute the separately reviewed elevated firewall rollback and mirrored
rollback, verify both firewall residues are zero, and remove run-owned files:

```bash
infra/lan/rollback-runtime.sh --config /ABSOLUTE/PRIVATE/PATH/lan.tsv \
  --state-dir /tmp/teremoq-lan-RUN_ID
```

Rollback first verifies the exact run/source/owner markers, metadata and inode,
then removes only that run's capability. A partial or foreign capability state
is preserved and rejected for manual investigation rather than deleted.

## 6. Reproducible client package and evidence

`package-client.sh` is deprecated and intentionally fails: no client state,
player, certificate or configuration is packaged or transferred from the
server. Use the native Git clone, Web Git builder and client-local initializer
documented in `client/README.md`.

The sole positive flow is documented in `client/README.md`: native clone of
the explicit Git ref and commit, `Build-LanPlayerFromGit.ps1` from that clean
checkout, then `Initialize-LanClientState.ps1` against the external builder
state. The Web builder alone creates `players/<source_commit>` after two
byte-identical builds; Platform consumes its closed provenance and initializes
only public pin/config/evidence metadata. No PEM, player directory or state is
packaged, copied or transferred from the server.

This versioned boundary is intentionally ready for a later move to
`teremoq-client`: the operator workflow stays the same and only the
repository/ref/subdirectory contract changes. This Platform-only branch
deliberately remains `pending_owner_integration`; preparation fails until the
reviewed nine-key Web launcher and versioned manifest are rebuilt from the
exact clean integrated commit. No 1/5/10/25 start is claimed before that gate
passes.

During each later real level, run the bounded collector on both Windows hosts:

```powershell
.\infra\lan\windows\Collect-Evidence.ps1 -Role Server -RunId RUN_ID `
  -SourceCommit FULL_LOCAL_COMMIT -Level 1 -LocalIPv4 SERVER_EXACT_IP `
  -PeerIPv4 CLIENT_EXACT_IP -DurationSeconds 600 `
  -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE-EXPORT
.\infra\lan\windows\Collect-Evidence.ps1 -Role Client -RunId RUN_ID `
  -SourceCommit FULL_LOCAL_COMMIT -Level 1 -LocalIPv4 CLIENT_EXACT_IP `
  -PeerIPv4 SERVER_EXACT_IP -DurationSeconds 600 `
  -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE-EXPORT
```

Collectors record UTC timestamps, duration, samples, CPU, memory, adapter
bandwidth and ICMP RTT/loss/jitter approximation with explicit provenance.
They write only `EVIDENCE-EXPORT\RUN_ID\level-LEVEL\ROLE-host-evidence.tsv`
plus its SHA-256 sidecar. The Web launcher uses the same deterministic layout
for `player-evidence.tsv`; a manually renamed/moved file, missing sidecar or
wrong run/level path is rejected. They do not claim QUIC transport telemetry.
Progressive gates require exact collector hashes and cross-check measurable result fields; see
`chaos/lan/README.md`.

This two-machine laboratory does not prove HA, production capacity, an SLO or
Internet safety. Before real execution it has measured no player, session,
video, latency, loss, jitter or recovery result.
