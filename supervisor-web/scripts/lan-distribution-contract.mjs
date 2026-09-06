import { createHash } from "node:crypto";

export const DISTRIBUTION_RECEIPT_KEYS = Object.freeze([
  "schema_version", "status", "build_mode", "player_identity", "source_commit",
  "source_tree", "package_lock_sha256", "node_version", "npm_version",
  "dependency_status", "previous_source_commit", "source_diff_files",
  "source_diff_sha256", "builds_executed", "build_verification",
  "manifest_sha256", "launcher_contract_sha256", "artifact_inventory_sha256",
  "player_relative_path",
]);
export const DEPENDENCY_EVIDENCE_KEYS = Object.freeze([
  "schema_version", "status", "source_commit", "package_lock_sha256",
  "node_version", "npm_version", "cache_relative_path",
]);
export const ARTIFACT_EVIDENCE_KEYS = Object.freeze([
  "schema_version", "status", "player_identity", "source_commit", "source_tree",
  "package_lock_sha256", "node_version", "npm_version", "created_build_mode",
  "created_builds", "build_verification", "manifest_sha256",
  "launcher_contract_sha256", "artifact_inventory_sha256", "player_relative_path",
]);

export function computePlayerIdentity(sourceTree, packageLockSha256) {
  requireHex(sourceTree, 40, "source tree");
  requireHex(packageLockSha256, 64, "package lock");
  const canonical = [
    "schema_version=1", `source_tree=${sourceTree}`,
    `package_lock_sha256=${packageLockSha256}`, "",
  ].join("\n");
  return `sha256:${createHash("sha256").update(canonical).digest("hex")}`;
}

export function playerRelativePath(playerIdentity, sourceCommit) {
  requireIdentity(playerIdentity);
  requireHex(sourceCommit, 40, "source commit");
  return `players/${playerIdentity.replace(":", "-")}/${sourceCommit}`;
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

export function dependencyCacheRelativePath(packageLockSha256, nodeVersion, npmVersion) {
  requireHex(packageLockSha256, 64, "package lock");
  requireRuntime(nodeVersion, npmVersion);
  return `npm-cache/${packageLockSha256}/node-${nodeVersion}/npm-${npmVersion}`;
}

export function createDependencyEvidence(value) {
  return freezeValidated(DEPENDENCY_EVIDENCE_KEYS, {
    schema_version: 1, status: "npm-ci-cache-verified", ...value,
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
  );
  requireHex(current.source_commit, 40, "source commit");
  if (typeof refresh !== "boolean") throw new Error("refresh de dependencias inválido");
  if (previousEvidence === null) {
    return Object.freeze({ status: "created", cache_relative_path: expectedPath });
  }
  validateDependencyEvidence(previousEvidence);
  const matches = previousEvidence.package_lock_sha256 === current.package_lock_sha256 &&
    previousEvidence.node_version === current.node_version &&
    previousEvidence.npm_version === current.npm_version &&
    previousEvidence.cache_relative_path === expectedPath;
  if (matches) return Object.freeze({ status: "reused-verified", cache_relative_path: expectedPath });
  if (!refresh) throw new Error("evidencia de dependencias no coincide; exige refresh explícito");
  return Object.freeze({ status: "refreshed", cache_relative_path: expectedPath });
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
    "player_identity", "source_commit", "source_tree", "package_lock_sha256",
    "node_version", "npm_version", "player_relative_path",
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
  if (value.schema_version !== 1 || value.status !== "npm-ci-cache-verified") {
    throw new Error("evidencia de dependencias fuera de versión/estado");
  }
  requireHex(value.source_commit, 40, "source commit");
  requireHex(value.package_lock_sha256, 64, "package lock");
  requireRuntime(value.node_version, value.npm_version);
  if (value.cache_relative_path !== dependencyCacheRelativePath(
    value.package_lock_sha256, value.node_version, value.npm_version,
  )) throw new Error("path de cache no coincide con lock/runtime");
}

function validateArtifactEvidence(value) {
  requireClosed(value, ARTIFACT_EVIDENCE_KEYS, "evidencia de player");
  if (value.schema_version !== 1 || value.status !== "sealed-player") {
    throw new Error("evidencia de player fuera de versión/estado");
  }
  requireIdentity(value.player_identity);
  requireHex(value.source_commit, 40, "source commit");
  requireHex(value.source_tree, 40, "source tree");
  requireHex(value.package_lock_sha256, 64, "package lock");
  requireRuntime(value.node_version, value.npm_version);
  if (value.player_identity !== computePlayerIdentity(value.source_tree, value.package_lock_sha256) ||
      value.player_relative_path !== playerRelativePath(value.player_identity, value.source_commit)) {
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
  requireIdentity(value.player_identity);
  requireHex(value.source_commit, 40, "source commit");
  requireHex(value.source_tree, 40, "source tree");
  requireHex(value.package_lock_sha256, 64, "package lock");
  requireRuntime(value.node_version, value.npm_version);
  if (value.player_identity !== computePlayerIdentity(value.source_tree, value.package_lock_sha256) ||
      value.player_relative_path !== playerRelativePath(value.player_identity, value.source_commit)) {
    throw new Error("recibo contiene identidad/path incoherentes");
  }
  if (!["created", "reused-verified", "refreshed", "not-used"].includes(value.dependency_status) ||
      !/^(none|[0-9a-f]{40})$/.test(value.previous_source_commit) ||
      !Number.isSafeInteger(value.source_diff_files) || value.source_diff_files < 0 ||
      value.source_diff_files > 4_096) throw new Error("recibo contiene estado/diff inválido");
  requireHex(value.source_diff_sha256, 64, "source diff");
  const built = value.status === "built" && (
    (value.build_mode === "integration" && value.builds_executed === 2 &&
      value.build_verification === "double-build-byte-identical") ||
    (value.build_mode === "node" && value.builds_executed === 1 &&
      value.build_verification === "single-build")
  ) && value.dependency_status !== "not-used";
  const reused = value.status === "reused" && value.builds_executed === 0 &&
    ((value.build_mode === "integration" &&
      value.build_verification === "reused-integration-double") ||
     (value.build_mode === "node" &&
      ["reused-integration-double", "reused-node-single"].includes(value.build_verification))) &&
    value.dependency_status === "not-used" && value.previous_source_commit === "none" &&
    value.source_diff_files === 0 &&
    value.source_diff_sha256 === createHash("sha256").update("").digest("hex");
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
