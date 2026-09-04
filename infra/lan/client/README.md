<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Remote LAN client checkout

The LAN client no longer runs from a USB or tarball package. Code comes only
from a reviewed Git checkout of `https://github.com/Teremoq/teremoq` on an
explicit LAN branch ref, while every run-specific or local artifact stays
outside that checkout in a separate state directory.

Current boundary:

- Git checkout: reviewed scripts and support files under the repository root.
- External state root: `VERSION.tsv`, `LAN-CONFIG.json`,
  `CLIENT-COMPATIBILITY.tsv`, `SHA256SUMS`, `public-identity/` and `player/`.
- Evidence root: deterministic per-run output only.

The versioned compatibility contract already carries
`repository_url`, `repository_ref` and `repository_subdirectory`. Today it
points at the monorepo and `infra/lan`; a future move to `teremoq-client`
changes that contract boundary instead of changing the operator workflow.

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

Initial installation uses the approved Git ref from
`CLIENT-COMPATIBILITY.tsv`:

```powershell
& .\infra\lan\client\Install-LanClient.ps1 `
  -StateRoot $StateRoot -CheckoutRoot $CheckoutRoot
```

The script clones only from the approved repository URL and explicit
`refs/heads/*` LAN ref, then refuses the checkout unless:

- `origin` is the only remote;
- the stored fetch/push URL is exactly the approved URL;
- `HEAD` is exactly the approved commit;
- the checkout is clean; and
- the approved support files still exist under the contracted repository
  subdirectory.

Safe updates use only `git fetch` plus validation plus `git merge --ff-only`:

```powershell
& "$CheckoutRoot\infra\lan\client\Update-LanClient.ps1" `
  -StateRoot $StateRoot -CheckoutRoot $CheckoutRoot
```

Updates fail closed on a dirty worktree, untracked files, remote URL drift,
branch drift, divergence, a fetched commit different from the approved commit,
or any unexpected checkout layout. No downloaded code is executed before that
validation passes.

After installation or update, verify the checkout and the external state
together:

```powershell
& "$CheckoutRoot\infra\lan\client\Verify-Package.ps1" `
  -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot
```

`CLIENT-COMPATIBILITY.tsv` is the compatibility gate between the client checkout
and the approved server run. Its closed keys bind:

- repository URL/ref/subdirectory;
- the exact allowed client commit;
- the exact source commit;
- the player `package_version`;
- the fixed protocol label `teremoq-lan-git-v1`; and
- the SHA-256 of `MANIFEST.sha256.json`, `player/lan-launcher.tsv` and
  `LAN-CONFIG.json`.

In the current monorepo contract, `allowed_client_commit` and `source_commit`
must be exactly the same 40-character commit. That keeps the player artifact,
the LAN config and the reviewed scripts on one clean integration commit. A
future `teremoq-client` split would revise only this contract version.

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

The external state contains no private key, capability, token, password, `.env`
or server-side configuration. The relay leaf certificate and SHA-256 pin are
public inspection material only. No client script installs trust globally or
modifies Windows configuration.
