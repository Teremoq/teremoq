import { createHash } from "node:crypto";
import {
  cp,
  lstat,
  mkdir,
  readFile,
  readdir,
  writeFile,
} from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import {
  BUILD_PROVENANCE_NAME,
  hashRegularFile,
  normalizeEmptyServerReferenceManifests,
  normalizePrerenderManifest,
  normalizeRequiredServerFiles,
  normalizeStandaloneServer,
  readBuildProvenanceFile,
} from "./lan-build-provenance.mjs";
import { verifyPackageSource } from "./verify-package-source.mjs";

const MAX_PACKAGE_BYTES = 128 * 1024 * 1024;
const MAX_LAUNCHER_CONTRACT_BYTES = 4_096;
const PLATFORM_LAUNCHER_NAME = "teremoq-lan-platform.ps1";
const EVIDENCE_VALIDATOR_NAME = "validate-lan-evidence.mjs";
const outputFlag = process.argv.indexOf("--output");
const sourceCommitFlag = process.argv.indexOf("--source-commit");
if (outputFlag === -1 || !process.argv[outputFlag + 1] ||
    sourceCommitFlag === -1 || !process.argv[sourceCommitFlag + 1]) {
  throw new Error(
    "Uso: npm run package:lan -- --output <directorio-nuevo> --source-commit <40 hex>",
  );
}
const sourceCommit = process.argv[sourceCommitFlag + 1];
if (!/^[0-9a-f]{40}$/.test(sourceCommit)) {
  throw new Error("--source-commit debe ser un commit SHA-1 canónico de 40 hex");
}
const packageMetadata = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
if (typeof packageMetadata.version !== "string" ||
    !/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(packageMetadata.version)) {
  throw new Error("package.json no contiene una versión canónica");
}
const packageVersion = packageMetadata.version;

const projectRoot = process.cwd();
const source = verifyPackageSource(projectRoot, sourceCommit);
const standaloneRoot = join(projectRoot, ".next", "standalone");
const standaloneServer = join(standaloneRoot, "server.js");
const buildProvenancePath = join(projectRoot, ".next", BUILD_PROVENANCE_NAME);
const outputRoot = resolve(process.argv[outputFlag + 1]);
const outputRelativeToProject = relative(projectRoot, outputRoot);
if (
  outputRelativeToProject === "" ||
  (!outputRelativeToProject.startsWith("..") && !isAbsolute(outputRelativeToProject))
) {
  throw new Error("El paquete LAN debe escribirse fuera del checkout");
}
await requireRegularFile(standaloneServer, "Ejecuta npm run build:lan antes de empaquetar");
const npmVersion = npmVersionFromEnvironment();
const expectedProvenance = {
  schema_version: 1,
  source_commit: source.sourceCommit,
  source_tree: source.sourceTree,
  package_lock_sha256: await hashRegularFile(join(projectRoot, "package-lock.json"), 1_048_576),
  package_json_sha256: await hashRegularFile(join(projectRoot, "package.json"), 65_536),
  node_version: process.version,
  npm_version: npmVersion,
  build_mode: "lan-standalone",
};
const { text: buildProvenanceBytes } = await readBuildProvenanceFile(
  buildProvenancePath,
  expectedProvenance,
);
try {
  await lstat(outputRoot);
  throw new Error("El directorio de salida ya existe");
} catch (cause) {
  if (cause instanceof Error && "code" in cause && cause.code === "ENOENT") {
    // Un destino nuevo evita mezclar artefactos de generaciones anteriores.
  } else {
    throw cause;
  }
}

await mkdir(outputRoot, { recursive: true });
await cp(standaloneRoot, outputRoot, { recursive: true, errorOnExist: true });
const packagedStandaloneServer = join(outputRoot, "server.js");
await writeFile(
  packagedStandaloneServer,
  normalizeStandaloneServer(await readFile(packagedStandaloneServer, "utf8"), projectRoot),
  { encoding: "utf8" },
);
await cp(join(projectRoot, ".next", "static"), join(outputRoot, ".next", "static"), {
  recursive: true,
  errorOnExist: true,
});
const packagedRequiredServerFiles = join(outputRoot, ".next", "required-server-files.json");
await writeFile(
  packagedRequiredServerFiles,
  normalizeRequiredServerFiles(await readFile(packagedRequiredServerFiles, "utf8"), projectRoot),
  { encoding: "utf8" },
);
const packagedPrerenderManifest = join(outputRoot, ".next", "prerender-manifest.json");
await writeFile(
  packagedPrerenderManifest,
  normalizePrerenderManifest(await readFile(packagedPrerenderManifest, "utf8"), sourceCommit),
  { encoding: "utf8" },
);
const serverReferenceJson = join(outputRoot, ".next", "server", "server-reference-manifest.json");
const serverReferenceJs = join(outputRoot, ".next", "server", "server-reference-manifest.js");
const normalizedServerReferences = normalizeEmptyServerReferenceManifests(
  await readFile(serverReferenceJson, "utf8"),
  await readFile(serverReferenceJs, "utf8"),
  sourceCommit,
);
await Promise.all([
  writeFile(serverReferenceJson, normalizedServerReferences.json, { encoding: "utf8" }),
  writeFile(serverReferenceJs, normalizedServerReferences.js, { encoding: "utf8" }),
]);
await writeFile(
  join(outputRoot, "BUILD-PROVENANCE.json"),
  buildProvenanceBytes,
  { encoding: "utf8", flag: "wx" },
);
await cp(
  join(projectRoot, "scripts", "start-lan-lab.mjs"),
  join(outputRoot, "start.mjs"),
  { errorOnExist: true },
);
const platformLauncherSource = join(projectRoot, "scripts", PLATFORM_LAUNCHER_NAME);
const platformLauncherTarget = join(outputRoot, PLATFORM_LAUNCHER_NAME);
await requireRegularFile(platformLauncherSource, "Falta el launcher cerrado de Platform");
await cp(platformLauncherSource, platformLauncherTarget, { errorOnExist: true });
await cp(
  join(projectRoot, "scripts", EVIDENCE_VALIDATOR_NAME),
  join(outputRoot, EVIDENCE_VALIDATOR_NAME),
  { errorOnExist: true },
);
const launcherSha256 = createHash("sha256")
  .update(await readFile(platformLauncherSource))
  .digest("hex");
const launcherContract = [
  "schema_version\t1",
  `launcher_relative_path\t${PLATFORM_LAUNCHER_NAME}`,
  `launcher_sha256\t${launcherSha256}`,
  "actions\tstart,status,stop,collect",
  "levels\t1,5,10,25",
  "max_clients\t25",
  "network_contract\toutbound_udp_14433_only",
  "loopback_http_only\ttrue",
  `source_commit\t${sourceCommit}`,
  "",
].join("\n");
if (Buffer.byteLength(launcherContract, "utf8") > MAX_LAUNCHER_CONTRACT_BYTES) {
  throw new Error("lan-launcher.tsv supera el límite de 4096 bytes");
}
await writeFile(join(outputRoot, "lan-launcher.tsv"), launcherContract, {
  encoding: "utf8",
  flag: "wx",
});

const files = await inventory(outputRoot);
const totalBytes = files.reduce((total, file) => total + file.bytes, 0);
if (totalBytes > MAX_PACKAGE_BYTES) {
  throw new Error("El paquete LAN supera el límite de 128 MiB");
}
const manifest = {
  schema_version: 1,
  artifact: "teremoq-lan-lab-standalone",
  entrypoint: "start.mjs",
  package_version: packageVersion,
  source_commit: sourceCommit,
  files,
  total_bytes: totalBytes,
};
await writeFile(
  join(outputRoot, "MANIFEST.sha256.json"),
  `${JSON.stringify(manifest, null, 2)}\n`,
  { encoding: "utf8", flag: "wx" },
);
process.stdout.write(
  `Paquete LAN: ${basename(outputRoot)} · ${files.length} ficheros · ${totalBytes} bytes\n`,
);

async function inventory(root) {
  const paths = await walk(root);
  const entries = [];
  for (const path of paths.sort()) {
    const data = await readFile(path);
    entries.push({
      path: relative(root, path).replaceAll("\\", "/"),
      bytes: data.byteLength,
      sha256: createHash("sha256").update(data).digest("hex"),
    });
  }
  return entries;
}

async function walk(directory) {
  const paths = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error("El paquete LAN no admite symlinks");
    if (entry.isDirectory()) paths.push(...await walk(path));
    else if (entry.isFile()) paths.push(path);
    else throw new Error("Tipo de fichero no admitido en el paquete LAN");
  }
  return paths;
}

async function requireRegularFile(path, message) {
  try {
    if ((await lstat(path)).isFile()) return;
  } catch {
    // Se devuelve una razón estable sin revelar rutas locales.
  }
  throw new Error(message);
}

function npmVersionFromEnvironment() {
  const userAgent = process.env.npm_config_user_agent ?? "";
  const match = /(?:^|\s)npm\/(10\.[0-9]+\.[0-9]+)(?:\s|$)/.exec(userAgent);
  if (!match) throw new Error("package:lan exige npm 10.x explícito");
  if (!/^v22\.[0-9]+\.[0-9]+$/.test(process.version)) {
    throw new Error("package:lan exige Node 22.x");
  }
  return match[1];
}
