#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Teremoq contributors
// SPDX-License-Identifier: Apache-2.0

import { spawnSync } from "node:child_process";
import { runProcess, terminateProcessTree } from "../client/Lan-Interactive-Agent.mjs";

function expect(condition, message) {
  if (!condition) throw new Error(message);
}

const invalidPid = await terminateProcessTree(0);
expect(invalidPid.status === "invalid-pid" && invalidPid.exitCode === -1, "invalid taskkill PID was accepted");

const originalSystemRoot = process.env.SystemRoot;
process.env.SystemRoot = "C:\\substituted-windows-root";
let poisonedRootRejected = false;
try {
  await runProcess(process.execPath, ["-e", "process.exit(0)"], process.cwd(), async () => ({}));
} catch {
  poisonedRootRejected = true;
} finally {
  process.env.SystemRoot = originalSystemRoot;
}
expect(poisonedRootRejected, "substituted Windows executable root was accepted");

const failedKill = {
  actionTimeoutMs: 2_000,
  heartbeatMs: 25,
  taskkillFile: process.execPath,
  taskkillArguments: () => ["-e", "process.exit(7)"],
  taskkillTimeoutMs: 1_000,
  terminationTimeoutMs: 2_000,
};
const exited = await runProcess(
  process.execPath,
  ["-e", "setTimeout(() => process.exit(0), 200)"],
  process.cwd(),
  async () => ({ cancel_requested: true }),
  failedKill,
);
expect(exited.code === -1 && exited.signal === "taskkill-failed", "failed taskkill was not terminal");
expect(exited.residualPid === null, "exited child was incorrectly reported as residue");
expect(exited.output.includes("taskkill_exit=7"), "failed taskkill exit was not preserved");
expect(exited.output.includes("termination_reason=cancel-requested"), "cancellation reason was not preserved");

const survived = await runProcess(
  process.execPath,
  ["-e", "setInterval(() => {}, 1000)"],
  process.cwd(),
  async () => ({}),
  { ...failedKill, actionTimeoutMs: 25, heartbeatMs: 10_000, terminationTimeoutMs: 150 },
);
expect(survived.code === -1 && survived.signal === "termination-residue", "survivor was not terminal residue");
expect(Number.isSafeInteger(survived.residualPid) && survived.residualPid > 0, "residual PID was not preserved");
expect(survived.output.includes(`residual_process_pid=${survived.residualPid}`), "residual evidence is incomplete");
if (process.platform === "win32") {
  const cleanup = spawnSync(`${process.env.SystemRoot}\\System32\\taskkill.exe`, [
    "/PID", String(survived.residualPid), "/T", "/F",
  ], { windowsHide: true, shell: false, timeout: 5_000 });
  expect(cleanup.status === 0, "process canary cleanup failed");
  const killed = await runProcess(
    process.execPath,
    ["-e", "setInterval(() => {}, 1000)"],
    process.cwd(),
    async () => ({}),
    { actionTimeoutMs: 25, heartbeatMs: 10_000, terminationTimeoutMs: 2_000 },
  );
  expect(killed.code === -1 && killed.signal === "termination-requested", "successful taskkill was not observed");
  expect(killed.residualPid === null && killed.output.includes("taskkill_exit=0"), "successful termination evidence is incomplete");
} else {
  process.kill(survived.residualPid, "SIGKILL");
}

console.log("lan-interactive-agent-process-test: PASS");
