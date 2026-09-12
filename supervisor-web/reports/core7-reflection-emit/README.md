<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Core7 Reflection.Emit — owner focal passed, Security review pending

## Finding first

Task05's composition of `e1e6bdee313c9bb68bef0d1f51f7300494687338`
passed Prepare without a new build and Supersede, but failed ValidateOnly before
validation at `teremoq-lan-platform.ps1:66`: the AppDomain instance method
`DefineDynamicAssembly` is not available on the selected Core7 runtime.
The packaged launcher SHA-256 was
`b85e762b7e639efc8d81805918df607987f9dc476da9e552714aca7343113082`.
That failed composition, its recovery and the previous artifact remain intact.

This separate owner worktree starts at that exact commit. No source edit or test
was performed while RP's recovery was active. RP explicitly closed recovery
before this delta was prepared. No rebuild is authorized by this assignment.

## Minimal source changes

- Use `Reflection.Emit.AssemblyBuilder.DefineDynamicAssembly` in process.
  AssemblyBuilderAccess.Run, module/type names, CreateType, the kernel32 entry
  point, SafeFileHandle argument, uint32 return/arguments, Unicode, Winapi and
  PreserveSig remain unchanged. No Add-Type, compiler or subprocess is added.
- Preserve JSON strings through Core7's `-DateKind String`, matching the
  reviewed Platform JSON boundary without importing Platform at product runtime.
- Five schema fields on the same ValidateOnly path accept only CLR Int32 or
  Int64 and still require value 1. Core7's integer representation must not be
  confused with a coercible string, boolean or floating-point value. Existing
  byte/cardinality/value limits and other integer checks remain unchanged.
- Update only the versioned launcher template hash. A future authorized
  packaging run computes the new real contract; no existing artifact is edited.

No changes to P/Invoke signature, descriptors, sharing modes, retention/finally,
hash/identity bindings, canonical paths, reparse rejection, inventory, actions,
start/stop/collect code, player, PKI, Platform or dependencies.

## Same-path runtime audit

Reviewed every call before the ValidateOnly return: Reflection.Emit creation,
SafeFileHandle P/Invoke, SHA256, strict UTF-8, FileStream reads/EOF, canonical
JSON/TSV, URI/IP parsing, arithmetic, file inventory and final receipt/finally.
The AppDomain factory and Int32-only JSON schema checks were the obvious legacy
runtime dependencies addressed. The explicit string JSON policy avoids implicit
DateTime conversion. Other calls and limits are left intact and were exercised
by the real Core7 path in the existing harness.

The later Start/Read-State/collect paths are outside the tested static boundary;
their runtime behavior, ports, readiness, PID recovery and audiovisual behavior
are NOT approved by this correction or its ValidateOnly tests.

## Executed focal and evidence limits

RP opened a new window on 2026-09-12, 18:22:15–18:34:15 UTC, limited to ONE
PowerShell harness execution. The existing `scripts/test-managed-launcher.ps1`
ran under selected Windows x64 Core7 7.6.6 in a new private native source copy.
It copies the exact launcher bytes into a sealed test package, uses the real
unchanged Platform slot producer, and invokes the full packaged-path launcher
with `-Action Start -ValidateOnly` for levels 1/5/10/25. Product-shaped JS files
are deliberately non-executable fixtures, not a traced standalone or built player.
No Start action without ValidateOnly, Node probe, port probe, PKI or actual
Prepare/Restore occurs. No accepted old artifact is relabelled or resealed.

Existing negative cases, no-file/no-environment-effect checks and retained-pin
write-denial/release checks remain. New cases cover Core7's actual Int64/string
JSON representation and reject strings, float 1.0 and booleans in all five schema
fields. The harness traps Add-Type as well as Start-Process and Get-Command on
the validation path. Supplemental Vitest tests guard native signature stability
and template hash consistency; these are structural/unit tests, not E2E.

### Result: 55 PASS, exit 0, stderr empty

One invocation started at `2026-09-12T18:24:30.4883009Z` and reached exit/stream
EOF at `18:25:57.0024471Z`. The existing Platform bounded native-process helper
limited it to 240,000 ms and 131,072 bytes per output stream. Actual stdout was
2,223 bytes; stderr was empty. Parent and child used `-NoLogo -NoProfile
-NonInteractive`, without ExecutionPolicy overrides or Bypass. The parent helper
has its existing Add-Type initialization; the child did not load that helper and
its Add-Type/Start-Process/Get-Command traps remained installed.

The 55 checks include all four accepted levels, actual Core7 Int64/string JSON
representation, retained descriptor write denial and release, existing closed
contract/pin/inventory/size negatives, and 15 new adversarial cases rejecting
string, boolean and float schema tokens across all five fields.
[core7-result.json](core7-result.json) is the exact result with CRLF normalized
to LF only; it contains no fixture configuration or operational evidence.

The native command was equivalent to the following invocation, executed ONCE
through `Invoke-TeremoqBoundedNativeProcess` using the selected absolute Core7
path and native-copy working directory (not directly as an unbounded process):

```powershell
pwsh.exe -NoLogo -NoProfile -NonInteractive -File supervisor-web/scripts/test-managed-launcher.ps1 -OutputRoot <new-native-copy>/supervisor-web/evidence/core7-emit-focal
```

An initial orchestration JavaScript syntax error occurred before evaluation or
any process invocation. Correcting command serialization did not retry the
harness. No product or test source was edited during the focal.

### Private raw evidence and closure

The retained native scratch is named `teremoq-web-core7-emit.qWPIHu` in the
owner's native temporary directory; its full private path was sent to RP and
Security. It contains only the four copied sources, generated fixtures and
execution/closure evidence, without Git metadata or dependencies. Source/copy
hashes and the selected runtime hash matched before and after execution:

| Input | SHA-256 |
| --- | --- |
| Web launcher | `41c69bf4b8126fb468d69cd609428cb0d3b7877b69cb673f80f993e6ef3bec93` |
| Web harness | `b8890d2407b82ef2b689b087822010136d2316216ecf1b2a957ea3d0334fc8fe` |
| Unchanged Platform slot producer | `ffad87d3d4fdb4f54aa3c62828c02307298f10560912616d9735443d13a62755` |
| Unchanged Platform outer-process helper | `414cefd46784728b3b19966e080c2c27438b8962b87cdb21746b94210820d8cb` |
| Selected Core7 executable | `bfb46af89433268872ddb43d1ca7a3f433452ee91ed356a9786940f90118e285` |

| Raw evidence | SHA-256 |
| --- | --- |
| `supervisor-web/evidence/core7-emit-focal/result.json` | `5a467136b014c92397afb7df3990041a427b74936eafc4e53927add53c118320` |
| `opening.json` | `77a112a4082d7bdfcb908aceb4d7550c508b78531199749cc886b146287e84f1` |
| `execution.json` | `54e65d4585b024a66635bc2ccfd949027663dbb9b6fc31790e696438e343567e` |
| `harness.stdout.log` | `90eeeddc50e9be6ddb08f3c4c0d134aeb295dbb913f113f4b79e6a37c0a084ec` |
| `harness.stderr.log` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `harness.exit.txt` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `process-observation.json` | `5ee631a3f70324196cc4c562017f5585c70ea066ef2d047b98fb205cc46f1c74` |
| `process-closure.json` | `72073931a5ba647ebe68197176911795849a672bef9a6e844d4ef522dce1ad4f` |

The final own-process query at `18:26:25.5907306Z` found zero remaining recorded
PID/start-time identities (three had been observed), direct children or native
scratch markers, excluding the current observer. All tool processes subsequently
reached EOF. No process was killed. This is bounded own-process evidence, not
hard-tree containment, a census of transient children, global cleanup or an
empty TEMP claim. RP independently read/checked the result, execution, output,
opening and closure and explicitly closed/released the reservation. Fixtures,
old artifacts, failed composition and recovery evidence are retained intact.

## Gates, pathset and next authority

- Executed: one real Core7 full ValidateOnly fixture focal, 55 PASS; local
  `git diff --check` PASS. No dependencies or lock changes.
- Not executed in this delta: Vitest (including the new structural regression),
  lint, tsc, npm audit, build, build:lan or package:lan. RP explicitly excluded
  supplementary tests and builds from this window; earlier results must not be
  presented as results for these changed bytes. No network audit was attempted.
- Source pathset: `scripts/teremoq-lan-platform.ps1`,
  `scripts/test-managed-launcher.ps1`, `lan-launcher.tsv`,
  `src/lib/lan-lab/managed-launcher.test.ts`, and this report/result directory,
  all inside `supervisor-web/**`. Platform source was read/copied unchanged,
  never edited. The immutable base remains `e1e6bdee313c9bb68bef0d1f51f7300494687338`.
- Security delta review is REQUIRED and pending. Protected/stable runtime,
  DLLs and ancestors remain a Platform prerequisite; hash-to-path execution is
  not atomic. Validation does not authorize later mutable or audiovisual paths.

Status: **READY FOR MASTER / TP-SEC-PKI SOURCE REVIEW**, not artifact/composition
acceptance. The source change changes the Web tree and player identity. Only a
separately authorized future campaign may build/package that identity. The old
identity `7e82…` cannot become corrected by updating metadata. Zero rebuild,
publication, push, remote resources, credentials, real Start or ports in this
delta. No new profile, task, framework or channel was introduced.
