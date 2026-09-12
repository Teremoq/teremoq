// SPDX-FileCopyrightText: 2026 Teremoq contributors
// SPDX-License-Identifier: Apache-2.0
// Real Windows Node -> Core7 policy fixtures; no npm ci/build/network/product.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import { pinSecureDirectoryPath, pinSecureRegularFile, revalidateSecureDirectoryPin,
  WINDOWS_HOST_ENV, parseWindowsHostSelection } from "./path-security.mjs";
import { buildIsolatedNpmEnvironment } from "./npm-isolation.mjs";

assert.equal(process.platform, "win32");
assert.equal(process.arch, "x64");
const host = parseWindowsHostSelection(process.env[WINDOWS_HOST_ENV]);
const expectedPath = [dirname(process.execPath), join(process.env.ProgramFiles, "Git", "cmd"),
  dirname(host), join(process.env.SystemRoot, "System32"), process.env.SystemRoot].join(";");
assert.equal(process.env.PATH, expectedPath, "requires the exact wrapper PATH");
const where = spawnSync(join(process.env.SystemRoot, "System32", "where.exe"), ["powershell.exe"],
  { timeout: 10_000, encoding: "utf8" });
assert.equal(where.status, 1, "PS5 must be absent from wrapper PATH");
const scripts = dirname(fileURLToPath(import.meta.url));
const root = await mkdtemp(join(tmpdir(), "teremoq-core7-path-focal-"));
const results = [];
const check = async (name, action) => { await action(); results.push(name); };
const target = join(root, "real ñ & [path]");
await mkdir(target);
try {
  await check("real-direct-node-core7-pin-unicode", async () => {
    const pin = await pinSecureDirectoryPath(target);
    assert.equal(pin.path, target);
    await revalidateSecureDirectoryPin(pin);
    await writeFile(join(target, "empty.npmrc"), "");
    assert.equal((await pinSecureRegularFile(join(target, "empty.npmrc"), 0)).size, 0);
    const missing = await pinSecureDirectoryPath(join(target, "missing"), { allowMissing: true });
    assert.equal(missing.missing, true);
  });
  await check("real-node-after-npm-isolation-core7-pin", async () => {
    const paths = Object.fromEntries(["home", "userProfile", "appData", "localAppData", "prefix", "cache"]
      .map(key => [key, join(root, key)]));
    for (const path of Object.values(paths)) await mkdir(path);
    paths.userConfig = join(root, "user.npmrc"); paths.globalConfig = join(root, "global.npmrc");
    await writeFile(paths.userConfig, ""); await writeFile(paths.globalConfig, "");
    const env = buildIsolatedNpmEnvironment(process.env, paths);
    assert.equal(env[WINDOWS_HOST_ENV], host);
    const moduleUrl = pathToFileURL(join(scripts, "path-security.mjs")).href;
    const code = `import {pinSecureDirectoryPath} from ${JSON.stringify(moduleUrl)}; process.stdout.write((await pinSecureDirectoryPath(process.argv[1])).path);`;
    const output = execFileSync(process.execPath, ["--input-type=module", "-e", code, target],
      { env, encoding: "utf8", timeout: 60_000, maxBuffer: 16_384 });
    assert.equal(output, target);
  });
  await check("missing-and-malformed-selection-fail-before-exec", async () => {
    for (const value of [undefined, "", "pwsh.exe", "C:\\x\\powershell.exe", "\\\\host\\share\\pwsh.exe"]) {
      if (value === undefined) delete process.env[WINDOWS_HOST_ENV];
      else process.env[WINDOWS_HOST_ENV] = value;
      await assert.rejects(pinSecureDirectoryPath(target), /selected Core7 host path/);
    }
    process.env[WINDOWS_HOST_ENV] = host;
  });
  await check("altered-executable-fingerprint-and-size-rejected", async () => {
    const fake = join(root, "pwsh.exe");
    await writeFile(fake, "not an executable");
    process.env[WINDOWS_HOST_ENV] = fake;
    await assert.rejects(pinSecureDirectoryPath(target), /fingerprint/);
    await writeFile(fake, Buffer.alloc(1_048_577));
    await assert.rejects(pinSecureDirectoryPath(target), /size/);
    // The reader was closed even on rejection: Windows must allow removal.
    await rm(fake);
    process.env[WINDOWS_HOST_ENV] = host;
  });
  await check("runtime-junction-and-target-junction-rejected", async () => {
    const alias = join(root, "runtime-alias");
    await symlink(dirname(host), alias, "junction");
    process.env[WINDOWS_HOST_ENV] = join(alias, "pwsh.exe");
    await assert.rejects(pinSecureDirectoryPath(target), /symlink|junction|reparse/);
    process.env[WINDOWS_HOST_ENV] = host;
    const targetAlias = join(root, "target-alias");
    await symlink(target, targetAlias, "junction");
    await assert.rejects(pinSecureDirectoryPath(targetAlias), /symlink|junction|reparse/);
  });
  // Exact consumer module copied unchanged; ONLY the sibling policy is a
  // deliberately failing fixture. These are real subprocess/bounds tests,
  // not claims that the fixture bodies are production policy code.
  for (const [name, body, errorCheck] of [
    ["empty-stdout", "# no output", e => /otro path/.test(e.message)],
    ["wrong-stdout", "Write-Output 'C:\\different'", e => /otro path/.test(e.message)],
    ["child-error", "[Console]::Error.Write('fixture-error'); exit 9", e => e.status === 9],
    ["bounded-output", "[Console]::Out.Write(('x' * 20000))", e => e.code === "ENOBUFS"],
    ["timeout-30000", "Start-Sleep -Seconds 35", e => e.code === "ETIMEDOUT"],
  ]) {
    await check(`real-core7-consumer-${name}`, async () => {
      const directory = join(root, name); await mkdir(directory);
      const moduleFile = join(directory, "path-security.mjs");
      await copyFile(join(scripts, "path-security.mjs"), moduleFile);
      await writeFile(join(directory, "assert-windows-path-policy.ps1"), body);
      const consumer = await import(pathToFileURL(moduleFile).href);
      await assert.rejects(consumer.pinSecureDirectoryPath(target), errorCheck);
    });
  }
  const digest = async file => createHash("sha256").update(await readFile(file)).digest("hex");
  console.log(JSON.stringify({ kind: "real-server-node-core7-path-policy-fixtures-not-build",
    result: "PASS", checks: results, node: process.version, platform: process.platform, arch: process.arch,
    host_sha256: await digest(host), consumer_sha256: await digest(join(scripts, "path-security.mjs")),
    policy_sha256: await digest(join(scripts, "assert-windows-path-policy.ps1")),
    child_execution_policy: "existing-Bypass-flag-unchanged-not-global-policy", builds: 0 }));
} finally {
  process.env[WINDOWS_HOST_ENV] = host;
  await rm(root, { recursive: true, force: true });
}
