#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
agent="${ROOT}/client/Lan-Interactive-Agent.mjs"
launcher="${ROOT}/client/Start-LanInteractiveClient.ps1"
control="${ROOT}/interactive-channel-control.sh"
channel="${ROOT}/interactive_channel.py"
firewall="${ROOT}/windows/Firewall-Lan.ps1"

grep -Fq 'C:\\Program Files\\Git\\cmd\\git.exe' "${agent}"
grep -Fq 'C:\Program Files\Git\cmd\git.exe' "${launcher}"
grep -Fq 'node_modules\\npm\\bin\\npm-cli.js' "${agent}"
! grep -Fq 'runProcess("npm.cmd"' "${agent}"
grep -Fq 'taskkill.exe' "${agent}"
grep -Fq 'taskkill_status=' "${agent}"
grep -Fq 'termination-residue' "${agent}"
grep -Fq 'residual_process_pid=' "${agent}"
grep -Fq '[Parameter(Mandatory = $true)][string]$ExpectedCommit' "${launcher}"
! grep -Fq 'ExpectedLauncherSha256' "${launcher}"
grep -Fq 'Get-TeremoqProtectedExecutableSha256' "${launcher}"
grep -Fq -- "'--taskkill-sha256'" "${launcher}"
grep -Fq '[IO.FileShare]::Read' "${launcher}"
grep -Fq 'Get-TeremoqStreamGitBlobId' "${launcher}"
grep -Fq "'ls-tree','-r','--full-tree'" "${launcher}"
grep -Fq 'cancel_requested' "${channel}"
grep -Fq 'daemon-start' "${control}"
grep -Fq 'daemon-stop' "${control}"
grep -Fq 'channel-process.json' "${channel}"
! grep -Fq 'channel.pid' "${control}"
! grep -Fq 'nohup' "${control}"
! grep -Fq 'rm -f' "${control}"
! grep -Fq 'tail -n' "${control}"
! grep -Fq '${state_root}/' "${control}"
grep -Fq -- '--confirm-start' "${control}"
grep -Fq -- '--confirm-authorize' "${channel}"
! grep -Eq 'start\|enqueue\|status\|stop\|cleanup|^[[:space:]]*cleanup\)' "${control}"
grep -Fq "CoordinationTlsPort -notin @(0, 18443)" "${firewall}"
grep -Fq 'RemoteAddress = $ClientIPv4' "${firewall}"

printf 'lan-interactive-channel-policy-test: PASS\n'
