import { execFileSync } from "node:child_process";
import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, parse, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const WINDOWS_POLICY = fileURLToPath(
  new URL("./assert-windows-path-policy.ps1", import.meta.url),
);

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
  if (process.platform === "win32") runNativeWindowsPolicy(absolute, allowMissing);
  return missing;
}

function runNativeWindowsPolicy(path, allowMissing) {
  const args = [
    "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
    "-File", WINDOWS_POLICY, "-Path", path,
  ];
  if (allowMissing) args.push("-AllowMissingLeaf");
  const output = execFileSync("powershell.exe", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 30_000,
    maxBuffer: 16_384,
  }).trim();
  if (!samePath(output, path)) throw new Error("policy Windows devolvió otro path final");
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
