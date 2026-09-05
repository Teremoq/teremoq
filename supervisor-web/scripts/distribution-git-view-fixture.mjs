#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Teremoq contributors
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  DISTRIBUTION_GIT_PREFIX,
  parseClosedSourceContract,
  runDistributionGit,
  verifyDistributionSource,
} from "./distribution-contract.mjs";

const contract = parseClosedSourceContract(readFileSync(
  new URL("../lan-player/source-contract.tsv", import.meta.url), "utf8",
));
const launcher = readFileSync(
  new URL("../../infra/lan/client/Start-LanInteractiveClient.ps1", import.meta.url), "utf8",
);
const root = mkdtempSync(join(tmpdir(), "teremoq-git-view-"));
const checkout = join(root, "checkout");
const project = join(checkout, "supervisor-web");
const repositoryRef = "refs/heads/lan-windows-view";
const trackedPath = join(project, "tracked.txt");
const untrackedPath = join(project, "private-untracked.txt");
const hookMarker = join(root, "fsmonitor-ran");
const hookPath = join(root, process.platform === "win32" ? "fsmonitor.cmd" : "fsmonitor.sh");
const globalConfig = join(root, "adversarial-windows.gitconfig");
const originalGitEnvironment = Object.fromEntries(
  Object.entries(process.env).filter(([name]) => name.startsWith("GIT_")),
);
const originalPath = process.env.PATH;

function rawGit(args, environment = process.env) {
  return execFileSync("git", args, {
    encoding: "utf8", env: environment, stdio: ["ignore", "pipe", "pipe"],
    timeout: 60_000, maxBuffer: 131_072,
  }).trim();
}

function isolatedGitEnvironment() {
  const environment = { ...process.env };
  for (const name of Object.keys(environment)) {
    if (name.startsWith("GIT_")) delete environment[name];
  }
  environment.GIT_CONFIG_NOSYSTEM = "1";
  environment.GIT_CONFIG_GLOBAL = process.platform === "win32" ? "NUL" : "/dev/null";
  environment.GIT_OPTIONAL_LOCKS = "0";
  return environment;
}

function failureMessage(operation) {
  try { operation(); } catch (error) { return error instanceof Error ? error.message : "non-error"; }
  return "no-error";
}

try {
  rawGit(["init", checkout]);
  rawGit(["-C", checkout, "checkout", "-b", repositoryRef.slice("refs/heads/".length)]);
  rawGit(["-C", checkout, "config", "user.name", "Teremoq fixture"]);
  rawGit(["-C", checkout, "config", "user.email", "fixture@example.invalid"]);
  mkdirSync(project);
  writeFileSync(trackedPath, "reviewed LF bytes\n");
  rawGit(["-C", checkout, "add", "supervisor-web/tracked.txt"]);
  rawGit(["-C", checkout, "commit", "-m", "fixture"]);
  rawGit(["-C", checkout, "remote", "add", "origin", contract.repository_url]);
  const sourceCommit = rawGit(["-C", checkout, "rev-parse", "HEAD"]);
  if (process.platform === "win32") {
    writeFileSync(hookPath, `@echo invoked>"${hookMarker}"\r\n@echo token\r\n`);
  } else {
    writeFileSync(hookPath, `#!/bin/sh\nprintf invoked > '${hookMarker}'\nprintf 'token\\n'\n`);
    chmodSync(hookPath, 0o700);
  }
  rawGit(["-C", checkout, "config", "core.fsmonitor", hookPath]);
  rawGit(["config", "--file", globalConfig, "core.autocrlf", "true"]);
  rawGit(["config", "--file", globalConfig, "core.eol", "crlf"]);
  rawGit(["config", "--file", globalConfig, "core.safecrlf", "false"]);
  rawGit(["config", "--file", globalConfig, "protocol.file.allow", "always"]);

  process.env.GIT_CONFIG_NOSYSTEM = "0";
  process.env.GIT_CONFIG_GLOBAL = globalConfig;
  process.env.GIT_WORK_TREE = join(root, "wrong-work-tree");
  process.env.GIT_INDEX_FILE = join(root, "wrong-index");
  const launcherEnvironment = isolatedGitEnvironment();
  const statusArguments = ["status", "--porcelain=v1", "--untracked-files=all"];
  const launcherStatus = () => rawGit([
    ...DISTRIBUTION_GIT_PREFIX, "-C", checkout, ...statusArguments,
  ], launcherEnvironment);
  assert.deepEqual(DISTRIBUTION_GIT_PREFIX, [
    "--no-replace-objects", "-c", "core.hooksPath=NUL", "-c", "core.fsmonitor=false",
    "-c", "core.autocrlf=false", "-c", "core.eol=lf", "-c", "core.safecrlf=true",
    "-c", "protocol.file.allow=never",
  ]);
  for (const fragment of ["core.hooksPath=NUL", "core.fsmonitor=false", "core.autocrlf=false", "core.eol=lf",
    "core.safecrlf=true", "protocol.file.allow=never", "'-C', $checkout"]) {
    assert.ok(launcher.includes(fragment), `launcher Git view lacks ${fragment}`);
  }
  assert.ok(launcher.includes("$env:GIT_CONFIG_NOSYSTEM = '1'"));
  assert.ok(launcher.includes("$env:GIT_CONFIG_GLOBAL = 'NUL'"));
  assert.equal(runDistributionGit(checkout, statusArguments), launcherStatus());
  assert.equal(launcherStatus(), "");
  assert.equal(existsSync(hookMarker), false);
  const request = {
    checkoutRoot: checkout,
    repositoryUrl: contract.repository_url,
    repositoryRef,
    sourceCommit,
  };
  assert.equal(verifyDistributionSource(project, request, contract).sourceCommit, sourceCommit);

  writeFileSync(trackedPath, "modified private bytes\n");
  assert.equal(runDistributionGit(checkout, statusArguments), launcherStatus());
  assert.equal(failureMessage(() => verifyDistributionSource(project, request, contract)),
    "checkout Git no está limpio (tracked)");
  rawGit([...DISTRIBUTION_GIT_PREFIX, "-C", checkout, "checkout", "--", "supervisor-web/tracked.txt"], launcherEnvironment);
  writeFileSync(untrackedPath, "private local data\n");
  assert.equal(runDistributionGit(checkout, statusArguments), launcherStatus());
  assert.equal(failureMessage(() => verifyDistributionSource(project, request, contract)),
    "checkout Git no está limpio (untracked)");
  assert.equal(existsSync(hookMarker), false);
  process.env.PATH = join(root, "missing-executables");
  assert.equal(failureMessage(() => runDistributionGit(checkout, statusArguments)),
    "validación Git local falló (spawn)");
  process.stdout.write("distribution-git-view-test: PASS\n");
} finally {
  if (originalPath === undefined) delete process.env.PATH;
  else process.env.PATH = originalPath;
  for (const name of Object.keys(process.env)) {
    if (name.startsWith("GIT_")) delete process.env[name];
  }
  Object.assign(process.env, originalGitEnvironment);
  rmSync(root, { recursive: true, force: true });
}
