#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Teremoq contributors
// SPDX-License-Identifier: Apache-2.0

import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import https from "node:https";
import path from "node:path";
import tls from "node:tls";
import { pathToFileURL } from "node:url";

const ACTIONS = new Set(["update-client", "prepare-client", "preflight", "player-1", "load-5", "load-10", "load-25", "wifi-observe", "collect", "stop"]);
const MAX_RESPONSE = 32768;
const MAX_MESSAGE = 16384;
const ACTION_TIMEOUT_MS = 5 * 60 * 1000;
const TASKKILL_TIMEOUT_MS = 5 * 1000;
const TERMINATION_TIMEOUT_MS = 15 * 1000;
const WINDOWS_ROOT = "C:\\Windows";
const PROGRAM_FILES = "C:\\Program Files";
const LOCAL_ACTION_LABELS = Object.freeze({
  "update-client": "Actualizar el cliente desde GitHub",
  "prepare-client": "Preparar y verificar el cliente",
  preflight: "Comprobar el portatil",
  "player-1": "Iniciar un reproductor",
  "load-5": "Probar cinco espectadores",
  "load-10": "Probar diez espectadores",
  "load-25": "Probar veinticinco espectadores",
  "wifi-observe": "Observar la recuperacion Wi-Fi",
  collect: "Recoger resultados",
  stop: "Detener el cliente",
});
const LOCAL_STAGE_LABELS = Object.freeze({
  received: "orden recibida",
  running: "en ejecucion",
  progress: "continua en ejecucion",
  complete: "completado",
  failed: "fallo comunicado al servidor",
});

function fail(message) { throw new Error(message); }
function formatLocalStatus(action, stage, sequence) {
  if (!ACTIONS.has(action) || !Object.hasOwn(LOCAL_STAGE_LABELS, stage) ||
      !Number.isSafeInteger(sequence) || sequence < 1) {
    fail("invalid local status");
  }
  return `[Teremoq] Paso ${sequence} - ${LOCAL_ACTION_LABELS[action]}: ${LOCAL_STAGE_LABELS[stage]}`;
}
function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    if (!key?.startsWith("--") || index + 1 >= argv.length || values[key]) fail("invalid or duplicate argument");
    values[key] = argv[index + 1];
  }
  const required = [
    "--server", "--fingerprint", "--run-id", "--source-commit", "--client-commit", "--credential-mode",
    "--checkout", "--state-root", "--evidence-root", "--git-sha256", "--node-sha256",
    "--npm-cli-sha256", "--powershell-sha256", "--taskkill-sha256",
  ];
  if (Object.keys(values).length !== required.length || required.some((key) => !values[key])) fail("agent arguments differ from the closed contract");
  if (values["--server"] !== "https://192.168.1.130:18443") fail("server URL differs from the exact LAN endpoint");
  if (!/^[0-9a-f]{64}$/.test(values["--fingerprint"]) || !/^[0-9a-f]{40}$/.test(values["--source-commit"]) ||
      !/^[0-9a-f]{40}$/.test(values["--client-commit"])) fail("invalid fingerprint or commit");
  for (const key of ["--git-sha256", "--node-sha256", "--npm-cli-sha256", "--powershell-sha256", "--taskkill-sha256"]) {
    if (!/^[0-9a-f]{64}$/.test(values[key])) fail("invalid executable approval hash");
  }
  if (!/^lan-[a-z0-9][a-z0-9-]{0,31}$/.test(values["--run-id"]) || !["pair", "session"].includes(values["--credential-mode"])) fail("invalid run or credential input policy");
  return values;
}

function exactDirectory(value, label) {
  const resolved = path.resolve(value);
  const stat = fs.lstatSync(resolved);
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a real directory`);
  return resolved;
}

function exactFutureDirectory(value, label) {
  const resolved = path.resolve(value);
  const parent = exactDirectory(path.dirname(resolved), `${label} parent`);
  if (path.dirname(resolved) !== parent) fail(`${label} parent is not canonical`);
  if (fs.existsSync(resolved)) {
    const stat = fs.lstatSync(resolved);
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a real directory when present`);
  }
  return resolved;
}

function pinnedAgent(url, expectedFingerprint) {
  const agent = new https.Agent({ keepAlive: false, maxSockets: 1 });
  agent.createConnection = (options, callback) => {
      let settled = false;
      const finish = (error, socket) => {
        if (settled) return;
        settled = true;
        callback(error, socket);
      };
      const socket = tls.connect({ ...options, rejectUnauthorized: false });
      socket.once("secureConnect", () => {
        const certificate = socket.getPeerCertificate(true);
        const actual = certificate?.raw ? crypto.createHash("sha256").update(certificate.raw).digest("hex") : "";
        if (actual !== expectedFingerprint) {
          socket.destroy();
          finish(new Error("server certificate fingerprint mismatch"));
          return;
        }
        finish(null, socket);
      });
      socket.once("error", (error) => finish(error));
      return socket;
  };
  return agent;
}

function requestJson(agent, server, route, body, session = "") {
  const encoded = Buffer.from(JSON.stringify(body), "utf8");
  return new Promise((resolve, reject) => {
    const request = https.request(new URL(route, server), {
      method: "POST", agent, timeout: 10000,
      headers: { "Content-Type": "application/json", "Content-Length": encoded.length, ...(session ? { "X-Teremoq-Session": session } : {}) },
    }, (response) => {
      const chunks = []; let size = 0;
      response.on("data", (chunk) => { size += chunk.length; if (size > MAX_RESPONSE) response.destroy(new Error("response exceeds limit")); else chunks.push(chunk); });
      response.on("end", () => {
        if (response.statusCode !== 200) { reject(new Error(`channel rejected request (${response.statusCode})`)); return; }
        try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); } catch { reject(new Error("channel returned invalid JSON")); }
      });
    });
    request.once("timeout", () => request.destroy(new Error("channel request timed out")));
    request.once("error", reject);
    request.end(encoded);
  });
}

function scrub(value) {
  return value
    .replace(/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*/gi, "[private key blocked]")
    .replace(/(authorization:\s*bearer\s+)\S+/gi, "$1[blocked]")
    .replace(/(ghp_|github_pat_)[A-Za-z0-9_]+/g, "[token blocked]")
    .replace(/((?:password|passwd|token|secret|api[_-]?key)\s*[=:]\s*)\S+/gi, "$1[blocked]")
    .replace(/(?:[A-Za-z]:[\\/]|\\\\)[^\r\n]*/g, "[local path blocked]")
    .slice(-MAX_MESSAGE);
}

function restrictedEnvironment() {
  const systemRoot = process.env.SystemRoot;
  const programFiles = process.env.ProgramFiles;
  if (!systemRoot || !programFiles ||
      path.win32.resolve(systemRoot).toLowerCase() !== WINDOWS_ROOT.toLowerCase() ||
      path.win32.resolve(programFiles).toLowerCase() !== PROGRAM_FILES.toLowerCase()) {
    fail("required Windows roots differ from the reviewed locations");
  }
  return {
    SystemRoot: WINDOWS_ROOT,
    WINDIR: WINDOWS_ROOT,
    ProgramFiles: PROGRAM_FILES,
    "ProgramFiles(x86)": process.env["ProgramFiles(x86)"] || "",
    LOCALAPPDATA: process.env.LOCALAPPDATA || "",
    TEMP: process.env.TEMP || "",
    TMP: process.env.TMP || "",
    USERPROFILE: process.env.USERPROFILE || "",
    ComSpec: `${WINDOWS_ROOT}\\System32\\cmd.exe`,
    PATH: `${PROGRAM_FILES}\\nodejs;${WINDOWS_ROOT}\\System32;${WINDOWS_ROOT};${PROGRAM_FILES}\\Git\\cmd`,
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "NUL",
    GIT_OPTIONAL_LOCKS: "0",
    NO_COLOR: "1",
  };
}

function verifyApprovedFile(file, expectedSha256) {
  if (!/^[0-9a-f]{64}$/.test(expectedSha256)) fail("approved executable hash is invalid");
  const absolute = path.win32.resolve(file);
  let current = absolute;
  for (;;) {
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) fail("approved executable path contains a reparse point");
    const parent = path.win32.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  if (fs.realpathSync.native(absolute).toLowerCase() !== absolute.toLowerCase()) {
    fail("approved executable resolves outside its reviewed path");
  }
  const descriptor = fs.openSync(absolute, "r");
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile() || before.size < 1 || before.size > 134_217_728) {
      fail("approved executable size is outside contract");
    }
    const digest = crypto.createHash("sha256");
    const buffer = Buffer.allocUnsafe(65_536);
    let position = 0;
    for (;;) {
      const count = fs.readSync(descriptor, buffer, 0, buffer.length, position);
      if (count === 0) break;
      digest.update(buffer.subarray(0, count));
      position += count;
    }
    const after = fs.fstatSync(descriptor);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size ||
        digest.digest("hex") !== expectedSha256) {
      fail("executable bytes differ from approved SHA-256");
    }
  } finally {
    fs.closeSync(descriptor);
  }
}

function verifyCheckout(context) {
  const prefix = ["--no-replace-objects", "-c", "core.hooksPath=NUL", "-c", "core.fsmonitor=false", "-c", "core.autocrlf=false", "-c", "core.eol=lf", "-c", "core.safecrlf=true", "-c", "protocol.file.allow=never", "-C", context.checkout];
  const runGit = (args) => {
    verifyApprovedFile(context.git, context.gitSha256);
    const result = spawnSync(context.git, [...prefix, ...args], {
      encoding: "utf8", windowsHide: true, shell: false, env: restrictedEnvironment(), timeout: 10000,
    });
    if (result.status !== 0 || result.error) fail("Git provenance verification failed");
    return result.stdout.trim();
  };
  if (runGit(["rev-parse", "HEAD"]) !== context.commit || runGit(["symbolic-ref", "--short", "HEAD"]) !== "codex/lan-e2e-integration") {
    fail("checkout commit or branch differs from the paired server");
  }
  if (runGit(["remote", "get-url", "origin"]).replace(/\/$/, "") !== "https://github.com/Teremoq/teremoq") fail("checkout remote differs from the official repository");
  if (runGit(["status", "--porcelain=v1", "--untracked-files=all"]) !== "") fail("checkout changed after pairing");
}

function approvedGitBlobId(context, relativePath) {
  if (!/^[A-Za-z0-9._/-]{1,256}$/.test(relativePath)) fail("approved source path is invalid");
  verifyApprovedFile(context.git, context.gitSha256);
  const result = spawnSync(context.git, ["--no-replace-objects", "-c", "core.hooksPath=NUL", "-c", "core.fsmonitor=false",
    "-c", "core.autocrlf=false", "-c", "core.eol=lf", "-c", "core.safecrlf=true", "-c", "protocol.file.allow=never",
    "-C", context.checkout, "rev-parse", `${context.commit}:${relativePath}`], {
    encoding: "utf8", windowsHide: true, shell: false, env: restrictedEnvironment(), timeout: 10_000,
  });
  const blob = result.stdout?.trim() || "";
  if (result.status !== 0 || result.error || !/^[0-9a-f]{40}$/.test(blob)) fail("approved launcher blob could not be resolved");
  return blob;
}

function pinUpdatedLauncher(context, launcher, expectedBlob) {
  const powershell = `${WINDOWS_ROOT}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`;
  verifyApprovedFile(powershell, context.powershellSha256);
  const helper = path.join(context.checkout, "infra", "lan", "client", "Pin-LanUpdateLauncher.ps1");
  return new Promise((resolve, reject) => {
    let settled = false;
    let stdout = "";
    let stderr = "";
    const child = spawn(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", helper,
      "-LauncherPath", launcher, "-ExpectedBlobId", expectedBlob], {
      cwd: context.checkout, windowsHide: true, shell: false, env: restrictedEnvironment(), stdio: ["pipe", "pipe", "pipe"],
    });
    const timer = setTimeout(() => finish(new Error("updated launcher pin timed out")), 5_000);
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) {
        child.stdin.destroy();
        reject(error);
      } else {
        resolve({
          release: () => new Promise((releaseResolve, releaseReject) => {
            const releaseTimer = setTimeout(() => {
              child.kill();
              releaseReject(new Error("updated launcher pin did not release"));
            }, 2_000);
            child.once("exit", (code) => {
              clearTimeout(releaseTimer);
              if (code === 0) releaseResolve();
              else releaseReject(new Error(`updated launcher pin release failed (${code ?? -1})`));
            });
            child.stdin.end("release\n", "ascii");
          }),
        });
      }
    };
    child.once("error", finish);
    child.once("exit", (code) => {
      if (!settled) finish(new Error(`updated launcher pin exited (${code ?? -1}): ${scrub(stderr)}`));
    });
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("ascii");
      if (stdout.length > 32) finish(new Error("updated launcher pin output exceeded contract"));
      else if (stdout === "PINNED\r\n" || stdout === "PINNED\n") finish();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
      if (stderr.length > 2048) finish(new Error("updated launcher pin error exceeded contract"));
    });
  });
}

async function waitForHandoffAck(ackPath, expected, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const stat = fs.lstatSync(ackPath);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== 65) fail("handoff acknowledgement file differs from contract");
      const descriptor = fs.openSync(ackPath, "r");
      try {
        const content = fs.readFileSync(descriptor, { encoding: "ascii" });
        const after = fs.fstatSync(descriptor);
        if (after.dev !== stat.dev || after.ino !== stat.ino || after.size !== stat.size || content !== `${expected}\n`) {
          fail("handoff acknowledgement identity differs from contract");
        }
      } finally { fs.closeSync(descriptor); }
      fs.unlinkSync(ackPath);
      return;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  fail("updated launcher did not acknowledge pinned source files");
}

function terminateProcessTree(pid, options = {}) {
  if (!Number.isSafeInteger(pid) || pid < 1) {
    return Promise.resolve({ status: "invalid-pid", exitCode: -1, output: "taskkill PID was invalid" });
  }
  const spawnProcess = options.spawnProcess ?? spawn;
  const taskkill = options.taskkillFile ?? `${WINDOWS_ROOT}\\System32\\taskkill.exe`;
  const taskkillArgs = options.taskkillArguments?.(pid) ?? ["/PID", String(pid), "/T", "/F"];
  try {
    verifyApprovedFile(taskkill, options.taskkillSha256);
  } catch (error) {
    return Promise.resolve({ status: "verification-failed", exitCode: -1, output: scrub(error.message) });
  }
  const timeoutMs = options.taskkillTimeoutMs ?? TASKKILL_TIMEOUT_MS;
  return new Promise((resolve) => {
    let killer;
    let settled = false;
    let output = "";
    const finish = (status, exitCode) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ status, exitCode, output: scrub(output || "no taskkill output") });
    };
    try {
      killer = spawnProcess(taskkill, taskkillArgs, {
        windowsHide: true,
        shell: false,
        env: restrictedEnvironment(),
      });
    } catch (error) {
      resolve({ status: "spawn-error", exitCode: -1, output: scrub(error.message) });
      return;
    }
    const append = (chunk) => { output = (output + chunk.toString("utf8")).slice(-MAX_MESSAGE); };
    killer.stdout?.on("data", append);
    killer.stderr?.on("data", append);
    const timer = setTimeout(() => {
      killer.kill();
      finish("timeout", -1);
    }, timeoutMs);
    killer.once("error", (error) => {
      output = error.message;
      finish("spawn-error", -1);
    });
    killer.once("exit", (code) => finish(code === 0 ? "complete" : "failed", code ?? -1));
  });
}

function waitForChildExit(child, timeoutMs = TERMINATION_TIMEOUT_MS) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolve) => {
    let settled = false;
    const finish = (exited) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.removeListener("exit", onExit);
      resolve(exited);
    };
    const onExit = () => finish(true);
    child.once("exit", onExit);
    const timer = setTimeout(
      () => finish(child.exitCode !== null || child.signalCode !== null),
      timeoutMs,
    );
  });
}

async function containUpdatedClientBeforeRelease(child, context, releasePin, options = {}) {
  if (!child?.pid) {
    await releasePin();
    return { contained: true, attempts: 0, termination: { status: "not-started", exitCode: -1 } };
  }
  const terminate = options.terminateProcessTree ?? terminateProcessTree;
  const observeExit = options.waitForChildExit ?? waitForChildExit;
  const maxAttempts = options.maxAttempts ?? Number.POSITIVE_INFINITY;
  const retryDelayMs = options.retryDelayMs ?? 1_000;
  let attempts = 0;
  let treeTerminationConfirmed = false;
  let termination = { status: "not-attempted", exitCode: -1 };
  while (attempts < maxAttempts) {
    attempts += 1;
    try {
      termination = await terminate(child.pid, { taskkillSha256: context.taskkillSha256 });
    } catch (error) {
      termination = { status: "verification-failed", exitCode: -1, output: scrub(error.message) };
    }
    if (termination.status === "complete") treeTerminationConfirmed = true;
    const childExited = await observeExit(child, options.childExitTimeoutMs ?? TERMINATION_TIMEOUT_MS);
    if (treeTerminationConfirmed && childExited) {
      await releasePin();
      return { contained: true, attempts, termination };
    }
    if (attempts < maxAttempts) {
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    }
  }
  return { contained: false, attempts, termination };
}

function runProcess(file, args, cwd, onProgress, options = {}) {
  return new Promise((resolve) => {
    const spawnProcess = options.spawnProcess ?? spawn;
    verifyApprovedFile(file, options.expectedFileSha256);
    const child = spawnProcess(file, args, {
      cwd,
      windowsHide: true,
      shell: false,
      env: restrictedEnvironment(),
    });
    let output = "";
    let terminating = false;
    let childTerminal = null;
    let taskkillResult = null;
    let terminationExpired = false;
    let settled = false;
    const append = (chunk) => { output = (output + chunk.toString("utf8")).slice(-MAX_MESSAGE); };
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearInterval(heartbeat);
      clearTimeout(actionTimer);
      clearTimeout(terminationTimer);
      resolve(result);
    };
    const terminalOutput = (reason) => scrub([
      output || "no process output",
      reason,
      taskkillResult ? `taskkill_status=${taskkillResult.status}; taskkill_exit=${taskkillResult.exitCode}` : "taskkill_status=pending",
    ].join("\n"));
    const maybeFinishTermination = () => {
      if (!terminating || settled || !taskkillResult) return;
      if (childTerminal) {
        const taskkillFailed = taskkillResult.status !== "complete";
        finish({
          code: -1,
          signal: taskkillFailed ? "taskkill-failed" : "termination-requested",
          output: terminalOutput(`child_terminal=${childTerminal.signal || childTerminal.code}`),
          residualPid: null,
        });
        return;
      }
      if (!terminationExpired) return;
      child.stdout?.destroy();
      child.stderr?.destroy();
      child.removeAllListeners();
      child.once("error", () => {});
      child.unref();
      finish({
        code: -1,
        signal: "termination-residue",
        output: terminalOutput(`residual_process_pid=${child.pid}`),
        residualPid: child.pid,
      });
    };
    const terminateTree = (reason = "termination-requested") => {
      if (settled || terminating || !child.pid) return;
      terminating = true;
      clearInterval(heartbeat);
      clearTimeout(actionTimer);
      output = `${output}\ntermination_reason=${reason}`;
      terminationTimer = setTimeout(() => {
        terminationExpired = true;
        maybeFinishTermination();
      }, options.terminationTimeoutMs ?? TERMINATION_TIMEOUT_MS);
      Promise.resolve().then(() => terminateProcessTree(child.pid, options)).then(
        (result) => {
          taskkillResult = result;
          maybeFinishTermination();
        },
        (error) => {
          taskkillResult = { status: "verification-failed", exitCode: -1, output: scrub(error.message) };
          maybeFinishTermination();
        },
      );
    };
    child.stdout.on("data", append); child.stderr.on("data", append);
    const heartbeat = setInterval(() => {
      Promise.resolve(onProgress(scrub(output || "process is still running")))
        .then((reply) => { if (reply?.cancel_requested === true) terminateTree("cancel-requested"); })
        .catch(() => terminateTree("progress-channel-failed"));
    }, options.heartbeatMs ?? 15000);
    const actionTimer = setTimeout(
      () => terminateTree("action-timeout"),
      options.actionTimeoutMs ?? ACTION_TIMEOUT_MS,
    );
    let terminationTimer = null;
    child.once("exit", (code, signal) => {
      childTerminal = { code: code ?? -1, signal: signal ?? "" };
      if (terminating) maybeFinishTermination();
      else finish({ ...childTerminal, output: scrub(output || "no process output"), residualPid: null });
    });
    child.once("error", (error) => {
      childTerminal = { code: -1, signal: "spawn-error" };
      output = error.message;
      if (terminating) maybeFinishTermination();
      else finish({ ...childTerminal, output: scrub(output), residualPid: null });
    });
  });
}

async function execute(action, context, progress) {
  if (!ACTIONS.has(action)) fail("action is not approved");
  verifyCheckout(context);
  const powershell = `${process.env.SystemRoot}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`;
  const nodeOptions = {
    expectedFileSha256: context.nodeSha256,
    taskkillSha256: context.taskkillSha256,
  };
  const powershellOptions = {
    expectedFileSha256: context.powershellSha256,
    taskkillSha256: context.taskkillSha256,
  };
  if (action === "update-client") {
    const update = context.taskParameters;
    if (!update || Object.keys(update).sort().join(",") !== "repository_ref,repository_url,target_commit" ||
        update.repository_url !== "https://github.com/Teremoq/teremoq" ||
        update.repository_ref !== "refs/heads/codex/lan-e2e-integration" ||
        !/^[0-9a-f]{40}$/.test(update.target_commit) || update.target_commit === context.commit) {
      fail("update parameters differ from the closed Git policy");
    }
    const script = path.join(context.checkout, "infra", "lan", "client", "Stage-LanClientUpdate.ps1");
    const result = await runProcess(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
      "-CheckoutRoot", context.checkout, "-CurrentCommit", context.commit, "-TargetCommit", update.target_commit,
      "-RepositoryUrl", update.repository_url, "-RepositoryRef", update.repository_ref],
    context.checkout, progress, powershellOptions);
    if (result.code === 0) {
      result.handoff = {
        commit: update.target_commit,
        checkout: path.join(process.env.LOCALAPPDATA, "Teremoq", `checkout-lan-${update.target_commit.slice(0, 8)}`),
      };
    }
    return result;
  }
  if (action === "prepare-client") {
    const script = path.join(context.checkout, "infra", "lan", "client", "Prepare-LanClientFromGit.ps1");
    return runProcess(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
      "-CheckoutRoot", context.checkout, "-StateRoot", context.stateRoot, "-RepositoryUrl", "https://github.com/Teremoq/teremoq",
      "-RepositoryRef", "refs/heads/codex/lan-e2e-integration", "-ExpectedCommit", context.commit, "-RunId", context.runId,
      "-ServerIPv4", "192.168.1.130", "-PrefixLength", "24", "-Namespace", "teremoq/live", "-FingerprintSha256", context.fingerprint],
      context.checkout, progress, powershellOptions);
  }
  if (action === "preflight") {
    const script = path.join(context.checkout, "infra", "lan", "windows", "Preflight-Client.ps1");
    return runProcess(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
      "-RunId", context.runId, "-SourceCommit", context.commit, "-ServerIPv4", "192.168.1.130", "-ClientIPv4", "192.168.1.139",
      "-PrefixLength", "24", "-NetworkProfile", "Public", "-ExpectedWslMode", "nat", "-MaximumClockOffsetMs", "60000",
      "-MinimumMtu", "1280", "-MinimumCpuCores", "2", "-MinimumMemoryMiB", "2048", "-MinimumDiskMiB", "4096"], context.checkout, progress, powershellOptions);
  }
  if (["player-1", "load-5", "load-10", "load-25"].includes(action)) {
    const level = action === "player-1" ? "1" : action.split("-")[1];
    const script = path.join(context.checkout, "infra", "lan", "client", "Invoke-LanLoad.ps1");
    const args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", "Start",
      "-Level", level, "-RunId", context.runId, "-CheckoutRoot", context.checkout, "-StateRoot", context.stateRoot,
      "-EvidenceRoot", context.evidenceRoot, "-ConfirmStart"];
    return runProcess(powershell, args, context.checkout, progress, powershellOptions);
  }
  if (action === "collect") {
    if (!context.activeLevel) return { code: -1, signal: "", output: "No client workload is active for collection." };
    const script = path.join(context.checkout, "infra", "lan", "client", "Invoke-LanLoad.ps1");
    const common = ["-Level", String(context.activeLevel), "-RunId", context.runId, "-CheckoutRoot", context.checkout,
      "-StateRoot", context.stateRoot, "-EvidenceRoot", context.evidenceRoot];
    const collected = await runProcess(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", "Collect", ...common], context.checkout, progress, powershellOptions);
    if (collected.code !== 0) return collected;
    const stopped = await runProcess(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", "Stop", ...common], context.checkout, progress, powershellOptions);
    if (stopped.code === 0) context.activeLevel = 0;
    return { code: stopped.code, signal: stopped.signal, output: `${collected.output}\n${stopped.output}` };
  }
  if (action === "wifi-observe") return { code: 0, signal: "", output: "Wi-Fi recovery observation is armed; disconnect/reconnect remains a physical user action." };
  if (action === "stop") {
    if (!context.activeLevel) return { code: 0, signal: "", output: "No client workload was active; the interactive agent can stop." };
    const script = path.join(context.checkout, "infra", "lan", "client", "Invoke-LanLoad.ps1");
    const result = await runProcess(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
      "-Action", "Stop", "-Level", String(context.activeLevel), "-RunId", context.runId, "-CheckoutRoot", context.checkout,
      "-StateRoot", context.stateRoot, "-EvidenceRoot", context.evidenceRoot], context.checkout, progress, powershellOptions);
    if (result.code === 0) context.activeLevel = 0;
    return result;
  }
  fail("action is not implemented");
}

async function restartUpdatedClient(context, handoff, session) {
  const updated = { ...context, checkout: exactDirectory(handoff.checkout, "updated checkout"), commit: handoff.commit };
  verifyCheckout(updated);
  const powershell = `${WINDOWS_ROOT}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`;
  verifyApprovedFile(powershell, context.powershellSha256);
  const launcher = path.join(updated.checkout, "infra", "lan", "client", "Start-LanInteractiveClient.ps1");
  const expectedBlob = approvedGitBlobId(updated, "infra/lan/client/Start-LanInteractiveClient.ps1");
  const pin = await pinUpdatedLauncher(context, launcher, expectedBlob);
  let pinReleased = false;
  const releasePin = async () => {
    if (pinReleased) return;
    pinReleased = true;
    await pin.release();
  };
  const nonce = crypto.randomBytes(32).toString("hex");
  const acknowledgement = crypto.createHash("sha256").update(nonce, "ascii").digest("hex");
  const updatedStateRoot = path.join(process.env.LOCALAPPDATA, "Teremoq",
    `interactive-state-${context.runId}-${updated.commit.slice(0, 12)}`);
  const ackPath = path.join(updatedStateRoot, `handoff-${crypto.randomBytes(16).toString("hex")}.ack`);
  let child = null;
  try {
    child = spawn(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", launcher,
      "-ExpectedCommit", updated.commit, "-ChannelCommit", context.channelCommit, "-ResumeSessionStdin", "-HandoffAckPath", ackPath], {
      cwd: updated.checkout, windowsHide: true, detached: true, shell: false,
      env: restrictedEnvironment(), stdio: ["pipe", "ignore", "ignore"],
    });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("updated client credential handoff timed out")), 5_000);
      child.once("error", (error) => { clearTimeout(timer); reject(error); });
      child.once("spawn", () => {
        child.stdin.once("error", (error) => { clearTimeout(timer); reject(error); });
        child.stdin.end(`${nonce}\n${session}\n`, "ascii", () => { clearTimeout(timer); resolve(); });
      });
    });
    await waitForHandoffAck(ackPath, acknowledgement);
    await releasePin();
    child.unref();
  } catch (error) {
    let containmentError = null;
    try { await containUpdatedClientBeforeRelease(child, context, releasePin); }
    catch (cleanupError) { containmentError = cleanupError; }
    try { fs.unlinkSync(ackPath); } catch (cleanupError) {
      if (cleanupError?.code !== "ENOENT") throw cleanupError;
    }
    throw containmentError || error;
  }
}

async function confirmUpdateTransition(channelRequest, identity, task, session, targetCommit, event, message) {
  const terminalRequest = {
    ...identity, sequence: task.sequence, event, action: task.action,
    status: "complete", message: scrub(message),
  };
  let lastError = new Error("client update transition was not confirmed");
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const terminal = await channelRequest("/v1/event", terminalRequest, session);
      if (Object.keys(terminal).sort().join(",") !== "accepted,cancel_requested,client_commit,event,schema_version,sequence,source_commit" ||
          terminal.schema_version !== 1 || terminal.sequence !== task.sequence || terminal.event !== event ||
          terminal.accepted !== true || terminal.source_commit !== identity.source_commit ||
          terminal.client_commit !== targetCommit) fail("invalid update transition response");
      return terminal;
    } catch (error) {
      lastError = error instanceof Error ? error : lastError;
      try {
        const probeIdentity = { ...identity, client_commit: targetCommit };
        const probe = await channelRequest("/v1/poll", probeIdentity, session);
        if (Object.keys(probe).sort().join(",") === "action,client_commit,parameters,run_id,schema_version,sequence,source_commit" &&
            probe.schema_version === 1 && probe.run_id === identity.run_id &&
            probe.source_commit === identity.source_commit && probe.client_commit === targetCommit &&
            Number.isSafeInteger(probe.sequence) && probe.parameters && typeof probe.parameters === "object" &&
            !Array.isArray(probe.parameters)) {
          return { schema_version: 1, sequence: task.sequence, event, accepted: true,
            cancel_requested: false, source_commit: identity.source_commit, client_commit: targetCommit };
        }
      } catch {
        // The server may still have the old identity; retry the same idempotent event.
      }
    }
  }
  throw lastError;
}

async function main() {
  if (process.platform !== "win32" || process.versions.node.split(".")[0] !== "22") fail("agent requires native Windows and Node 22.x");
  const values = parseArguments(process.argv.slice(2));
  const credential = fs.readFileSync(0, { encoding: "ascii" }).trim();
  if (values["--credential-mode"] === "pair" && !/^[0-9a-f]{48}$/.test(credential)) fail("invalid one-time pairing code from standard input");
  if (values["--credential-mode"] === "session" && !/^[0-9a-f]{64}$/.test(credential)) fail("invalid session credential from standard input");
  const context = {
    checkout: exactDirectory(values["--checkout"], "checkout"), stateRoot: exactFutureDirectory(values["--state-root"], "state root"),
    evidenceRoot: exactDirectory(values["--evidence-root"], "evidence root"), runId: values["--run-id"],
    channelCommit: values["--source-commit"], commit: values["--client-commit"],
    fingerprint: values["--fingerprint"],
    git: "C:\\Program Files\\Git\\cmd\\git.exe",
    node: "C:\\Program Files\\nodejs\\node.exe",
    npmCli: "C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npm-cli.js",
    gitSha256: values["--git-sha256"],
    nodeSha256: values["--node-sha256"],
    npmCliSha256: values["--npm-cli-sha256"],
    powershellSha256: values["--powershell-sha256"],
    taskkillSha256: values["--taskkill-sha256"],
    activeLevel: 0,
  };
  verifyApprovedFile(context.git, context.gitSha256);
  verifyApprovedFile(context.node, context.nodeSha256);
  verifyApprovedFile(context.npmCli, context.npmCliSha256);
  verifyApprovedFile(`${WINDOWS_ROOT}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`, context.powershellSha256);
  verifyApprovedFile(`${WINDOWS_ROOT}\\System32\\taskkill.exe`, context.taskkillSha256);
  const agent = pinnedAgent(values["--server"], values["--fingerprint"]);
  let identity = { schema_version: 1, run_id: context.runId, source_commit: context.channelCommit, client_commit: context.commit };
  let previousRequest = 0;
  const channelRequest = async (route, body, session = "") => {
    const delay = Math.max(0, 125 - (Date.now() - previousRequest));
    if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
    const response = await requestJson(agent, values["--server"], route, body, session);
    previousRequest = Date.now();
    return response;
  };
  let session = credential;
  if (values["--credential-mode"] === "pair") {
    const pair = await channelRequest("/v1/pair", { ...identity, pairing_code: credential });
    if (pair.schema_version !== 1 || pair.run_id !== context.runId || pair.source_commit !== context.channelCommit ||
        pair.client_commit !== context.commit || !/^[0-9a-f]{64}$/.test(pair.session)) fail("invalid pairing response");
    session = pair.session;
  }
  process.stdout.write("[Teremoq] Canal seguro conectado. Esperando ordenes del servidor...\n");
  for (;;) {
    const task = await channelRequest("/v1/poll", identity, session);
    if (Object.keys(task).sort().join(",") !== "action,client_commit,parameters,run_id,schema_version,sequence,source_commit" ||
        task.schema_version !== 1 || task.run_id !== context.runId || task.source_commit !== context.channelCommit ||
        task.client_commit !== context.commit || !Number.isSafeInteger(task.sequence) ||
        !task.parameters || typeof task.parameters !== "object" || Array.isArray(task.parameters)) fail("invalid task response");
    if (task.action === "wait") {
      if (task.sequence !== 0 || Object.keys(task.parameters).length !== 0) fail("wait response differs from the closed contract");
      await new Promise((resolve) => setTimeout(resolve, 2000));
      continue;
    }
    if (!ACTIONS.has(task.action) || task.sequence < 1) fail("server requested an unapproved action");
    if (task.action !== "update-client" && Object.keys(task.parameters).length !== 0) fail("non-update task carried unexpected parameters");
    context.taskParameters = task.parameters;
    process.stdout.write(`${formatLocalStatus(task.action, "received", task.sequence)}\n`);
    let event = 1;
    let sendQueue = Promise.resolve();
    const send = (status, message) => {
      const currentEvent = event++;
      sendQueue = sendQueue.then(() => channelRequest("/v1/event", { ...identity, sequence: task.sequence, event: currentEvent, action: task.action, status, message: scrub(message) }, session));
      return sendQueue;
    };
    const started = await send("started", `${task.action} started`);
    process.stdout.write(`${formatLocalStatus(task.action, "running", task.sequence)}\n`);
    const result = started.cancel_requested === true
      ? { code: -1, signal: "cancel-requested", output: "The server cancelled the action before execution." }
      : await execute(task.action, context, (message) => {
          process.stdout.write(`${formatLocalStatus(task.action, "progress", task.sequence)}\n`);
          return send("progress", message);
        });
    if (result.code === 0 && ["player-1", "load-5", "load-10", "load-25"].includes(task.action)) {
      context.activeLevel = Number(task.action.split("-")[1]);
    }
    await sendQueue;
    if (task.action === "update-client" && result.code === 0) {
      const terminal = await confirmUpdateTransition(channelRequest, identity, task, session, result.handoff?.commit || "", event++,
        `exit=${result.code}; signal=${result.signal || "none"}\n${result.output}`);
      process.stdout.write(`${formatLocalStatus(task.action, "complete", task.sequence)}\n`);
      if (!result.handoff || terminal.source_commit !== context.channelCommit || terminal.client_commit !== result.handoff.commit) fail("server did not confirm the client commit transition");
      await restartUpdatedClient(context, result.handoff, session);
      process.stdout.write("[Teremoq] Cliente actualizado; la sesion segura continua en la nueva version.\n");
      break;
    }
    await send(result.code === 0 ? "complete" : "failed", `exit=${result.code}; signal=${result.signal || "none"}\n${result.output}`);
    process.stdout.write(`${formatLocalStatus(task.action, result.code === 0 ? "complete" : "failed", task.sequence)}\n`);
    if (task.action === "stop") break;
  }
}

export { approvedGitBlobId, confirmUpdateTransition, containUpdatedClientBeforeRelease, execute, formatLocalStatus, parseArguments, pinnedAgent, pinUpdatedLauncher, requestJson, restartUpdatedClient, runProcess, scrub, terminateProcessTree, verifyCheckout, waitForChildExit, waitForHandoffAck };

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => { process.stderr.write(`Teremoq LAN agent: ${scrub(error.message)}\n`); process.exitCode = 1; });
}
