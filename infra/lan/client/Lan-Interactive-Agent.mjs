#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Teremoq contributors
// SPDX-License-Identifier: Apache-2.0

import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import https from "node:https";
import path from "node:path";
import tls from "node:tls";
import { pathToFileURL } from "node:url";

const ACTIONS = new Set(["diagnose-build", "prepare-client", "preflight", "player-1", "load-5", "load-10", "load-25", "wifi-observe", "collect", "stop"]);
const MAX_RESPONSE = 32768;
const MAX_MESSAGE = 16384;

function fail(message) { throw new Error(message); }
function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    if (!key?.startsWith("--") || index + 1 >= argv.length || values[key]) fail("invalid or duplicate argument");
    values[key] = argv[index + 1];
  }
  const required = ["--server", "--fingerprint", "--run-id", "--source-commit", "--pairing-stdin", "--checkout", "--state-root", "--evidence-root"];
  if (Object.keys(values).length !== required.length || required.some((key) => !values[key])) fail("agent arguments differ from the closed contract");
  if (values["--server"] !== "https://192.168.1.130:18443") fail("server URL differs from the exact LAN endpoint");
  if (!/^[0-9a-f]{64}$/.test(values["--fingerprint"]) || !/^[0-9a-f]{40}$/.test(values["--source-commit"])) fail("invalid fingerprint or commit");
  if (!/^lan-[a-z0-9][a-z0-9-]{0,31}$/.test(values["--run-id"]) || values["--pairing-stdin"] !== "true") fail("invalid run or pairing input policy");
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
    .replace(/-----BEGIN PRIVATE KEY-----[\s\S]*/gi, "[private key blocked]")
    .replace(/(authorization:\s*bearer\s+)\S+/gi, "$1[blocked]")
    .replace(/(ghp_|github_pat_)[A-Za-z0-9_]+/g, "[token blocked]")
    .slice(-MAX_MESSAGE);
}

function runProcess(file, args, cwd, onProgress) {
  return new Promise((resolve) => {
    const child = spawn(file, args, { cwd, windowsHide: true, shell: false, env: { ...process.env, NO_COLOR: "1" } });
    let output = "";
    const append = (chunk) => { output = (output + chunk.toString("utf8")).slice(-MAX_MESSAGE); };
    child.stdout.on("data", append); child.stderr.on("data", append);
    const heartbeat = setInterval(() => onProgress(scrub(output || "process is still running")), 15000);
    const timer = setTimeout(() => child.kill(), 15 * 60 * 1000);
    child.once("exit", (code, signal) => { clearInterval(heartbeat); clearTimeout(timer); resolve({ code: code ?? -1, signal: signal ?? "", output: scrub(output || "no process output") }); });
    child.once("error", (error) => { clearInterval(heartbeat); clearTimeout(timer); resolve({ code: -1, signal: "spawn-error", output: scrub(error.message) }); });
  });
}

async function execute(action, context, progress) {
  const powershell = `${process.env.SystemRoot}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`;
  if (action === "diagnose-build") {
    return runProcess("npm.cmd", ["run", "build:lan"], path.join(context.checkout, "supervisor-web"), progress);
  }
  if (action === "prepare-client") {
    const script = path.join(context.checkout, "infra", "lan", "client", "Prepare-LanClientFromGit.ps1");
    return runProcess(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
      "-CheckoutRoot", context.checkout, "-StateRoot", context.stateRoot, "-RepositoryUrl", "https://github.com/Teremoq/teremoq",
      "-RepositoryRef", "refs/heads/codex/lan-e2e-integration", "-ExpectedCommit", context.commit, "-RunId", context.runId,
      "-ServerIPv4", "192.168.1.130", "-PrefixLength", "24", "-Namespace", "teremoq/live", "-FingerprintSha256", context.fingerprint],
      context.checkout, progress);
  }
  if (action === "preflight") {
    const script = path.join(context.checkout, "infra", "lan", "windows", "Preflight-Client.ps1");
    return runProcess(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
      "-RunId", context.runId, "-SourceCommit", context.commit, "-ServerIPv4", "192.168.1.130", "-ClientIPv4", "192.168.1.139",
      "-PrefixLength", "24", "-NetworkProfile", "Public", "-ExpectedWslMode", "nat", "-MaximumClockOffsetMs", "60000",
      "-MinimumMtu", "1280", "-MinimumCpuCores", "2", "-MinimumMemoryMiB", "2048", "-MinimumDiskMiB", "4096"], context.checkout, progress);
  }
  if (["player-1", "load-5", "load-10", "load-25", "collect"].includes(action)) {
    const level = action === "player-1" ? "1" : action === "collect" ? "1" : action.split("-")[1];
    const command = action === "collect" ? "Collect" : "Start";
    const script = path.join(context.checkout, "infra", "lan", "client", "Invoke-LanLoad.ps1");
    const args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", command,
      "-Level", level, "-RunId", context.runId, "-CheckoutRoot", context.checkout, "-StateRoot", context.stateRoot,
      "-EvidenceRoot", context.evidenceRoot];
    if (command === "Start") args.push("-ConfirmStart");
    return runProcess(powershell, args, context.checkout, progress);
  }
  if (action === "wifi-observe") return { code: 0, signal: "", output: "Wi-Fi recovery observation is armed; disconnect/reconnect remains a physical user action." };
  if (action === "stop") return { code: 0, signal: "", output: "Interactive client agent stopped by the reviewed action queue." };
  fail("action is not implemented");
}

async function main() {
  if (process.platform !== "win32" || process.versions.node.split(".")[0] !== "22") fail("agent requires native Windows and Node 22.x");
  const values = parseArguments(process.argv.slice(2));
  const pairingCode = fs.readFileSync(0, { encoding: "ascii" }).trim();
  if (!/^[0-9a-f]{48}$/.test(pairingCode)) fail("invalid one-time pairing code from standard input");
  const context = {
    checkout: exactDirectory(values["--checkout"], "checkout"), stateRoot: exactFutureDirectory(values["--state-root"], "state root"),
    evidenceRoot: exactDirectory(values["--evidence-root"], "evidence root"), runId: values["--run-id"], commit: values["--source-commit"],
    fingerprint: values["--fingerprint"],
  };
  const agent = pinnedAgent(values["--server"], values["--fingerprint"]);
  const identity = { schema_version: 1, run_id: context.runId, source_commit: context.commit };
  let previousRequest = 0;
  const channelRequest = async (route, body, session = "") => {
    const delay = Math.max(0, 125 - (Date.now() - previousRequest));
    if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
    const response = await requestJson(agent, values["--server"], route, body, session);
    previousRequest = Date.now();
    return response;
  };
  const pair = await channelRequest("/v1/pair", { ...identity, pairing_code: pairingCode });
  if (pair.schema_version !== 1 || pair.run_id !== context.runId || pair.source_commit !== context.commit || !/^[0-9a-f]{64}$/.test(pair.session)) fail("invalid pairing response");
  for (;;) {
    const task = await channelRequest("/v1/poll", identity, pair.session);
    if (task.schema_version !== 1 || task.run_id !== context.runId || task.source_commit !== context.commit || !Number.isSafeInteger(task.sequence)) fail("invalid task response");
    if (task.action === "wait") { await new Promise((resolve) => setTimeout(resolve, 2000)); continue; }
    if (!ACTIONS.has(task.action) || task.sequence < 1) fail("server requested an unapproved action");
    let event = 1;
    let sendQueue = Promise.resolve();
    const send = (status, message) => {
      const currentEvent = event++;
      sendQueue = sendQueue.then(() => channelRequest("/v1/event", { ...identity, sequence: task.sequence, event: currentEvent, action: task.action, status, message: scrub(message) }, pair.session));
      return sendQueue;
    };
    await send("started", `${task.action} started`);
    const result = await execute(task.action, context, (message) => { void send("progress", message); });
    await sendQueue;
    await send(result.code === 0 ? "complete" : "failed", `exit=${result.code}; signal=${result.signal || "none"}\n${result.output}`);
    if (task.action === "stop") break;
  }
}

export { pinnedAgent, requestJson, scrub };

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => { process.stderr.write(`Teremoq LAN agent: ${scrub(error.message)}\n`); process.exitCode = 1; });
}
