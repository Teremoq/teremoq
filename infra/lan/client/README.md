<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Remote LAN client package

This directory is copied from the explicit local commit by
`infra/lan/package-client.sh`. The generated package is incomplete unless it
also contains an already-built, reviewed `player/` artifact, the public relay
certificate for inspection, its exact SHA-256 pin, `VERSION.tsv` and
`SHA256SUMS`. Root `LAN-CONFIG.json` is the only player connection input: its
seven public keys (including run and commit) and SHA-256 are closed by
`VERSION.tsv`; the client must not
type or redirect JSON to another address. The launcher resolves it
deterministically as `../LAN-CONFIG.json` from `player/`.

On Windows 10, open a native Windows PowerShell console, verify the archive
SHA-256 before extracting it, then run:

```powershell
$archive = 'C:\ABSOLUTE\PRIVATE\teremoq-lan-client-RUN-COMMIT.tar.gz'
$expected = (Get-Content -LiteralPath "$archive.sha256" -Raw).Split()[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'client archive SHA-256 mismatch' }
# Extract only after this comparison, then change to the extracted package root.
& .\infra\lan\client\Verify-Package.ps1 `
  -PackageRoot (Get-Location).Path
```

First run the exact client preflight from the repository package:

```powershell
& .\infra\lan\windows\Preflight-Client.ps1 `
  -RunId RUN_ID -SourceCommit FULL_INTEGRATED_COMMIT `
  -ServerIPv4 SERVER_EXACT_IP -ClientIPv4 CLIENT_EXACT_IP -PrefixLength PREFIX `
  -NetworkProfile Public -ExpectedWslMode nat `
  -MaximumClockOffsetMs MAX_CLOCK_MS -MinimumMtu MINIMUM_MTU `
  -MinimumCpuCores CLIENT_MIN_CPU -MinimumMemoryMiB CLIENT_MIN_MEMORY_MIB `
  -MinimumDiskMiB CLIENT_MIN_DISK_MIB
```

The preflight requires an approved Node 22.x runtime because the Web standalone
does not embed Node. A missing or different major version blocks the run; the
scripts never download or install Node. Loopback TCP/3000 is also reserved and
must be free before `Start`.

Validate the owner launcher contract without starting a player:

```powershell
& .\infra\lan\client\Invoke-LanLoad.ps1 `
  -Action Validate -RunId RUN_ID -Level 1 -PackageRoot (Get-Location).Path `
  -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE
```

Once TP-WEB-REALTIME has supplied the checksum-bound contract and the previous
progressive gate has passed, the exact start commands are:

```powershell
# One real player for at least 10 minutes; only this level includes manual Wi-Fi recovery.
.\infra\lan\client\Invoke-LanLoad.ps1 -Action Start -ConfirmStart -RunId RUN_ID -Level 1 `
  -PackageRoot (Get-Location).Path -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE
# After accepted level 1, choose only the next lightweight-session line for the current run.
.\infra\lan\client\Invoke-LanLoad.ps1 -Action Start -ConfirmStart -RunId RUN_ID -Level 5 `
  -PackageRoot (Get-Location).Path -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE
.\infra\lan\client\Invoke-LanLoad.ps1 -Action Start -ConfirmStart -RunId RUN_ID -Level 10 `
  -PackageRoot (Get-Location).Path -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE
.\infra\lan\client\Invoke-LanLoad.ps1 -Action Start -ConfirmStart -RunId RUN_ID -Level 25 `
  -PackageRoot (Get-Location).Path -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE
```

Status, evidence collection and exact run-id stop are:

```powershell
.\infra\lan\client\Invoke-LanLoad.ps1 -Action Status -RunId RUN_ID -Level LEVEL `
  -PackageRoot (Get-Location).Path -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE
.\infra\lan\client\Invoke-LanLoad.ps1 -Action Collect -RunId RUN_ID -Level LEVEL `
  -PackageRoot (Get-Location).Path -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE
.\infra\lan\client\Invoke-LanLoad.ps1 -Action Stop -RunId RUN_ID -Level LEVEL `
  -PackageRoot (Get-Location).Path -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE
```

If the reviewed browser UI can only download its observation JSON, rename no
arbitrary file: export it with the exact name
`local-browser-observation-user-exported.json`, then run:

```powershell
.\infra\lan\client\Import-BrowserObservation.ps1 `
  -SourcePath C:\ABSOLUTE\DOWNLOAD\local-browser-observation-user-exported.json `
  -PackageRoot (Get-Location).Path -EvidenceRoot C:\ABSOLUTE\PRIVATE\EVIDENCE `
  -RunId RUN_ID -Level LEVEL
```

The importer checks a closed JSON schema and run/commit/level binding, writes
only the deterministic run/level destination and a raw SHA-256 sidecar. This
is explicitly a `local-browser-observation-user-exported` observation, not a
cryptographic attestation; by itself it cannot pass the progressive gate.

Run the packaged player only on client loopback using the reviewed
TP-WEB-REALTIME artifact. Its final nine-key `player/lan-launcher.tsv`, launcher
and closed manifest must be built from the same clean integration commit passed
to `package-client.sh`; this Platform-only branch does not integrate Web and
therefore remains `pending_owner_integration`. A missing or stale integrated
artifact fails packaging and no 1/5/10/25 level may be claimed.
`http://localhost` is the browser secure-context exception; a LAN HTTP origin
is not. Chrome/Edge then initiates outbound UDP/14433 to the exact server
address recorded in `VERSION.tsv`. Windows 10 WSL2 stays NAT and initiates only
outbound traffic.
Native PowerShell preflight output is the only accepted evidence source on this
host. Running the preflight via WSL `powershell.exe` interop is not a valid
collection path because nested native stdout can be incomplete.

The ready package is accepted only when the exact nine-key launcher contract,
its `source_commit`, launcher SHA-256 and the closed standalone manifest all
match `VERSION.tsv`. `Collect` must export
`EVIDENCE\RUN_ID\level-LEVEL\player-evidence.tsv` plus its SHA-256 sidecar;
arbitrary or manually moved evidence is not ingested.

Level 1 is the sole rendered player gate: it requires real frames, media
objects and RX-to-canvas p95. Levels 5/10/25 are lightweight MoQT sessions and
must report render fields as `not_available`, while still proving positive
objects, exact peak sessions and at least 600 seconds. The single allowed
client IP is only a firewall scope; authenticated viewers remain
`not_measured` and are never inferred from session count.

The package contains no private key, password, token, `.env` or client
identity. The relay leaf certificate and fingerprint are public inspection/pin
material only. The script never installs a CA or modifies Windows trust. No
player, session, video, latency or recovery result is real until separately
measured and accepted by the progressive gate.
