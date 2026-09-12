<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Selected Core7 runtime — compatibility delta from 107a769

This change is for reviewed local LAN preparation, not a new launcher, channel,
installation mechanism or product activation. The selected runtime is official
Windows x64 PowerShell Core **7.6.6**, invoked by its already-verified absolute
`pwsh.exe` path, with `-NoProfile -NonInteractive`. Installation and compatibility
approval remain separate. Do not replace Windows PowerShell 5.1, modify global
PATH/policies, or retry a failed client operation before reconciliation.

## Boundaries

- Prepare and Initialize require exact Core7.6.6/x64, an actual process image
  matching `PSHOME/pwsh.exe`, and a regular non-reparse executable. This guard
  precedes helper loading, Git probes, layout/archive creation and recovery.
  The Web builder must have its independently reviewed matching runtime delta;
  Platform does not edit or bypass it. Prepare uses the validated current host,
  not a PATH lookup, fallback, new host parameter or automatic relaunch.
- Git install/update/staging, slot management, observation import and Windows
  preflights reject unsupported hosts before dot-sourcing. Historical Desktop5
  remains a separate regression path, not an automatic fallback or the selected
  client procedure. Both entrypoint pairs require Windows x64 and image/PSHOME
  agreement; Core additionally requires exactly 7.6.6.
- Public capture-context schema remains v2: only Desktop/powershell.exe/5 and
  Core/pwsh.exe/7 pairs are admitted. Trusted Explorer termination still needs
  exactly one stable explorer.exe ancestor and no WSL environment indicators.
  Double CIM queries, identity/CreationDate/order, depth and cycle checks remain.
  Existing Desktop interactive ancestry is unchanged; no node→pwsh exception
  is introduced. StartInteractive, Repair and channel sources are not migrated.
- Core JSON parsing uses `ConvertFrom-Json -DateKind String`; timestamp strings
  are validated as strings, never coerced from DateTime or reformatted to make
  evidence pass. Existing bounded descriptor reads and raw-byte hashes remain.
  Transition/manifest version integers admit CLR integral types with exact value
  1, excluding booleans, strings, decimal and floating-point values.
- Win32 argv quoting, concurrent bounded stdout/stderr reads, EOF, exit checks,
  timeout/kill/wait and pinned-file semantics remain unchanged. Empty argv is an
  existing rejected binding case, not a newly claimed supported input.

## Explicit native test procedure

Use a fresh **server test-only** Windows scratch directory with byte-identical,
SHA-256-checked copies of the owner sources and existing fixtures. Run no real
preflight, Prepare, channel, proxy, PKI or audiovisual load. Capture actual
runtime/version/x64, source hashes, exit status and cleanup per test. Invocation
through WSL is test interoperability only, never native preflight provenance.

With `$Pwsh` set to the verified absolute selected runtime and `$Source` to the
native scratch source root, the permitted focused commands are:

```powershell
& $Pwsh -NoProfile -NonInteractive -File "$Source\infra\lan\tests\core7-compatibility-test.ps1"
& $Pwsh -NoProfile -NonInteractive -File "$Source\infra\lan\tests\client-distribution-fixture.ps1" -Core7 -ScriptPath "$Source\infra\lan\client\Client-Distribution.ps1"
& $Pwsh -NoProfile -NonInteractive -File "$Source\infra\lan\tests\client-slot-state-test.ps1"
& $Pwsh -NoProfile -NonInteractive -File "$Source\infra\lan\tests\client-unconfirmed-transition-test.ps1"
& $Pwsh -NoProfile -NonInteractive -File "$Source\infra\lan\tests\Run-GitClientE2E.ps1" -SourceRoot $Source -GitExecutable $VerifiedGit
& $Pwsh -NoProfile -NonInteractive -File "$Source\infra\lan\tests\Run-StageUpdateE2E.ps1" -SourceRoot $Source -GitExecutable $VerifiedGit
```

The Git fixtures allow **file protocol only**, create their own bare repositories
and state, and do not contact GitHub. Copy the existing `.gitattributes` and Web
package manifests unchanged for these fixtures; do not build Web. Record the
exit of every command (PowerShell does not automatically fail an entire command
list on a native nonzero exit). The long transition fixture self-terminates only
its three identified child processes and reconciles synthetic state; do not
substitute any real StateRoot. Shell syntax, Python lab-runtime unit tests and
read-only PowerShell AST parsing are separate checks. No expansive test glob.

The preflight-contract fixture remains a separate Desktop5 mocked regression;
Core7 producer/context cases are explicit in core7-compatibility-test. No
global ExecutionPolicy change is required. Any exceptional test-only process
policy permission must be explicit and cannot override an administrative GPO.

## Limits and deviation record

During this delta's validation an erroneous broad Python test selection ran the
existing proxy and publish-capability fixtures. These opened temporary UDP
loopback sockets and created synthetic certificates/keys/capabilities. This was
reported as an unauthorized expansion of the Core7 focal scope, not counted as
AV or native preflight. The private incident report records observed exits,
subsequent empty UDP/TCP14433 Linux snapshots and the absence of per-path/PID
retrospective inventory; it does **not** certify universal cleanup. Do not repeat
those tests under this authorization. The explicit list above supersedes broad
test discovery for these focales.

Client execution still requires owner reconciliation, reviewed exact integrated
commit and runtime selection, independent Security review, and a fresh bounded
order/lease. A passing fixture does not establish real client compatibility,
native CIM provenance, identity validity, video, health or production readiness.
