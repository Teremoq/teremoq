<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Host-specific server UAC capture warning (PoC)

This opt-in exception addresses only a native Windows Desktop5 elevated process
whose parent has already disappeared: `parent_process_missing`, zero observed
parents, and no WSL environment indicators. It does **not** prove that an absent
parent was Explorer, rewrite the original observation, or admit other ambiguous
origins. Ordinary server/client capture validation is unchanged.

Platform independently measured and approved this one host binary on 2026-09-20:
`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`, SHA-256
`3247bcfd60f6dd25f34cb74b5889ab10ef1b3ec72b4d4b3d95b5b25b534560b8`.
This is a local reviewed binding, **not** a claim to validate Microsoft's
signature, a generic Windows allowlist, or cryptographic host attestation. A
different hash fails closed and needs review, not a caller-supplied override.

## Collection and consumption

Only a future execution can generate the independent evidence. Historical
blocked JSON stays blocked; no retrospective evidence is manufactured.

`Preflight-Lan.ps1` retains the default behavior. With both `-UacRawReportPath`
and `-UacDecisionPath`, Server only, it first writes the original JSON with
CreateNew, UTF-8 without BOM. It then measures, in the same process:

- native Desktop5 x64, elevation and exact System32 executable/hash;
- no visible WSL environment and no reparse/local-path contradiction;
- the collector's own local Git checkout, clean status and exact source commit.

There is no input flag asserting elevation, executable identity or Git identity.
The separately generated closed decision binds the **exact original bytes** by
SHA-256, including every configuration field. Original `capture_origin` and
`preflight_gate` remain `blocked`. Every other material failure still rejects.
The only derived disposition is
`warning:verified-elevated-host-parent-unobserved`, never `pass`.

The raw UTF-8 report is at most 24 KiB; the envelope at most 64 KiB. Both output
paths must be new local regular files under existing non-reparse parents.
Partial failure preserves the original; reconcile it instead of overwriting or
retrying into the same paths. The collector performs no new parent-chain probe.

The runtime and coordination channel use the same `parse_windows_preflight`
gate. Their existing `--server-preflight` argument receives the **derived file**;
their authorization hashes bind that entire envelope. It is read through their
existing bounded readers. Do not pass only its embedded report or relabel it.
Existing manual authorization, exact IP/profile binding, client allowlist,
firewall verification and TLS gates remain required. A capture warning grants
no permission to bind a port or run AV.

## Platform procedure delta (not executed by this change)

Use a reviewed, clean **local Windows Git checkout of this candidate commit**.
The older checkout does not contain this API. Keep the same approved run and
network parameters; set SourceCommit/configuration/authorization to the reviewed
candidate. Do not mix old source bindings. The Web tree and lock are unchanged.

In the existing elevated server procedure, before Firewall Plan/Apply, replace
the old preflight call/write/manual `pass` check with this call. `$preflight`,
`$p` and `$out` are the existing reviewed procedure variables. `$out` is a fresh
private evidence directory. No new launcher or policy change is required:

```powershell
$pf = & $preflight @p -Role Server -ExpectedWslMode mirrored `
    -MaximumClockOffsetMs 2000 -MinimumMtu 1280 -MinimumCpuCores 2 `
    -MinimumMemoryMiB 2048 -MinimumDiskMiB 2048 `
    -UacRawReportPath (Join-Path $out 'server-preflight.json') `
    -UacDecisionPath (Join-Path $out 'server-capture-decision.json')
$decision = ($pf -join "`n") | ConvertFrom-Json
if ($decision.report_kind -cne 'teremoq-server-uac-capture-decision-v1' -or
    $decision.disposition -cne 'warning:verified-elevated-host-parent-unobserved') {
    throw 'Validated server capture decision was not returned; no firewall activation'
}
```

This return is produced only after the shared collector/decision function
validates the fresh report; it is not an instruction to parse an arbitrary
operator-authored file permissively. Do not repeat the old WriteAllText of the
original file. Do not manually change `blocked` to `pass`. Pass the decision file
and its measured hash through the existing authorization/runtime flow. The
minimum disk parameter above matches the coordination channel's existing
2048 MiB binding; an older 1024 MiB invocation remains a mismatch, not a waived
gate. Remaining procedure/firewall code is unchanged and still requires RP's
manual gate and approved window.

If parent capture no longer matches this exact exception, the opt-in decision
rejects. Reconcile the actual observation; do not manufacture the missing-parent
case or use another host. A normally valid report can use the unchanged normal
procedure, not this exception.

## Focused validation and known limitation

From the candidate checkout, without starting any laboratory component:

```text
PYTHONDONTWRITEBYTECODE=1 python3 infra/lan/tests/server-uac-decision-test.py
PYTHONDONTWRITEBYTECODE=1 python3 infra/lan/tests/lab-runtime-test.py
```

On the reviewed local Windows Git checkout, normal Desktop5 policy:

```powershell
& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    -NoProfile -NonInteractive -File `
    (Join-Path $CheckoutRoot 'infra\lan\tests\server-uac-decision-test.ps1')
```

The PowerShell fixture is synthetic and does not call the live collector,
preflight, firewall or network. Its invocation from the Linux worktree via UNC
was refused by signing policy before its body ran. That is **NOT_EXECUTED**, not
PASS, and does not establish whether a legitimate local Git checkout is refused.
No Bypass, policy change, encoded launcher or fixture relocation is prescribed.
Native AST parsing alone is not execution coverage. Live measured collection and
the end-to-end server procedure remain RP validation, outside this source change.
