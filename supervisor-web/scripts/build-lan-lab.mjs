import { execFileSync, spawn } from "node:child_process";
import { rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BUILD_PROVENANCE_NAME,
  hashRegularFile,
  serializeBuildProvenance,
} from "./lan-build-provenance.mjs";
import { verifyPackageSource } from "./verify-package-source.mjs";

const require = createRequire(import.meta.url);
const scriptRoot = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptRoot, "..");
const nextCli = require.resolve("next/dist/bin/next");
const sourceCommit = git(["-C", projectRoot, "rev-parse", "HEAD"]);
const source = verifyPackageSource(projectRoot, sourceCommit);
const npmCli = process.env.npm_execpath;
if (!npmCli || !isAbsolute(npmCli)) throw new Error("build:lan exige npm local explícito");
const npmVersion = execFileSync(process.execPath, [npmCli, "--version"], {
  encoding: "utf8",
  timeout: 30_000,
  maxBuffer: 16_384,
}).trim();
if (!/^v22\.[0-9]+\.[0-9]+$/.test(process.version) ||
    !/^10\.[0-9]+\.[0-9]+$/.test(npmVersion)) {
  throw new Error("build:lan exige Node 22.x y npm 10.x");
}
const provenance = {
  schema_version: 1,
  source_commit: source.sourceCommit,
  source_tree: source.sourceTree,
  package_lock_sha256: await hashRegularFile(join(projectRoot, "package-lock.json"), 1_048_576),
  package_json_sha256: await hashRegularFile(join(projectRoot, "package.json"), 65_536),
  node_version: process.version,
  npm_version: npmVersion,
  build_mode: "lan-standalone",
};
await rm(join(projectRoot, ".next", BUILD_PROVENANCE_NAME), { force: true });
const child = spawn(process.execPath, [nextCli, "build"], {
  cwd: projectRoot,
  stdio: "inherit",
  env: {
    ...process.env,
    TEREMOQ_LAN_LAB: "1",
    TEREMOQ_LAN_SOURCE_COMMIT: source.sourceCommit,
  },
});

const forwardSignal = (signal) => {
  if (!child.killed) child.kill(signal);
};
const forwardInterrupt = () => forwardSignal("SIGINT");
const forwardTermination = () => forwardSignal("SIGTERM");
process.once("SIGINT", forwardInterrupt);
process.once("SIGTERM", forwardTermination);
let spawnFailed = false;
child.once("error", () => {
  spawnFailed = true;
  process.stderr.write("No se pudo construir el paquete LAN local.\n");
});
child.once("exit", async (code) => {
  process.removeListener("SIGINT", forwardInterrupt);
  process.removeListener("SIGTERM", forwardTermination);
  if (spawnFailed || code !== 0) {
    process.exitCode = code ?? 1;
    return;
  }
  try {
    await writeFile(
      join(projectRoot, ".next", BUILD_PROVENANCE_NAME),
      serializeBuildProvenance(provenance),
      { encoding: "utf8", flag: "wx" },
    );
  } catch {
    process.stderr.write("No se pudo sellar la procedencia del build LAN.\n");
    process.exitCode = 1;
  }
});

function git(args) {
  return execFileSync("git", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 60_000,
    maxBuffer: 131_072,
  }).trim();
}
