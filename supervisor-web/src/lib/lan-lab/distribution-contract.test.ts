import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  SOURCE_CONTRACT_KEYS,
  assertExternalStateRoot,
  compareDirectories,
  compareSourceUpdate,
  dependencyDecision,
  parseClosedSourceContract,
  validateToolVersions,
  verifyContractFiles,
  verifyDistributionSource,
} from "../../../scripts/distribution-contract.mjs";

const checkout = "/checkout";
const project = `${checkout}/supervisor-web`;
const commit = "1".repeat(40);
const tree = "2".repeat(40);
const repositoryRef = "refs/heads/codex/lan-player-client";
const sourceText = readFileSync("lan-player/source-contract.tsv", "utf8");
const contract = parseClosedSourceContract(sourceText);
const temporaryRoots: string[] = [];

function gitRunner(overrides: Record<string, string | Error> = {}) {
  return (_cwd: string, args: string[]) => {
    const command = args.join(" ");
    const value = overrides[command];
    if (value instanceof Error) throw value;
    if (value !== undefined) return value;
    const defaults: Record<string, string> = {
      "rev-parse --show-toplevel": checkout,
      [`rev-parse --verify ${commit}^{commit}`]: commit,
      "rev-parse HEAD": commit,
      [`rev-parse --verify ${repositoryRef}^{commit}`]: commit,
      "symbolic-ref --quiet HEAD": repositoryRef,
      "status --porcelain=v1 --untracked-files=all": "",
      remote: "origin",
      "config --get-all remote.origin.url": contract.repository_url,
      "config --get-all remote.origin.pushurl": "",
      [`rev-parse ${commit}:supervisor-web`]: tree,
    };
    if (!Object.hasOwn(defaults, command)) throw new Error(`Git inesperado: ${command}`);
    return defaults[command];
  };
}

function request(overrides: Record<string, string> = {}) {
  return {
    checkoutRoot: checkout,
    repositoryUrl: contract.repository_url,
    repositoryRef,
    sourceCommit: commit,
    ...overrides,
  };
}

function tempRoot() {
  const root = mkdtempSync(join(tmpdir(), "teremoq-distribution-"));
  temporaryRoots.push(root);
  return root;
}

afterEach(() => {
  while (temporaryRoots.length > 0) rmSync(temporaryRoots.pop()!, { recursive: true, force: true });
});

describe("contrato de distribución Git del player LAN", () => {
  it("es pequeño, cerrado y fija sólo fuente/lock/herramientas", () => {
    expect(Buffer.byteLength(sourceText, "utf8")).toBeLessThanOrEqual(4_096);
    expect(Object.keys(contract)).toEqual(SOURCE_CONTRACT_KEYS);
    expect(contract.future_repository_boundary).toBe("teremoq-client");
    expect(contract.output_contract).toBe("external-state-root-only");
  });

  it.each([
    ["desconocido", `${sourceText}extra\tvalue\n`],
    ["duplicado", `${sourceText}schema_version\t1\n`],
    ["ausente", sourceText.split("\n").filter((line) => !line.startsWith("node_major\t")).join("\n")],
    ["repositorio distinto", sourceText.replace("https://github.com/Teremoq/teremoq", "https://example.invalid/repo")],
  ])("rechaza contrato %s", (_label, value) => {
    expect(() => parseClosedSourceContract(value)).toThrow();
  });

  it("acepta URL, ref, HEAD, árbol, remote y checkout limpios exactos", () => {
    expect(verifyDistributionSource(project, request(), contract, gitRunner())).toEqual({
      checkoutRoot: checkout,
      sourceCommit: commit,
      sourceTree: tree,
    });
  });

  it.each([
    ["HEAD", "rev-parse HEAD", "3".repeat(40)],
    ["ref", `rev-parse --verify ${repositoryRef}^{commit}`, "3".repeat(40)],
    ["rama", "symbolic-ref --quiet HEAD", "refs/heads/otra"],
    ["sucio", "status --porcelain=v1 --untracked-files=all", "?? extra"],
    ["remote", "config --get-all remote.origin.url", "git@github.com:Teremoq/teremoq.git"],
  ])("rechaza mismatch de %s", (_label, command, value) => {
    expect(() => verifyDistributionSource(
      project, request(), contract, gitRunner({ [command]: value }),
    )).toThrow();
  });

  it("rechaza commit no resoluble y URL/ref no canónicas", () => {
    expect(() => verifyDistributionSource(project, request(), contract, gitRunner({
      [`rev-parse --verify ${commit}^{commit}`]: new Error("unknown"),
    }))).toThrow();
    expect(() => verifyDistributionSource(project, request({ repositoryUrl: "https://example.invalid" }), contract, gitRunner())).toThrow();
    expect(() => verifyDistributionSource(project, request({ repositoryRef: "HEAD" }), contract, gitRunner())).toThrow();
  });

  it("exige Node 22/npm 10 y separa StateRoot del checkout", () => {
    expect(validateToolVersions("v22.14.0", "10.9.2", contract)).toEqual({
      nodeVersion: "v22.14.0", npmVersion: "10.9.2",
    });
    expect(() => validateToolVersions("v20.0.0", "10.9.2", contract)).toThrow();
    expect(() => validateToolVersions("v22.14.0", "11.0.0", contract)).toThrow();
    expect(() => assertExternalStateRoot(checkout, `${checkout}/state`)).toThrow();
    expect(assertExternalStateRoot(checkout, "/external/state")).toBe("/external/state");
  });

  it("reutiliza sólo el lock idéntico y bloquea cambios sin refresh", () => {
    expect(dependencyDecision(null, "a", false)).toBe("initial-npm-ci");
    expect(dependencyDecision("a", "a", false)).toBe("reused-lock-cache");
    expect(() => dependencyDecision("a", "b", false)).toThrow("refresh-dependencies");
    expect(dependencyDecision("a", "b", true)).toBe("explicit-lock-refresh");
  });

  it("compara y sella el diff supervisor-web frente a la generación anterior", () => {
    const previous = "8".repeat(40);
    const diff = "M\tsupervisor-web/package.json\nA\tsupervisor-web/new.ts";
    const compared = compareSourceUpdate(checkout, previous, commit, (_cwd, args) => {
      const command = args.join(" ");
      if (command === `rev-parse --verify ${previous}^{commit}`) return previous;
      if (command === `diff --name-status --no-renames ${previous} ${commit} -- supervisor-web`) {
        return diff;
      }
      throw new Error(`Git inesperado: ${command}`);
    });
    expect(compared).toEqual({
      previousSourceCommit: previous,
      changedFiles: 2,
      diffSha256: createHash("sha256").update(diff).digest("hex"),
    });
    expect(compareSourceUpdate(checkout, null, commit).changedFiles).toBe(0);
  });

  it("rechaza diffs fuera de supervisor-web o con estado/path no cerrado", () => {
    const previous = "8".repeat(40);
    for (const diff of ["M\tinfra/lan/file", "R100\tsupervisor-web/a\tsupervisor-web/b", "M\tsupervisor-web/a\nM\tbad"]) {
      expect(() => compareSourceUpdate(checkout, previous, commit, (_cwd, args) => (
        args[0] === "rev-parse" ? previous : diff
      ))).toThrow();
    }
  });

  it("verifica hashes versionados de package y lock", async () => {
    const root = tempRoot();
    writeFileSync(join(root, "package-lock.json"), "lock\n");
    writeFileSync(join(root, "package.json"), "package\n");
    const local = {
      ...contract,
      package_lock_sha256: createHash("sha256").update("lock\n").digest("hex"),
      package_json_sha256: createHash("sha256").update("package\n").digest("hex"),
    };
    await expect(verifyContractFiles(root, local)).resolves.toEqual({
      lockSha256: local.package_lock_sha256,
      packageJsonSha256: local.package_json_sha256,
    });
    writeFileSync(join(root, "package.json"), "changed\n");
    await expect(verifyContractFiles(root, local)).rejects.toThrow("no coinciden");
  });

  it("exige dos paquetes con inventario y bytes idénticos y sin symlinks", async () => {
    const root = tempRoot();
    const left = join(root, "left");
    const right = join(root, "right");
    mkdirSync(join(left, "nested"), { recursive: true });
    mkdirSync(join(right, "nested"), { recursive: true });
    writeFileSync(join(left, "nested", "a"), "same");
    writeFileSync(join(right, "nested", "a"), "same");
    await expect(compareDirectories(left, right)).resolves.toHaveLength(1);
    writeFileSync(join(right, "nested", "a"), "different");
    await expect(compareDirectories(left, right)).rejects.toThrow("byte-identical");
    rmSync(join(right, "nested", "a"));
    symlinkSync(join(left, "nested", "a"), join(right, "nested", "a"));
    await expect(compareDirectories(left, right)).rejects.toThrow("symlinks");
  });

  it("launcher Windows y orquestador no leen config/evidencia ni ejecutan red Git", () => {
    const launcher = readFileSync("lan-player/Build-LanPlayerFromGit.ps1", "utf8");
    const orchestrator = readFileSync("scripts/distribute-lan-from-git.mjs", "utf8");
    expect(launcher).toContain("Node 22.x and npm 10.x are required");
    expect(launcher).toContain("distribute:lan");
    expect(orchestrator).toContain('"worktree", "add", "--detach"');
    expect(orchestrator).not.toMatch(/\[\s*"(?:clone|fetch|pull|push)"/);
    for (const forbidden of ["LAN-CONFIG.json", "VERSION.tsv", "EvidenceDirectory", "FingerprintPath"]) {
      expect(`${launcher}\n${orchestrator}`).not.toContain(forbidden);
    }
  });
});
