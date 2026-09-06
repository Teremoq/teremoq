import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  pinSecureDirectoryPath,
  pinSecureRegularFile,
  revalidateSecureDirectoryPin,
  revalidateSecureRegularFilePin,
} from "../../../scripts/path-security.mjs";

const roots: string[] = [];
function tempRoot() {
  const root = mkdtempSync(join(tmpdir(), "teremoq-path-policy-"));
  roots.push(root);
  return root;
}

afterEach(() => {
  while (roots.length > 0) rmSync(roots.pop()!, { recursive: true, force: true });
});

describe("paths externos fijados y sin reparse ancestral", () => {
  it("el canario PS5 obtiene ExitCode del proceso y verifica el reparse real", () => {
    const script = readFileSync(join(
      process.cwd(),
      "scripts",
      "test-windows-path-policy.ps1",
    ), "utf8");
    expect(script).not.toContain("$LASTEXITCODE");
    expect(script).toContain("Diagnostics.ProcessStartInfo");
    expect(script).toContain("$process.ExitCode");
    expect(script).toContain("[IO.FileAttributes]::ReparsePoint");
    expect(script).toContain("$process.WaitForExit(10000)");
    expect(script).toContain("Assert-MklinkFailureCaptured $parentJunction $checkout");
  }, 15_000);

  it("acepta y revalida una cadena real estable", async () => {
    const root = tempRoot();
    const state = join(root, "state", "players");
    mkdirSync(state, { recursive: true });
    const pin = await pinSecureDirectoryPath(state);
    await expect(revalidateSecureDirectoryPin(pin)).resolves.toMatchObject({ path: state });
  }, 15_000);

  it("rechaza symlink/junction como padre o componente intermedio", async () => {
    const root = tempRoot();
    const real = join(root, "real");
    mkdirSync(join(real, "nested"), { recursive: true });
    const parentAlias = join(root, "parent-alias");
    symlinkSync(real, parentAlias, process.platform === "win32" ? "junction" : "dir");
    await expect(pinSecureDirectoryPath(join(parentAlias, "generated"), {
      allowMissing: true,
    })).rejects.toThrow(/symlink|junction|reparse/);

    const state = join(root, "state");
    mkdirSync(state);
    const intermediate = join(state, "cache");
    symlinkSync(real, intermediate, process.platform === "win32" ? "junction" : "dir");
    await expect(pinSecureDirectoryPath(join(intermediate, "lock"), {
      allowMissing: true,
    })).rejects.toThrow(/symlink|junction|reparse/);
  }, 15_000);

  it("detecta sustitución del directorio después de fijarlo", async () => {
    const root = tempRoot();
    const state = join(root, "state");
    const moved = join(root, "moved");
    mkdirSync(state);
    const pin = await pinSecureDirectoryPath(state);
    renameSync(state, moved);
    mkdirSync(state);
    await expect(revalidateSecureDirectoryPin(pin)).rejects.toThrow("identidad");
  }, 15_000);

  it("fija también los npmrc vacíos por handle e identidad", async () => {
    const root = tempRoot();
    const config = join(root, "empty.npmrc");
    const moved = join(root, "moved.npmrc");
    writeFileSync(config, "");
    const pin = await pinSecureRegularFile(config, 0);
    await expect(revalidateSecureRegularFilePin(pin)).resolves.toMatchObject({ size: 0 });
    renameSync(config, moved);
    writeFileSync(config, "");
    await expect(revalidateSecureRegularFilePin(pin)).rejects.toThrow("identidad");
  }, 15_000);
});
