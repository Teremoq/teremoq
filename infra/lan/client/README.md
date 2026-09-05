<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Remote LAN client checkout

## Interactive laboratory channel

`Start-LanInteractiveClient.ps1` starts the temporary client agent after a
reviewed Git update. The agent initiates outbound HTTPS only to
`192.168.1.130:18443`, pins the exact temporary certificate fingerprint and
exchanges a one-use pairing code for an in-memory session. It never accepts a
shell command, URL or path from the server. The server can enqueue only the
closed actions `diagnose-build`, `prepare-client`, `preflight`, `player-1`,
`load-5`, `load-10`, `load-25`, `wifi-observe`, `collect` and `stop`.

Progress and bounded diagnostics are written automatically to the server's
private run state. GitHub carries reviewed code only; logs, credentials and
evidence are never uploaded. The channel uses a separate exact TCP/18443
firewall rule and is removed during LAN rollback.

If the server requests `stop` while a test command is running, the agent
terminates that command and its Windows child-process tree before processing
the final stop action. Every action has a five-minute upper bound. Cancellation
waits for and validates `taskkill`, then waits at most another fifteen seconds
for the original child. A failed kill or surviving process produces a terminal
failed status containing the bounded residual PID instead of blocking the
queue indefinitely or claiming successful cleanup.

The launcher requires six SHA-256 values supplied by the approving operator:
its own reviewed file plus Git, Node, npm-cli.js, Windows PowerShell and
taskkill. It opens those files and every tracked file under `infra/lan` and
`supervisor-web` with read-only handles that deny write/delete sharing,
validates executable SHA-256 and source Git blob identity, and keeps all handles
open until the agent exits. Hashes calculated ad hoc by the client are not an
approval manifest.

The LAN client no longer runs from a USB or tarball package. The first action
is a native Git clone of `https://github.com/Teremoq/teremoq` on an explicit
LAN branch ref. No PowerShell file or compatibility file is required before
that clone. Every run-specific or local artifact is initialized on the client,
outside the checkout, after the exact Git commit has been validated.

Current boundary:

- Git checkout: reviewed scripts and support files under the repository root.
- External state root: locally generated `VERSION.tsv`, `LAN-CONFIG.json`,
  `CLIENT-COMPATIBILITY.tsv`, `SHA256SUMS`, the public SHA-256 pin and a copy
  of the player built from the exact Git checkout.
- Evidence root: deterministic per-run output only.

Today the Git boundary points at the monorepo and `infra/lan`; a future move to
`teremoq-client` changes only the explicit URL/ref/subdirectory parameters,
not this operator workflow.

On Windows 10/11, open a native Windows PowerShell console with Git for Windows
already installed. Do not run the preflights from WSL interop: on this host,
`powershell.exe` launched from WSL can lose nested native stdout and is not an
accepted evidence path.

Choose explicit locations outside the checkout first:

```powershell
$StateRoot = 'C:\ABSOLUTE\PRIVATE\teremoq-lan-state'
$CheckoutRoot = 'C:\ABSOLUTE\PRIVATE\teremoq-lan-checkout'
$EvidenceRoot = 'C:\ABSOLUTE\PRIVATE\teremoq-lan-evidence'
```

The checkout and the external state root must remain separate trees. Neither
may contain the other.

The Master-approved client handoff must also provide these lowercase hashes;
they are specific to the reviewed checkout and installed Windows toolchain:

```powershell
$ExpectedLauncherSha256 = 'APPROVED_START_LAUNCHER_SHA256'
$ExpectedGitSha256 = 'APPROVED_GIT_EXE_SHA256'
$ExpectedNodeSha256 = 'APPROVED_NODE_EXE_SHA256'
$ExpectedNpmCliSha256 = 'APPROVED_NPM_CLI_SHA256'
$ExpectedPowerShellSha256 = 'APPROVED_POWERSHELL_EXE_SHA256'
$ExpectedTaskkillSha256 = 'APPROVED_TASKKILL_EXE_SHA256'
```

Do not derive these values from the files immediately before launch: that
would only describe the local bytes and would not establish approval.

## First installation: native Git only

In an empty parent directory, set the public, reviewed values supplied by the
approved LAN integration. `ExpectedCommit` is always the full 40-character
commit. These commands execute no repository script until the clone itself,
its remote, branch, HEAD and clean state have all been checked.

```powershell
$RepositoryUrl = 'https://github.com/Teremoq/teremoq'
$RepositoryRef = 'refs/heads/EXPLICIT_LAN_BRANCH'
$ExpectedCommit = 'FULL_40_CHARACTER_APPROVED_COMMIT'
$RepositorySubdirectory = 'infra/lan'
$Branch = $RepositoryRef.Substring('refs/heads/'.Length)

git clone --origin origin --branch $Branch --single-branch --no-tags `
  $RepositoryUrl $CheckoutRoot
Set-Location $CheckoutRoot
if ((git remote) -cne 'origin') { throw 'unexpected Git remote set' }
if ((git remote get-url origin) -cne $RepositoryUrl) { throw 'unexpected Git remote URL' }
if ((git rev-parse --abbrev-ref HEAD) -cne $Branch) { throw 'unexpected Git branch' }
if ((git rev-parse HEAD) -cne $ExpectedCommit) { throw 'unexpected Git commit' }
if (git status --porcelain=v1 --untracked-files=all) { throw 'checkout is not clean' }
```

Only after the native checks pass, run the combined preparation command from
that exact checkout. It invokes the reviewed Web builder, requires two
byte-identical builds and initializes the compatibility state under the
external `StateRoot`; no player, certificate, configuration or compatibility
file is copied from the server.

```powershell
$RunId = 'lan-EXPLICIT-RUN-ID'
$ServerIPv4 = 'SERVER_EXACT_RFC1918_IP'
$PrefixLength = 24
$Namespace = 'teremoq/live'
$FingerprintSha256 = 'EXACT_64_LOWERCASE_HEX_RELAY_PIN'

& "$CheckoutRoot\infra\lan\client\Prepare-LanClientFromGit.ps1" `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot `
  -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef `
  -ExpectedCommit $ExpectedCommit -RunId $RunId `
  -ServerIPv4 $ServerIPv4 -PrefixLength $PrefixLength -Namespace $Namespace `
  -FingerprintSha256 $FingerprintSha256
```

The builder emits a closed JSON result with `players/<source_commit>` only after
byte-identical builds; Platform resolves that path solely below `StateRoot` and
requires its Web provenance and manifest/launcher hashes. The initializer then
writes the closed v2 compatibility contract and local hashes without executing
the player. The client uses `serverCertificateHashes`, so it needs the exact
SHA-256 pin, not a PEM certificate; no PEM is stored in or required by state.

Subsequent verification refuses the checkout unless:

- `origin` is the only remote;
- the stored fetch/push URL is exactly the approved URL;
- `HEAD` is exactly the approved commit;
- the checkout is clean; and
- the approved support files still exist under the contracted repository
  subdirectory.

Safe updates require the next approved full commit. Git downloads only missing
objects with `fetch`, verifies that exact commit and advances with
`merge --ff-only`. A new external state directory is built for the new commit;
the previous local state is never overwritten and remains available for
rollback.

```powershell
& "$CheckoutRoot\infra\lan\client\Update-LanClient.ps1" `
  -StateRoot $StateRoot -CheckoutRoot $CheckoutRoot `
  -ExpectedCommit 'NEXT_FULL_40_CHARACTER_APPROVED_COMMIT' `
  -NewStateRoot 'C:\ABSOLUTE\PRIVATE\teremoq-lan-state-next'
```

Updates fail closed on a dirty worktree, untracked files, remote URL drift,
branch drift, divergence, a fetched commit different from the approved commit,
or any unexpected checkout layout. A no-op update to the current commit does
not require `NewStateRoot`. The updated player is prepared only after the Git
commit and fast-forward relationship have been validated.

After initialization or update, verify the checkout and the external state
together:

```powershell
& "$CheckoutRoot\infra\lan\client\Verify-Package.ps1" `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot
```

`CLIENT-COMPATIBILITY.tsv` is generated locally and is the compatibility gate
between the client checkout and the approved server run. Its closed keys bind:

- repository URL/ref/subdirectory;
- the exact allowed client commit;
- the exact source commit;
- the player `package_version`;
- the fixed protocol label `teremoq-lan-git-v2`; and
- the versioned player relative path; and
- the SHA-256 of `MANIFEST.sha256.json`, `player/lan-launcher.tsv` and
  `LAN-CONFIG.json`.

In the current monorepo contract, `allowed_client_commit` and `source_commit`
are exactly the same 40-character commit. That keeps the player artifact, LAN
config and reviewed scripts on one clean integration commit. A future
`teremoq-client` split revises only this contract version.

Run the exact client preflight from the Git checkout:

```powershell
& "$CheckoutRoot\infra\lan\windows\Preflight-Client.ps1" `
  -RunId RUN_ID -SourceCommit FULL_INTEGRATED_COMMIT `
  -ServerIPv4 SERVER_EXACT_IP -ClientIPv4 CLIENT_EXACT_IP -PrefixLength PREFIX `
  -NetworkProfile Public -ExpectedWslMode nat `
  -MaximumClockOffsetMs MAX_CLOCK_MS -MinimumMtu MINIMUM_MTU `
  -MinimumCpuCores CLIENT_MIN_CPU -MinimumMemoryMiB CLIENT_MIN_MEMORY_MIB `
  -MinimumDiskMiB CLIENT_MIN_DISK_MIB `
  | Set-Content -Encoding UTF8 C:\ABSOLUTE\PRIVATE\client-preflight.json
```

The preflight requires an approved Node 22.x runtime because the standalone Web
player does not embed Node. A missing or different major version blocks the
run; the scripts never download Node.

Validate the launcher contract without starting any player:

```powershell
& "$CheckoutRoot\infra\lan\client\Invoke-LanLoad.ps1" `
  -Action Validate -RunId RUN_ID -Level 1 `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot
```

Once the previous progressive gate has passed, the exact start commands are:

```powershell
& "$CheckoutRoot\infra\lan\client\Invoke-LanLoad.ps1" `
  -Action Start -ConfirmStart -RunId RUN_ID -Level 1 `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot

& "$CheckoutRoot\infra\lan\client\Invoke-LanLoad.ps1" `
  -Action Start -ConfirmStart -RunId RUN_ID -Level 5 `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot

& "$CheckoutRoot\infra\lan\client\Invoke-LanLoad.ps1" `
  -Action Start -ConfirmStart -RunId RUN_ID -Level 10 `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot

& "$CheckoutRoot\infra\lan\client\Invoke-LanLoad.ps1" `
  -Action Start -ConfirmStart -RunId RUN_ID -Level 25 `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot
```

Status, collection and stop keep the same split roots:

```powershell
& "$CheckoutRoot\infra\lan\client\Invoke-LanLoad.ps1" `
  -Action Status -RunId RUN_ID -Level LEVEL `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot

& "$CheckoutRoot\infra\lan\client\Invoke-LanLoad.ps1" `
  -Action Collect -RunId RUN_ID -Level LEVEL `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot

& "$CheckoutRoot\infra\lan\client\Invoke-LanLoad.ps1" `
  -Action Stop -RunId RUN_ID -Level LEVEL `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot
```

If the browser downloads its observation JSON, keep the exact filename
`local-browser-observation-user-exported.json` and import it with:

```powershell
& "$CheckoutRoot\infra\lan\client\Import-BrowserObservation.ps1" `
  -SourcePath C:\ABSOLUTE\DOWNLOAD\local-browser-observation-user-exported.json `
  -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot `
  -RunId RUN_ID -Level LEVEL
```

The importer opens the file once, locks it against concurrent write/delete,
parses those exact bytes, computes the SHA-256 of those exact bytes and writes
those exact bytes to the deterministic evidence destination. This browser export
is still only `local-browser-observation-user-exported`, not a cryptographic
attestation.

The external state contains no private key, capability, token, password, `.env`,
PEM certificate or server-side configuration. It contains only the exact public
SHA-256 pin needed by WebTransport and locally derived, hash-bound state. No
client script installs trust globally or modifies Windows configuration.
