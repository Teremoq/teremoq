import { execFileSync } from "node:child_process";
import { lstat, readFile } from "node:fs/promises";
import { join } from "node:path";

export function buildIsolatedNpmEnvironment(processEnvironment, isolation) {
  const env = Object.create(null);
  const executablePath = processEnvironment.PATH ?? processEnvironment.Path;
  if (typeof executablePath === "string") env.PATH = executablePath;
  for (const key of [
    "SystemRoot", "SYSTEMROOT", "ComSpec", "PATHEXT",
    "TEMP", "TMP", "TMPDIR", "LANG", "LC_ALL",
  ]) {
    if (typeof processEnvironment[key] === "string") env[key] = processEnvironment[key];
  }
  Object.assign(env, {
    CI: "1",
    NO_COLOR: "1",
    NEXT_TELEMETRY_DISABLED: "1",
    npm_config_audit: "false",
    npm_config_fund: "false",
    npm_config_update_notifier: "false",
    HOME: isolation.home,
    USERPROFILE: isolation.userProfile,
    APPDATA: isolation.appData,
    LOCALAPPDATA: isolation.localAppData,
    npm_config_cache: isolation.cache,
    npm_config_userconfig: isolation.userConfig,
    NPM_CONFIG_USERCONFIG: isolation.userConfig,
    npm_config_globalconfig: isolation.globalConfig,
    NPM_CONFIG_GLOBALCONFIG: isolation.globalConfig,
    npm_config_prefix: isolation.prefix,
    NPM_CONFIG_PREFIX: isolation.prefix,
    npm_config_registry: "https://registry.npmjs.org/",
    NPM_CONFIG_REGISTRY: "https://registry.npmjs.org/",
  });
  return Object.freeze(env);
}

export async function rejectProjectNpmConfiguration(checkoutRoot, projectRoot) {
  for (const candidate of [join(checkoutRoot, ".npmrc"), join(projectRoot, ".npmrc")]) {
    try {
      await lstat(candidate);
      throw new Error(".npmrc de proyecto no está permitido");
    } catch (cause) {
      if (cause && typeof cause === "object" && "code" in cause && cause.code === "ENOENT") continue;
      throw cause;
    }
  }
}

export async function requireEmptyRegularNpmConfig(path) {
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== 0 ||
      (await readFile(path)).byteLength !== 0) {
    throw new Error("npmrc aislado debe ser fichero regular vacío");
  }
}

export function verifyEffectiveNpmConfiguration(npmCli, cwd, env, runner = defaultRunner) {
  const raw = runner(npmCli, cwd, env);
  if (typeof raw !== "string" || Buffer.byteLength(raw, "utf8") > 131_072) {
    throw new Error("configuración npm efectiva fuera de límite");
  }
  let config;
  try {
    config = JSON.parse(raw);
  } catch {
    throw new Error("configuración npm efectiva no es JSON");
  }
  if (!isRecord(config) || config.userconfig !== env.npm_config_userconfig ||
      config.globalconfig !== env.npm_config_globalconfig ||
      config.cache !== env.npm_config_cache || config.prefix !== env.npm_config_prefix ||
      config.registry !== "https://registry.npmjs.org/") {
    throw new Error("npm no aplica exclusivamente la configuración aislada");
  }
  for (const key of [
    "_auth", "_authToken", "username", "password", "cert", "key", "cafile",
    "https-proxy", "proxy",
  ]) {
    if (Object.hasOwn(config, key) && config[key] !== null && config[key] !== "" &&
        config[key] !== false) {
      throw new Error("npm conserva credenciales/proxy fuera de contrato");
    }
  }
  return true;
}

function defaultRunner(npmCli, cwd, env) {
  return execFileSync(process.execPath, [npmCli, "config", "list", "--json"], {
    cwd,
    env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 30_000,
    maxBuffer: 131_072,
  });
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
