<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# CORE7-WEB-PATH-01 — transitive Windows path policy

## Finding and scope

The source composition `8ef8325d15a6b1ad061186993d379656e9368575`
failed before npm/build: the Core7 wrapper removed PS5 from PATH, but the Node
path policy still invoked `powershell.exe`. The earlier wrapper fixtures did
not exercise this valid transitive path. Their PASS does not close this finding.
The failed campaign executed zero builds; it must not be retried or reused as
artifact evidence without a newly reviewed composition and explicit authority.

This delta changes only the Web wrapper, its Node/PowerShell policy boundary,
the existing npm environment allowlist and focal fixtures. It does not change
the player, client, Platform helper, network, dependencies, lock or build mode.

## Runtime boundary

`TEREMOQ_WEB_POWERSHELL_HOST` is an internal selection derived from the wrapper's
validated current Core7 host, not an operator override. An inherited selection
must match exactly (empty/different values reject before effects). The wrapper
restores the previous value in `finally`. npm isolation propagates only this
exact key after lexical validation, never a family of overrides or an env hash.
Node rejects missing/malformed selection; there is no PATH lookup or PS5 fallback.

Before each native policy call, Node checks the runtime's ancestry and realpath
without recursively calling the policy, opens the regular executable, limits
the read to its verified size plus one byte (maximum file size 1 MiB), checks EOF
and descriptor/path identity, then compares SHA-256 with the reviewed constant
`bfb46af89433268872ddb43d1ca7a3f433452ee91ed356a9786940f90118e285`.
The descriptor closes in `finally`, including failures. The native policy also
requires Core 7.6.6 / Windows / X64, the selected current image and non-reparse
runtime ancestry before loading its unchanged target-path native checks.

**Residual boundary:** an open descriptor plus hash is not an atomic
hash-to-pathname-execution pin. Platform must keep the reviewed runtime and its
ancestors protected and stable, including the runtime libraries. This change
does not claim ACL ownership, prevention of a privileged replacement race, or
process-tree containment.

The child policy retains its **existing** `-ExecutionPolicy Bypass` argument;
no Bypass is added to the exterior invocation, no system/GPO policy is changed,
and no TLS bypass is involved. Runtime execution of this child requires the
explicit focal authority. Existing 30-second / 16-KiB subprocess limits and
target-path pin/reparse checks remain. Empty/multiline/wrong stdout rejects.

## Focal reproduction (not a build or LAN measurement)

Use the Platform-selected official Core7 runtime and Node 22 on SERVER only,
inside a newly opened focal window. Copy exact source bytes to a private native
Windows scratch with **no `.git` in any ancestor**, plus the unchanged reviewed
`infra/lan/client/Client-Distribution.ps1`. Use a private dependency copy for
Vitest/tsc/lint; do not modify the original snapshot. The harness refuses the
full-wrapper valid-argument fixture on any Git checkout, preventing a build.

Invoke existing `scripts/test-build-lan-core7.ps1` through the existing bounded
native-process helper with a 240-second exterior timeout. It runs the previous
argv/guard/contract fixtures, real wrapper error/environment restoration for
absent and exact selection, and `scripts/test-core7-path-policy.mjs` (180-second
parent maximum). The Node canary uses the exact wrapper PATH, proves PS5 absent,
and tests direct policy, actual Node child after npm isolation, missing/invalid
selection, altered/oversized executable, junctions and real subprocess failures.
Only the sibling policy bodies in the last five negative fixtures are replaced;
their consumer module is copied unchanged. They test output/error/timeout
handling, not production-policy acceptance. The existing native reparse harness
is reused separately under Core7.

The full-wrapper no-Git rejection exercises the production Node path policies
before the existing redacted Git rejection and before StateRoot creation. It
does not execute npm ci/build/package, change Git, start a player or open a port.

## First focal — incomplete, retained

[attempt-1.json](attempt-1.json) records the exact authorized hashes, structured
tool results and diagnostic payload. This is an owner transcription, not an
independent attestation or a raw terminal recording. The authorized window was
2026-09-12 17:04:15–17:16:15 UTC; execution started at 17:04:49 and the final
scoped process query ended at 17:09:33.6632700 with zero matching processes.
Every tool session reached EOF; this is not process-tree containment.

Node's ten real path-policy checks passed, as did 36 Vitest tests (three files)
and focal lint. The full harness failed with the inherited-selection rejection.
The separately authorized ten-second Core7 diagnostic demonstrated that calling
`SetEnvironmentVariable(key, $null, 'Process')` through PowerShell leaves an
existing empty string, just like `string.Empty`. The absence fixture therefore
supplied an invalid empty selection. This also exposed a genuine restoration
defect in the delta, not merely a fixture problem. After focal closure, both
wrapper and harness were corrected to remove only the exact internal variable
when restoring absence; the guard still rejects inherited empty selections.

`tsc --noEmit` exited 2 because the source-only scratch lacked Next's generated
`LayoutProps` definition. The original workspace already contains this in
`.next/types/routes.d.ts`; the next focal must copy and hash the existing
generated declarations and `next-env.d.ts`, without changing application types
or generating a build. This first tsc result remains a failure, not a PASS.

## Second focal — owner validation passed, Security gate pending

RP opened a fresh window 17:13:45–17:25:45 UTC. The six earlier source files
were preserved in the private native scratch before replacing the two changed
files. All six source/copy hashes and the runtime hash were checked before and
after execution. No source was edited during the tests. The last scoped query
ended at 17:16:22.8870463 UTC with zero matching processes and all tool sessions
at EOF. The remaining reservation is not reused.

- [attempt-2-harness.json](attempt-2-harness.json): 20 checks, exit 0, empty
  stderr. Includes the actual wrapper reaching the redacted no-Git error after
  real path validation, exact restoration of absent/present environment, and
  unchanged argv, native reparse and closed JSON contracts. The alternative
  runtime versions/architectures in its list are predicate fixtures, not claims
  of executing those runtimes.
- [attempt-2-node.json](attempt-2-node.json): ten real Node/Core7 checks inside
  that harness, not an additional ten independent full-harness tests.
- Vitest 4.1.11: `node node_modules/vitest/vitest.mjs run
  src/lib/lan-lab/path-security.test.ts src/lib/lan-lab/npm-isolation.test.ts
  src/lib/lan-lab/distribution-contract.test.ts`; 36/36 passed, three files
  (6/7/23), exit 0, empty stderr. This is focal coverage, not the full suite.
- `node node_modules/typescript/bin/tsc --noEmit`: exit 0, empty stdout/stderr.
- `node node_modules/eslint/bin/eslint.js scripts/path-security.mjs
  scripts/npm-isolation.mjs scripts/test-core7-path-policy.mjs
  src/lib/lan-lab/path-security.test.ts src/lib/lan-lab/npm-isolation.test.ts
  src/lib/lan-lab/distribution-contract.test.ts`: exit 0, empty stdout/stderr.
- `git diff --check`: exit 0. No npm ci, Next, build, package, audit network call,
  LAN run, player, listener, credential, publication, push or deployment action.
  These omitted campaigns are outside this minimal corrective assignment;
  earlier results are not relabelled as current build/audit evidence.

Commands ran through the unchanged Platform bounded process helper with maximum
240/180/90/60-second limits described above, using existing native Node 22.23.2
and Core7 7.6.6. npm 10.9.8 was probed by the real wrapper, not installed.

The raw harness report in the private scratch has SHA-256
`ea0c6411783ff9197b031d0619ab35f619fedc452841273ef90960c70a5e8856`.
Its versioned copy only normalizes CRLF to LF. The Node report retains its bytes,
SHA-256 `84f426c390f7758b25b195cb6f87dcfc8129a3196473438bc6bb4af250b6d4ab`.

### Existing TypeScript inputs — not build evidence

The five files below were already present under `supervisor-web` in the owner
worktree, copied unchanged into the same relative paths of the private native
scratch and hash-checked. They were not generated during this assignment or
added to Git. No application type or TS compiler option was weakened.

| Existing input | SHA-256 (source and copy) |
| --- | --- |
| `next-env.d.ts` | `1862ac4bbbc5192d4bf562161df66ea547ed3e67173100656ab606ae9797db2b` |
| `.next/types/routes.d.ts` | `9d9e0c9337d067afcc31c6952ff1d02c223d779bb2a6e92705f3922900332cab` |
| `.next/types/root-params.d.ts` | `f3387dd7800eec3c34273f7a8efad13e864598c7e8f788d321e407390989bb59` |
| `.next/types/validator.ts` | `83a08ff4511b28597100c9357d3872a398f81c8eba1eb630cd9e12917f8c2f3e` |
| `.next/types/cache-life.d.ts` | `4f984436b10cfb43ccf7fc3114dcb851cbefa4d58b7d8ae741aaae0f6e330129` |

Security's independent review of the final commit remains required. Owner
focal PASS is not SOURCE approval, a new integrated build, an artifact, an
audiovisual result or permission to repeat the failed build campaign. Task 05
must compose reviewed source separately; RP controls any later execution.
