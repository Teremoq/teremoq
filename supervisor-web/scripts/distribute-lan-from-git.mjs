import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertExternalStateRoot,
  compareSourceUpdate,
  compareDirectories,
  dependencyDecision,
  parseClosedSourceContract,
  validateToolVersions,
  verifyContractFiles,
  verifyDistributionSource,
} from "./distribution-contract.mjs";

const scriptRoot = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptRoot, "..");
const contractPath = join(projectRoot, "lan-player", "source-contract.tsv");
const request = parseArguments(process.argv.slice(2));
const contractBytes = await readBoundedRegular(contractPath, 4_096);
const contract = parseClosedSourceContract(contractBytes.toString("utf8"));
const npmCli = resolveNpmCli();
const npmVersion = execFileSync(process.execPath, [npmCli, "--version"], {
  encoding: "utf8",
  timeout: 30_000,
  maxBuffer: 16_384,
}).trim();
const runtime = validateToolVersions(process.version, npmVersion, contract);
const source = verifyDistributionSource(projectRoot, request, contract);
const files = await verifyContractFiles(projectRoot, contract);
const stateRoot = assertExternalStateRoot(source.checkoutRoot, request.stateRoot);
await ensureRoot(stateRoot);
const buildStateRoot = join(stateRoot, ".teremoq-web-build");
const playersRoot = join(stateRoot, "players");
await Promise.all([mkdir(buildStateRoot, { recursive: true }), mkdir(playersRoot, { recursive: true })]);
await rejectSymlink(buildStateRoot);
await rejectSymlink(playersRoot);
const finalPlayerRoot = join(playersRoot, source.sourceCommit);
await requireAbsent(finalPlayerRoot, "ya existe una generación player para source_commit");

const dependencyStatePath = join(buildStateRoot, "dependency-state.tsv");
const previousState = await readPreviousState(dependencyStatePath);
const dependencyMode = dependencyDecision(
  previousState?.lockSha256 ?? null,
  files.lockSha256,
  request.refreshDependencies,
);
const sourceUpdate = compareSourceUpdate(
  source.checkoutRoot,
  previousState?.sourceCommit ?? null,
  source.sourceCommit,
);
const cacheRoot = join(buildStateRoot, "npm-cache", files.lockSha256);
await mkdir(cacheRoot, { recursive: true });
await rejectSymlink(cacheRoot);
const emptyNpmConfig = join(buildStateRoot, "empty.npmrc");
try {
  await writeFile(emptyNpmConfig, "", { encoding: "utf8", flag: "wx" });
} catch (cause) {
  if (!cause || typeof cause !== "object" || !("code" in cause) || cause.code !== "EEXIST") {
    throw cause;
  }
}
const emptyNpmConfigStat = await lstat(emptyNpmConfig);
if (!emptyNpmConfigStat.isFile() || emptyNpmConfigStat.isSymbolicLink() ||
    emptyNpmConfigStat.size !== 0) {
  throw new Error("config npm aislada fuera de contrato");
}
const childEnv = buildChildEnvironment(cacheRoot, emptyNpmConfig);

const temporaryRoot = await mkdtemp(join(buildStateRoot, "run-"));
const checkoutRoots = [join(temporaryRoot, "checkout-a"), join(temporaryRoot, "checkout-b")];
const packageRoots = [join(temporaryRoot, "package-a"), join(temporaryRoot, "package-b")];
const activeWorktrees = [];
let promoted = false;
let primaryFailure = null;
const cleanupFailures = [];
let finalProvenance = null;
try {
  for (let index = 0; index < checkoutRoots.length; index += 1) {
    const checkout = checkoutRoots[index];
    runGit(source.checkoutRoot, ["worktree", "add", "--detach", checkout, source.sourceCommit]);
    activeWorktrees.push(checkout);
    const workspace = join(checkout, contract.source_subdirectory);
    const ciArguments = [
      "ci", "--cache", cacheRoot, "--no-audit", "--no-fund", "--prefer-offline",
    ];
    if (request.offline) ciArguments.push("--offline");
    runNpm(npmCli, ciArguments, workspace, 900_000, childEnv);
    runNpm(npmCli, ["run", contract.build_script], workspace, 900_000, childEnv);
    runNpm(npmCli, [
      "run", contract.package_script, "--", "--output", packageRoots[index],
      "--source-commit", source.sourceCommit,
    ], workspace, 900_000, childEnv);
  }

  const inventory = await compareDirectories(packageRoots[0], packageRoots[1]);
  const manifestSha256 = await sha256File(join(packageRoots[0], "MANIFEST.sha256.json"));
  const launcherContractSha256 = await sha256File(join(packageRoots[0], "lan-launcher.tsv"));
  const inventorySha256 = createHash("sha256")
    .update(`${JSON.stringify(inventory)}\n`)
    .digest("hex");
  while (activeWorktrees.length > 0) {
    const checkout = activeWorktrees.at(-1);
    runGit(source.checkoutRoot, ["worktree", "remove", "--force", checkout]);
    activeWorktrees.pop();
  }
  const generationRoot = join(buildStateRoot, "generations");
  await mkdir(generationRoot, { recursive: true });
  const provenance = [
    "schema_version\t1",
    `repository_url\t${request.repositoryUrl}`,
    `repository_ref\t${request.repositoryRef}`,
    `source_commit\t${source.sourceCommit}`,
    `source_tree\t${source.sourceTree}`,
    `source_contract_sha256\t${sha256(contractBytes)}`,
    `package_lock_sha256\t${files.lockSha256}`,
    `package_json_sha256\t${files.packageJsonSha256}`,
    `node_version\t${runtime.nodeVersion}`,
    `npm_version\t${runtime.npmVersion}`,
    `dependency_mode\t${dependencyMode}`,
    `previous_source_commit\t${sourceUpdate.previousSourceCommit}`,
    `source_diff_files\t${sourceUpdate.changedFiles}`,
    `source_diff_sha256\t${sourceUpdate.diffSha256}`,
    "independent_builds\t2",
    "byte_identical\ttrue",
    `player_manifest_sha256\t${manifestSha256}`,
    `launcher_contract_sha256\t${launcherContractSha256}`,
    `inventory_sha256\t${inventorySha256}`,
    `player_relative_path\tplayers/${source.sourceCommit}`,
    "",
  ].join("\n");
  const dependencyState = [
    "schema_version\t1",
    `source_commit\t${source.sourceCommit}`,
    `package_lock_sha256\t${files.lockSha256}`,
    `node_major\t${contract.node_major}`,
    `npm_major\t${contract.npm_major}`,
    `cache_relative_path\tnpm-cache/${files.lockSha256}`,
    "",
  ].join("\n");
  await replaceDependencyState(dependencyStatePath, dependencyState, temporaryRoot);
  const stagedProvenance = join(temporaryRoot, "generation.tsv");
  finalProvenance = join(generationRoot, `${source.sourceCommit}.tsv`);
  await writeFile(stagedProvenance, provenance, { flag: "wx" });
  await requireAbsent(finalProvenance, "ya existe procedencia para source_commit");
  await rename(packageRoots[0], finalPlayerRoot);
  await rename(stagedProvenance, finalProvenance);
  await rm(temporaryRoot, { recursive: true, force: true });
  promoted = true;
  process.stdout.write(`${JSON.stringify({
    status: "built-from-clean-git-source",
    source_commit: source.sourceCommit,
    source_tree: source.sourceTree,
    package_lock_sha256: files.lockSha256,
    dependency_mode: dependencyMode,
    previous_source_commit: sourceUpdate.previousSourceCommit,
    source_diff_files: sourceUpdate.changedFiles,
    source_diff_sha256: sourceUpdate.diffSha256,
    independent_builds: 2,
    byte_identical: true,
    manifest_sha256: manifestSha256,
    player_relative_path: `players/${source.sourceCommit}`,
  })}\n`);
} catch (cause) {
  primaryFailure = cause;
} finally {
  for (const checkout of activeWorktrees.reverse()) {
    try { runGit(source.checkoutRoot, ["worktree", "remove", "--force", checkout]); }
    catch { cleanupFailures.push("worktree"); }
  }
  try { await rm(temporaryRoot, { recursive: true, force: true }); }
  catch { cleanupFailures.push("temporary-root"); }
  if (!promoted) {
    try { await rm(finalPlayerRoot, { recursive: true, force: true }); }
    catch { cleanupFailures.push("unpromoted-player"); }
    if (finalProvenance !== null) {
      try { await rm(finalProvenance, { force: true }); }
      catch { cleanupFailures.push("unpromoted-provenance"); }
    }
  }
}
if (cleanupFailures.length > 0) {
  throw new Error("limpieza acotada incompleta; no se acepta la distribución", {
    cause: primaryFailure ?? undefined,
  });
}
if (primaryFailure) throw primaryFailure;

function parseArguments(args) {
  const allowed = new Set([
    "--checkout-root", "--state-root", "--repository-url", "--repository-ref",
    "--source-commit",
  ]);
  const values = Object.create(null);
  let refreshDependencies = false;
  let offline = false;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--refresh-dependencies" || argument === "--offline") {
      if ((argument === "--refresh-dependencies" && refreshDependencies) ||
          (argument === "--offline" && offline)) throw new Error("flag duplicado");
      if (argument === "--refresh-dependencies") refreshDependencies = true;
      else offline = true;
      continue;
    }
    if (!allowed.has(argument) || Object.hasOwn(values, argument) ||
        index + 1 >= args.length || args[index + 1].startsWith("--")) {
      throw new Error("argumentos de distribución inválidos");
    }
    values[argument] = args[++index];
  }
  if (Object.keys(values).length !== allowed.size) throw new Error("faltan argumentos de distribución");
  if (!isAbsolute(values["--checkout-root"]) || !isAbsolute(values["--state-root"])) {
    throw new Error("CheckoutRoot y StateRoot deben ser absolutos");
  }
  return Object.freeze({
    checkoutRoot: values["--checkout-root"],
    stateRoot: values["--state-root"],
    repositoryUrl: values["--repository-url"],
    repositoryRef: values["--repository-ref"],
    sourceCommit: values["--source-commit"],
    refreshDependencies,
    offline,
  });
}

function resolveNpmCli() {
  const value = process.env.npm_execpath;
  if (!value || !isAbsolute(value)) throw new Error("ejecuta mediante npm 10.x desde el checkout");
  return resolve(value);
}

function runNpm(npmCli, args, cwd, timeout, env) {
  const result = spawnSync(process.execPath, [npmCli, ...args], {
    cwd,
    stdio: "inherit",
    timeout,
    env,
  });
  if (result.error || result.status !== 0) throw new Error("npm/build/package local falló");
}

function buildChildEnvironment(cacheRoot, userConfigPath) {
  const env = Object.create(null);
  for (const key of [
    "PATH", "Path", "SystemRoot", "SYSTEMROOT", "ComSpec", "PATHEXT",
    "TEMP", "TMP", "TMPDIR", "LANG", "LC_ALL", "HOME", "USERPROFILE",
    "APPDATA", "LOCALAPPDATA",
  ]) {
    if (typeof process.env[key] === "string") env[key] = process.env[key];
  }
  env.CI = "1";
  env.NO_COLOR = "1";
  env.npm_config_cache = cacheRoot;
  env.npm_config_userconfig = userConfigPath;
  env.NPM_CONFIG_USERCONFIG = userConfigPath;
  return env;
}

async function replaceDependencyState(path, contents, temporaryRoot) {
  const candidate = join(temporaryRoot, "dependency-state.tsv");
  await writeFile(candidate, contents, { encoding: "utf8", flag: "wx" });
  try {
    await rename(candidate, path);
  } catch (cause) {
    if (process.platform !== "win32" || !cause || typeof cause !== "object" ||
        !("code" in cause) || !["EEXIST", "EPERM"].includes(cause.code)) throw cause;
    await rm(path, { force: true });
    await rename(candidate, path);
  }
}

function runGit(cwd, args) {
  execFileSync("git", ["-C", cwd, ...args], {
    stdio: "ignore",
    timeout: 120_000,
    maxBuffer: 131_072,
  });
}

async function readPreviousState(path) {
  try {
    const bytes = await readBoundedRegular(path, 4_096);
    const values = new Map();
    for (const line of bytes.toString("utf8").split(/\r?\n/)) {
      if (line === "") continue;
      const fields = line.split("\t");
      if (fields.length !== 2 || values.has(fields[0])) throw new Error("estado de dependencias inválido");
      values.set(fields[0], fields[1]);
    }
    const expected = [
      "schema_version", "source_commit", "package_lock_sha256", "node_major",
      "npm_major", "cache_relative_path",
    ];
    if (values.size !== expected.length || expected.some((key) => !values.has(key)) ||
        values.get("schema_version") !== "1" ||
        !/^[0-9a-f]{40}$/.test(values.get("source_commit") ?? "") ||
        !/^[0-9a-f]{64}$/.test(values.get("package_lock_sha256") ?? "") ||
        values.get("node_major") !== "22" || values.get("npm_major") !== "10" ||
        values.get("cache_relative_path") !== `npm-cache/${values.get("package_lock_sha256")}`) {
      throw new Error("estado de dependencias fuera de contrato");
    }
    return Object.freeze({
      sourceCommit: values.get("source_commit"),
      lockSha256: values.get("package_lock_sha256"),
    });
  } catch (cause) {
    if (cause && typeof cause === "object" && "code" in cause && cause.code === "ENOENT") return null;
    throw cause;
  }
}

async function ensureRoot(path) {
  try {
    await rejectSymlink(path);
  } catch (cause) {
    if (!cause || typeof cause !== "object" || !("code" in cause) || cause.code !== "ENOENT") throw cause;
    await mkdir(path, { recursive: true });
    await rejectSymlink(path);
  }
}

async function rejectSymlink(path) {
  const stat = await lstat(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("raíz externa no es directorio regular");
}

async function requireAbsent(path, message) {
  try {
    await lstat(path);
    throw new Error(message);
  } catch (cause) {
    if (cause && typeof cause === "object" && "code" in cause && cause.code === "ENOENT") return;
    throw cause;
  }
}

async function readBoundedRegular(path, limit) {
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 2 || stat.size > limit) {
    throw new Error("fichero regular fuera de límite");
  }
  const bytes = await readFile(path);
  if (bytes.byteLength !== stat.size) throw new Error("fichero cambió durante lectura");
  return bytes;
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}
