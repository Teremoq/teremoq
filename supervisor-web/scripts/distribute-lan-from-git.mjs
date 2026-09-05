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
import {
  buildIsolatedNpmEnvironment,
  rejectProjectNpmConfiguration,
  requireEmptyRegularNpmConfig,
  verifyEffectiveNpmConfiguration,
} from "./npm-isolation.mjs";
import {
  pinSecureDirectoryPath,
  pinSecureRegularFile,
  revalidateSecureDirectoryPin,
  revalidateSecureDirectoryPins,
  revalidateSecureRegularFilePin,
} from "./path-security.mjs";

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
const checkoutPin = await pinSecureDirectoryPath(request.checkoutRoot);
const projectPin = await pinSecureDirectoryPath(projectRoot);
await revalidateSecureDirectoryPins(checkoutPin, projectPin);
const source = verifyDistributionSource(projectRoot, request, contract);
await revalidateSecureDirectoryPins(checkoutPin, projectPin);
await rejectProjectNpmConfiguration(source.checkoutRoot, projectRoot);
const files = await verifyContractFiles(projectRoot, contract);
assertExternalStateRoot(source.checkoutRoot, request.stateRoot);
await pinSecureDirectoryPath(request.stateRoot, { allowMissing: true });
await mkdir(request.stateRoot, { recursive: true });
const statePin = await pinSecureDirectoryPath(request.stateRoot);
const stateRoot = assertExternalStateRoot(
  source.checkoutRoot,
  request.stateRoot,
  checkoutPin.realPath,
  statePin.realPath,
);
const buildStateRoot = join(stateRoot, ".teremoq-web-build");
const playersRoot = join(stateRoot, "players");
await revalidateSecureDirectoryPin(statePin);
await Promise.all([
  mkdir(buildStateRoot, { recursive: true }),
  mkdir(playersRoot, { recursive: true }),
]);
const buildStatePin = await pinSecureDirectoryPath(buildStateRoot);
const playersPin = await pinSecureDirectoryPath(playersRoot);
const generationRoot = join(buildStateRoot, "generations");
const npmCacheRoot = join(buildStateRoot, "npm-cache");
const npmIsolationRoot = join(buildStateRoot, "npm-isolation");
await revalidateSecureDirectoryPins(statePin, buildStatePin, playersPin);
await Promise.all([
  mkdir(generationRoot, { recursive: true }),
  mkdir(npmCacheRoot, { recursive: true }),
  mkdir(npmIsolationRoot, { recursive: true }),
]);
const generationPin = await pinSecureDirectoryPath(generationRoot);
const npmCachePin = await pinSecureDirectoryPath(npmCacheRoot);
const npmIsolationPin = await pinSecureDirectoryPath(npmIsolationRoot);
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
const cacheRoot = join(npmCacheRoot, files.lockSha256);
await revalidateSecureDirectoryPins(buildStatePin, npmCachePin);
await mkdir(cacheRoot, { recursive: true });
const cachePin = await pinSecureDirectoryPath(cacheRoot);
const isolationPaths = {
  home: join(npmIsolationRoot, "home"),
  userProfile: join(npmIsolationRoot, "user-profile"),
  appData: join(npmIsolationRoot, "app-data"),
  localAppData: join(npmIsolationRoot, "local-app-data"),
  prefix: join(npmIsolationRoot, "prefix"),
  userConfig: join(npmIsolationRoot, "empty-user.npmrc"),
  globalConfig: join(npmIsolationRoot, "empty-global.npmrc"),
  cache: cacheRoot,
};
await revalidateSecureDirectoryPin(npmIsolationPin);
await Promise.all([
  mkdir(isolationPaths.home, { recursive: true }),
  mkdir(isolationPaths.userProfile, { recursive: true }),
  mkdir(isolationPaths.appData, { recursive: true }),
  mkdir(isolationPaths.localAppData, { recursive: true }),
  mkdir(isolationPaths.prefix, { recursive: true }),
]);
const isolationPins = await Promise.all([
  pinSecureDirectoryPath(isolationPaths.home),
  pinSecureDirectoryPath(isolationPaths.userProfile),
  pinSecureDirectoryPath(isolationPaths.appData),
  pinSecureDirectoryPath(isolationPaths.localAppData),
  pinSecureDirectoryPath(isolationPaths.prefix),
]);
await revalidateSecureDirectoryPins(npmIsolationPin, ...isolationPins);
await Promise.all([
  createEmptyNpmConfig(isolationPaths.userConfig),
  createEmptyNpmConfig(isolationPaths.globalConfig),
]);
await Promise.all([
  requireEmptyRegularNpmConfig(isolationPaths.userConfig),
  requireEmptyRegularNpmConfig(isolationPaths.globalConfig),
]);
const npmConfigPins = await Promise.all([
  pinSecureRegularFile(isolationPaths.userConfig, 0),
  pinSecureRegularFile(isolationPaths.globalConfig, 0),
]);
const childEnv = buildIsolatedNpmEnvironment(process.env, isolationPaths);

await revalidateSecureDirectoryPins(buildStatePin, cachePin, npmIsolationPin, ...isolationPins);
const temporaryRoot = await mkdtemp(join(buildStateRoot, "run-"));
const temporaryPin = await pinSecureDirectoryPath(temporaryRoot);
const checkoutRoots = [join(temporaryRoot, "checkout-a"), join(temporaryRoot, "checkout-b")];
const packageRoots = [join(temporaryRoot, "package-a"), join(temporaryRoot, "package-b")];
const activeWorktrees = [];
const activeWorktreePins = new Map();
const packagePins = [];
let promoted = false;
let temporaryRemoved = false;
let primaryFailure = null;
const cleanupFailures = [];
let finalProvenance = null;
try {
  for (let index = 0; index < checkoutRoots.length; index += 1) {
    const checkout = checkoutRoots[index];
    await revalidateSecureDirectoryPins(
      checkoutPin, projectPin, statePin, buildStatePin, cachePin, temporaryPin,
      npmIsolationPin, ...isolationPins,
    );
    await pinSecureDirectoryPath(checkout, { allowMissing: true });
    runGit(source.checkoutRoot, ["worktree", "add", "--detach", checkout, source.sourceCommit]);
    activeWorktrees.push(checkout);
    const worktreePin = await pinSecureDirectoryPath(checkout);
    activeWorktreePins.set(checkout, worktreePin);
    const workspace = join(checkout, contract.source_subdirectory);
    const workspacePin = await pinSecureDirectoryPath(workspace);
    await rejectProjectNpmConfiguration(checkout, workspace);
    await Promise.all([
      requireEmptyRegularNpmConfig(isolationPaths.userConfig),
      requireEmptyRegularNpmConfig(isolationPaths.globalConfig),
      ...npmConfigPins.map((pin) => revalidateSecureRegularFilePin(pin)),
    ]);
    verifyEffectiveNpmConfiguration(npmCli, workspace, childEnv);
    const ciArguments = [
      "ci", "--cache", cacheRoot, "--no-audit", "--no-fund", "--prefer-offline",
    ];
    if (request.offline) ciArguments.push("--offline");
    await revalidateSecureDirectoryPins(
      checkoutPin, statePin, buildStatePin, cachePin, temporaryPin,
      worktreePin, workspacePin, npmIsolationPin, ...isolationPins,
    );
    await Promise.all(npmConfigPins.map((pin) => revalidateSecureRegularFilePin(pin)));
    runNpm(npmCli, ciArguments, workspace, 900_000, childEnv);
    await revalidateSecureDirectoryPins(
      checkoutPin, statePin, buildStatePin, cachePin, temporaryPin,
      worktreePin, workspacePin, npmIsolationPin, ...isolationPins,
    );
    await Promise.all(npmConfigPins.map((pin) => revalidateSecureRegularFilePin(pin)));
    runNpm(npmCli, ["run", contract.build_script], workspace, 900_000, childEnv);
    await revalidateSecureDirectoryPins(
      checkoutPin, statePin, buildStatePin, cachePin, temporaryPin,
      worktreePin, workspacePin, npmIsolationPin, ...isolationPins,
    );
    await Promise.all(npmConfigPins.map((pin) => revalidateSecureRegularFilePin(pin)));
    await pinSecureDirectoryPath(packageRoots[index], { allowMissing: true });
    runNpm(npmCli, [
      "run", contract.package_script, "--", "--output", packageRoots[index],
      "--source-commit", source.sourceCommit,
    ], workspace, 900_000, childEnv);
    packagePins[index] = await pinSecureDirectoryPath(packageRoots[index]);
  }

  await revalidateSecureDirectoryPins(
    checkoutPin, statePin, buildStatePin, playersPin, generationPin, cachePin,
    temporaryPin, packagePins[0], packagePins[1], npmIsolationPin, ...isolationPins,
  );
  const inventory = await compareDirectories(packageRoots[0], packageRoots[1]);
  const manifestSha256 = await sha256File(join(packageRoots[0], "MANIFEST.sha256.json"));
  const launcherContractSha256 = await sha256File(join(packageRoots[0], "lan-launcher.tsv"));
  const inventorySha256 = createHash("sha256")
    .update(`${JSON.stringify(inventory)}\n`)
    .digest("hex");
  while (activeWorktrees.length > 0) {
    const checkout = activeWorktrees.at(-1);
    await revalidateSecureDirectoryPins(checkoutPin, activeWorktreePins.get(checkout));
    runGit(source.checkoutRoot, ["worktree", "remove", "--force", checkout]);
    activeWorktreePins.delete(checkout);
    activeWorktrees.pop();
  }
  await revalidateSecureDirectoryPins(
    checkoutPin, statePin, buildStatePin, playersPin, generationPin, cachePin,
    temporaryPin, packagePins[0], packagePins[1], npmIsolationPin, ...isolationPins,
  );
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
  await pinSecureDirectoryPath(finalPlayerRoot, { allowMissing: true });
  await revalidateSecureDirectoryPins(
    statePin, buildStatePin, playersPin, generationPin, temporaryPin, packagePins[0],
  );
  await promoteDirectory(packageRoots[0], finalPlayerRoot, packagePins[0], playersPin);
  const finalPlayerPin = await pinSecureDirectoryPath(finalPlayerRoot);
  await revalidateSecureDirectoryPins(finalPlayerPin, generationPin, temporaryPin);
  await rename(stagedProvenance, finalProvenance);
  await revalidateSecureDirectoryPins(finalPlayerPin, generationPin, temporaryPin);
  await rm(temporaryRoot, { recursive: true, force: true });
  temporaryRemoved = true;
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
    try {
      await revalidateSecureDirectoryPins(checkoutPin, activeWorktreePins.get(checkout));
      runGit(source.checkoutRoot, ["worktree", "remove", "--force", checkout]);
    }
    catch { cleanupFailures.push("worktree"); }
  }
  if (!temporaryRemoved) {
    try {
      await revalidateSecureDirectoryPin(temporaryPin);
      await rm(temporaryRoot, { recursive: true, force: true });
    }
    catch { cleanupFailures.push("temporary-root"); }
  }
  if (!promoted) {
    try {
      if (await pathExists(finalPlayerRoot)) {
        const unpromotedPin = await pinSecureDirectoryPath(finalPlayerRoot);
        await revalidateSecureDirectoryPins(playersPin, unpromotedPin);
        await rm(finalPlayerRoot, { recursive: true, force: true });
      }
    }
    catch { cleanupFailures.push("unpromoted-player"); }
    if (finalProvenance !== null) {
      try {
        await revalidateSecureDirectoryPin(generationPin);
        if (await pathExists(finalProvenance)) {
          const provenancePin = await pinSecureRegularFile(finalProvenance);
          await revalidateSecureRegularFilePin(provenancePin);
          await rm(finalProvenance, { force: true });
        }
      }
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
  return resolve(dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js");
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

async function promoteDirectory(source, destination, sourcePin, destinationParentPin) {
  const attempts = process.platform === "win32" ? 20 : 1;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    await revalidateSecureDirectoryPins(sourcePin, destinationParentPin);
    await requireAbsent(destination, "ya existe una generación player para source_commit");
    try {
      await rename(source, destination);
      return;
    } catch (cause) {
      const retryable = process.platform === "win32" && cause && typeof cause === "object" &&
        "code" in cause && ["EBUSY", "EPERM"].includes(cause.code);
      if (!retryable || attempt === attempts) throw cause;
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
    }
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

async function createEmptyNpmConfig(path) {
  try {
    await writeFile(path, "", { encoding: "utf8", flag: "wx" });
  } catch (cause) {
    if (!cause || typeof cause !== "object" || !("code" in cause) || cause.code !== "EEXIST") {
      throw cause;
    }
  }
}

async function pathExists(path) {
  try {
    await lstat(path);
    return true;
  } catch (cause) {
    if (cause && typeof cause === "object" && "code" in cause && cause.code === "ENOENT") {
      return false;
    }
    throw cause;
  }
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
