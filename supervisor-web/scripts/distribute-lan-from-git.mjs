import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { cp, lstat, mkdir, mkdtemp, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertExternalStateRoot, compareDirectories, compareSourceUpdate, inventoryDirectory,
  parseClosedSourceContract, runDistributionGit, validateToolVersions,
  verifyContractFiles, verifyDistributionSource,
} from "./distribution-contract.mjs";
import {
  computePlayerIdentity, createArtifactEvidence, createBuildPlan,
  createDependencyEvidence, createDistributionReceipt, decideDependencyCache,
  CONFIG_SCHEMA_VERSION, dependencyCacheRelativePath,
  parseArtifactEvidence, parseDependencyEvidence, playerRelativePath,
  serializeArtifactEvidence, serializeDependencyEvidence,
  serializeDistributionReceipt, UPDATER_VERSION, validateReusableArtifact,
} from "./lan-distribution-contract.mjs";
import { assertDependencySnapshot, measureDependencySnapshot } from "./dependency-snapshot.mjs";
import {
  buildIsolatedNpmEnvironment, rejectProjectNpmConfiguration,
  requireEmptyRegularNpmConfig, verifyEffectiveNpmConfiguration,
} from "./npm-isolation.mjs";
import {
  pinSecureDirectoryPath, pinSecureRegularFile, revalidateSecureDirectoryPin,
  revalidateSecureDirectoryPins, revalidateSecureRegularFilePin,
} from "./path-security.mjs";

const scriptRoot = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptRoot, "..");
const request = parseArguments(process.argv.slice(2));
const contractPath = join(projectRoot, "lan-player", "source-contract.tsv");
const contractBytes = await readBoundedRegular(contractPath, 4_096);
const contract = parseClosedSourceContract(contractBytes.toString("utf8"));
const npmCli = resolveNpmCli();
const npmVersion = execFileSync(process.execPath, [npmCli, "--version"], {
  encoding: "utf8", timeout: 30_000, maxBuffer: 16_384,
}).trim();
const runtime = validateToolVersions(process.version, npmVersion, contract);
const checkoutPin = await pinSecureDirectoryPath(request.checkoutRoot);
const projectPin = await pinSecureDirectoryPath(projectRoot);
await revalidateSecureDirectoryPins(checkoutPin, projectPin);
const source = verifyDistributionSource(projectRoot, request, contract);
await rejectProjectNpmConfiguration(source.checkoutRoot, projectRoot);
const files = await verifyContractFiles(projectRoot, contract);
const playerVersion = await readPlayerVersion(projectRoot);
const playerIdentity = computePlayerIdentity(source.sourceTree, files.lockSha256);
const relativePlayerPath = playerRelativePath(playerIdentity);

assertExternalStateRoot(source.checkoutRoot, request.stateRoot);
await pinSecureDirectoryPath(request.stateRoot, { allowMissing: true });
await mkdir(request.stateRoot, { recursive: true });
const statePin = await pinSecureDirectoryPath(request.stateRoot);
const stateRoot = assertExternalStateRoot(
  source.checkoutRoot, request.stateRoot, checkoutPin.realPath, statePin.realPath,
);
const buildStateRoot = join(stateRoot, ".teremoq-web-build");
const playersRoot = join(stateRoot, "players");
const generationRoot = join(buildStateRoot, "generations");
const npmIsolationRoot = join(buildStateRoot, "npm-isolation");
await revalidateSecureDirectoryPin(statePin);
await Promise.all([
  mkdir(buildStateRoot, { recursive: true }), mkdir(playersRoot, { recursive: true }),
  mkdir(generationRoot, { recursive: true }), mkdir(npmIsolationRoot, { recursive: true }),
]);
const buildStatePin = await pinSecureDirectoryPath(buildStateRoot);
const playersPin = await pinSecureDirectoryPath(playersRoot);
const generationPin = await pinSecureDirectoryPath(generationRoot);
const npmIsolationPin = await pinSecureDirectoryPath(npmIsolationRoot);
const identityParentPin = playersPin;
const finalPlayerRoot = join(stateRoot, relativePlayerPath);
const artifactEvidencePath = join(generationRoot, `${playerIdentity.replace(":", "-")}.json`);
const updateStatePath = join(buildStateRoot, "update-state.json");
const previousUpdate = await readUpdateState(updateStatePath);
const sourceUpdate = compareSourceUpdate(
  source.checkoutRoot, previousUpdate?.source_commit ?? null, source.sourceCommit,
);

const artifactExists = await pathExists(finalPlayerRoot);
const evidenceExists = await pathExists(artifactEvidencePath);
if (artifactExists !== evidenceExists) {
  throw new Error("player/evidencia existente incompletos; distribución rechazada");
}
if (artifactExists) {
  const receipt = await reuseExistingArtifact({
    finalPlayerRoot, artifactEvidencePath, playerIdentity, relativePlayerPath,
    source, files, runtime, request, identityParentPin, generationPin, playerVersion, sourceUpdate,
  });
  await writeUpdateState(updateStatePath, source.sourceCommit, buildStateRoot);
  process.stdout.write(serializeDistributionReceipt(receipt));
} else {
  const receipt = await buildArtifact({
    finalPlayerRoot, artifactEvidencePath, playerIdentity,
    relativePlayerPath, source, files, runtime, request, contract, npmCli,
    checkoutPin, projectPin, statePin, buildStatePin, playersPin, identityParentPin,
    generationPin, npmIsolationPin, npmIsolationRoot, playerVersion, sourceUpdate,
  });
  await writeUpdateState(updateStatePath, source.sourceCommit, buildStateRoot);
  process.stdout.write(serializeDistributionReceipt(receipt));
}

async function reuseExistingArtifact(context) {
  const playerPin = await pinSecureDirectoryPath(context.finalPlayerRoot);
  const evidencePin = await pinSecureRegularFile(context.artifactEvidencePath);
  await revalidateSecureDirectoryPins(context.identityParentPin, playerPin, context.generationPin);
  await revalidateSecureRegularFilePin(evidencePin);
  const evidence = parseArtifactEvidence(
    (await readBoundedRegular(context.artifactEvidencePath, 8_192)).toString("utf8"),
  );
  validateReusableArtifact(evidence, {
    player_identity: context.playerIdentity, player_version: context.playerVersion,
    config_schema_version: CONFIG_SCHEMA_VERSION, source_tree: context.source.sourceTree,
    package_lock_sha256: context.files.lockSha256,
    node_version: context.runtime.nodeVersion, npm_version: context.runtime.npmVersion,
    platform: process.platform, architecture: process.arch,
    player_relative_path: context.relativePlayerPath,
  }, context.request.buildMode);
  const inventory = await inventoryDirectory(context.finalPlayerRoot);
  const measured = {
    manifest: await sha256File(join(context.finalPlayerRoot, "MANIFEST.sha256.json")),
    launcher: await sha256File(join(context.finalPlayerRoot, "lan-launcher.tsv")),
    inventory: inventorySha256(inventory),
  };
  if (measured.manifest !== evidence.manifest_sha256 ||
      measured.launcher !== evidence.launcher_contract_sha256 ||
      measured.inventory !== evidence.artifact_inventory_sha256) {
    throw new Error("player reutilizable no coincide con evidencia sellada");
  }
  return createDistributionReceipt({
    status: "reused", build_mode: context.request.buildMode,
    updater_version: UPDATER_VERSION, player_identity: context.playerIdentity,
    player_version: context.playerVersion, config_schema_version: CONFIG_SCHEMA_VERSION,
    source_commit: context.source.sourceCommit,
    source_tree: context.source.sourceTree, package_lock_sha256: context.files.lockSha256,
    node_version: context.runtime.nodeVersion, npm_version: context.runtime.npmVersion,
    platform: process.platform, architecture: process.arch,
    dependency_status: "not-used", previous_source_commit: context.sourceUpdate.previousSourceCommit,
    source_diff_files: context.sourceUpdate.changedFiles,
    source_diff_sha256: context.sourceUpdate.diffSha256, builds_executed: 0,
    build_verification: evidence.created_build_mode === "integration"
      ? "reused-integration-double" : "reused-node-single",
    manifest_sha256: measured.manifest, launcher_contract_sha256: measured.launcher,
    artifact_inventory_sha256: measured.inventory,
    player_relative_path: context.relativePlayerPath,
  });
}

async function buildArtifact(context) {
  const dependencyDescriptor = {
    package_lock_sha256: context.files.lockSha256,
    node_version: context.runtime.nodeVersion, npm_version: context.runtime.npmVersion,
    platform: process.platform, architecture: process.arch,
  };
  const snapshotRelativePath = dependencyCacheRelativePath(
    dependencyDescriptor.package_lock_sha256, dependencyDescriptor.node_version,
    dependencyDescriptor.npm_version, dependencyDescriptor.platform,
    dependencyDescriptor.architecture,
  );
  const snapshotRoot = join(context.buildStateRoot, snapshotRelativePath);
  const snapshotEvidencePath = `${snapshotRoot}.json`;
  let dependencyStatus = "integration-npm-ci";
  let dependencyEvidence = null;
  if (context.request.buildMode === "node") {
    const snapshotExists = await pathExists(snapshotRoot);
    const snapshotEvidenceExists = await pathExists(snapshotEvidencePath);
    if (snapshotExists !== snapshotEvidenceExists) {
      throw new Error("snapshot/evidencia de dependencias incompletos");
    }
    if (snapshotExists) {
      const snapshotPin = await pinSecureDirectoryPath(snapshotRoot);
      const snapshotEvidencePin = await pinSecureRegularFile(snapshotEvidencePath);
      await revalidateSecureDirectoryPin(snapshotPin);
      await revalidateSecureRegularFilePin(snapshotEvidencePin);
      dependencyEvidence = await readDependencyEvidence(snapshotEvidencePath);
      const decision = decideDependencyCache(dependencyEvidence, dependencyDescriptor,
        context.request.refreshDependencies);
      const measured = await measureDependencySnapshot(snapshotRoot);
      assertDependencySnapshot(measured, dependencyEvidence);
      await revalidateSecureDirectoryPin(snapshotPin);
      await revalidateSecureRegularFilePin(snapshotEvidencePin);
      dependencyStatus = decision.status;
    } else {
      dependencyStatus = decideDependencyCache(null, dependencyDescriptor,
        context.request.refreshDependencies).status;
    }
  }
  const cacheRoot = join(context.buildStateRoot, "npm-download-cache",
    context.files.lockSha256, `${process.platform}-${process.arch}`);
  await mkdir(cacheRoot, { recursive: true });
  const cachePin = await pinSecureDirectoryPath(cacheRoot);
  const isolationPaths = await prepareNpmIsolation(context.npmIsolationRoot, cacheRoot);
  const isolationPins = await Promise.all([
    pinSecureDirectoryPath(isolationPaths.home), pinSecureDirectoryPath(isolationPaths.userProfile),
    pinSecureDirectoryPath(isolationPaths.appData), pinSecureDirectoryPath(isolationPaths.localAppData),
    pinSecureDirectoryPath(isolationPaths.prefix),
  ]);
  const npmConfigPins = await Promise.all([
    pinSecureRegularFile(isolationPaths.userConfig, 0),
    pinSecureRegularFile(isolationPaths.globalConfig, 0),
  ]);
  const childEnv = buildIsolatedNpmEnvironment(process.env, isolationPaths);
  const temporaryRoot = await mkdtemp(join(context.buildStateRoot, "run-"));
  const temporaryPin = await pinSecureDirectoryPath(temporaryRoot);
  const plan = createBuildPlan(context.request.buildMode);
  const checkoutRoots = plan.map((item) => join(temporaryRoot, item.checkout));
  const packageRoots = plan.map((item) => join(temporaryRoot, item.package));
  const activeWorktrees = [];
  const activePins = new Map();
  const packagePins = [];
  let stagedSnapshot = null;
  let stagedSnapshotMeasurement = null;
  let promoted = false;
  let temporaryRemoved = false;
  let evidencePromoted = false;
  let snapshotPromoted = false;
  let snapshotEvidencePromoted = false;
  let primaryFailure = null;
  const cleanupFailures = [];
  try {
    for (let index = 0; index < plan.length; index += 1) {
      const checkout = checkoutRoots[index];
      await pinSecureDirectoryPath(checkout, { allowMissing: true });
      runDistributionGit(context.source.checkoutRoot, [
        "worktree", "add", "--detach", checkout, context.source.sourceCommit,
      ]);
      activeWorktrees.push(checkout);
      const worktreePin = await pinSecureDirectoryPath(checkout);
      activePins.set(checkout, worktreePin);
      const workspace = join(checkout, context.contract.source_subdirectory);
      const workspacePin = await pinSecureDirectoryPath(workspace);
      await rejectProjectNpmConfiguration(checkout, workspace);
      await Promise.all([
        requireEmptyRegularNpmConfig(isolationPaths.userConfig),
        requireEmptyRegularNpmConfig(isolationPaths.globalConfig),
        ...npmConfigPins.map((pin) => revalidateSecureRegularFilePin(pin)),
      ]);
      verifyEffectiveNpmConfiguration(context.npmCli, workspace, childEnv);
      const ciArguments = [
        "ci", "--cache", cacheRoot, "--no-audit", "--no-fund", "--prefer-offline",
      ];
      if (context.request.offline) ciArguments.push("--offline");
      await revalidateSecureDirectoryPins(cachePin, temporaryPin, worktreePin, workspacePin,
        context.npmIsolationPin, ...isolationPins);
      if (context.request.buildMode === "node" && dependencyEvidence !== null) {
        const workspaceModules = join(workspace, "node_modules");
        await requireAbsent(workspaceModules, "worktree contiene node_modules inesperado");
        await cp(snapshotRoot, workspaceModules, { recursive: true, errorOnExist: true });
        assertDependencySnapshot(await measureDependencySnapshot(workspaceModules), dependencyEvidence);
      } else {
        runNpm(context.npmCli, ciArguments, workspace, 900_000, childEnv);
        if (context.request.buildMode === "node") {
          stagedSnapshot = join(temporaryRoot, "dependency-snapshot");
          await cp(join(workspace, "node_modules"), stagedSnapshot, {
            recursive: true, errorOnExist: true,
          });
          stagedSnapshotMeasurement = await measureDependencySnapshot(stagedSnapshot);
        }
      }
      runNpm(context.npmCli, ["run", context.contract.build_script], workspace, 900_000, childEnv);
      await pinSecureDirectoryPath(packageRoots[index], { allowMissing: true });
      runNpm(context.npmCli, [
        "run", context.contract.package_script, "--", "--output", packageRoots[index],
        "--player-identity", context.playerIdentity,
      ], workspace, 900_000, childEnv);
      packagePins[index] = await pinSecureDirectoryPath(packageRoots[index]);
    }
    const inventory = plan.length === 2
      ? await compareDirectories(packageRoots[0], packageRoots[1])
      : await inventoryDirectory(packageRoots[0]);
    const manifestSha256 = await sha256File(join(packageRoots[0], "MANIFEST.sha256.json"));
    const launcherContractSha256 = await sha256File(join(packageRoots[0], "lan-launcher.tsv"));
    const artifactInventorySha256 = inventorySha256(inventory);
    if (stagedSnapshot !== null && stagedSnapshotMeasurement !== null) {
      await mkdir(dirname(snapshotRoot), { recursive: true });
      const snapshotParentPin = await pinSecureDirectoryPath(dirname(snapshotRoot));
      const stagedSnapshotPin = await pinSecureDirectoryPath(stagedSnapshot);
      await requireAbsent(snapshotRoot, "snapshot de dependencias ya existe sin evidencia aceptada");
      await requireAbsent(snapshotEvidencePath, "evidencia de snapshot ya existe sin contenido aceptado");
      await promoteDirectory(stagedSnapshot, snapshotRoot, stagedSnapshotPin, snapshotParentPin);
      snapshotPromoted = true;
      dependencyEvidence = createDependencyEvidence({
        ...dependencyDescriptor,
        snapshot_relative_path: snapshotRelativePath,
        ...stagedSnapshotMeasurement,
      });
      await writeFile(snapshotEvidencePath, serializeDependencyEvidence(dependencyEvidence), {
        encoding: "utf8", flag: "wx",
      });
      snapshotEvidencePromoted = true;
    }
    while (activeWorktrees.length > 0) {
      const checkout = activeWorktrees.at(-1);
      await revalidateSecureDirectoryPins(context.checkoutPin, activePins.get(checkout));
      runDistributionGit(context.source.checkoutRoot, ["worktree", "remove", "--force", checkout]);
      activePins.delete(checkout);
      activeWorktrees.pop();
    }
    const artifactEvidence = createArtifactEvidence({
      player_identity: context.playerIdentity, player_version: context.playerVersion,
      config_schema_version: CONFIG_SCHEMA_VERSION,
      source_tree: context.source.sourceTree, package_lock_sha256: context.files.lockSha256,
      node_version: context.runtime.nodeVersion, npm_version: context.runtime.npmVersion,
      platform: process.platform, architecture: process.arch,
      created_build_mode: context.request.buildMode, created_builds: plan.length,
      build_verification: plan.length === 2 ? "double-build-byte-identical" : "single-build",
      manifest_sha256: manifestSha256, launcher_contract_sha256: launcherContractSha256,
      artifact_inventory_sha256: artifactInventorySha256,
      player_relative_path: context.relativePlayerPath,
    });
    const stagedEvidence = join(temporaryRoot, "artifact-evidence.json");
    await writeFile(stagedEvidence, serializeArtifactEvidence(artifactEvidence), { flag: "wx" });
    await requireAbsent(context.finalPlayerRoot, "ya existe una generación player para la identidad");
    await requireAbsent(context.artifactEvidencePath, "ya existe evidencia para la identidad");
    await promoteDirectory(packageRoots[0], context.finalPlayerRoot, packagePins[0], context.identityParentPin);
    promoted = true;
    await rename(stagedEvidence, context.artifactEvidencePath);
    evidencePromoted = true;
    await rm(temporaryRoot, { recursive: true, force: true });
    temporaryRemoved = true;
    return createDistributionReceipt({
      status: "built", build_mode: context.request.buildMode,
      updater_version: UPDATER_VERSION, player_identity: context.playerIdentity,
      player_version: context.playerVersion, config_schema_version: CONFIG_SCHEMA_VERSION,
      source_commit: context.source.sourceCommit,
      source_tree: context.source.sourceTree, package_lock_sha256: context.files.lockSha256,
      node_version: context.runtime.nodeVersion, npm_version: context.runtime.npmVersion,
      platform: process.platform, architecture: process.arch,
      dependency_status: dependencyStatus,
      previous_source_commit: context.sourceUpdate.previousSourceCommit,
      source_diff_files: context.sourceUpdate.changedFiles,
      source_diff_sha256: context.sourceUpdate.diffSha256,
      builds_executed: plan.length,
      build_verification: plan.length === 2 ? "double-build-byte-identical" : "single-build",
      manifest_sha256: manifestSha256, launcher_contract_sha256: launcherContractSha256,
      artifact_inventory_sha256: artifactInventorySha256,
      player_relative_path: context.relativePlayerPath,
    });
  } catch (cause) { primaryFailure = cause; }
  finally {
    for (const checkout of activeWorktrees.reverse()) {
      try {
        await revalidateSecureDirectoryPins(context.checkoutPin, activePins.get(checkout));
        runDistributionGit(context.source.checkoutRoot, ["worktree", "remove", "--force", checkout]);
      } catch { cleanupFailures.push("worktree"); }
    }
    if (!temporaryRemoved) {
      try { await revalidateSecureDirectoryPin(temporaryPin); await rm(temporaryRoot, { recursive: true, force: true }); }
      catch { cleanupFailures.push("temporary-root"); }
    }
    if (promoted && !evidencePromoted) {
      try {
        const playerPin = await pinSecureDirectoryPath(context.finalPlayerRoot);
        await revalidateSecureDirectoryPins(context.identityParentPin, playerPin);
        await rm(context.finalPlayerRoot, { recursive: true, force: true });
      } catch { cleanupFailures.push("unsealed-player"); }
    }
    if (snapshotPromoted && !snapshotEvidencePromoted) {
      try {
        const snapshotPin = await pinSecureDirectoryPath(snapshotRoot);
        await revalidateSecureDirectoryPin(snapshotPin);
        await rm(snapshotRoot, { recursive: true, force: true });
      } catch { cleanupFailures.push("unsealed-dependency-snapshot"); }
    }
  }
  if (cleanupFailures.length > 0) {
    throw new Error("limpieza acotada incompleta; distribución rechazada", { cause: primaryFailure ?? undefined });
  }
  throw primaryFailure;
}

function parseArguments(args) {
  const allowed = new Set([
    "--checkout-root", "--state-root", "--repository-url", "--repository-ref",
    "--source-commit", "--build-mode",
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
  const required = [...allowed].filter((key) => key !== "--build-mode");
  if (required.some((key) => !Object.hasOwn(values, key))) throw new Error("faltan argumentos de distribución");
  if (!isAbsolute(values["--checkout-root"]) || !isAbsolute(values["--state-root"])) {
    throw new Error("CheckoutRoot y StateRoot deben ser absolutos");
  }
  const buildMode = values["--build-mode"] ?? "integration";
  createBuildPlan(buildMode);
  return Object.freeze({
    checkoutRoot: values["--checkout-root"], stateRoot: values["--state-root"],
    repositoryUrl: values["--repository-url"], repositoryRef: values["--repository-ref"],
    sourceCommit: values["--source-commit"], buildMode, refreshDependencies, offline,
  });
}

async function prepareNpmIsolation(root, cache) {
  const paths = {
    home: join(root, "home"), userProfile: join(root, "user-profile"),
    appData: join(root, "app-data"), localAppData: join(root, "local-app-data"),
    prefix: join(root, "prefix"), userConfig: join(root, "empty-user.npmrc"),
    globalConfig: join(root, "empty-global.npmrc"), cache,
  };
  await Promise.all([
    mkdir(paths.home, { recursive: true }), mkdir(paths.userProfile, { recursive: true }),
    mkdir(paths.appData, { recursive: true }), mkdir(paths.localAppData, { recursive: true }),
    mkdir(paths.prefix, { recursive: true }),
  ]);
  await Promise.all([createEmptyNpmConfig(paths.userConfig), createEmptyNpmConfig(paths.globalConfig)]);
  await Promise.all([requireEmptyRegularNpmConfig(paths.userConfig), requireEmptyRegularNpmConfig(paths.globalConfig)]);
  return paths;
}
async function readDependencyEvidence(path) {
  try { return parseDependencyEvidence((await readBoundedRegular(path, 4_096)).toString("utf8")); }
  catch (cause) {
    if (cause && typeof cause === "object" && "code" in cause && cause.code === "ENOENT") return null;
    throw cause;
  }
}
function resolveNpmCli() { return resolve(dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js"); }
function runNpm(npmCli, args, cwd, timeout, env) {
  const result = spawnSync(process.execPath, [npmCli, ...args], { cwd, stdio: "inherit", timeout, env });
  if (result.error || result.status !== 0) throw new Error("npm/build/package local falló");
}
async function writeUpdateState(path, sourceCommit, stateRoot) {
  const candidate = join(stateRoot, `update-state-${process.pid}.json`);
  const contents = `${JSON.stringify({
    schema_version: 1, updater_version: UPDATER_VERSION, source_commit: sourceCommit,
  })}\n`;
  await writeFile(candidate, contents, { encoding: "utf8", flag: "wx" });
  try { await rename(candidate, path); }
  catch (cause) {
    if (process.platform !== "win32" || !cause || typeof cause !== "object" ||
        !("code" in cause) || !["EEXIST", "EPERM"].includes(cause.code)) throw cause;
    await rm(path, { force: true });
    await rename(candidate, path);
  }
}
async function readUpdateState(path) {
  try {
    const text = (await readBoundedRegular(path, 1_024)).toString("utf8");
    const value = JSON.parse(text);
    if (!value || Array.isArray(value) || Object.keys(value).length !== 3 ||
        value.schema_version !== 1 || value.updater_version !== UPDATER_VERSION ||
        !/^[0-9a-f]{40}$/.test(value.source_commit) ||
        text !== `${JSON.stringify(value)}\n`) throw new Error("estado de updater fuera de contrato");
    return Object.freeze(value);
  } catch (cause) {
    if (cause && typeof cause === "object" && "code" in cause && cause.code === "ENOENT") return null;
    throw cause;
  }
}
async function readPlayerVersion(root) {
  const value = JSON.parse((await readBoundedRegular(join(root, "package.json"), 65_536)).toString("utf8"));
  if (!value || Array.isArray(value) || typeof value.version !== "string" ||
      !/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(value.version)) {
    throw new Error("player_version fuera de contrato");
  }
  return value.version;
}
async function promoteDirectory(source, destination, sourcePin, destinationParentPin) {
  const attempts = process.platform === "win32" ? 20 : 1;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    await revalidateSecureDirectoryPins(sourcePin, destinationParentPin);
    await requireAbsent(destination, "ya existe una generación player para la identidad");
    try { await rename(source, destination); return; }
    catch (cause) {
      const retryable = process.platform === "win32" && cause && typeof cause === "object" &&
        "code" in cause && ["EBUSY", "EPERM"].includes(cause.code);
      if (!retryable || attempt === attempts) throw cause;
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
    }
  }
}
async function createEmptyNpmConfig(path) {
  try { await writeFile(path, "", { encoding: "utf8", flag: "wx" }); }
  catch (cause) {
    if (!cause || typeof cause !== "object" || !("code" in cause) || cause.code !== "EEXIST") throw cause;
  }
}
async function pathExists(path) {
  try { await lstat(path); return true; }
  catch (cause) {
    if (cause && typeof cause === "object" && "code" in cause && cause.code === "ENOENT") return false;
    throw cause;
  }
}
async function requireAbsent(path, message) {
  try { await lstat(path); throw new Error(message); }
  catch (cause) {
    if (cause && typeof cause === "object" && "code" in cause && cause.code === "ENOENT") return;
    throw cause;
  }
}
async function readBoundedRegular(path, limit) {
  const pathStat = await lstat(path);
  if (!pathStat.isFile() || pathStat.isSymbolicLink()) {
    throw new Error("fichero regular fuera de límite");
  }
  const handle = await open(path, "r");
  try {
    const before = await handle.stat();
    if (!before.isFile() || before.size < 2 || before.size > limit ||
        before.dev !== pathStat.dev || before.ino !== pathStat.ino) {
      throw new Error("fichero regular fuera de límite");
    }
    const bytes = await handle.readFile();
    const after = await handle.stat();
    if (bytes.byteLength !== before.size || after.size !== before.size ||
        after.mtimeMs !== before.mtimeMs) throw new Error("fichero cambió durante lectura");
    return bytes;
  } finally {
    await handle.close();
  }
}
async function sha256File(path) { return sha256(await readFile(path)); }
function inventorySha256(inventory) { return sha256(`${JSON.stringify(inventory)}\n`); }
function sha256(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
