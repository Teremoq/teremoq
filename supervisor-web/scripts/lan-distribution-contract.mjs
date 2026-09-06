import { createHash } from "node:crypto";

export const DISTRIBUTION_RECEIPT_KEYS = Object.freeze([
  "schema_version", "status", "updater_version", "player_identity", "player_version",
  "config_schema_version", "build_mode", "source_commit", "source_tree",
  "package_lock_sha256", "node_version", "npm_version", "platform", "architecture",
  "dependency_status", "previous_source_commit", "source_diff_files",
  "source_diff_sha256", "builds_executed", "build_verification",
  "manifest_sha256", "launcher_contract_sha256", "artifact_inventory_sha256",
  "player_relative_path",
]);
export const DEPENDENCY_EVIDENCE_KEYS = Object.freeze([
  "schema_version", "status", "package_lock_sha256", "node_version", "npm_version",
  "platform", "architecture", "snapshot_relative_path", "inventory_files",
  "total_bytes", "inventory_sha256",
]);
export const ARTIFACT_EVIDENCE_KEYS = Object.freeze([
  "schema_version", "status", "player_identity", "player_version", "config_schema_version",
  "source_tree", "package_lock_sha256", "node_version", "npm_version", "platform",
  "architecture", "created_build_mode",
  "created_builds", "build_verification", "manifest_sha256",
  "launcher_contract_sha256", "artifact_inventory_sha256", "player_relative_path",
]);
export const UPDATER_VERSION = "2.0.0";
export const CONFIG_SCHEMA_VERSION = 1;

export function computePlayerIdentity(sourceTree, packageLockSha256) {
  requireHex(sourceTree, 40, "source tree");
  requireHex(packageLockSha256, 64, "package lock");
  const canonical = [
    "schema_version=1", `source_tree=${sourceTree}`,
    `package_lock_sha256=${packageLockSha256}`, "",
  ].join("\n");
  return `sha256:${createHash("sha256").update(canonical).digest("hex")}`;
}

export function playerRelativePath(playerIdentity) {
  requireIdentity(playerIdentity);
  return `players/${playerIdentity.replace(":", "-")}`;
}

export function buildCountForMode(buildMode) {
  if (buildMode === "integration") return 2;
  if (buildMode === "node") return 1;
  throw new Error("modo de build fuera de contrato");
}

export function createBuildPlan(buildMode) {
  const count = buildCountForMode(buildMode);
  return Object.freeze(Array.from({ length: count }, (_, index) => Object.freeze({
    checkout: `checkout-${index + 1}`,
    package: `package-${index + 1}`,
  })));
}

export function dependencyCacheRelativePath(
  packageLockSha256, nodeVersion, npmVersion, platform, architecture,
) {
  requireHex(packageLockSha256, 64, "package lock");
  requireRuntime(nodeVersion, npmVersion);
  requireHost(platform, architecture);
  return `dependency-snapshots/${packageLockSha256}/node-${nodeVersion}/npm-${npmVersion}/${platform}-${architecture}`;
}

export function createDependencyEvidence(value) {
  return freezeValidated(DEPENDENCY_EVIDENCE_KEYS, {
    schema_version: 1, status: "npm-ci-snapshot-verified", ...value,
  }, validateDependencyEvidence);
}
export function serializeDependencyEvidence(value) {
  validateDependencyEvidence(value);
  return `${JSON.stringify(value)}\n`;
}
export function parseDependencyEvidence(text) {
  return parseCanonical(text, 4_096, validateDependencyEvidence, serializeDependencyEvidence,
    "evidencia de dependencias");
}

export function decideDependencyCache(previousEvidence, current, refresh) {
  const expectedPath = dependencyCacheRelativePath(
    current.package_lock_sha256, current.node_version, current.npm_version,
    current.platform, current.architecture,
  );
  if (typeof refresh !== "boolean") throw new Error("refresh de dependencias inválido");
  if (previousEvidence === null) {
    return Object.freeze({ status: "snapshot-created", snapshot_relative_path: expectedPath });
  }
  validateDependencyEvidence(previousEvidence);
  const matches = previousEvidence.package_lock_sha256 === current.package_lock_sha256 &&
    previousEvidence.node_version === current.node_version &&
    previousEvidence.npm_version === current.npm_version &&
    previousEvidence.platform === current.platform &&
    previousEvidence.architecture === current.architecture &&
    previousEvidence.snapshot_relative_path === expectedPath;
  if (matches) return Object.freeze({ status: "snapshot-reused-verified", snapshot_relative_path: expectedPath });
  throw new Error("evidencia de dependencias no coincide; snapshot adulterado");
}

export function createArtifactEvidence(value) {
  return freezeValidated(ARTIFACT_EVIDENCE_KEYS, {
    schema_version: 1, status: "sealed-player", ...value,
  }, validateArtifactEvidence);
}
export function serializeArtifactEvidence(value) {
  validateArtifactEvidence(value);
  return `${JSON.stringify(value)}\n`;
}
export function parseArtifactEvidence(text) {
  return parseCanonical(text, 8_192, validateArtifactEvidence, serializeArtifactEvidence,
    "evidencia de player");
}
export function validateReusableArtifact(evidence, expected, requestedMode) {
  validateArtifactEvidence(evidence);
  buildCountForMode(requestedMode);
  for (const key of [
    "player_identity", "player_version", "config_schema_version", "source_tree",
    "package_lock_sha256", "node_version", "npm_version", "platform", "architecture",
    "player_relative_path",
  ]) {
    if (evidence[key] !== expected[key]) throw new Error("player existente no coincide con identidad/runtime");
  }
  if (requestedMode === "integration" && evidence.build_verification !== "double-build-byte-identical") {
    throw new Error("modo integración exige evidencia previa de dos builds idénticos");
  }
  return evidence;
}

export function createDistributionReceipt(value) {
  return freezeValidated(DISTRIBUTION_RECEIPT_KEYS, { schema_version: 1, ...value },
    validateDistributionReceipt);
}
export function serializeDistributionReceipt(value) {
  validateDistributionReceipt(value);
  return `${JSON.stringify(value)}\n`;
}
export function parseDistributionReceipt(text) {
  return parseCanonical(text, 8_192, validateDistributionReceipt,
    serializeDistributionReceipt, "recibo de distribución");
}

function validateDependencyEvidence(value) {
  requireClosed(value, DEPENDENCY_EVIDENCE_KEYS, "evidencia de dependencias");
  if (value.schema_version !== 1 || value.status !== "npm-ci-snapshot-verified") {
    throw new Error("evidencia de dependencias fuera de versión/estado");
  }
  requireHex(value.package_lock_sha256, 64, "package lock");
  requireRuntime(value.node_version, value.npm_version);
  requireHost(value.platform, value.architecture);
  if (value.snapshot_relative_path !== dependencyCacheRelativePath(
    value.package_lock_sha256, value.node_version, value.npm_version,
    value.platform, value.architecture,
  ) || !Number.isSafeInteger(value.inventory_files) || value.inventory_files < 1 ||
      value.inventory_files > 200_000 || !Number.isSafeInteger(value.total_bytes) ||
      value.total_bytes < 1 || value.total_bytes > 1_073_741_824) {
    throw new Error("snapshot de dependencias fuera de contrato");
  }
  requireHex(value.inventory_sha256, 64, "inventario de dependencias");
}

function validateArtifactEvidence(value) {
  requireClosed(value, ARTIFACT_EVIDENCE_KEYS, "evidencia de player");
  if (value.schema_version !== 1 || value.status !== "sealed-player") {
    throw new Error("evidencia de player fuera de versión/estado");
  }
  requireIdentity(value.player_identity);
  requirePlayerVersion(value.player_version, value.config_schema_version);
  requireHex(value.source_tree, 40, "source tree");
  requireHex(value.package_lock_sha256, 64, "package lock");
  requireRuntime(value.node_version, value.npm_version);
  requireHost(value.platform, value.architecture);
  if (value.player_identity !== computePlayerIdentity(value.source_tree, value.package_lock_sha256) ||
      value.player_relative_path !== playerRelativePath(value.player_identity)) {
    throw new Error("identidad/path de player incoherentes");
  }
  const expectedBuilds = buildCountForMode(value.created_build_mode);
  const expectedVerification = value.created_build_mode === "integration"
    ? "double-build-byte-identical" : "single-build";
  if (value.created_builds !== expectedBuilds || value.build_verification !== expectedVerification) {
    throw new Error("evidencia de builds incoherente");
  }
  for (const key of ["manifest_sha256", "launcher_contract_sha256", "artifact_inventory_sha256"]) {
    requireHex(value[key], 64, key);
  }
}

function validateDistributionReceipt(value) {
  requireClosed(value, DISTRIBUTION_RECEIPT_KEYS, "recibo de distribución");
  if (value.schema_version !== 1 || !["built", "reused"].includes(value.status)) {
    throw new Error("recibo fuera de versión/estado");
  }
  buildCountForMode(value.build_mode);
  if (value.updater_version !== UPDATER_VERSION) throw new Error("updater fuera de versión");
  requireIdentity(value.player_identity);
  requirePlayerVersion(value.player_version, value.config_schema_version);
  requireHex(value.source_commit, 40, "source commit");
  requireHex(value.source_tree, 40, "source tree");
  requireHex(value.package_lock_sha256, 64, "package lock");
  requireRuntime(value.node_version, value.npm_version);
  requireHost(value.platform, value.architecture);
  if (value.player_identity !== computePlayerIdentity(value.source_tree, value.package_lock_sha256) ||
      value.player_relative_path !== playerRelativePath(value.player_identity)) {
    throw new Error("recibo contiene identidad/path incoherentes");
  }
  if (!["snapshot-created", "snapshot-reused-verified", "integration-npm-ci", "not-used"].includes(value.dependency_status) ||
      !/^(none|[0-9a-f]{40})$/.test(value.previous_source_commit) ||
      !Number.isSafeInteger(value.source_diff_files) || value.source_diff_files < 0 ||
      value.source_diff_files > 4_096) throw new Error("recibo contiene estado/diff inválido");
  requireHex(value.source_diff_sha256, 64, "source diff");
  const built = value.status === "built" && (
    (value.build_mode === "integration" && value.builds_executed === 2 &&
      value.build_verification === "double-build-byte-identical") ||
    (value.build_mode === "node" && value.builds_executed === 1 &&
      value.build_verification === "single-build")
  ) && ((value.build_mode === "integration" && value.dependency_status === "integration-npm-ci") ||
        (value.build_mode === "node" && ["snapshot-created", "snapshot-reused-verified"].includes(value.dependency_status)));
  const reused = value.status === "reused" && value.builds_executed === 0 &&
    ((value.build_mode === "integration" &&
      value.build_verification === "reused-integration-double") ||
     (value.build_mode === "node" &&
      ["reused-integration-double", "reused-node-single"].includes(value.build_verification))) &&
    value.dependency_status === "not-used";
  if (!built && !reused) throw new Error("recibo contiene conteo/verificación incoherente");
  for (const key of ["manifest_sha256", "launcher_contract_sha256", "artifact_inventory_sha256"]) {
    requireHex(value[key], 64, key);
  }
}

function parseCanonical(text, limit, validate, serialize, label) {
  if (typeof text !== "string" || Buffer.byteLength(text, "utf8") < 3 ||
      Buffer.byteLength(text, "utf8") > limit) throw new Error(`${label} ausente o fuera de límite`);
  let value;
  try { value = JSON.parse(text); } catch { throw new Error(`${label} no es JSON válido`); }
  validate(value);
  if (text !== serialize(value)) throw new Error(`${label} no es JSON canónico cerrado`);
  return Object.freeze(value);
}

function freezeValidated(keys, value, validate) {
  const ordered = {};
  for (const key of keys) {
    if (!Object.hasOwn(value, key)) throw new Error("objeto contractual incompleto");
    ordered[key] = value[key];
  }
  if (Object.keys(value).length !== keys.length) throw new Error("objeto contractual contiene campos extra");
  validate(ordered);
  return Object.freeze(ordered);
}
function requireClosed(value, keys, label) {
  if (!isRecord(value) || Object.keys(value).length !== keys.length ||
      keys.some((key) => !Object.hasOwn(value, key))) throw new Error(`${label} no es cerrado`);
}
function requireRuntime(nodeVersion, npmVersion) {
  if (!/^v22\.[0-9]+\.[0-9]+$/.test(nodeVersion) || !/^10\.[0-9]+\.[0-9]+$/.test(npmVersion)) {
    throw new Error("runtime Node/npm fuera de contrato");
  }
}
function requireHost(platform, architecture) {
  if (platform !== "win32" || architecture !== "x64") {
    throw new Error("plataforma/arquitectura fuera de contrato");
  }
}
function requirePlayerVersion(playerVersion, configSchemaVersion) {
  if (!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(playerVersion) ||
      configSchemaVersion !== CONFIG_SCHEMA_VERSION) {
    throw new Error("versión de player/config fuera de contrato");
  }
}
function requireIdentity(value) {
  if (!/^sha256:[0-9a-f]{64}$/.test(value)) throw new Error("identidad de player inválida");
}
function requireHex(value, length, label) {
  if (typeof value !== "string" || !new RegExp(`^[0-9a-f]{${length}}$`).test(value)) {
    throw new Error(`${label} inválido`);
  }
}
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
