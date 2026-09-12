import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, parse, resolve, win32 } from "node:path";
import { fileURLToPath } from "node:url";

const WINDOWS_POLICY = fileURLToPath(
  new URL("./assert-windows-path-policy.ps1", import.meta.url),
);
export const WINDOWS_HOST_ENV = "TEREMOQ_WEB_POWERSHELL_HOST";
// Reviewed official Windows x64 Core 7.6.6 executable, NOT an observed/env digest.
const WINDOWS_HOST_SHA256 = "bfb46af89433268872ddb43d1ca7a3f433452ee91ed356a9786940f90118e285";
const MAX_WINDOWS_HOST_BYTES = 1_048_576;

export function parseWindowsHostSelection(value) {
  if (typeof value !== "string" || value.length > 4_096 ||
      !/^[A-Za-z]:\\/.test(value) || /[\u0000-\u001f\u007f]/.test(value) ||
      win32.normalize(value) !== value || win32.basename(value).toLowerCase() !== "pwsh.exe") {
    throw new Error("selected Core7 host path is missing or outside the closed policy");
  }
  return value;
}

export async function pinSecureDirectoryPath(path, options = {}) {
  const absolute = resolveAbsolute(path);
  const missing = await validateAncestry(absolute, options.allowMissing === true);
  if (missing) return Object.freeze({ path: absolute, missing: true });
  const stat = await lstat(absolute);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error("path seguro debe ser directorio real");
  }
  if (process.platform === "win32") {
    const resolvedPath = await realpath(absolute);
    if (!samePath(resolvedPath, absolute)) throw new Error("path final resuelve fuera de sí mismo");
    return Object.freeze({
      path: absolute,
      missing: false,
      realPath: resolvedPath,
      dev: stat.dev,
      ino: stat.ino,
      birthtimeMs: stat.birthtimeMs,
    });
  }
  const handle = await open(absolute, constants.O_RDONLY);
  try {
    const handleStat = await handle.stat();
    if (!handleStat.isDirectory()) throw new Error("handle no identifica directorio");
    const resolvedPath = await realpath(absolute);
    if (!samePath(resolvedPath, absolute)) throw new Error("path final resuelve fuera de sí mismo");
    return Object.freeze({
      path: absolute,
      missing: false,
      realPath: resolvedPath,
      dev: handleStat.dev,
      ino: handleStat.ino,
      birthtimeMs: handleStat.birthtimeMs,
    });
  } finally {
    await handle.close();
  }
}

export async function revalidateSecureDirectoryPin(pin) {
  if (!pin || pin.missing === true) throw new Error("no se puede revalidar un path no fijado");
  const current = await pinSecureDirectoryPath(pin.path);
  if (!samePath(current.realPath, pin.realPath) || current.dev !== pin.dev ||
      current.ino !== pin.ino || current.birthtimeMs !== pin.birthtimeMs) {
    throw new Error("identidad del directorio cambió después de fijarla");
  }
  return current;
}

export async function revalidateSecureDirectoryPins(...pins) {
  for (const pin of pins) await revalidateSecureDirectoryPin(pin);
}

/**
 * @param {string} path
 * @param {number | undefined} expectedBytes
 */
export async function pinSecureRegularFile(path, expectedBytes = undefined) {
  const absolute = resolveAbsolute(path);
  await validateAncestry(dirname(absolute), false);
  const stat = await lstat(absolute);
  if (!stat.isFile() || stat.isSymbolicLink() ||
      (expectedBytes !== undefined && stat.size !== expectedBytes)) {
    throw new Error("path seguro debe ser fichero regular esperado");
  }
  const handle = await open(absolute, constants.O_RDONLY);
  try {
    const handleStat = await handle.stat();
    const resolvedPath = await realpath(absolute);
    if (!handleStat.isFile() || !samePath(resolvedPath, absolute) ||
        (expectedBytes !== undefined && handleStat.size !== expectedBytes)) {
      throw new Error("handle no identifica el fichero regular esperado");
    }
    return Object.freeze({
      path: absolute,
      realPath: resolvedPath,
      dev: handleStat.dev,
      ino: handleStat.ino,
      birthtimeMs: handleStat.birthtimeMs,
      size: handleStat.size,
    });
  } finally {
    await handle.close();
  }
}

export async function revalidateSecureRegularFilePin(pin) {
  if (!pin) throw new Error("pin de fichero ausente");
  const current = await pinSecureRegularFile(pin.path, pin.size);
  if (!samePath(current.realPath, pin.realPath) || current.dev !== pin.dev ||
      current.ino !== pin.ino || current.birthtimeMs !== pin.birthtimeMs) {
    throw new Error("identidad del fichero cambió después de fijarla");
  }
  return current;
}

async function validateAncestry(absolute, allowMissing) {
  const missing = await validateFilesystemAncestry(absolute, allowMissing);
  if (process.platform === "win32") await runNativeWindowsPolicy(absolute, allowMissing);
  return missing;
}

// Non-recursive primitive also used BEFORE loading the selected runtime.
// Full Windows reparse attributes remain checked by the native policy and
// Platform's prerequisite that the runtime installation is stable/protected.
async function validateFilesystemAncestry(absolute, allowMissing) {
  const { root } = parse(absolute);
  const relative = absolute.slice(root.length);
  const segments = relative.split(/[\\/]/).filter(Boolean);
  let current = root;
  let missing = false;
  for (const segment of segments) {
    current = join(current, segment);
    try {
      const stat = await lstat(current);
      if (stat.isSymbolicLink()) throw new Error("path rechaza symlink/junction ancestral");
      if (!stat.isDirectory()) throw new Error("ancestro de path no es directorio");
      const resolved = await realpath(current);
      if (!samePath(resolved, current)) throw new Error("ancestro resuelve mediante reparse/junction");
    } catch (cause) {
      if (cause && typeof cause === "object" && "code" in cause && cause.code === "ENOENT") {
        missing = true;
        break;
      }
      throw cause;
    }
  }
  if (missing && !allowMissing) throw new Error("path seguro no existe");
  return missing;
}

async function runNativeWindowsPolicy(path, allowMissing) {
  const host = parseWindowsHostSelection(process.env[WINDOWS_HOST_ENV]);
  await validateFilesystemAncestry(dirname(host), false);
  const entry = await lstat(host);
  if (!entry.isFile() || entry.isSymbolicLink() || !samePath(await realpath(host), host)) {
    throw new Error("selected Core7 host must be a canonical regular file");
  }
  const handle = await open(host, constants.O_RDONLY);
  try {
    const before = await handle.stat();
    if (!before.isFile() || before.size < 1 || before.size > MAX_WINDOWS_HOST_BYTES ||
        before.dev !== entry.dev || before.ino !== entry.ino || before.size !== entry.size) {
      throw new Error("selected Core7 host identity or size is invalid");
    }
    const bytes = Buffer.alloc(before.size + 1);
    let length = 0;
    while (length < bytes.length) {
      const read = await handle.read(bytes, length, bytes.length - length, length);
      if (read.bytesRead === 0) break;
      length += read.bytesRead;
    }
    const after = await handle.stat();
    const current = await lstat(host);
    if (length !== before.size || after.size !== before.size || after.mtimeMs !== before.mtimeMs ||
        after.dev !== before.dev || after.ino !== before.ino ||
        current.dev !== before.dev || current.ino !== before.ino || current.size !== before.size || !current.isFile() ||
        current.isSymbolicLink() || !samePath(await realpath(host), host) ||
        createHash("sha256").update(bytes.subarray(0, length)).digest("hex") !== WINDOWS_HOST_SHA256) {
      throw new Error("selected Core7 host changed or fingerprint does not match");
    }
    // Keep the descriptor open through execution. This is NOT an atomic
    // hash-to-exec pin: Platform must keep the selected runtime/ancestors
    // protected and stable; pathname replacement remains a residual boundary.
    return executeWindowsPolicy(host, path, allowMissing);
  } finally {
    await handle.close();
  }
}

function executeWindowsPolicy(host, path, allowMissing) {
  const args = [
    "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
    "-File", WINDOWS_POLICY, "-Path", path,
  ];
  if (allowMissing) args.push("-AllowMissingLeaf");
  const output = execFileSync(host, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 30_000,
    maxBuffer: 16_384,
  }).trim();
  if (!output || !isAbsolute(output) || /[\r\n\u0000]/.test(output) || !samePath(output, path)) {
    throw new Error("policy Windows devolvió otro path final");
  }
}

function resolveAbsolute(path) {
  if (typeof path !== "string" || !isAbsolute(path) || path.length > 4_096 || /[\r\n]/.test(path)) {
    throw new Error("path absoluto fuera de contrato");
  }
  return resolve(path);
}

function samePath(left, right) {
  const normalize = (value) => {
    const result = resolve(value).replace(/[\\/]$/, "");
    return process.platform === "win32" ? result.toLowerCase() : result;
  };
  return normalize(left) === normalize(right);
}
