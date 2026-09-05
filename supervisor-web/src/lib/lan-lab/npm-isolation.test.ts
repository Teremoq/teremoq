import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  buildIsolatedNpmEnvironment,
  rejectProjectNpmConfiguration,
  requireEmptyRegularNpmConfig,
  verifyEffectiveNpmConfiguration,
} from "../../../scripts/npm-isolation.mjs";

const roots: string[] = [];
function isolationFixture() {
  const root = mkdtempSync(join(tmpdir(), "teremoq-npm-isolation-"));
  roots.push(root);
  const directories = ["home", "user", "app", "local-app", "prefix", "cache"];
  for (const directory of directories) mkdirSync(join(root, directory));
  const userConfig = join(root, "empty-user.npmrc");
  const globalConfig = join(root, "empty-global.npmrc");
  writeFileSync(userConfig, "");
  writeFileSync(globalConfig, "");
  return {
    root,
    paths: {
      home: join(root, "home"),
      userProfile: join(root, "user"),
      appData: join(root, "app"),
      localAppData: join(root, "local-app"),
      prefix: join(root, "prefix"),
      cache: join(root, "cache"),
      userConfig,
      globalConfig,
    },
  };
}

afterEach(() => {
  while (roots.length > 0) rmSync(roots.pop()!, { recursive: true, force: true });
});

describe("aislamiento completo de configuración npm", () => {
  it("normaliza PATH sin conservar la variante hostil de Windows", () => {
    const { paths } = isolationFixture();
    const env = buildIsolatedNpmEnvironment({
      PATH: "C:\\approved-node;C:\\approved-git",
      Path: "C:\\hostile",
    }, paths);
    expect(env.PATH).toBe("C:\\approved-node;C:\\approved-git");
    expect(Object.hasOwn(env, "Path")).toBe(false);
  });

  it("sustituye HOME/perfiles/config global hostil y no hereda credenciales", () => {
    const { root, paths } = isolationFixture();
    const hostile = join(root, "hostile-global.npmrc");
    writeFileSync(hostile, [
      "registry=https://hostile.invalid/",
      "//hostile.invalid/:_authToken=DO_NOT_READ_THIS_TOKEN",
      "proxy=http://credential-like@hostile.invalid/",
      "",
    ].join("\n"));
    const env = buildIsolatedNpmEnvironment({
      ...process.env,
      HOME: "/host-home",
      USERPROFILE: "/host-profile",
      APPDATA: "/host-appdata",
      LOCALAPPDATA: "/host-local-appdata",
      NPM_CONFIG_GLOBALCONFIG: hostile,
      npm_config_registry: "https://hostile.invalid/",
      npm_config__authToken: "DO_NOT_READ_THIS_TOKEN",
    }, paths);
    expect(env.HOME).toBe(paths.home);
    expect(env.USERPROFILE).toBe(paths.userProfile);
    expect(env.NPM_CONFIG_GLOBALCONFIG).toBe(paths.globalConfig);
    expect(JSON.stringify(env)).not.toContain("DO_NOT_READ_THIS_TOKEN");
    const npmCli = process.env.npm_execpath;
    expect(npmCli).toBeTruthy();
    expect(verifyEffectiveNpmConfiguration(resolve(npmCli!), process.cwd(), env)).toBe(true);
  });

  it("rechaza npmrc de checkout o proyecto y exige configs vacías regulares", async () => {
    const { root, paths } = isolationFixture();
    const checkout = join(root, "checkout");
    const project = join(checkout, "supervisor-web");
    mkdirSync(project, { recursive: true });
    await expect(rejectProjectNpmConfiguration(checkout, project)).resolves.toBeUndefined();
    writeFileSync(join(project, ".npmrc"), "registry=https://hostile.invalid/\n");
    await expect(rejectProjectNpmConfiguration(checkout, project)).rejects.toThrow("no está permitido");
    await expect(requireEmptyRegularNpmConfig(paths.userConfig)).resolves.toBeUndefined();
    writeFileSync(paths.userConfig, "token=forged\n");
    await expect(requireEmptyRegularNpmConfig(paths.userConfig)).rejects.toThrow("vacío");
  });

  it("rechaza una configuración efectiva con auth/proxy aunque las rutas coincidan", () => {
    const { paths } = isolationFixture();
    const env = buildIsolatedNpmEnvironment(process.env, paths);
    const otherwiseValid = {
      userconfig: paths.userConfig,
      globalconfig: paths.globalConfig,
      cache: paths.cache,
      prefix: paths.prefix,
      registry: "https://registry.npmjs.org/",
      proxy: "http://hostile.invalid/",
    };
    expect(() => verifyEffectiveNpmConfiguration("npm", process.cwd(), env, () => (
      JSON.stringify(otherwiseValid)
    ))).toThrow("credenciales/proxy");
  });
});
