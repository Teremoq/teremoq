#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Teremoq contributors
// SPDX-License-Identifier: Apache-2.0

import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { confirmUpdateTransition, execute, formatLocalStatus, parseArguments, restartUpdatedClient, runProcess, terminateProcessTree } from "../client/Lan-Interactive-Agent.mjs";

function expect(condition, message) {
  if (!condition) throw new Error(message);
}

const poisonedCheckout = fs.mkdtempSync(path.join(os.tmpdir(), "teremoq-ignored-runtime-"));
try {
  const ignoredNext = path.join(poisonedCheckout, "supervisor-web", "node_modules", "next", "dist", "bin");
  const executionMarker = path.join(poisonedCheckout, "ignored-runtime-executed");
  fs.mkdirSync(ignoredNext, { recursive: true });
  fs.writeFileSync(path.join(ignoredNext, "next"), `require("node:fs").writeFileSync(${JSON.stringify(executionMarker)}, "executed")\n`);
  let removedBuildRejected = false;
  try {
    await execute("diagnose-build", { checkout: poisonedCheckout }, async () => ({}));
  } catch (error) {
    removedBuildRejected = error.message === "action is not approved";
  }
  expect(removedBuildRejected, "removed diagnose-build action was not rejected before execution");
  expect(!fs.existsSync(executionMarker), "ignored node_modules code was executed");
} finally {
  fs.rmSync(poisonedCheckout, { recursive: true, force: true });
}

const invalidPid = await terminateProcessTree(0);
expect(invalidPid.status === "invalid-pid" && invalidPid.exitCode === -1, "invalid taskkill PID was accepted");
expect(
  formatLocalStatus("prepare-client", "running", 1) ===
    "[Teremoq] Paso 1 - Preparar y verificar el cliente: en ejecucion",
  "local progress is not deterministic",
);
let arbitraryStatusRejected = false;
try { formatLocalStatus("prepare-client", "C:\\secret", 1); } catch { arbitraryStatusRejected = true; }
expect(arbitraryStatusRejected, "arbitrary local status text was accepted");
const nodeSha256 = crypto.createHash("sha256").update(fs.readFileSync(process.execPath)).digest("hex");
const agentArgv = [
  "--server", "https://192.168.1.130:18443", "--fingerprint", "1".repeat(64),
  "--run-id", "lan-argv-canary", "--source-commit", "2".repeat(40),
  "--client-commit", "2".repeat(40), "--credential-mode", "pair", "--checkout", "C:\\source", "--state-root", "C:\\state",
  "--evidence-root", "C:\\evidence", "--git-sha256", "3".repeat(64),
  "--node-sha256", "4".repeat(64), "--npm-cli-sha256", "5".repeat(64),
  "--powershell-sha256", "6".repeat(64), "--taskkill-sha256", "7".repeat(64),
];
const parsedArgv = parseArguments(agentArgv);
expect(agentArgv.length === 28 && Object.keys(parsedArgv).length === 14, "closed agent argv cardinality drifted");
expect(parsedArgv["--taskkill-sha256"] === "7".repeat(64), "taskkill session hash was not parsed");
expect(parsedArgv["--credential-mode"] === "pair", "credential mode was not parsed");
const resumedArgv = [...agentArgv];
resumedArgv[resumedArgv.indexOf("pair")] = "session";
expect(parseArguments(resumedArgv)["--credential-mode"] === "session", "session resume mode was rejected");
const restartSource = restartUpdatedClient.toString();
expect(!restartSource.includes('"--session"') && !restartSource.includes("SESSION="), "session credential can reach child argv or environment");
expect(restartSource.includes('stdio: ["pipe", "ignore", "ignore"]') && restartSource.includes("credential handoff timed out"),
  "session handoff is not bounded to the private stdin pipe");
const channelCommit = "8".repeat(40);
const targetCommit = "9".repeat(40);
const transitionIdentity = { schema_version: 1, run_id: "lan-transition", source_commit: channelCommit, client_commit: channelCommit };
const transitionTask = { sequence: 1, action: "update-client" };
let transitionCalls = 0;
const reconciled = await confirmUpdateTransition(async (route, body) => {
  transitionCalls += 1;
  if (transitionCalls === 1) throw new Error("simulated lost terminal response");
  expect(route === "/v1/poll" && body.client_commit === targetCommit, "ambiguous transition did not probe the target identity");
  return { schema_version: 1, run_id: transitionIdentity.run_id, source_commit: channelCommit,
    client_commit: targetCommit, sequence: 0, action: "wait", parameters: {} };
}, transitionIdentity, transitionTask, "a".repeat(64), targetCommit, 2, "complete");
expect(reconciled.client_commit === targetCommit && transitionCalls === 2, "lost update response was not reconciled safely");
let extraArgRejected = false;
try { parseArguments([...agentArgv, "--extra", "forbidden"]); } catch { extraArgRejected = true; }
expect(extraArgRejected, "agent accepted an extra argv pair");
const rejectedTaskkill = await terminateProcessTree(123, {
  taskkillFile: process.execPath,
  taskkillSha256: "0".repeat(64),
});
expect(rejectedTaskkill.status === "verification-failed", "taskkill verification exception escaped");

const originalSystemRoot = process.env.SystemRoot;
process.env.SystemRoot = "C:\\substituted-windows-root";
let poisonedRootRejected = false;
try {
  await runProcess(process.execPath, ["-e", "process.exit(0)"], process.cwd(), async () => ({}), {
    expectedFileSha256: nodeSha256,
  });
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
  expectedFileSha256: nodeSha256,
  taskkillSha256: nodeSha256,
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
  const taskkill = `${process.env.SystemRoot}\\System32\\taskkill.exe`;
  const taskkillSha256 = crypto.createHash("sha256").update(fs.readFileSync(taskkill)).digest("hex");
  const cleanup = spawnSync(taskkill, [
    "/PID", String(survived.residualPid), "/T", "/F",
  ], { windowsHide: true, shell: false, timeout: 5_000 });
  expect(cleanup.status === 0, "process canary cleanup failed");
  const killed = await runProcess(
    process.execPath,
    ["-e", "setInterval(() => {}, 1000)"],
    process.cwd(),
    async () => ({}),
    {
      actionTimeoutMs: 25,
      heartbeatMs: 10_000,
      terminationTimeoutMs: 2_000,
      expectedFileSha256: nodeSha256,
      taskkillSha256,
    },
  );
  expect(killed.code === -1 && killed.signal === "termination-requested", "successful taskkill was not observed");
  expect(killed.residualPid === null && killed.output.includes("taskkill_exit=0"), "successful termination evidence is incomplete");
} else {
  process.kill(survived.residualPid, "SIGKILL");
}

console.log("lan-interactive-agent-process-test: PASS");
