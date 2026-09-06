import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { lstat, readFile, readdir } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";

export const DISTRIBUTION_GIT_PREFIX = Object.freeze([
  "--no-replace-objects",
  "-c", "core.hooksPath=NUL",
  "-c", "core.fsmonitor=false",
  "-c", "core.autocrlf=false",
  "-c", "core.eol=lf",
  "-c", "core.safecrlf=true",
  "-c", "protocol.file.allow=never",
]);

export const SOURCE_CONTRACT_KEYS = Object.freeze([
  "schema_version",
  "repository_url",
  "source_subdirectory",
  "package_lock_relative_path",
  "package_lock_sha256",
  "package_json_relative_path",
  "package_json_sha256",
  "node_major",
  "npm_major",
  "build_script",
  "package_script",
  "output_contract",
  "future_repository_boundary",
  "source_commit",
  "player_identity_scheme",
  "receipt_schema_version",
  "dependency_evidence_schema_version",
  "artifact_evidence_schema_version",
  "integration_builds",
  "node_builds",
  "updater_version",
  "player_version_source",
  "config_schema_version",
  "player_path_scheme",
  "dependency_snapshot_scheme",
]);

export function parseClosedSourceContract(text) {
  if (typeof text !== "string" || Buffer.byteLength(text, "utf8") > 4_096) {
    throw new Error("contrato de fuente ausente o fuera de límite");
  }
  const values = Object.create(null);
  for (const line of text.split(/\r?\n/)) {
    if (line === "" || line.startsWith("#")) continue;
    const fields = line.split("\t");
    if (fields.length !== 2 || !SOURCE_CONTRACT_KEYS.includes(fields[0]) ||
        Object.hasOwn(values, fields[0]) || fields[1] === "") {
      throw new Error("contrato de fuente abierto o duplicado");
    }
    values[fields[0]] = fields[1];
  }
  if (Object.keys(values).length !== SOURCE_CONTRACT_KEYS.length) {
    throw new Error("contrato de fuente incompleto");
  }
  if (values.schema_version !== "3" ||
      values.repository_url !== "https://github.com/Teremoq/teremoq" ||
      values.source_subdirectory !== "supervisor-web" ||
      values.package_lock_relative_path !== "package-lock.json" ||
      !/^[0-9a-f]{64}$/.test(values.package_lock_sha256) ||
      values.package_json_relative_path !== "package.json" ||
      !/^[0-9a-f]{64}$/.test(values.package_json_sha256) ||
      values.node_major !== "22" || values.npm_major !== "10" ||
      values.build_script !== "build:lan" || values.package_script !== "package:lan" ||
      values.output_contract !== "external-state-root-only" ||
      values.future_repository_boundary !== "teremoq-client" ||
      values.source_commit !== "<runtime-exact-head>" ||
      values.player_identity_scheme !== "sha256-git-tree-lock-v1" ||
      values.receipt_schema_version !== "1" ||
      values.dependency_evidence_schema_version !== "1" ||
      values.artifact_evidence_schema_version !== "1" ||
      values.integration_builds !== "2" || values.node_builds !== "1" ||
      values.updater_version !== "2.0.0" ||
      values.player_version_source !== "package-json-version" ||
      values.config_schema_version !== "1" ||
      values.player_path_scheme !== "identity-only-v1" ||
      values.dependency_snapshot_scheme !== "lock-runtime-platform-arch-v1") {
    throw new Error("valores del contrato de fuente fuera de política");
  }
  return Object.freeze(values);
}

export function verifyDistributionSource(
  projectRoot,
  request,
  contract,
  runGit = runDistributionGit,
) {
  if (!request || request.repositoryUrl !== contract.repository_url ||
      typeof request.repositoryRef !== "string" ||
      !/^refs\/heads\/[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/.test(request.repositoryRef) ||
      !/^[0-9a-f]{40}$/.test(request.sourceCommit)) {
    throw new Error("identidad Git de distribución inválida");
  }
  const checkoutRoot = resolve(request.checkoutRoot);
  const expectedProject = join(checkoutRoot, contract.source_subdirectory);
  if (resolve(projectRoot) !== expectedProject) {
    throw new Error("supervisor-web no coincide con el checkout esperado");
  }
  const topLevel = resolve(runGit(checkoutRoot, ["rev-parse", "--show-toplevel"]));
  if (topLevel !== checkoutRoot) throw new Error("CheckoutRoot no es la raíz Git exacta");
  const resolvedCommit = runGit(checkoutRoot, [
    "rev-parse", "--verify", `${request.sourceCommit}^{commit}`,
  ]);
  if (resolvedCommit !== request.sourceCommit) throw new Error("commit Git no resoluble exacto");
  if (runGit(checkoutRoot, ["rev-parse", "HEAD"]) !== request.sourceCommit) {
    throw new Error("HEAD no coincide con source_commit");
  }
  if (runGit(checkoutRoot, ["rev-parse", "--verify", `${request.repositoryRef}^{commit}`]) !==
      request.sourceCommit) {
    throw new Error("repository_ref no coincide con source_commit");
  }
  if (runGit(checkoutRoot, ["symbolic-ref", "--quiet", "HEAD"]) !== request.repositoryRef) {
    throw new Error("checkout no está en repository_ref");
  }
  const status = runGit(checkoutRoot, ["status", "--porcelain=v1", "--untracked-files=all"]);
  if (status !== "") {
    const entries = status.split("\n");
    const tracked = entries.some((entry) => !entry.startsWith("?? "));
    const untracked = entries.some((entry) => entry.startsWith("?? "));
    const category = tracked && untracked ? "tracked-and-untracked" : tracked ? "tracked" : "untracked";
    throw new Error(`checkout Git no está limpio (${category})`);
  }
  const remotes = lines(runGit(checkoutRoot, ["remote"]));
  if (remotes.length !== 1 || remotes[0] !== "origin") {
    throw new Error("se requiere un único remote origin");
  }
  const fetchUrls = lines(runGit(checkoutRoot, ["config", "--get-all", "remote.origin.url"]));
  if (fetchUrls.length !== 1 || fetchUrls[0] !== request.repositoryUrl) {
    throw new Error("URL fetch de origin no coincide");
  }
  const pushUrls = lines(runGit(checkoutRoot, [
    "config", "--get-all", "remote.origin.pushurl",
  ], true));
  if (pushUrls.length > 1 || (pushUrls.length === 1 && pushUrls[0] !== request.repositoryUrl)) {
    throw new Error("URL push de origin no coincide");
  }
  const sourceTree = runGit(checkoutRoot, [
    "rev-parse", `${request.sourceCommit}:${contract.source_subdirectory}`,
  ]);
  if (!/^[0-9a-f]{40}$/.test(sourceTree)) throw new Error("árbol supervisor-web inválido");
  return Object.freeze({ checkoutRoot, sourceCommit: request.sourceCommit, sourceTree });
}

export function validateToolVersions(nodeVersion, npmVersion, contract) {
  if (!new RegExp(`^v${contract.node_major}\\.[0-9]+\\.[0-9]+$`).test(nodeVersion) ||
      !new RegExp(`^${contract.npm_major}\\.[0-9]+\\.[0-9]+$`).test(npmVersion)) {
    throw new Error("se requieren Node 22.x y npm 10.x exactos");
  }
  return Object.freeze({ nodeVersion, npmVersion });
}

export function dependencyDecision(previousLockSha256, currentLockSha256, refresh) {
  if (previousLockSha256 === null) return "initial-npm-ci";
  if (previousLockSha256 === currentLockSha256) return "reused-lock-cache";
  if (!refresh) throw new Error("package-lock cambió; exige --refresh-dependencies");
  return "explicit-lock-refresh";
}

export function compareSourceUpdate(
  checkoutRoot,
  previousSourceCommit,
  currentSourceCommit,
  runGit = runDistributionGit,
) {
  if (previousSourceCommit === null) {
    return Object.freeze({
      previousSourceCommit: "none",
      changedFiles: 0,
      diffSha256: createHash("sha256").update("").digest("hex"),
    });
  }
  if (!/^[0-9a-f]{40}$/.test(previousSourceCommit) ||
      !/^[0-9a-f]{40}$/.test(currentSourceCommit)) {
    throw new Error("commit previo de distribución inválido");
  }
  if (runGit(checkoutRoot, [
    "rev-parse", "--verify", `${previousSourceCommit}^{commit}`,
  ]) !== previousSourceCommit) {
    throw new Error("commit previo de distribución no resoluble");
  }
  const diff = runGit(checkoutRoot, [
    "diff", "--name-status", "--no-renames",
    previousSourceCommit, currentSourceCommit, "--", "supervisor-web",
  ]);
  if (Buffer.byteLength(diff, "utf8") > 262_144) {
    throw new Error("diff supervisor-web supera el límite");
  }
  const lines = diff === "" ? [] : diff.split("\n");
  if (lines.length > 4_096 || lines.some((line) => {
    const fields = line.split("\t");
    return fields.length !== 2 || !/^[ACDMRTUXB]$/.test(fields[0]) ||
      !fields[1].startsWith("supervisor-web/") || fields[1].length > 1_024 ||
      /[\u0000-\u001f\u007f]/.test(fields[1]);
  })) {
    throw new Error("diff supervisor-web fuera de contrato");
  }
  return Object.freeze({
    previousSourceCommit,
    changedFiles: lines.length,
    diffSha256: createHash("sha256").update(diff).digest("hex"),
  });
}

export function assertExternalStateRoot(
  checkoutRoot,
  stateRoot,
  resolvedCheckoutRoot = checkoutRoot,
  resolvedStateRoot = stateRoot,
) {
  const pairs = [
    [normalizeRoot(checkoutRoot), normalizeRoot(stateRoot)],
    [normalizeRoot(resolvedCheckoutRoot), normalizeRoot(resolvedStateRoot)],
  ];
  if (pairs.some(([checkout, state]) => (
    checkout === state || state.startsWith(`${checkout}${sep}`) ||
    checkout.startsWith(`${state}${sep}`)
  ))) {
    throw new Error("StateRoot debe estar separado del checkout");
  }
  return resolve(resolvedStateRoot);
}

export async function verifyContractFiles(projectRoot, contract) {
  const lockPath = join(projectRoot, contract.package_lock_relative_path);
  const packagePath = join(projectRoot, contract.package_json_relative_path);
  await requireRegular(lockPath, 1_048_576);
  await requireRegular(packagePath, 65_536);
  const lockSha256 = await sha256File(lockPath);
  const packageJsonSha256 = await sha256File(packagePath);
  if (lockSha256 !== contract.package_lock_sha256 ||
      packageJsonSha256 !== contract.package_json_sha256) {
    throw new Error("package.json/package-lock no coinciden con el contrato versionado");
  }
  return Object.freeze({ lockSha256, packageJsonSha256 });
}

export async function compareDirectories(leftRoot, rightRoot) {
  const [left, right] = await Promise.all([inventoryDirectory(leftRoot), inventoryDirectory(rightRoot)]);
  if (left.length !== right.length) throw new Error("builds independientes difieren en inventario");
  for (let index = 0; index < left.length; index += 1) {
    const a = left[index];
    const b = right[index];
    if (a.path !== b.path || a.bytes !== b.bytes || a.sha256 !== b.sha256) {
      const relativePath = a.path === b.path ? a.path : "inventario-distinto";
      throw new Error(`builds independientes no son byte-identical: ${relativePath}`);
    }
  }
  return Object.freeze(left);
}

export async function inventoryDirectory(root) {
  const entries = [];
  await walk(resolve(root), resolve(root), entries);
  return entries.sort((a, b) => {
    if (a.path === "MANIFEST.sha256.json") return 1;
    if (b.path === "MANIFEST.sha256.json") return -1;
    return a.path < b.path ? -1 : a.path > b.path ? 1 : 0;
  });
}

async function walk(root, directory, entries) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error("el artefacto no admite symlinks");
    if (entry.isDirectory()) await walk(root, path, entries);
    else if (entry.isFile()) {
      const bytes = await readFile(path);
      entries.push({
        path: relative(root, path).replaceAll("\\", "/"),
        bytes: bytes.byteLength,
        sha256: createHash("sha256").update(bytes).digest("hex"),
      });
    } else throw new Error("tipo de fichero no permitido");
  }
}

async function requireRegular(path, maxBytes) {
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 2 || stat.size > maxBytes) {
    throw new Error("fichero contractual ausente o fuera de límite");
  }
}

async function sha256File(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

function normalizeRoot(path) {
  const normalized = resolve(path).replace(/[\\/]$/, "");
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

function lines(value) {
  return value.split(/\r?\n/).filter((line) => line !== "");
}

export function runDistributionGit(cwd, args, allowMissing = false) {
  const environment = { ...process.env };
  for (const name of Object.keys(environment)) {
    if (name.startsWith("GIT_")) delete environment[name];
  }
  environment.GIT_CONFIG_NOSYSTEM = "1";
  environment.GIT_CONFIG_GLOBAL = process.platform === "win32" ? "NUL" : "/dev/null";
  environment.GIT_OPTIONAL_LOCKS = "0";
  try {
    return execFileSync("git", [...DISTRIBUTION_GIT_PREFIX, "-C", cwd, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: environment,
      timeout: 60_000,
      maxBuffer: 131_072,
    }).trim();
  } catch (cause) {
    if (allowMissing && cause && typeof cause === "object" && "status" in cause && cause.status === 1) {
      return "";
    }
    const category = cause && typeof cause === "object" && "code" in cause && cause.code === "ETIMEDOUT"
      ? "timeout"
      : cause && typeof cause === "object" && "code" in cause && cause.code === "ENOBUFS"
        ? "output-limit"
        : cause && typeof cause === "object" && "status" in cause && Number.isInteger(cause.status)
          ? "exit"
          : "spawn";
    throw new Error(`validación Git local falló (${category})`);
  }
}
