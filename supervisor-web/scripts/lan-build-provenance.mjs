import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";

export const BUILD_PROVENANCE_NAME = "TEREMOQ-LAN-BUILD.json";
export const BUILD_PROVENANCE_KEYS = Object.freeze([
  "schema_version",
  "source_commit",
  "source_tree",
  "package_lock_sha256",
  "package_json_sha256",
  "node_version",
  "npm_version",
  "build_mode",
]);

export async function hashRegularFile(path, maxBytes) {
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 2 || stat.size > maxBytes) {
    throw new Error("fichero de procedencia ausente o fuera de límite");
  }
  const bytes = await readFile(path);
  if (bytes.byteLength !== stat.size) throw new Error("fichero cambió durante lectura");
  return createHash("sha256").update(bytes).digest("hex");
}

export function serializeBuildProvenance(value) {
  validateBuildProvenance(value);
  return `${JSON.stringify(value, null, 2)}\n`;
}

export function parseBuildProvenance(text, expected) {
  if (typeof text !== "string" || Buffer.byteLength(text, "utf8") > 4_096) {
    throw new Error("procedencia de build ausente o fuera de límite");
  }
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error("procedencia de build no es JSON válido");
  }
  validateBuildProvenance(value);
  for (const key of BUILD_PROVENANCE_KEYS) {
    if (value[key] !== expected[key]) {
      throw new Error("build LAN no coincide con fuente/herramientas actuales");
    }
  }
  return Object.freeze(value);
}

export async function readBuildProvenanceFile(path, expected) {
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 2 || stat.size > 4_096) {
    throw new Error("procedencia de build ausente o fuera de límite");
  }
  const text = await readFile(path, "utf8");
  if (Buffer.byteLength(text, "utf8") !== stat.size) {
    throw new Error("procedencia de build cambió durante lectura");
  }
  return { text, value: parseBuildProvenance(text, expected) };
}

export function normalizePrerenderManifest(text, sourceCommit) {
  if (typeof text !== "string" || Buffer.byteLength(text, "utf8") > 1_048_576 ||
      !/^[0-9a-f]{40}$/.test(sourceCommit)) {
    throw new Error("prerender manifest fuera de límite");
  }
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error("prerender manifest no es JSON válido");
  }
  const previewKeys = [
    "previewModeId",
    "previewModeSigningKey",
    "previewModeEncryptionKey",
  ];
  if (!isRecord(value) || !isRecord(value.preview) ||
      Object.keys(value.preview).length !== previewKeys.length ||
      previewKeys.some((key) => !Object.hasOwn(value.preview, key)) ||
      !/^[0-9a-f]{32}$/.test(value.preview.previewModeId) ||
      !/^[0-9a-f]{64}$/.test(value.preview.previewModeSigningKey) ||
      !/^[0-9a-f]{64}$/.test(value.preview.previewModeEncryptionKey)) {
    throw new Error("preview metadata fuera del contrato Next 16 fijado");
  }
  value.preview = {
    previewModeId: derive("id", sourceCommit).slice(0, 32),
    previewModeSigningKey: derive("signing", sourceCommit),
    previewModeEncryptionKey: derive("encryption", sourceCommit),
  };
  return `${JSON.stringify(value)}\n`;
}

export function normalizeRequiredServerFiles(text, projectRoot) {
  if (typeof text !== "string" || Buffer.byteLength(text, "utf8") > 1_048_576 ||
      typeof projectRoot !== "string" || projectRoot.length < 2 || projectRoot.length > 1_024) {
    throw new Error("required-server-files fuera de límite");
  }
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error("required-server-files no es JSON válido");
  }
  if (!isRecord(value) || !isRecord(value.config) || !isRecord(value.config.turbopack) ||
      value.appDir !== projectRoot || value.config.outputFileTracingRoot !== projectRoot ||
      value.config.repoRoot !== projectRoot || value.config.turbopack.root !== projectRoot) {
    throw new Error("paths de build Next 16 fuera del contrato fijado");
  }
  value.appDir = ".";
  value.config.outputFileTracingRoot = ".";
  value.config.repoRoot = ".";
  value.config.turbopack.root = ".";
  const normalized = `${JSON.stringify(value, null, 2)}\n`;
  if (normalized.includes(projectRoot)) {
    throw new Error("required-server-files conserva un path local inesperado");
  }
  return normalized;
}

export function normalizeEmptyServerReferenceManifests(jsonText, jsText, sourceCommit) {
  if (typeof jsonText !== "string" || typeof jsText !== "string" ||
      Buffer.byteLength(jsonText, "utf8") > 65_536 ||
      Buffer.byteLength(jsText, "utf8") > 131_072 ||
      !/^[0-9a-f]{40}$/.test(sourceCommit) ||
      jsText !== `self.__RSC_SERVER_MANIFEST=${JSON.stringify(jsonText)}`) {
    throw new Error("server reference manifests no coinciden");
  }
  let value;
  try {
    value = JSON.parse(jsonText);
  } catch {
    throw new Error("server reference manifest no es JSON válido");
  }
  if (!isRecord(value) || Object.keys(value).length !== 3 ||
      !isRecord(value.node) || Object.keys(value.node).length !== 0 ||
      !isRecord(value.edge) || Object.keys(value.edge).length !== 0 ||
      typeof value.encryptionKey !== "string" ||
      !/^[A-Za-z0-9+/]{43}=$/.test(value.encryptionKey)) {
    throw new Error("Server Actions no está vacío o queda fuera de contrato");
  }
  value.encryptionKey = Buffer.from(derive("server-actions-disabled", sourceCommit), "hex")
    .toString("base64");
  const json = JSON.stringify(value, null, 2);
  return Object.freeze({
    json,
    js: `self.__RSC_SERVER_MANIFEST=${JSON.stringify(json)}`,
  });
}

export function normalizeStandaloneServer(text, projectRoot) {
  if (typeof text !== "string" || Buffer.byteLength(text, "utf8") > 65_536 ||
      typeof projectRoot !== "string" || projectRoot.length < 2 || projectRoot.length > 1_024) {
    throw new Error("standalone server fuera de límite");
  }
  const marker = "const nextConfig = ";
  const suffix = "\n\nprocess.env.__NEXT_PRIVATE_STANDALONE_CONFIG = JSON.stringify(nextConfig)";
  const start = text.indexOf(marker);
  const end = text.indexOf(suffix);
  if (start === -1 || end === -1 || start !== text.lastIndexOf(marker) ||
      end !== text.lastIndexOf(suffix) || end <= start + marker.length) {
    throw new Error("plantilla standalone Next 16 fuera de contrato");
  }
  let config;
  try {
    config = JSON.parse(text.slice(start + marker.length, end));
  } catch {
    throw new Error("nextConfig standalone no es JSON válido");
  }
  if (!isRecord(config) || !isRecord(config.turbopack) ||
      config.outputFileTracingRoot !== projectRoot || config.repoRoot !== projectRoot ||
      config.turbopack.root !== projectRoot) {
    throw new Error("paths standalone Next 16 fuera del contrato fijado");
  }
  config.outputFileTracingRoot = ".";
  config.repoRoot = ".";
  config.turbopack.root = ".";
  const normalized = `${text.slice(0, start + marker.length)}${JSON.stringify(config)}${text.slice(end)}`;
  if (normalized.includes(projectRoot)) {
    throw new Error("standalone server conserva un path local inesperado");
  }
  return normalized;
}

function validateBuildProvenance(value) {
  if (!isRecord(value) || Object.keys(value).length !== BUILD_PROVENANCE_KEYS.length ||
      BUILD_PROVENANCE_KEYS.some((key) => !Object.hasOwn(value, key)) ||
      value.schema_version !== 1 ||
      !/^[0-9a-f]{40}$/.test(value.source_commit) ||
      !/^[0-9a-f]{40}$/.test(value.source_tree) ||
      !/^[0-9a-f]{64}$/.test(value.package_lock_sha256) ||
      !/^[0-9a-f]{64}$/.test(value.package_json_sha256) ||
      !/^v22\.[0-9]+\.[0-9]+$/.test(value.node_version) ||
      !/^10\.[0-9]+\.[0-9]+$/.test(value.npm_version) ||
      value.build_mode !== "lan-standalone") {
    throw new Error("procedencia de build fuera de contrato cerrado");
  }
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function derive(purpose, sourceCommit) {
  return createHash("sha256")
    .update(`teremoq-lan-next-preview-disabled-v1\0${purpose}\0${sourceCommit}`)
    .digest("hex");
}
